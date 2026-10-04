// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Q6 (+ Q-A and Q-B). Forced graduation of a native-OKB Directed token on the fork and
///         everything the recipient contract sees afterwards.
///
///         setUp: full launch (tax 3% / 3%, recipient = probe), the probe buys 1 OKB on the curve (those
///         tokens are locked in it), alice buys 2 OKB, nobody claims, then a whale buys out the curve.
contract Q6_Graduation is ProbeBase {
    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;
    address internal pair;

    uint256 internal lockedBefore; // tokens the probe bought on the curve
    uint256 internal nativeTaxBeforeGrad;
    uint256 internal whaleCost;
    uint256 internal graduatedAt;

    address internal constant NATIVE = address(0);
    bytes32 internal constant PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    /// @dev the platform's push operator: DirectedVaultFactory.0x2761dbab()
    address internal constant PUSH_OPERATOR = 0xcc8D1916A96319A0Cdcde1897DAB61d34322FeFe;

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        vm.label(address(probe), "probe (recipient)");
        (token, vault) = _launch(_defaultCfg(address(probe)));
        vm.deal(address(probe), 100 ether);

        (lockedBefore,,) = probe.buyTo(M, address(token), 1 ether, 0, address(probe));
        _buy(alice, address(token), 2 ether);
        nativeTaxBeforeGrad = address(vault).balance; // 3% of 3 OKB, left unclaimed on purpose

        whaleCost = CurveQuote.costToGraduate(_curve(address(token)), 0);
        pair = _graduate(address(token));
        graduatedAt = block.timestamp;
    }

    // ───────────────────────── the graduation itself ─────────────────────────

    function test_Q6_whale_buyout_graduates_to_the_official_uniswap_v2_pair() public view {
        // Manager configuration, as the brief assumed
        assertEq(M.V2_ROUTER02(), 0x182a927119D56008d921126764bF884221b10f59, "router");
        assertEq(M.WRAPPED_NATIVE(), 0xe538905cf8410324e03A5A23C1c177a474D59b2b, "WOKB");
        assertEq(ROUTER.WETH(), WOKB);
        assertEq(ROUTER.factory(), M.V2_FACTORY());

        // pairOf is the graduated flag; it is the canonical CREATE2 pair of (token, WOKB)
        assertEq(M.pairOf(address(token)), pair);
        assertEq(IUniswapV2Factory(M.V2_FACTORY()).getPair(address(token), WOKB), pair);
        (address t0, address t1) = address(token) < WOKB ? (address(token), WOKB) : (WOKB, address(token));
        address predicted = address(
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
        assertEq(pair, predicted, "pair address is predictable before graduation");

        // opening reserves: the whole DEX allocation and the whole net raise
        (uint256 rToken, uint256 rWokb) = _reserves(pair, address(token));
        CurveToken memory t = _tok(address(token));
        assertEq(rToken, 200_000_000 ether, "token reserve = D");
        assertEq(rWokb, t.collected, "WOKB reserve = collected");
        assertEq(rWokb, 85 ether, "exactly the 85 OKB graduation threshold");
        assertEq(t.sold, t.sellable, "curve sold out");
        assertEq(t.poolId, bytes32(0), "V2 graduation leaves poolId zero");
        assertEq(token.balanceOf(address(M)), 0, "the Manager holds no token any more");

        // token side
        assertTrue(token.unlocked(), "transfers unlocked");
        assertEq(token.pair(), pair);
        assertTrue(token.pools(pair), "the pair is a taxed pool");
        assertFalse(token.taxExempt(pair));
        assertTrue(token.protectionActive(), "protection window open");
        assertEq(token.protectionEndsAt(), graduatedAt + 8_640_000, "100 days from graduation");

        // LP is locked: everything but Uniswap's MINIMUM_LIQUIDITY sits in the V2 locker
        uint256 lp = IUniswapV2Pair(pair).totalSupply();
        assertEq(IUniswapV2Pair(pair).balanceOf(M.V2_LOCKER()), lp - 1_000);

        // the whale's own buy paid 3% tax in native OKB to the vault, inside the graduating tx
        assertEq(address(vault).balance - nativeTaxBeforeGrad, (whaleCost * 300) / 10_000);
        console2.log("whale gross cost to finish the curve (wei)", whaleCost);
        console2.log("native tax in vault after graduation (wei)", address(vault).balance);
    }

    function test_Q6_curve_buy_buyTo_and_sell_revert_Graduated_() public {
        bytes4 graduated = IIgnixManager.Graduated_.selector;
        assertEq(graduated, bytes4(0x735c0da7));

        vm.prank(alice);
        vm.expectRevert(graduated);
        M.buy{value: 1 ether}(address(token), 1 ether, 0);

        (bool ok, bytes memory err,, uint256 gasUsed) =
            probe.tryBuyTo(M, address(token), 0.1 ether, 0, address(probe));
        assertFalse(ok);
        assertEq(_sel(err), graduated, "buyTo");
        console2.log("failed buyTo after graduation, gas", gasUsed);
        assertEq(address(probe).balance, 100 ether - 1 ether, "the msg.value came back with the revert");

        uint256 bal = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(M), bal);
        vm.expectRevert(graduated);
        M.sell(address(token), bal, 0);
        vm.stopPrank();

        // snipeBpsNow and tokens() keep answering after graduation
        assertEq(M.snipeBpsNow(address(token)), 0);
        assertEq(
            CurveQuote.maxNonGraduatingBuy(_curve(address(token)), 0), 0, "helper returns 0 when sold out"
        );
    }

    // ───────────────────────── Q-A: where the token tax sits and what moves it ─────────────────────────

    function _v2Buy(address who, uint256 amountIn) internal returns (uint256 received) {
        uint256 b0 = token.balanceOf(who);
        vm.prank(who);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            0, _path(WOKB, address(token)), who, block.timestamp
        );
        received = token.balanceOf(who) - b0;
    }

    function _v2Sell(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(ROUTER), amount);
        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, _path(address(token), WOKB), who, block.timestamp
        );
        vm.stopPrank();
    }

    function test_Q6_QA_v2_trades_put_project_token_tax_straight_into_the_vault() public {
        assertEq(token.taxSink(), address(vault), "taxSink is the vault");
        assertEq(token.balanceOf(address(vault)), 0);
        uint256 vaultNative = address(vault).balance;

        // buy
        (uint256 rToken, uint256 rWokb) = _reserves(pair, address(token));
        (uint256 gross, uint256 tax, uint256 net) = V2TaxQuote.buyOut(1 ether, rWokb, rToken, 300);
        uint256 received = _v2Buy(alice, 1 ether);
        assertEq(received, net, "buyer receives gross - 3%");
        assertEq(token.balanceOf(address(vault)), tax, "buy tax is in the vault, in the project token");
        assertEq(tax, (gross * 300) / 10_000);
        assertEq(token.balanceOf(address(token)), 0, "the token contract holds nothing in between");

        // sell
        uint256 sellAmt = received / 2;
        _v2Sell(alice, sellAmt);
        assertEq(
            token.balanceOf(address(vault)),
            tax + (sellAmt * 300) / 10_000,
            "sell tax = 3% of the amount sold"
        );
        assertEq(token.balanceOf(address(token)), 0);

        // V2 trades never touch the vault's native balance: after graduation new tax is token-only
        assertEq(address(vault).balance, vaultNative);
        // and it is claimable at once, with no sync and no waiting
        assertEq(vault.claimableNow(address(probe), address(token)), token.balanceOf(address(vault)));
    }

    function test_Q6_claim_token_delivers_project_tokens_to_the_contract_recipient() public {
        _v2Buy(alice, 1 ether);
        _v2Sell(alice, token.balanceOf(alice) / 2);

        uint256 claimable = vault.claimableNow(address(probe), address(token));
        assertEq(claimable, token.balanceOf(address(vault)), "claimableNow == vault token balance");
        assertGt(claimable, 0);

        (uint256 ret, uint256 delta, uint256 gasUsed) = probe.claim(vault, address(token));
        assertEq(ret, claimable, "return value");
        assertEq(
            delta, claimable, "balance delta == claimableNow (the vault is tax exempt, nothing is skimmed)"
        );
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(probe)), lockedBefore + claimable);
        console2.log("claim(token) delivered (wei)", delta);
        console2.log("claim(token) gas, during protection", gasUsed);
    }

    function test_Q6_claimFor_token_by_a_third_party_pushes_to_the_recipient() public {
        _v2Buy(alice, 1 ether);
        uint256 claimable = vault.claimableNow(address(probe), address(token));
        uint256 p0 = token.balanceOf(address(probe));

        vm.prank(bob);
        uint256 ret = vault.claimFor(address(probe), address(token));

        assertEq(ret, claimable);
        assertEq(token.balanceOf(address(probe)) - p0, claimable, "delta == claimableNow");
        assertEq(token.balanceOf(bob), 0);
        // a token push does NOT call the recipient: no receive(), no hook
        assertEq(probe.receiveCount(), 0);

        vm.prank(bob);
        vm.expectRevert(IDirectedVault.Unauthorized.selector);
        vault.claimFor(bob, address(token));
    }

    function test_Q6_QA_there_is_no_onchain_threshold_one_wei_is_claimable() public {
        // a 1-wei token balance in the vault (wallet-to-wallet transfers are untaxed, so exactly 1 wei lands)
        _v2Buy(alice, 0.01 ether);
        uint256 dust = token.balanceOf(address(vault));
        (, uint256 d0,) = probe.claim(vault, address(token));
        assertEq(d0, dust);
        vm.prank(alice);
        token.transfer(address(vault), 1);
        assertEq(vault.claimableNow(address(probe), address(token)), 1);

        (uint256 ret, uint256 delta,) = probe.claim(vault, address(token));
        assertEq(ret, 1);
        assertEq(delta, 1, "a claim of a single wei succeeds");

        // only an exactly empty vault refuses
        vm.expectRevert(IDirectedVault.NothingToClaim.selector);
        probe.claim(vault, address(token));
    }

    function test_Q6_QA_sync_moves_nothing() public {
        _v2Buy(alice, 1 ether);
        uint256 v0 = token.balanceOf(address(vault));
        uint256 p0 = token.balanceOf(address(probe));
        vm.prank(bob);
        vault.sync();
        assertEq(token.balanceOf(address(vault)), v0);
        assertEq(token.balanceOf(address(probe)), p0);
    }

    /// @dev The platform's "daily push above a threshold" is selector 0x67318ec1(uint256 minAmount), callable
    ///      only by DirectedVaultFactory.0x2761dbab(). The threshold is a calldata argument chosen off-chain.
    function test_Q6_QA_platform_push_is_operator_only_and_its_threshold_is_calldata() public {
        (bool okOp, bytes memory opRet) = vault.FACTORY().staticcall(abi.encodeWithSelector(0x2761dbab));
        assertTrue(okOp);
        address operator = abi.decode(opRet, (address));
        assertEq(operator, PUSH_OPERATOR);
        assertEq(operator.code.length, 0, "an EOA bot");

        _v2Buy(alice, 1 ether);
        uint256 bal = token.balanceOf(address(vault));
        uint256 p0 = token.balanceOf(address(probe));

        // anyone else: Unauthorized
        vm.prank(bob);
        (bool ok, bytes memory err) = address(vault).call(abi.encodeWithSelector(0x67318ec1, uint256(0)));
        assertFalse(ok);
        assertEq(_sel(err), IDirectedVault.Unauthorized.selector);
        // the recipient itself is not the operator either
        (ok, err,) = probe.exec(address(vault), 0, abi.encodeWithSelector(0x67318ec1, uint256(0)));
        assertFalse(ok);
        assertEq(_sel(err), IDirectedVault.Unauthorized.selector);

        // operator, threshold above the balance: returns 0, moves nothing, does not revert
        vm.prank(operator);
        (ok, err) = address(vault).call(abi.encodeWithSelector(0x67318ec1, bal + 1));
        assertTrue(ok);
        assertEq(abi.decode(err, (uint256)), 0);
        assertEq(token.balanceOf(address(vault)), bal);

        // operator, threshold at the balance: pushes the WHOLE balance to RECIPIENT
        vm.prank(operator);
        (ok, err) = address(vault).call(abi.encodeWithSelector(0x67318ec1, bal));
        assertTrue(ok);
        assertEq(abi.decode(err, (uint256)), bal);
        assertEq(token.balanceOf(address(probe)) - p0, bal, "pushed to the recipient contract");
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(operator), 0);
    }

    function test_Q6_residual_native_tax_is_still_claimable_after_graduation() public {
        uint256 residual = address(vault).balance;
        assertEq(residual, nativeTaxBeforeGrad + (whaleCost * 300) / 10_000);
        assertEq(vault.claimableNow(address(probe), NATIVE), residual);

        probe.setMode(RecipientProbe.Mode.Record);
        (uint256 ret, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(ret, residual);
        assertEq(delta, residual);
        assertEq(address(vault).balance, 0);
        console2.log("residual native tax claimed after graduation (wei)", delta);

        // from here on the native side stays empty: V2 trades only produce token tax
        _v2Buy(alice, 1 ether);
        vm.expectRevert(IDirectedVault.NothingToClaim.selector);
        probe.claim(vault, NATIVE);
    }

    // ───────────────────────── Q-B: moving and burning the tokens ─────────────────────────

    function _transferToDeadIsUntaxed(uint256 amount) internal returns (uint256 gasUsed) {
        uint256 d0 = token.balanceOf(DEAD);
        uint256 v0 = token.balanceOf(address(vault));
        uint256 p0 = token.balanceOf(address(probe));
        gasUsed = probe.tokenTransfer(address(token), DEAD, amount);
        assertEq(token.balanceOf(DEAD) - d0, amount, "0xdEaD receives the full amount");
        assertEq(token.balanceOf(address(vault)), v0, "no tax taken");
        assertEq(p0 - token.balanceOf(address(probe)), amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether, "totalSupply does not change");
    }

    function test_Q6_QB_tokens_bought_on_the_curve_can_go_to_dead_untaxed_during_and_after_protection()
        public
    {
        assertEq(token.balanceOf(address(probe)), lockedBefore);
        assertTrue(token.protectionActive());

        uint256 g1 = _transferToDeadIsUntaxed(lockedBefore / 2);
        console2.log("transfer to 0xdEaD during protection, gas (first, zero -> non-zero)", g1);

        vm.warp(token.protectionEndsAt());
        assertFalse(token.protectionActive(), "window closes exactly at protectionEndsAt");
        uint256 g2 = _transferToDeadIsUntaxed(token.balanceOf(address(probe)));
        console2.log("transfer to 0xdEaD after protection, gas (non-zero -> non-zero)", g2);
        assertEq(token.balanceOf(DEAD), lockedBefore);
    }

    function test_Q6_there_is_no_burn_function_and_zero_address_is_refused() public {
        bool ok;
        bytes memory err;
        (ok, err,) = probe.exec(address(token), 0, abi.encodeWithSignature("burn(uint256)", uint256(1)));
        assertFalse(ok, "burn(uint256)");
        assertEq(err.length, 0, "no such selector: empty revert");
        (ok, err,) = probe.exec(
            address(token),
            0,
            abi.encodeWithSignature("burnFrom(address,uint256)", address(probe), uint256(1))
        );
        assertFalse(ok, "burnFrom");

        (ok, err,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (address(0), 1)));
        assertFalse(ok, "transfer to address(0)");
        console2.log("transfer to address(0) revert data:");
        console2.logBytes(err);
        assertEq(_sel(err), bytes4(keccak256("ERC20InvalidReceiver(address)")));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_Q6_wallet_transfers_are_untaxed_but_a_transfer_to_the_pair_is_taxed_as_a_sell() public {
        // contract -> EOA
        uint256 v0 = token.balanceOf(address(vault));
        probe.tokenTransfer(address(token), bob, 1_000 ether);
        assertEq(token.balanceOf(bob), 1_000 ether, "untaxed");
        // EOA -> contract
        vm.prank(bob);
        token.transfer(address(probe), 400 ether);
        assertEq(token.balanceOf(bob), 600 ether);
        assertEq(token.balanceOf(address(vault)), v0, "no tax on wallet-to-wallet transfers");

        // anything sent to the pair is a sell: 3% is diverted to the vault
        uint256 pr0 = token.balanceOf(pair);
        probe.tokenTransfer(address(token), pair, 1_000 ether);
        assertEq(token.balanceOf(pair) - pr0, 970 ether);
        assertEq(token.balanceOf(address(vault)) - v0, 30 ether);
    }
}
