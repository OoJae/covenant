// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Fidelity check of the whole method: a REAL mainnet curve buy, re-executed on a fork of the block
///         before it, must give the token amount in the real `Trade` event and the gas in the real receipt.
///
///         Transaction 0x521559763f9546f914e726146eaf9ee00db39754c8ff8fb4a625f794beca1cbe
///         block 72,368,108 (index 3), `IgnixManager.buy` of 0.046809775 OKB by an EOA.
///         Real Trade event: tokenAmount = 1,704,326.672566188590158383. Real receipt: gasUsed = 210,837.
///
/// forge-config: default.isolate = true
contract Q10_Replay is ProbeBase {
    address internal constant BUYER = 0xb8E0588b53c8a60F411b8a9dBc584b135d197011;
    address internal constant TOKEN_X = 0xFCf11D7E266aD76E90d909c72F4AC7Da5Ac7eEee;
    uint256 internal constant BLOCK = 72_368_108;
    uint256 internal constant BLOCK_TIME = 1_791_137_144;
    uint256 internal constant AMOUNT_IN = 46_809_775_000_000_000;
    uint256 internal constant MIN_OUT = 1_653_196_872_389_202_932_453_631;
    uint256 internal constant REAL_TOKENS_OUT = 1_704_326_672_566_188_590_158_383;
    uint256 internal constant REAL_GAS_USED = 210_837;

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", DEFAULT_RPC), BLOCK - 1);
        vm.roll(BLOCK);
        vm.warp(BLOCK_TIME);
    }

    function test_Q10_fork_reproduces_a_real_mainnet_buy_tokens_and_gas() public {
        // the on-chain quote, from state before the trade
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(_curve(TOKEN_X), M.snipeBpsNow(TOKEN_X), AMOUNT_IN);
        assertEq(q.tokensOut, REAL_TOKENS_OUT, "CurveQuote == the real Trade event");

        uint256 b0 = IIgnixToken(TOKEN_X).balanceOf(BUYER);
        vm.prank(BUYER);
        M.buy{value: AMOUNT_IN}(TOKEN_X, AMOUNT_IN, MIN_OUT);
        Vm.Gas memory g = vm.lastFrameGas();

        assertEq(IIgnixToken(TOKEN_X).balanceOf(BUYER) - b0, REAL_TOKENS_OUT, "fork == mainnet, to the wei");
        console2.log("real receipt gasUsed            ", REAL_GAS_USED);
        console2.log("fork: gas used by the same call ", uint256(g.gasTotalUsed));
        console2.log("fork: refund                    ", uint256(int256(g.gasRefunded)));
        assertEq(
            uint256(g.gasTotalUsed) - uint256(int256(g.gasRefunded)),
            REAL_GAS_USED,
            "fork gas (after refund) == the real receipt, to the unit"
        );
    }

    /// @dev The platform's real daily push, found by scanning the vault's logs:
    ///      tx 0x4c1b8ddd4af56229dcb5b128e99dc9f34506a747d92cb95bd243090276a1eb34, block 72,303,399
    ///      (2026-10-04 00:07:15 UTC), from the operator EOA to the live graduated Directed vault, calldata
    ///      0x67318ec1 + minAmount. It moved 86,793.012027758266434075 tokens to RECIPIENT (0x...dEaD) and
    ///      used 66,828 gas.
    function test_Q10_fork_reproduces_the_real_platform_push_with_its_calldata_threshold() public {
        address operator = 0xcc8D1916A96319A0Cdcde1897DAB61d34322FeFe;
        IDirectedVault v = IDirectedVault(0xa6A54EE383A75DA9A2f6e6a060A4c023C8DE8d64);
        IIgnixToken t = IIgnixToken(0x16Aa672ddA63F5ACd0De098c04c4A3e957d1EEEE);
        uint256 realMinAmount = 0x62b22aa64815705ae; // 113.789... tokens: the off-chain job's threshold
        uint256 realPushed = 86_793_012_027_758_266_434_075;

        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", DEFAULT_RPC), 72_303_398);
        vm.roll(72_303_399);
        vm.warp(1_791_072_435);

        assertEq(v.claimableNow(DEAD, address(t)), realPushed, "the vault balance before the push");
        assertGt(realPushed, realMinAmount);
        uint256 d0 = t.balanceOf(DEAD);
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeWithSelector(0x67318ec1, realMinAmount));
        Vm.Gas memory g = vm.lastFrameGas();
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), realPushed);
        assertEq(t.balanceOf(DEAD) - d0, realPushed, "same amount as the real Transfer log");
        assertEq(t.balanceOf(address(v)), 0);
        assertEq(
            uint256(g.gasTotalUsed) - uint256(int256(g.gasRefunded)), 66_828, "same gas as the real receipt"
        );
    }
}
