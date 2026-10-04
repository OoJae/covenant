// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Q3. A contract buying on the curve with buyTo, and what it can do with the tokens before
///         graduation.
contract Q3_BuyTo is ProbeBase {
    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;

    bytes32 internal constant PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        vm.label(address(probe), "probe (recipient)");
        (token, vault) = _launch(_defaultCfg(address(probe)));
        vm.deal(address(probe), 10 ether);
    }

    function _predictedPair() internal view returns (address) {
        (address t0, address t1) = address(token) < WOKB ? (address(token), WOKB) : (WOKB, address(token));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", M.V2_FACTORY(), keccak256(abi.encodePacked(t0, t1)), PAIR_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    // ───────────────────────── buyTo from a contract ─────────────────────────

    function test_Q3_buyTo_from_contract_delivers_exact_quoted_tokens_to_itself() public {
        uint256 amt = 0.5 ether;
        uint256 expected = CurveQuote.tokensOut(_curve(address(token)), M.snipeBpsNow(address(token)), amt);

        vm.recordLogs();
        (uint256 got, uint256 spent, uint256 gasUsed) =
            probe.buyTo(M, address(token), amt, expected, address(probe));

        assertEq(got, expected, "tokens received != on-chain quote");
        assertEq(token.balanceOf(address(probe)), expected);
        assertEq(spent, amt, "no refund on a normal buy");
        console2.log("buyTo 0.5 OKB -> tokens (wei)", got);
        console2.log("buyTo gas (first buy on a fresh curve)", gasUsed);

        // the Trade event names the RECIPIENT as trader
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(M) && logs[i].topics[0] == IIgnixManager.Trade.selector) {
                found = true;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(token)))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(probe)))));
            }
        }
        assertTrue(found);
    }

    function test_Q3_buy_by_the_vaults_own_recipient_pays_tax_back_to_its_vault() public {
        assertFalse(token.taxExempt(address(probe)), "the recipient is not tax exempt");
        uint256 amt = 1 ether;
        uint256 v0 = address(vault).balance;
        probe.buyTo(M, address(token), amt, 0, address(probe));
        uint256 taxBack = address(vault).balance - v0;
        assertEq(taxBack, (amt * 300) / 10_000, "tax on the recipient's own buy");
        // and it can claim it straight back: a kernel buy of X returns X * taxBuyBps / 1e4 next epoch
        (, uint256 delta,) = probe.claim(vault, address(0));
        assertEq(delta, 0.03 ether);
    }

    function test_Q3_tax_exempt_flags() public view {
        assertTrue(token.taxExempt(address(vault)), "vault");
        assertTrue(token.taxExempt(address(M)), "manager");
        assertTrue(token.taxExempt(M.V2_LOCKER()), "V2 LP locker");
        assertTrue(token.taxExempt(M.LIQUIDITY_HELPER()), "liquidity helper");
        assertFalse(token.taxExempt(address(probe)), "recipient / kernel");
        assertFalse(token.taxExempt(DEAD), "0xdEaD");
        assertFalse(token.taxExempt(address(ROUTER)), "router");
        assertFalse(token.taxExempt(creator), "creator");
        assertEq(token.taxSink(), address(vault));
        assertEq(token.taxBuyBps(), 300);
        assertEq(token.taxSellBps(), 300);
        // same on the live OB token
        IIgnixToken ob = IIgnixToken(OB_TOKEN);
        assertTrue(ob.taxExempt(OB_VAULT));
        assertFalse(ob.taxExempt(OB_RECIPIENT));
    }

    // ───────────────────────── tokens are transfer-locked on the curve ─────────────────────────

    function test_Q3_tokens_cannot_move_before_graduation_CurveOnly() public {
        (uint256 got,,) = probe.buyTo(M, address(token), 1 ether, 0, address(probe));
        bytes4 curveOnly = IIgnixToken.CurveOnly.selector;
        assertEq(curveOnly, bytes4(0x9dabc49b));

        bool ok;
        bytes memory err;

        // to 0xdEaD
        (ok, err,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (DEAD, got)));
        assertFalse(ok, "transfer to dead");
        assertEq(_sel(err), curveOnly);

        // to another address
        (ok, err,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (alice, 1)));
        assertFalse(ok, "transfer to EOA");
        assertEq(_sel(err), curveOnly);

        // to its own vault
        (ok, err,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (address(vault), 1)));
        assertFalse(ok, "transfer to vault");
        assertEq(_sel(err), curveOnly);

        // to itself
        (ok, err,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (address(probe), 1)));
        assertFalse(ok, "self transfer");
        assertEq(_sel(err), curveOnly);

        // zero-value transfer
        (ok, err,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (alice, 0)));
        assertFalse(ok, "zero-value transfer");
        assertEq(_sel(err), curveOnly);

        // to the future pair
        (ok, err,) =
            probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (_predictedPair(), 1)));
        assertFalse(ok, "transfer to future pair");
        assertEq(_sel(err), curveOnly);

        // approve works, but a third party's transferFrom does not
        (ok,,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.approve, (alice, got)));
        assertTrue(ok, "approve");
        vm.prank(alice);
        vm.expectRevert(curveOnly);
        token.transferFrom(address(probe), alice, 1);

        assertEq(token.balanceOf(address(probe)), got, "nothing moved");
    }

    /// @dev The only two ways out before graduation both go through the Manager.
    function test_Q3_the_only_exits_before_graduation_are_the_manager() public {
        (uint256 got,,) = probe.buyTo(M, address(token), 1 ether, 0, address(probe));

        // (a) a plain transfer TO the Manager succeeds: the tokens are simply gifted to the Manager
        uint256 m0 = token.balanceOf(address(M));
        (bool ok, bytes memory err,) =
            probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (address(M), got / 4)));
        console2.log("transfer to manager ok?", ok);
        console2.logBytes(err);
        assertTrue(ok, "transfer to manager");
        assertEq(token.balanceOf(address(M)) - m0, got / 4);
        CurveToken memory t = _tok(address(token));
        assertEq(t.sold, got, "curve accounting ignores the gift: it is a pure loss for the sender");

        // (b) selling back to the curve (approve + sell) works for a contract and pays native OKB
        uint256 rest = token.balanceOf(address(probe));
        (ok,,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.approve, (address(M), rest)));
        assertTrue(ok);
        uint256 n0 = address(probe).balance;
        uint256 v0 = address(vault).balance;
        (ok, err,) = probe.exec(address(M), 0, abi.encodeCall(IIgnixManager.sell, (address(token), rest, 0)));
        assertTrue(ok, "sell from contract");
        assertGt(address(probe).balance - n0, 0, "sell proceeds in native OKB");
        assertGt(address(vault).balance - v0, 0, "sell tax to the vault");
        console2.log("sell proceeds (wei)", address(probe).balance - n0);
    }

    // ───────────────────────── buyTo argument rules ─────────────────────────

    function test_Q3_buyTo_rejects_bad_recipients_and_bad_value() public {
        bytes4 badValue = IIgnixManager.BadValue.selector;
        assertEq(badValue, bytes4(0x0bba69fb));

        (bool ok, bytes memory err,,) = probe.tryBuyTo(M, address(token), 0.1 ether, 0, address(0));
        assertFalse(ok);
        assertEq(_sel(err), badValue, "recipient 0");

        (ok, err,,) = probe.tryBuyTo(M, address(token), 0.1 ether, 0, address(M));
        assertFalse(ok);
        assertEq(_sel(err), badValue, "recipient manager");

        (ok, err,,) = probe.tryBuyTo(M, address(token), 0.1 ether, 0, _predictedPair());
        assertFalse(ok);
        assertEq(_sel(err), badValue, "recipient future pair");

        // msg.value must equal amountIn exactly
        bool ok2;
        (ok2, err,) = probe.exec(
            address(M),
            0.1 ether,
            abi.encodeCall(IIgnixManager.buyTo, (address(token), 0.2 ether, 0, address(probe)))
        );
        assertFalse(ok2);
        assertEq(_sel(err), badValue, "value mismatch");

        // slippage
        uint256 q = CurveQuote.tokensOut(_curve(address(token)), 0, 0.1 ether);
        (ok, err,,) = probe.tryBuyTo(M, address(token), 0.1 ether, q + 1, address(probe));
        assertFalse(ok);
        assertEq(_sel(err), IIgnixManager.Slippage.selector);
        assertEq(bytes4(IIgnixManager.Slippage.selector), bytes4(0x7dd37f70));

        // zero buy
        (ok, err,,) = probe.tryBuyTo(M, address(token), 0, 0, address(probe));
        assertFalse(ok);
        assertEq(_sel(err), IIgnixManager.SoldOut.selector);
        assertEq(bytes4(IIgnixManager.SoldOut.selector), bytes4(0x52df9fe5));

        // not an IGNIX token
        (ok2, err,) = probe.exec(
            address(M),
            0.1 ether,
            abi.encodeCall(IIgnixManager.buyTo, (address(0xBEEF), 0.1 ether, 0, address(probe)))
        );
        assertFalse(ok2);
        assertEq(_sel(err), IIgnixManager.NotFound.selector);
        assertEq(bytes4(IIgnixManager.NotFound.selector), bytes4(0xc5723b51));
    }

    function test_Q3_buyTo_recipient_can_be_dead_or_anyone_and_third_parties_can_gift() public {
        // straight to 0xdEaD: allowed, the Manager is the sender so the curve lock does not apply
        (uint256 got,,) = probe.buyTo(M, address(token), 0.1 ether, 0, DEAD);
        assertGt(got, 0);
        assertEq(token.balanceOf(DEAD), got);

        // anybody can push locked tokens INTO the probe
        uint256 p0 = token.balanceOf(address(probe));
        vm.prank(alice);
        M.buyTo{value: 0.1 ether}(address(token), 0.1 ether, 0, address(probe));
        assertGt(token.balanceOf(address(probe)) - p0, 0, "gifted tokens arrive");
    }
}
