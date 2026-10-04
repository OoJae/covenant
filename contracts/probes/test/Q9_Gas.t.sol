// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Q9. Gas of every external leg the kernel will run, measured as the kernel would see it: a
///         SUB-CALL from a contract (gasleft() before and after the call, inside RecipientProbe).
///
///         This contract runs in ISOLATION mode (inline config below): every top-level call made by the
///         test is executed as its own transaction, so each measured leg starts with a cold access list
///         (only the caller contract itself is warm). These are therefore worst-case, per-leg numbers; inside
///         one settle() later legs are cheaper because the Manager, vault and token are already warm.
///
/// forge-config: default.isolate = true
contract Q9_Gas is ProbeBase {
    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;

    address internal constant NATIVE = address(0);

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        vm.label(address(probe), "probe (recipient)");
        (token, vault) = _launch(_defaultCfg(address(probe)));
        vm.deal(address(probe), 1_000 ether);
    }

    function _read(address target, bytes memory data) internal returns (uint256 gasUsed) {
        bool ok;
        (ok,, gasUsed) = probe.exec(target, 0, data);
        assertTrue(ok);
    }

    // ───────────────────────── curve phase ─────────────────────────

    function test_Q9_gas_claim_native() public {
        _buy(alice, address(token), 1 ether);
        (,, uint256 gTrivial) = probe.claim(vault, NATIVE);
        console2.log("claim(native), empty receive()            ", gTrivial);
        assertLt(gTrivial, 60_000);

        probe.setMode(RecipientProbe.Mode.Record);
        _buy(alice, address(token), 1 ether);
        (,, uint256 gHeavy) = probe.claim(vault, NATIVE);
        console2.log("claim(native), receive() with 4 SSTOREs+log", gHeavy);
        console2.log("  of which the receiver's own work        ", gHeavy - gTrivial);

        (bool ok,,, uint256 gEmpty) = probe.tryClaim(vault, NATIVE);
        assertFalse(ok);
        console2.log("claim(native) reverting NothingToClaim    ", gEmpty);
        assertLt(gEmpty, 40_000);

        (ok,,, gEmpty) = probe.tryClaim(vault, address(token));
        assertFalse(ok);
        console2.log("claim(token) before graduation (reverts)  ", gEmpty);
    }

    function test_Q9_gas_claimFor_as_a_transaction() public {
        _buy(alice, address(token), 1 ether);
        vm.prank(bob);
        vault.claimFor(address(probe), NATIVE);
        Vm.Gas memory g = vm.lastFrameGas(); // with isolation: includes the 21,000 intrinsic gas and calldata
        console2.log("claimFor(native) from an EOA, whole tx    ", g.gasTotalUsed);
        assertLt(g.gasTotalUsed, 90_000);
    }

    function test_Q9_gas_buyTo() public {
        (,, uint256 gFirst) = probe.buyTo(M, address(token), 0.5 ether, 0, address(probe));
        console2.log("buyTo, first (token balance 0 -> x)       ", gFirst);
        (,, uint256 gSecond) = probe.buyTo(M, address(token), 0.5 ether, 0, address(probe));
        console2.log("buyTo, later (balance x -> y)             ", gSecond);
        assertLt(gFirst, 250_000);
        assertLt(gSecond, gFirst);

        (,, uint256 gDead) = probe.buyTo(M, address(token), 0.5 ether, 0, DEAD);
        console2.log("buyTo with recipient 0xdEaD (first)       ", gDead);

        // failure paths the kernel catches
        (bool ok,,, uint256 gSlip) =
            probe.tryBuyTo(M, address(token), 0.5 ether, type(uint256).max, address(probe));
        assertFalse(ok);
        console2.log("buyTo reverting Slippage                  ", gSlip);
    }

    function test_Q9_gas_buyTo_that_graduates() public {
        uint256 cost = CurveQuote.costToGraduate(_curve(address(token)), 0);
        (,, uint256 g) = probe.buyTo(M, address(token), cost, 0, address(probe));
        console2.log("buyTo that sells out the curve + graduates", g);
        assertTrue(M.pairOf(address(token)) != address(0));
        assertLt(g, 4_000_000);
    }

    function test_Q9_gas_reads() public {
        uint256 g1 = _read(address(M), abi.encodeCall(IIgnixManager.tokens, (address(token))));
        uint256 g2 = _read(address(M), abi.encodeCall(IIgnixManager.snipeBpsNow, (address(token))));
        uint256 g3 = _read(address(M), abi.encodeCall(IIgnixManager.pairOf, (address(token))));
        uint256 g4 = _read(address(M), abi.encodeCall(IIgnixManager.pausedUntil, (uint256(6))));
        uint256 g5 = _read(address(M), abi.encodeCall(IIgnixManager.founderRound, (address(token))));
        uint256 g6 =
            _read(address(vault), abi.encodeCall(IDirectedVault.claimableNow, (address(probe), NATIVE)));
        console2.log("read tokens(token)        ", g1);
        console2.log("read snipeBpsNow(token)   ", g2);
        console2.log("read pairOf(token)        ", g3);
        console2.log("read pausedUntil(6)       ", g4);
        console2.log("read founderRound(token)  ", g5);
        console2.log("read vault.claimableNow   ", g6);
        assertLt(g1, 40_000);
    }

    // ───────────────────────── graduated phase ─────────────────────────

    function _graduatedWithTokens() internal returns (address pair, uint256 held) {
        (held,,) = probe.buyTo(M, address(token), 1 ether, 0, address(probe));
        pair = _graduate(address(token));
    }

    function test_Q9_gas_claim_token_after_graduation() public {
        _graduatedWithTokens();
        vm.prank(alice);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(
            0, _path(WOKB, address(token)), alice, block.timestamp
        );
        (,, uint256 g) = probe.claim(vault, address(token));
        console2.log("claim(token), during protection           ", g);
        assertLt(g, 120_000);

        (,, uint256 gNative) = probe.claim(vault, NATIVE);
        console2.log("claim(native) residual, after graduation  ", gNative);

        vm.warp(token.protectionEndsAt() + 1);
        vm.prank(alice);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(
            0, _path(WOKB, address(token)), alice, block.timestamp
        );
        (,, g) = probe.claim(vault, address(token));
        console2.log("claim(token), after protection            ", g);
    }

    function test_Q9_gas_transfer_to_dead() public {
        (, uint256 held) = _graduatedWithTokens();
        uint256 g1 = probe.tokenTransfer(address(token), DEAD, held / 4);
        console2.log("transfer to 0xdEaD, first (0 -> x), during protection", g1);
        uint256 g2 = probe.tokenTransfer(address(token), DEAD, held / 4);
        console2.log("transfer to 0xdEaD, later (x -> y), during protection", g2);
        vm.warp(token.protectionEndsAt() + 1);
        uint256 g3 = probe.tokenTransfer(address(token), DEAD, held / 4);
        console2.log("transfer to 0xdEaD, later, after protection          ", g3);
        assertLt(g1, 100_000);
    }

    function _aliceSwap() internal {
        vm.prank(alice);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(
            0, _path(WOKB, address(token)), alice, block.timestamp
        );
    }

    /// @dev A Uniswap V2 pair writes its two cumulative-price slots on the first swap of every block.
    ///      The very first time they go zero -> non-zero (+44,200 gas), so the worst case is "our buy is the
    ///      first swap ever, in a block after graduation".
    function test_Q9_gas_v2_router_buy() public {
        _graduatedWithTokens();

        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 1 hours);
        (, uint256 gWorst) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, DEAD);
        console2.log("router buy to 0xdEaD: first swap EVER on the pair, new block     ", gWorst);
        assertLt(gWorst, 300_000);
        vm.revertToState(snap);

        vm.warp(block.timestamp + 1 hours);
        _aliceSwap(); // someone else already traded: cumulative prices are initialised
        vm.warp(block.timestamp + 1 hours);
        (, uint256 g1) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, DEAD);
        console2.log("router buy to 0xdEaD: first swap of a block, dead balance 0 -> x ", g1);
        vm.warp(block.timestamp + 1 hours);
        (, uint256 g2) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, DEAD);
        console2.log("router buy to 0xdEaD: first swap of a block, dead balance x -> y ", g2);
        (, uint256 g2b) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, DEAD);
        console2.log("router buy to 0xdEaD: same block as another swap                 ", g2b);
        vm.warp(block.timestamp + 1 hours);
        (, uint256 g3) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, address(probe));
        console2.log("router buy to self:   first swap of a block (during protection)  ", g3);

        vm.warp(token.protectionEndsAt() + 1);
        (, uint256 g4) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, DEAD);
        console2.log("router buy to 0xdEaD: first swap of a block, after protection    ", g4);
        vm.warp(block.timestamp + 1 hours);
        (, uint256 g5) = probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, address(probe));
        console2.log("router buy to self:   first swap of a block, after protection    ", g5);

        // failure path: minOut too high
        (bool ok,, uint256 gFail) = probe.exec(
            address(ROUTER),
            0.5 ether,
            abi.encodeCall(
                IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens,
                (type(uint256).max, _path(WOKB, address(token)), DEAD, block.timestamp)
            )
        );
        assertFalse(ok);
        console2.log("router buy reverting INSUFFICIENT_OUTPUT_AMOUNT                  ", gFail);
    }

    // ───────────────────────── whole epochs, legs sharing one transaction ─────────────────────────

    function test_Q9_gas_curve_epoch_in_one_transaction() public {
        _buy(alice, address(token), 1 ether);
        (uint256[3] memory g, uint256 claimed, uint256 bought) =
            probe.curveEpoch(vault, M, address(token), 0.02 ether);
        assertEq(claimed, 0.03 ether);
        assertGt(bought, 0);
        console2.log("curve epoch: claim(native)                 ", g[0]);
        console2.log("curve epoch: tokens + snipeBpsNow + pairOf ", g[1]);
        console2.log("curve epoch: buyTo (first)                 ", g[2]);
        console2.log("curve epoch: external legs total           ", g[0] + g[1] + g[2]);

        // next epoch with no outside trade: the first epoch's own buy paid 3% tax back into the vault
        (g, claimed, bought) = probe.curveEpoch(vault, M, address(token), 0.02 ether);
        assertEq(claimed, (0.02 ether * 300) / 10_000);
        console2.log("curve epoch 2: claim(native)               ", g[0]);
        console2.log("curve epoch 2: reads                       ", g[1]);
        console2.log("curve epoch 2: buyTo (later)               ", g[2]);
        console2.log("curve epoch 2: external legs total         ", g[0] + g[1] + g[2]);
        assertLt(g[0] + g[1] + g[2], 250_000);
    }

    function test_Q9_gas_graduated_epoch_in_one_transaction() public {
        _graduatedWithTokens();
        vm.warp(block.timestamp + 1 hours);
        _aliceSwap();
        (uint256[3] memory g, uint256 tokenClaimed, uint256 burned) =
            probe.graduatedEpoch(vault, address(token), 5_000);
        assertGt(tokenClaimed, 0);
        assertGt(burned, 0);
        console2.log("graduated epoch: claim(token)              ", g[0]);
        console2.log("graduated epoch: claim(native) residual    ", g[1]);
        console2.log("graduated epoch: transfer to 0xdEaD (first)", g[2]);
        console2.log("graduated epoch: external legs total       ", g[0] + g[1] + g[2]);

        vm.warp(block.timestamp + 1 hours);
        _aliceSwap();
        (g, tokenClaimed, burned) = probe.graduatedEpoch(vault, address(token), 5_000);
        console2.log("graduated epoch 2: claim(token)            ", g[0]);
        console2.log("graduated epoch 2: claim(native) (reverts) ", g[1]);
        console2.log("graduated epoch 2: transfer to 0xdEaD      ", g[2]);
        console2.log("graduated epoch 2: external legs total     ", g[0] + g[1] + g[2]);
        assertLt(g[0] + g[1] + g[2], 200_000);
    }

    function test_Q9_gas_reads_after_graduation() public {
        (address pair,) = _graduatedWithTokens();
        uint256 g1 = _read(address(M), abi.encodeCall(IIgnixManager.pairOf, (address(token))));
        uint256 g2 = _read(pair, abi.encodeCall(IUniswapV2Pair.getReserves, ()));
        uint256 g3 = _read(pair, abi.encodeCall(IUniswapV2Pair.token0, ()));
        uint256 g4 = _read(address(token), abi.encodeCall(IIgnixToken.taxBuyBps, ()));
        uint256 g5 = _read(address(token), abi.encodeCall(IIgnixToken.balanceOf, (address(probe))));
        console2.log("read pairOf(token) (graduated) ", g1);
        console2.log("read pair.getReserves()        ", g2);
        console2.log("read pair.token0()             ", g3);
        console2.log("read token.taxBuyBps()         ", g4);
        console2.log("read token.balanceOf(self)     ", g5);
    }

    // ───────────────────────── smallest gas LIMIT each leg needs (for the kernel's guards) ─────────────────────────

    /// @dev Binary search of the smallest `gas:` value with which the sub-call succeeds. Below it the call
    ///      reverts as a whole (nothing moves); it is never a partial success. The limit is higher than the
    ///      gas actually used because of the 63/64 rule at each nested call.
    function _minGas(address target, uint256 value, bytes memory data) internal returns (uint256 lo) {
        uint256 hi = 6_000_000;
        lo = 5_000;
        (bool okHi,) = _tryAt(target, value, data, hi);
        require(okHi, "leg fails even with plenty of gas");
        while (hi - lo > 1) {
            uint256 mid = (hi + lo) / 2;
            (bool ok,) = _tryAt(target, value, data, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
    }

    function _tryAt(address target, uint256 value, bytes memory data, uint256 gasLimit)
        internal
        returns (bool ok, bytes memory ret)
    {
        uint256 snap = vm.snapshotState();
        (ok, ret) = probe.execGas(target, value, data, gasLimit);
        vm.revertToState(snap);
    }

    function test_Q9_min_gas_limit_curve_legs() public {
        uint256 gBuyFresh = _minGas(
            address(M),
            0.5 ether,
            abi.encodeCall(IIgnixManager.buyTo, (address(token), 0.5 ether, 0, address(probe)))
        );
        console2.log("min gas limit: buyTo, very first buy on the curve  ", gBuyFresh);
        assertLt(gBuyFresh, 200_000);
        _buy(alice, address(token), 1 ether);
        uint256 gClaim = _minGas(address(vault), 0, abi.encodeCall(IDirectedVault.claim, (NATIVE)));
        console2.log("min gas limit: claim(native), empty receive()      ", gClaim);
        probe.setMode(RecipientProbe.Mode.Record);
        uint256 gClaimHeavy = _minGas(address(vault), 0, abi.encodeCall(IDirectedVault.claim, (NATIVE)));
        console2.log("min gas limit: claim(native), 90k-gas receive()    ", gClaimHeavy);
        probe.setMode(RecipientProbe.Mode.Accept);

        uint256 gBuy = _minGas(
            address(M),
            0.5 ether,
            abi.encodeCall(IIgnixManager.buyTo, (address(token), 0.5 ether, 0, address(probe)))
        );
        console2.log("min gas limit: buyTo (curve already traded, 0 -> x) ", gBuy);
        uint256 gTokens = _minGas(address(M), 0, abi.encodeCall(IIgnixManager.tokens, (address(token))));
        console2.log("min gas limit: tokens(token)                       ", gTokens);
        assertLt(gClaim, 60_000);
        assertLt(gBuy, 200_000);

        // one below the minimum: a clean revert, nothing moved
        (bool ok,) =
            probe.execGas(address(vault), 0, abi.encodeCall(IDirectedVault.claim, (NATIVE)), gClaim - 1);
        assertFalse(ok);
        assertEq(address(vault).balance, 0.03 ether);
        (ok,) = probe.execGas(address(vault), 0, abi.encodeCall(IDirectedVault.claim, (NATIVE)), gClaim);
        assertTrue(ok);
        assertEq(address(vault).balance, 0);
    }

    function test_Q9_min_gas_limit_graduated_legs() public {
        (, uint256 held) = _graduatedWithTokens();
        vm.warp(block.timestamp + 1 hours);
        _aliceSwap();

        uint256 gClaimTok = _minGas(address(vault), 0, abi.encodeCall(IDirectedVault.claim, (address(token))));
        console2.log("min gas limit: claim(token), during protection       ", gClaimTok);
        uint256 gDead = _minGas(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (DEAD, held / 2)));
        console2.log("min gas limit: transfer to 0xdEaD (first, 0 -> x)     ", gDead);

        vm.warp(block.timestamp + 1 hours);
        bytes memory swapData = abi.encodeCall(
            IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens,
            (0, _path(WOKB, address(token)), DEAD, block.timestamp)
        );
        uint256 gSwap = _minGas(address(ROUTER), 0.5 ether, swapData);
        console2.log("min gas limit: router buy to 0xdEaD (first of block)  ", gSwap);
        assertLt(gClaimTok, 120_000);
        assertLt(gDead, 100_000);
        assertLt(gSwap, 300_000);
    }
}
