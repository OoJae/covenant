// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

interface IRouterExactOut {
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
}

/// @notice Q7 (+ Q-C). The post-graduation buy-and-burn leg: a contract holding native OKB buys
///         the project token on the official Uniswap V2 pair, straight to 0x...dEaD or to itself.
contract Q7_V2BuyBurn is ProbeBase {
    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;
    address internal pair;

    uint256 internal constant TAX_BUY = 300;

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        vm.label(address(probe), "probe (recipient)");
        (token, vault) = _launch(_defaultCfg(address(probe)));
        vm.deal(address(probe), 1_000 ether);
        pair = _graduate(address(token));
    }

    function _quote(uint256 amountIn) internal view returns (uint256 gross, uint256 tax, uint256 net) {
        (uint256 rToken, uint256 rWokb) = _reserves(pair, address(token));
        return V2TaxQuote.buyOut(amountIn, rWokb, rToken, TAX_BUY);
    }

    /// @dev One router buy from the probe; asserts recipient delta, vault tax and pair reserves exactly.
    function _swapAndCheck(uint256 amountIn, address to) internal returns (uint256 gasUsed) {
        (uint256 gross, uint256 tax, uint256 net) = _quote(amountIn);
        (uint256 rToken0, uint256 rWokb0) = _reserves(pair, address(token));
        uint256 v0 = token.balanceOf(address(vault));
        uint256 n0 = address(probe).balance;

        uint256 delta;
        (delta, gasUsed) = probe.swapNativeForTokens(ROUTER, address(token), amountIn, net, to); // minOut = net

        assertEq(delta, net, "recipient gets gross - tax, exactly as computed on-chain");
        assertEq(token.balanceOf(address(vault)) - v0, tax, "tax to the vault in project tokens");
        assertEq(n0 - address(probe).balance, amountIn, "exactly amountIn leaves the caller, nothing returns");
        (uint256 rToken1, uint256 rWokb1) = _reserves(pair, address(token));
        assertEq(rToken0 - rToken1, gross, "pair pays out the gross amount");
        assertEq(rWokb1 - rWokb0, amountIn, "the whole input stays in the pair (0.3% LP fee included)");
    }

    // ───────────────────────── during the protection window ─────────────────────────

    function test_Q7_QC_router_buy_to_dead_works_during_protection_with_exact_minOut() public {
        assertTrue(token.protectionActive());
        uint256 d0 = token.balanceOf(DEAD);
        (, uint256 tax, uint256 net) = _quote(0.5 ether);
        uint256 gasUsed = _swapAndCheck(0.5 ether, DEAD);
        assertEq(token.balanceOf(DEAD) - d0, net);
        console2.log("0.5 OKB -> tokens to 0xdEaD (wei)", net);
        console2.log("  tax taken in tokens (wei)        ", tax);
        console2.log("  gas (router, to 0xdEaD, during protection)", gasUsed);
        assertEq(token.totalSupply(), 1_000_000_000 ether, "burning to 0xdEaD does not reduce totalSupply");
    }

    function test_Q7_router_buy_to_self_works_during_protection() public {
        uint256 gasUsed = _swapAndCheck(0.5 ether, address(probe));
        console2.log("gas (router, to self, during protection)", gasUsed);
    }

    function test_Q7_minOut_one_wei_above_the_onchain_quote_reverts() public {
        (,, uint256 net) = _quote(0.5 ether);
        (bool ok, bytes memory err,) = probe.exec(
            address(ROUTER),
            0.5 ether,
            abi.encodeCall(
                IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens,
                (net + 1, _path(WOKB, address(token)), DEAD, block.timestamp)
            )
        );
        assertFalse(ok);
        assertEq(_revertString(err), "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        assertEq(address(probe).balance, 1_000 ether, "value returned with the revert");
    }

    // ───────────────────────── after the protection window ─────────────────────────

    function test_Q7_router_buys_work_and_are_taxed_the_same_after_protection() public {
        vm.warp(token.protectionEndsAt() + 1);
        assertFalse(token.protectionActive());
        uint256 g1 = _swapAndCheck(0.5 ether, DEAD);
        uint256 g2 = _swapAndCheck(0.5 ether, address(probe));
        console2.log("gas (router, to 0xdEaD, after protection)", g1);
        console2.log("gas (router, to self, after protection)", g2);
        assertTrue(token.pools(pair), "the official pair stays taxed forever");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_Q7_v2_quote_from_reserves_and_taxBuyBps_is_exact(
        uint256 seed,
        bool toDead,
        bool afterProtection
    ) public {
        if (afterProtection) vm.warp(token.protectionEndsAt() + 1);
        uint256 amountIn = bound(seed, 1e9, 200 ether);
        _swapAndCheck(amountIn, toDead ? DEAD : address(probe));
    }

    // ───────────────────────── Q-C: refund path and router function ─────────────────────────

    function test_Q7_QC_no_native_ever_returns_to_the_caller_receive_may_refuse_the_router() public {
        // a recipient whose receive() reverts for everyone can still do the swap
        probe.setMode(RecipientProbe.Mode.Refuse);
        _swapAndCheck(0.5 ether, DEAD);
        // and one that accepts only the vault and the manager
        probe.setMode(RecipientProbe.Mode.OnlyKnown);
        probe.setKnown(address(vault), true);
        probe.setKnown(address(M), true);
        _swapAndCheck(0.5 ether, address(probe));
        assertEq(probe.receiveCount(), 0, "receive() was never called");
    }

    function test_Q7_QC_plain_swapExactETHForTokens_succeeds_but_checks_minOut_before_tax() public {
        (uint256 gross,, uint256 net) = _quote(0.5 ether);
        uint256 d0 = token.balanceOf(DEAD);
        // minOut = gross passes, although 0xdEaD only receives `net`: the plain variant cannot protect a
        // fee-on-transfer buy. Use the SupportingFeeOnTransferTokens variant.
        (bool ok,,) = probe.exec(
            address(ROUTER),
            0.5 ether,
            abi.encodeCall(
                IUniswapV2Router02.swapExactETHForTokens,
                (gross, _path(WOKB, address(token)), DEAD, block.timestamp)
            )
        );
        assertTrue(ok);
        assertEq(token.balanceOf(DEAD) - d0, net);
        assertLt(net, gross);
    }

    function test_Q7_QC_exact_out_variant_refunds_native_and_needs_receive() public {
        (uint256 gross,,) = _quote(0.5 ether);
        bytes memory data = abi.encodeCall(
            IRouterExactOut.swapETHForExactTokens, (gross, _path(WOKB, address(token)), DEAD, block.timestamp)
        );
        // sends 0.6 OKB for something that costs 0.5: the router refunds 0.1 OKB to msg.sender
        probe.setMode(RecipientProbe.Mode.Refuse);
        (bool ok, bytes memory err,) = probe.exec(address(ROUTER), 0.6 ether, data);
        assertFalse(ok, "a refusing receive() breaks the exact-out variant");
        assertEq(_revertString(err), "TransferHelper: ETH_TRANSFER_FAILED");

        probe.setMode(RecipientProbe.Mode.Record);
        uint256 n0 = address(probe).balance;
        (ok,,) = probe.exec(address(ROUTER), 0.6 ether, data);
        assertTrue(ok);
        assertEq(probe.lastSender(), address(ROUTER), "refund comes from the router");
        assertApproxEqAbs(n0 - address(probe).balance, 0.5 ether, 1e6);
    }

    // ───────────────────────── direct pair.swap (no router) ─────────────────────────

    /// @dev wrap -> send WOKB to the pair -> pair.swap(out, to). Three calls from the probe, no router.
    function _directSwap(uint256 amountIn, uint256 out, address to)
        internal
        returns (bool ok, bytes memory err, uint256 gasTotal)
    {
        uint256 g;
        (ok,, g) = probe.exec(WOKB, amountIn, abi.encodeCall(IWOKB.deposit, ()));
        require(ok, "wrap");
        gasTotal = g;
        (ok,, g) = probe.exec(WOKB, 0, abi.encodeCall(IWOKB.transfer, (pair, amountIn)));
        require(ok, "send WOKB to the pair");
        gasTotal += g;
        bool tokenIs0 = IUniswapV2Pair(pair).token0() == address(token);
        (ok, err, g) = probe.exec(
            pair, 0, abi.encodeCall(IUniswapV2Pair.swap, (tokenIs0 ? out : 0, tokenIs0 ? 0 : out, to, ""))
        );
        gasTotal += g;
    }

    function test_Q7_direct_pair_swap_to_dead_works_and_is_taxed_the_same() public {
        (uint256 gross, uint256 tax, uint256 net) = _quote(0.5 ether);
        uint256 d0 = token.balanceOf(DEAD);
        uint256 v0 = token.balanceOf(address(vault));

        (bool ok,, uint256 gasTotal) = _directSwap(0.5 ether, gross, DEAD);
        assertTrue(ok, "pair.swap");
        assertEq(token.balanceOf(DEAD) - d0, net);
        assertEq(token.balanceOf(address(vault)) - v0, tax);
        console2.log("gas: WOKB.deposit + WOKB.transfer + pair.swap, same block as graduation", gasTotal);

        // asking the pair for one wei more than the 0.3%-fee formula allows fails the K check
        (gross,,) = _quote(0.5 ether);
        bytes memory err;
        (ok, err,) = _directSwap(0.5 ether, gross + 1, DEAD);
        assertFalse(ok);
        assertEq(_revertString(err), "UniswapV2: K");
    }

    // ───────────────────────── what the protection window actually restricts ─────────────────────────

    function test_Q7_protection_window_does_not_restrict_router_trades_or_plain_transfers() public {
        // official pair buy + sell by a contract, during protection
        (uint256 got,) = probe.swapNativeForTokens(ROUTER, address(token), 1 ether, 0, address(probe));
        (bool ok,,) =
            probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.approve, (address(ROUTER), got)));
        assertTrue(ok);
        bytes memory err;
        (ok, err,) = probe.exec(
            address(ROUTER),
            0,
            abi.encodeCall(
                IUniswapV2Router02.swapExactTokensForETHSupportingFeeOnTransferTokens,
                (got, 0, _path(address(token), WOKB), bob, block.timestamp)
            )
        );
        assertTrue(ok, "sell through the router during protection");

        // a plain transfer to an arbitrary contract (here the V4 PoolManager the token knows about) is not
        // blocked either, during or after the window
        address pm = token.poolManager();
        probe.swapNativeForTokens(ROUTER, address(token), 1 ether, 0, address(probe));
        (ok,,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (pm, 1 ether)));
        assertTrue(ok, "transfer to the V4 PoolManager during protection");
        vm.warp(token.protectionEndsAt() + 1);
        (ok,,) = probe.exec(address(token), 0, abi.encodeCall(IIgnixToken.transfer, (pm, 1 ether)));
        assertTrue(ok, "transfer to the V4 PoolManager after protection");
    }

    /// @dev During the window the token staticcalls token0() on a CONTRACT counterparty (10,000 gas cap) to see
    ///      whether it is a pool. The recipient contract must simply not answer: no fallback, no token0().
    function test_Q7_token_probes_a_contract_receiver_with_token0_during_protection() public {
        vm.expectCall(address(probe), abi.encodeWithSignature("token0()"), 1);
        probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, address(probe));
    }

    function test_Q7_token_probes_a_contract_sender_with_token0_during_protection() public {
        probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, address(probe));
        // 0xdEaD has no code and is never probed; the sending contract is
        vm.expectCall(address(probe), abi.encodeWithSignature("token0()"), 1);
        probe.tokenTransfer(address(token), DEAD, 1 ether);
    }

    function test_Q7_token_does_not_probe_anyone_after_protection() public {
        probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, address(probe));
        vm.warp(token.protectionEndsAt() + 1);
        vm.expectCall(address(probe), abi.encodeWithSignature("token0()"), 0);
        probe.swapNativeForTokens(ROUTER, address(token), 0.5 ether, 0, address(probe));
        probe.tokenTransfer(address(token), DEAD, 1 ether);
    }

    /// @dev What the window does, measured: every GENUINE Uniswap pool of the token (looked up in the official
    ///      factory) is auto-registered and taxed on transfer; a contract that merely exposes token0/token1
    ///      is not. After the window only the official pair stays taxed.
    function test_Q7_protection_window_only_extends_the_tax_to_other_genuine_pools() public {
        probe.swapNativeForTokens(ROUTER, address(token), 5 ether, 0, address(probe));
        address other = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5; // an unrelated ERC-20 on X Layer
        address pair2 = IV2FactoryCreate(M.V2_FACTORY()).createPair(address(token), other);
        assertFalse(token.pools(pair2));

        uint256 v0 = token.balanceOf(address(vault));
        probe.tokenTransfer(address(token), pair2, 1_000 ether);
        assertTrue(token.pools(pair2), "detected and registered on first transfer");
        assertEq(token.balanceOf(pair2), 970 ether, "taxed like a sell");
        assertEq(token.balanceOf(address(vault)) - v0, 30 ether);

        LookalikePool fake = new LookalikePool(address(token), WOKB);
        v0 = token.balanceOf(address(vault));
        probe.tokenTransfer(address(token), address(fake), 1_000 ether);
        assertEq(token.balanceOf(address(fake)), 1_000 ether, "a look-alike is not a pool");
        assertEq(token.balanceOf(address(vault)), v0);
        assertFalse(token.pools(address(fake)));
        assertFalse(token.pools(address(probe)), "the recipient contract is never mistaken for a pool");

        vm.warp(token.protectionEndsAt() + 1);
        v0 = token.balanceOf(address(vault));
        probe.tokenTransfer(address(token), pair2, 1_000 ether);
        assertEq(token.balanceOf(pair2), 1_970 ether, "after the window the secondary pool is untaxed");
        assertEq(token.balanceOf(address(vault)), v0);
    }
}

interface IV2FactoryCreate {
    function createPair(address a, address b) external returns (address);
}

contract LookalikePool {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }
}
