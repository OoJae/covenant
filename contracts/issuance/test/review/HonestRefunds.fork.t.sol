// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {XLayerFork} from "../fork/XLayerFork.sol";

interface IVaultMin {
    function claimFor(address recipient, address asset) external returns (uint256);
    function RECIPIENT() external view returns (address);
}

interface IMgr {
    function buyTo(address token, uint256 amountIn, uint256 minTokensOut, address recipient) external payable;
}

/// @notice Review measurement (story lens): the EIP-3529 refunds earned by the two IGNIX calls an honest kernel
///         makes in settle(), on the live contracts at the pinned block. Each passes one storage reentrancy
///         guard, which the EVM pays back with 2,800 gas at the end of the transaction. The tank counts that
///         gas and the caller is not billed for it: this is the figure KeeperTank's NatSpec and NOTES.md quote.
///         Adapted: the reviewer only printed the numbers; they are asserted here.
contract HonestRefundsForkTest is XLayerFork {
    /// @dev IgnixManager, the IGNIX launchpad a kernel buys from. Measured here, not part of the issuance.
    address internal constant IGNIX_MANAGER = 0x96B51c57e5346D0C0198899243cf851D1E23C309;
    address internal constant OB_TOKEN = 0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe;
    address internal constant OB_VAULT = 0xeC7732C9dCF978C8a97E6c44499331757D240365;

    function setUp() public {
        _fork();
    }

    function test_review_measure_claimFor_refund() public {
        address r = IVaultMin(OB_VAULT).RECIPIENT();
        console2.log("vault native balance before", OB_VAULT.balance);
        vm.prank(keeper, keeper);
        IVaultMin(OB_VAULT).claimFor(r, address(0));
        Vm.Gas memory g = vm.lastFrameGas();
        console2.log("claimFor: gas consumed", g.gasTotalUsed);
        console2.log("claimFor: EIP-3529 refund", uint256(int256(g.gasRefunded)));
        console2.log("vault native balance after", OB_VAULT.balance);
        assertEq(uint256(int256(g.gasRefunded)), 2_800, "one storage reentrancy guard");
    }

    function test_review_measure_buyTo_refund() public {
        vm.deal(keeper, 1 ether);
        vm.prank(keeper, keeper);
        IMgr(IGNIX_MANAGER).buyTo{value: 0.001 ether}(OB_TOKEN, 0.001 ether, 0, keeper);
        Vm.Gas memory g = vm.lastFrameGas();
        console2.log("buyTo: gas consumed", g.gasTotalUsed);
        console2.log("buyTo: EIP-3529 refund", uint256(int256(g.gasRefunded)));
        assertEq(uint256(int256(g.gasRefunded)), 2_800, "one storage reentrancy guard");
    }
}
