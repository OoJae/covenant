// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeCall} from "../../src/lib/SafeCall.sol";

/// @dev A callee that reverts or returns with data of a chosen size, burns gas, or records what it was sent.
contract Callee {
    uint256 public received;
    uint256 public calls;

    function ok() external payable {
        received += msg.value;
        calls++;
    }

    function okWithData(uint256 n) external pure returns (bytes memory) {
        assembly {
            mstore(0x00, not(0))
            return(0x00, n)
        }
    }

    function failWith(bytes calldata data) external pure {
        bytes memory d = data;
        assembly {
            revert(add(d, 0x20), mload(d))
        }
    }

    function failBig(uint256 n) external pure {
        assembly {
            revert(0x00, n)
        }
    }

    function burn() external pure {
        while (true) {}
    }

    /// @dev Reverts with the gas it had when it was entered (less the few units of its own dispatch).
    function failWithGasLeft() external payable {
        uint256 g = gasleft();
        assembly {
            mstore(0x00, g)
            revert(0x00, 0x20)
        }
    }
}

/// @dev SafeCall's functions are internal: this exposes `execCatch` and checks the memory around its result.
contract SafeCallHarness {
    function execCatch(address target, uint256 gasCap, uint256 value, bytes memory data, uint256 max)
        external
        payable
        returns (bool ok, bytes memory err, bytes32 guardBefore, bytes32 guardAfter, uint256 gasUsed)
    {
        // an allocation before and one after: the result must not overlap either
        bytes memory before = abi.encodePacked(keccak256("before"));
        uint256 g = gasleft();
        (ok, err) = SafeCall.execCatch(target, gasCap, value, data, max);
        gasUsed = g - gasleft();
        bytes memory afterwards = abi.encodePacked(keccak256("after"));
        guardBefore = bytes32(before);
        guardAfter = bytes32(afterwards);
    }
}

/// @notice SafeCall.execCatch: the call the kernel uses for its router buy. Like `exec` it can never make the
///         caller revert; on failure it hands back a bounded prefix of the revert data.
contract SafeCallTest is Test {
    uint256 internal constant CALLER_GAS = 8_000_000;

    Callee internal callee;
    SafeCallHarness internal h;

    function setUp() public {
        callee = new Callee();
        h = new SafeCallHarness();
        vm.deal(address(h), 10 ether);
    }

    function _run(bytes memory data, uint256 value, uint256 gasCap, uint256 max)
        internal
        returns (bool ok, bytes memory err, uint256 gasUsed)
    {
        bytes32 a;
        bytes32 b;
        // the caller itself has a bounded amount of gas, far above every cap used here
        (ok, err, a, b, gasUsed) = h.execCatch{gas: CALLER_GAS}(address(callee), gasCap, value, data, max);
        assertEq(a, keccak256("before"), "memory before the result is intact");
        assertEq(b, keccak256("after"), "memory after the result is intact");
    }

    function test_success_copies_nothing_and_forwards_the_value() public {
        (bool ok, bytes memory err,) = _run(abi.encodeCall(Callee.ok, ()), 1 ether, 100_000, 100);
        assertTrue(ok);
        assertEq(err.length, 0, "nothing is copied when the call succeeds");
        assertEq(callee.received(), 1 ether);
        assertEq(address(callee).balance, 1 ether);
        // a successful call that returns data: still nothing is copied
        (ok, err,) = _run(abi.encodeCall(Callee.okWithData, (64)), 0, 100_000, 100);
        assertTrue(ok);
        assertEq(err.length, 0);
    }

    function test_failure_returns_the_revert_data_up_to_max() public {
        bytes memory locked = abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKED");
        assertEq(locked.length, 100);
        (bool ok, bytes memory err,) = _run(abi.encodeCall(Callee.failWith, (locked)), 0, 100_000, 100);
        assertFalse(ok);
        assertEq(err, locked, "the whole revert data when it fits");
        // shorter than max: exactly what was reverted with
        (ok, err,) = _run(abi.encodeCall(Callee.failWith, (hex"3ee5aeb5")), 0, 100_000, 100);
        assertFalse(ok);
        assertEq(err, hex"3ee5aeb5");
        (ok, err,) = _run(abi.encodeCall(Callee.failWith, ("")), 0, 100_000, 100);
        assertFalse(ok);
        assertEq(err.length, 0);
        // longer than max: the first max bytes
        bytes memory long_ = bytes.concat(locked, hex"0102030405060708");
        (ok, err,) = _run(abi.encodeCall(Callee.failWith, (long_)), 0, 100_000, 100);
        assertFalse(ok);
        assertEq(err, locked);
        (ok, err,) = _run(abi.encodeCall(Callee.failWith, (long_)), 0, 100_000, 7);
        assertEq(err, hex"08c379a0000000");
        (ok, err,) = _run(abi.encodeCall(Callee.failWith, (long_)), 0, 100_000, 0);
        assertFalse(ok);
        assertEq(err.length, 0);
    }

    function test_failed_call_keeps_the_value() public {
        uint256 before = address(h).balance;
        (bool ok,,) = _run(abi.encodeCall(Callee.failWith, (hex"00")), 1 ether, 100_000, 100);
        assertFalse(ok);
        assertEq(address(h).balance, before, "the value came back with the revert");
        assertEq(callee.received(), 0);
    }

    function test_revert_bomb_is_not_copied() public {
        // 1 MB of revert data: the callee pays for producing it; the caller copies 100 bytes of it
        (bool ok, bytes memory err, uint256 gasUsed) =
            _run(abi.encodeCall(Callee.failBig, (1 << 20)), 0, 3_000_000, 100);
        assertFalse(ok);
        assertEq(err.length, 100);
        assertLt(gasUsed, 2_400_000, "the caller did not pay to copy the megabyte");
    }

    function test_gas_cap_is_honoured() public {
        (bool ok, bytes memory err, uint256 gasUsed) = _run(abi.encodeCall(Callee.burn, ()), 0, 50_000, 100);
        assertFalse(ok);
        assertEq(err.length, 0, "out of gas: no revert data");
        assertLt(gasUsed, 60_000, "the callee could burn only what it was given");
        assertGt(gasUsed, 50_000);
    }

    /// The callee is handed the cap, not what the caller has: seen from inside the callee.
    function test_callee_receives_the_cap_and_no_more() public {
        (bool ok, bytes memory err,) = _run(abi.encodeCall(Callee.failWithGasLeft, ()), 0, 50_000, 100);
        assertFalse(ok);
        uint256 seen = abi.decode(err, (uint256));
        assertLe(seen, 50_000, "no more than the cap, although the caller had millions");
        assertGt(seen, 49_500, "and all of the cap");
        // with a value the EVM adds its 2,300 stipend on top of the cap, and nothing else
        (ok, err,) = _run(abi.encodeCall(Callee.failWithGasLeft, ()), 1, 50_000, 100);
        assertFalse(ok);
        seen = abi.decode(err, (uint256));
        assertLe(seen, 52_300);
        assertGt(seen, 51_800);
    }

    function test_address_without_code_counts_as_success() public {
        bytes32 a;
        bytes32 b;
        (bool ok, bytes memory err,,,) =
            h.execCatch{gas: CALLER_GAS}(makeAddr("nobody"), 100_000, 0, hex"12345678", 100);
        (a, b);
        assertTrue(ok, "as for exec: callers only use it on addresses that were verified to be contracts");
        assertEq(err.length, 0);
    }
}
