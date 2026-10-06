// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SSTORE2} from "../src/lib/SSTORE2.sol";
import {NetlistBuilder} from "./utils/NetlistBuilder.sol";
import {ScanHarness} from "./utils/ScanHarness.sol";

/// @notice The snapshot pointer: runtime code 0x00 followed by the data, exactly TapeOut's format.
contract SSTORE2Test is Test {
    ScanHarness internal h;

    function setUp() public {
        h = new ScanHarness();
    }

    function test_write_storesStopThenData() public {
        bytes memory data = hex"00000002000003";
        address pointer = h.write(data);
        assertEq(pointer.code, hex"0000000002000003");
        assertEq(h.read(pointer), data);
    }

    function test_roundTrip_atTheSizesThatMatter() public {
        uint256[6] memory sizes = [uint256(0), 1, 31, 32, 448, 24000];
        for (uint256 i = 0; i < sizes.length; i++) {
            bytes memory data = NetlistBuilder.randomBytes(i, sizes[i]);
            address pointer = h.write(data);
            assertEq(pointer.code.length, sizes[i] + 1);
            assertEq(uint8(pointer.code[0]), 0, "leading STOP");
            assertEq(h.read(pointer), data);
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_roundTrip(bytes calldata data) public {
        address pointer = h.write(data);
        assertEq(pointer.code, abi.encodePacked(hex"00", data));
        assertEq(h.read(pointer), data);
    }

    function test_pointerCannotBeExecuted() public {
        // The code starts with STOP: any call succeeds, does nothing and returns nothing.
        address pointer = h.write(hex"ff6000526001601ff3");
        (bool ok, bytes memory ret) = pointer.call(hex"deadbeef");
        assertTrue(ok);
        assertEq(ret.length, 0);
        assertEq(pointer.code, hex"00ff6000526001601ff3", "unchanged");
    }

    function test_twoWritesOfTheSameData_giveTwoPointers() public {
        bytes memory data = hex"0102030405";
        address a = h.write(data);
        address b = h.write(data);
        assertTrue(a != b);
        assertEq(a.code, b.code);
    }

    function test_read_ofSomethingThatIsNotAPointer() public {
        assertEq(h.read(address(0xdead)), "", "no code");
        vm.etch(address(0xbeef), hex"00");
        assertEq(h.read(address(0xbeef)), "", "a pointer to nothing");
    }

    function test_write_revertsWhenTheCreationFails() public {
        // 2,000 bytes cost 400,000 gas to deposit as code. With 200,000 gas the creation runs out, CREATE
        // returns the zero address and the library reverts instead of handing back a pointer to nothing.
        bytes memory data = NetlistBuilder.randomBytes(1, 2000);
        vm.expectRevert(SSTORE2.WriteFailed.selector);
        h.write{gas: 200_000}(data);

        address pointer = h.write{gas: 600_000}(data);
        assertEq(h.read(pointer), data);
    }
}
