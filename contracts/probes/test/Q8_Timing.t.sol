// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

interface IManagerAdmin {
    function pauseAll() external;
}

interface IVaultFactoryView {
    function validate(address quote, uint256 graduation, bytes calldata vaultData)
        external
        view
        returns (bool);
}

/// @notice Q8. Timing and griefing facts: who can move the tax and when, what sync() does, what the pause
///         switches do to claim and to buys, anti-snipe, and the launch-time rules (LaunchLogic.validate).
contract Q8_Timing is ProbeBase {
    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;

    address internal constant NATIVE = address(0);
    bytes4 internal constant PAUSED = 0x9e87fac8;

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        vm.label(address(probe), "probe (recipient)");
        (token, vault) = _launch(_defaultCfg(address(probe)));
        vm.deal(address(probe), 100 ether);
    }

    // ───────────────────────── claimFor by anyone, at any time ─────────────────────────

    function test_Q8_anyone_can_claimFor_at_any_time_and_it_front_runs_the_recipients_own_claim() public {
        _buy(alice, address(token), 1 ether);

        // a stranger pushes the tax out just before the recipient would have claimed it
        vm.prank(bob);
        vault.claimFor(address(probe), NATIVE);
        assertEq(address(probe).balance, 100 ether + 0.03 ether, "the money arrived outside any call of ours");

        // the recipient's own claim in the same block now REVERTS: it must be inside try/catch
        (bool ok, bytes memory err, uint256 delta,) = probe.tryClaim(vault, NATIVE);
        assertFalse(ok);
        assertEq(_sel(err), IDirectedVault.NothingToClaim.selector);
        assertEq(delta, 0);

        // no cooldown and no per-block limit: buy, push, buy, claim, all in one block
        _buy(alice, address(token), 1 ether);
        vm.prank(bob);
        vault.claimFor(address(probe), NATIVE);
        _buy(alice, address(token), 1 ether);
        (ok,, delta,) = probe.tryClaim(vault, NATIVE);
        assertTrue(ok);
        assertEq(delta, 0.03 ether);
        assertEq(address(probe).balance, 100 ether + 0.09 ether, "nothing lost, whoever triggers the payout");
    }

    /// @dev A design option, not an IGNIX rule: if receive() only accepts the vault while the recipient is
    ///      inside its own claim, a stranger's native claimFor fails harmlessly and native tax can only ever
    ///      arrive inside the recipient's own call. (Token pushes have no hook and cannot be gated.)
    function test_Q8_receive_gated_to_own_claim_makes_third_party_native_pushes_revert() public {
        probe.setMode(RecipientProbe.Mode.OnlyOwnClaim);
        probe.setKnown(address(vault), true);
        _buy(alice, address(token), 1 ether);

        vm.prank(bob);
        vm.expectRevert(IDirectedVault.TransferFailed.selector);
        vault.claimFor(address(probe), NATIVE);
        assertEq(address(vault).balance, 0.03 ether, "the tax waits in the vault");

        // even the recipient's claim fails unless it raised its own flag first
        vm.expectRevert(IDirectedVault.TransferFailed.selector);
        probe.claim(vault, NATIVE);

        (uint256 ret, uint256 delta) = probe.claimGated(vault, NATIVE);
        assertEq(ret, 0.03 ether);
        assertEq(delta, 0.03 ether, "and arrives only inside the recipient's own claim");
    }

    // ───────────────────────── sync() ─────────────────────────

    function test_Q8_sync_is_a_noop_for_the_directed_vault() public {
        _buy(alice, address(token), 1 ether);
        uint256 bal = address(vault).balance;

        vm.record();
        vm.recordLogs();
        vm.prank(bob);
        vault.sync();
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(vault));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the only storage it touches is slot 0, the reentrancy guard (set to 2, then back to 1)
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], bytes32(0), "sync wrote a slot other than the reentrancy guard");
        }
        for (uint256 i; i < reads.length; ++i) {
            assertEq(reads[i], bytes32(0));
        }
        assertEq(uint256(vm.load(address(vault), bytes32(0))), 1, "guard restored");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(vault), "sync emitted an event");
        }
        assertEq(address(vault).balance, bal, "sync moved nothing");
        assertEq(vault.claimableNow(address(probe), NATIVE), bal);
        console2.log("sync(): storage writes", writes.length, "logs from vault", uint256(0));
    }

    // ───────────────────────── pause switches ─────────────────────────

    function _pause(uint256 kind, uint64 until) internal {
        vm.prank(M.owner());
        M.setPaused(kind, until);
    }

    function test_Q8_BUY_pause_blocks_buys_but_not_claims() public {
        _buy(alice, address(token), 1 ether);
        _pause(IgnixPause.BUY, type(uint64).max); // the BUY pause may be indefinite
        assertEq(M.pausedUntil(1), type(uint64).max);

        vm.prank(alice);
        vm.expectRevert(IIgnixManager.Paused.selector);
        M.buy{value: 1 ether}(address(token), 1 ether, 0);

        (bool ok, bytes memory err,,) = probe.tryBuyTo(M, address(token), 0.5 ether, 0, address(probe));
        assertFalse(ok);
        assertEq(_sel(err), PAUSED, "buyTo reverts Paused()");
        assertEq(address(probe).balance, 100 ether, "msg.value came back");

        // claim is NOT gated by the BUY switch
        (, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(delta, 0.03 ether);

        // sells stay open under a BUY pause
        uint256 bal = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(M), bal);
        M.sell(address(token), bal, 0);
        vm.stopPrank();
    }

    function test_Q8_DIVIDEND_pause_blocks_claim_and_claimFor_for_at_most_72h_per_call() public {
        _buy(alice, address(token), 1 ether);

        // capped: 72 hours per call
        vm.prank(M.owner());
        vm.expectRevert(IIgnixManager.FreezeTooLong.selector);
        M.setPaused(IgnixPause.DIVIDEND, uint64(block.timestamp + 72 hours + 1));

        uint64 until = uint64(block.timestamp + 72 hours);
        _pause(IgnixPause.DIVIDEND, until);

        (bool ok, bytes memory err, uint256 delta, uint256 gasUsed) = probe.tryClaim(vault, NATIVE);
        assertFalse(ok);
        assertEq(_sel(err), PAUSED, "claim reverts Paused()");
        assertEq(delta, 0);
        console2.log("failed claim (Paused) gas", gasUsed);

        vm.prank(bob);
        vm.expectRevert(IDirectedVault.Paused.selector);
        vault.claimFor(address(probe), NATIVE);

        // the view does not know about the pause: it still reports the balance
        assertEq(vault.claimableNow(address(probe), NATIVE), 0.03 ether);
        // tax keeps accruing and buys keep working while claims are frozen
        (ok,,,) = probe.tryBuyTo(M, address(token), 0.5 ether, 0, address(probe));
        assertTrue(ok, "buyTo is not gated by the DIVIDEND switch");
        assertEq(address(vault).balance, 0.03 ether + 0.015 ether);

        // one second before expiry: still frozen; at expiry: open again, nothing lost
        vm.warp(until - 1);
        (ok,,,) = probe.tryClaim(vault, NATIVE);
        assertFalse(ok);
        vm.warp(until);
        (ok,, delta,) = probe.tryClaim(vault, NATIVE);
        assertTrue(ok);
        assertEq(delta, 0.045 ether);
    }

    function test_Q8_pauseAll_after_graduation_freezes_claims_but_not_v2_buys_or_transfers() public {
        (uint256 locked,,) = probe.buyTo(M, address(token), 1 ether, 0, address(probe));
        _graduate(address(token));
        vm.prank(alice);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(
            0, _path(WOKB, address(token)), alice, block.timestamp
        );

        vm.prank(M.owner());
        IManagerAdmin(address(M)).pauseAll();
        assertEq(M.pausedUntil(IgnixPause.DIVIDEND), block.timestamp + 72 hours, "user-funds paths: 72 h");
        assertEq(M.pausedUntil(IgnixPause.BUY), type(uint64).max, "platform paths: indefinite");

        // both claims are frozen
        (bool ok, bytes memory err,,) = probe.tryClaim(vault, address(token));
        assertFalse(ok);
        assertEq(_sel(err), PAUSED);
        (ok, err,,) = probe.tryClaim(vault, NATIVE);
        assertFalse(ok);
        assertEq(_sel(err), PAUSED);

        // the Uniswap V2 leg and plain token transfers do not read the Manager's switches
        (uint256 got,) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, DEAD);
        assertGt(got, 0, "router buy to 0xdEaD under pauseAll");
        probe.tokenTransfer(address(token), DEAD, locked);
        assertEq(token.balanceOf(DEAD), got + locked);

        // after 72 h the claims reopen by themselves
        vm.warp(block.timestamp + 72 hours);
        (ok,,,) = probe.tryClaim(vault, address(token));
        assertTrue(ok);
        (ok,,,) = probe.tryClaim(vault, NATIVE);
        assertTrue(ok);
    }

    // ───────────────────────── anti-snipe ─────────────────────────

    function test_Q8_snipeBpsNow_decays_linearly_and_the_surcharge_goes_to_the_platform() public {
        LaunchCfg memory cfg = _defaultCfg(address(probe));
        cfg.snipeStartBps = 5_000;
        cfg.snipeMins = 30;
        (IIgnixToken t, IDirectedVault v) = _launch(cfg);
        uint256 t0 = block.timestamp;

        assertEq(M.snipeBpsNow(address(t)), 5_000, "at creation");
        vm.warp(t0 + 1);
        assertEq(M.snipeBpsNow(address(t)), (uint256(5_000) * 1_799) / 1_800, "one second in: 4997");
        vm.warp(t0 + 15 minutes);
        assertEq(M.snipeBpsNow(address(t)), 2_500, "half way");

        // a 1 OKB buy now pays 1% + 3% + 25% = 29%; only the 3% reaches the vault
        uint256 plat0 = M.platformAccrued(address(0));
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(_curve(address(t)), 2_500, 1 ether);
        uint256 out = _buy(alice, address(t), 1 ether);
        assertEq(out, q.tokensOut);
        assertEq(address(v).balance, 0.03 ether, "vault gets taxBuyBps only");
        assertEq(M.platformAccrued(address(0)) - plat0, 0.26 ether, "platform gets 1% + the 25% surcharge");
        assertEq(q.net, 0.71 ether);

        vm.warp(t0 + 30 minutes - 1);
        assertEq(M.snipeBpsNow(address(t)), 2, "last second: 5000 / 1800 rounded down");
        vm.warp(t0 + 30 minutes);
        assertEq(M.snipeBpsNow(address(t)), 0, "window over");
        vm.warp(t0 + 365 days);
        assertEq(M.snipeBpsNow(address(t)), 0);
    }

    function test_Q8_anti_snipe_is_optional_and_bounded_by_LaunchLogic() public {
        // optional: the default fixture launched with snipeStartBps = 0
        CurveToken memory t = _tok(address(token));
        assertEq(t.snipeStartBps, 0);
        assertEq(t.snipeMins, 0);
        assertEq(M.snipeBpsNow(address(token)), 0);

        bytes4 feeTooHigh = IIgnixManager.FeeTooHigh.selector;
        assertEq(feeTooHigh, bytes4(0xcd4e6167));
        _expectLaunchRevert(_snipeCfg(1_999, 30, 300), feeTooHigh); // below MIN_SNIPE_BPS
        _expectLaunchRevert(_snipeCfg(9_001, 30, 300), feeTooHigh); // above MAX_SNIPE_BPS
        _expectLaunchRevert(_snipeCfg(5_000, 0, 300), feeTooHigh); // window of zero minutes
        _expectLaunchRevert(_snipeCfg(9_000, 30, 500), feeTooHigh); // 9000 + 100 + 500 > MAX_TOTAL_BPS 9500
        _launch(_snipeCfg(2_000, 1, 300)); // lower bound ok
        _launch(_snipeCfg(9_000, 30, 400)); // 9000 + 100 + 400 = 9500 ok
        _launch(_snipeCfg(0, 0, 300)); // disabled ok
    }

    function _snipeCfg(uint16 startBps, uint16 mins, uint16 taxBuy)
        internal
        view
        returns (LaunchCfg memory c)
    {
        c = _defaultCfg(address(probe));
        c.snipeStartBps = startBps;
        c.snipeMins = mins;
        c.taxBuyBps = taxBuy;
    }

    function _expectLaunchRevert(LaunchCfg memory c, bytes4 sel) internal {
        uint256 pk = _overrideSigner();
        CreateArgs memory a = _createArgs(c);
        _signArgs(pk, creator, a);
        vm.deal(creator, creator.balance + a.p.firstBuy);
        vm.prank(creator);
        vm.expectRevert(sel);
        M.createToken{value: a.p.firstBuy}(
            a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig
        );
    }

    // ───────────────────────── tax, venue and protection bounds ─────────────────────────

    function test_Q8_tax_and_protection_bounds() public {
        LaunchCfg memory c = _defaultCfg(address(probe));
        c.taxBuyBps = 1_001;
        _expectLaunchRevert(c, IIgnixManager.FeeTooHigh.selector); // MAX_PROJECT_TAX_BPS = 1000

        c = _defaultCfg(address(probe));
        c.taxBuyBps = 0;
        c.taxSellBps = 0;
        _expectLaunchRevert(c, IIgnixManager.BadValue.selector); // a V2 (Directed) launch must tax

        c = _defaultCfg(address(probe));
        c.protectionSecs = 1 days - 1;
        _expectLaunchRevert(c, IIgnixManager.BadValue.selector); // MIN_PROTECTION_DURATION = 1 day

        // on-chain a single taxed side is enough, and 10% / 10% is the ceiling
        c = _defaultCfg(address(probe));
        c.taxBuyBps = 0;
        c.taxSellBps = 100;
        _launch(c);
        c.taxBuyBps = 1_000;
        c.taxSellBps = 1_000;
        c.protectionSecs = 1 days;
        (IIgnixToken t,) = _launch(c);
        assertEq(t.protectionDuration(), 1 days);
    }

    // ───────────────────────── firstBuy ─────────────────────────

    function test_Q8_firstBuy_is_optional_zero_is_accepted() public view {
        // the default fixture launched with firstBuy = 0 and msg.value = 0
        CurveToken memory t = _tok(address(token));
        assertEq(t.sold, 0, "nothing sold at launch");
        assertEq(t.collected, 0);
        assertEq(token.balanceOf(creator), 0, "the creator holds no token");
        assertEq(token.balanceOf(address(M)), 1_000_000_000 ether, "whole supply in the Manager");
        assertEq(address(vault).balance, 0);
        assertEq(t.creator, creator);
    }

    function test_Q8_nonzero_firstBuy_trades_in_the_creating_tx_and_pays_tax_into_the_vault() public {
        LaunchCfg memory c = _defaultCfg(address(probe));
        c.firstBuy = 0.4 ether;
        c.snipeStartBps = 5_000; // the first buy is exempt from anti-snipe
        c.snipeMins = 30;
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(_freshCurve(300), 0, 0.4 ether);
        (IIgnixToken t, IDirectedVault v) = _launch(c);
        assertEq(t.balanceOf(creator), q.tokensOut, "creator received the first-buy tokens, anti-snipe free");
        assertEq(address(v).balance, 0.012 ether, "3% of the creator's own 0.4 OKB is now vault tax");
        assertEq(_tok(address(t)).sold, q.tokensOut);
    }

    function _freshCurve(uint256 taxBuyBps) internal pure returns (CurveQuote.Curve memory c) {
        uint256 C = 800_000_000 ether;
        uint256 D = 200_000_000 ether;
        uint256 T = (C * C) / (C - D);
        uint256 E = (85 ether * (T - C)) / C;
        c = CurveQuote.Curve({
            buyFeeBps: 100, taxBuyBps: taxBuyBps, vQuote: E, vToken: T, sold: 0, sellable: C
        });
    }

    // ───────────────────────── admission: the platform signature ─────────────────────────

    function test_Q8_launch_needs_the_signer_and_binds_sender_deadline_and_value() public {
        uint256 pk = _overrideSigner();
        CreateArgs memory a = _createArgs(_defaultCfg(address(probe)));
        _signArgs(pk, creator, a);

        // a different msg.sender cannot use the creator's signature
        vm.prank(bob);
        vm.expectRevert(IIgnixManager.BadSignature.selector);
        M.createToken(a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig);

        // a different recipient invalidates the signature (vaultData is signed)
        bytes memory otherVaultData = abi.encode(bob);
        vm.prank(creator);
        vm.expectRevert(IIgnixManager.BadSignature.selector);
        M.createToken(
            a.p, TEMPLATE_DIRECTED, otherVaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig
        );

        // msg.value must equal listingFee + firstBuy (here 0)
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(IIgnixManager.BadValue.selector);
        M.createToken{value: 1}(
            a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig
        );

        // expired
        vm.warp(uint256(a.deadline) + 1);
        vm.prank(creator);
        vm.expectRevert(IIgnixManager.SignatureExpired.selector);
        M.createToken(a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig);
    }

    function test_Q8_real_platform_signer_is_required_on_mainnet_state() public {
        // a brand-new fork with untouched storage: our throwaway signature is rejected
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", DEFAULT_RPC), PINNED_BLOCK);
        assertEq(M.signer(), PLATFORM_SIGNER);
        (, uint256 pk) = makeAddrAndKey("covenant-probes fork-only signer");
        CreateArgs memory a = _createArgs(_defaultCfg(address(0xC0FFEE)));
        _signArgs(pk, creator, a);
        vm.prank(creator);
        vm.expectRevert(IIgnixManager.BadSignature.selector);
        M.createToken(a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig);
    }

    // ───────────────────────── the Directed factory's own admission check ─────────────────────────

    function test_Q8_directed_factory_validate_accepts_any_nonzero_recipient() public view {
        IVaultFactoryView f = IVaultFactoryView(IgnixAddresses.DIRECTED_FACTORY);
        assertTrue(f.validate(address(0), 85 ether, abi.encode(address(probe))), "a deployed contract");
        assertTrue(
            f.validate(address(0), 85 ether, abi.encode(address(0xC0FFEE))), "an address with no code yet"
        );
        assertTrue(f.validate(address(0), 85 ether, abi.encode(DEAD)), "0xdEaD");
        bool zeroOk = f.validate(address(0), 85 ether, abi.encode(address(0)));
        console2.log("validate(recipient = address(0))", zeroOk);
        assertFalse(zeroOk, "the zero recipient is refused");
    }
}
