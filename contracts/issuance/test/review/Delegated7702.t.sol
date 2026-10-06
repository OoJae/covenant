// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {LocalBase} from "../utils/LocalBase.sol";
import {Splitter} from "../../src/Splitter.sol";

/// @dev Smart-account code an EOA can delegate to (EIP-7702).
contract CheapAccount {
    event Got(uint256 value);

    receive() external payable {
        emit Got(msg.value);
    }
}

/// @dev Delegate code with no way to receive OKB.
contract DeafAccount {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Delegate code that burns everything it is offered.
contract GuzzlingAccount {
    receive() external payable {
        while (true) {}
    }
}

/// @notice Review test (splitter lens). X Layer has EIP-7702 live (NOTES.md section 5) and the maintainer is an
///         EOA, so its owner can turn it into "an address with code" at any time.
///         Adapted: the reviewer ran it with `--evm-version prague`. Here setUp switches the test EVM to the
///         Prague rules itself, so the tests run with the rest of the suite while the contracts stay compiled
///         for Cancun, exactly as they are deployed. If a toolchain cannot switch, the tests skip.
contract Delegated7702Test is LocalBase {
    address internal m;
    uint256 internal mKey;

    bool internal pragueRules;

    function setUp() public {
        vm.setEvmVersion("prague");
        (m, mKey) = makeAddrAndKey("maintainer eoa");
        _deployLocal(m);
        vm.deal(m, 1 wei); // the account exists, like a funded deployer

        // Is EIP-7702 active in this run? Under Cancun rules a designator is just invalid code.
        address probe = makeAddr("7702 probe");
        vm.etch(probe, abi.encodePacked(hex"ef0100", address(new CheapAccount())));
        (pragueRules,) = probe.call("");
    }

    modifier onlyPrague() {
        if (!pragueRules) {
            vm.skip(true); // the test EVM does not run the Prague rules
        }
        _;
    }

    function _delegate(address impl) internal {
        vm.etch(m, abi.encodePacked(hex"ef0100", impl));
    }

    function test_7702_isActiveInThisRun() public onlyPrague {
        CheapAccount impl = new CheapAccount();
        _delegate(address(impl));
        assertEq(m.code.length, 23);
        vm.deal(address(this), 1 ether);
        vm.recordLogs();
        (bool ok,) = m.call{value: 1}("");
        assertTrue(ok);
        assertEq(vm.getRecordedLogs().length, 1, "the delegate's code ran in the EOA's context: Prague rules are on");
    }

    function test_7702_delegatedMaintainer_isPaid_atEveryGasLimit() public onlyPrague {
        _delegate(address(new CheapAccount()));
        vm.deal(address(splitter), 1 ether);
        uint256 before = m.balance;
        uint256 succeeded;
        uint256 first;
        for (uint256 gasLimit = 40_000; gasLimit <= 300_000; gasLimit += 61) {
            uint256 snap = vm.snapshotState();
            try splitter.pull{gas: gasLimit}() {
                succeeded++;
                if (first == 0) first = gasLimit;
                assertEq(splitter.maintainerOwed(), 0, "delegated maintainer starved into the credit path");
                assertEq(m.balance - before, 0.15 ether);
            } catch {
                assertEq(address(splitter).balance, 1 ether);
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0);
        console2.log("7702 maintainer: first gas limit at which pull() succeeds:", first);
    }

    function test_7702_guzzlingDelegate_creditedOrReverted_neverHalfDone() public onlyPrague {
        _delegate(address(new GuzzlingAccount()));
        vm.deal(address(splitter), 1 ether);
        uint256 succeeded;
        uint256 first;
        for (uint256 gasLimit = 40_000; gasLimit <= 300_000; gasLimit += 61) {
            uint256 snap = vm.snapshotState();
            try splitter.pull{gas: gasLimit}() {
                succeeded++;
                if (first == 0) first = gasLimit;
                assertEq(splitter.maintainerOwed(), 0.15 ether);
                assertEq(address(tank).balance, 0.85 ether);
            } catch {
                assertEq(address(splitter).balance, 1 ether);
                assertEq(splitter.maintainerOwed(), 0);
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0);
        console2.log("7702 guzzling delegate: first gas limit at which pull() succeeds:", first);
    }

    function test_7702_deafDelegate_isCredited_andClaimableOnceTheDelegationIsGone() public onlyPrague {
        _delegate(address(new DeafAccount()));
        vm.deal(address(splitter), 1 ether);
        splitter.pull();
        assertEq(splitter.maintainerOwed(), 0.15 ether);
        assertEq(address(tank).balance, 0.85 ether);

        vm.expectRevert(Splitter.TransferFailed.selector);
        splitter.claimMaintainer();

        vm.etch(m, ""); // delegation removed
        uint256 before = m.balance;
        splitter.claimMaintainer();
        assertEq(m.balance - before, 0.15 ether);
    }
}
