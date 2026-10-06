// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {NetlistScan} from "../../src/lib/NetlistScan.sol";
import {NetlistOracle} from "../utils/NetlistOracle.sol";

contract ScanHarness {
    function burnOf(bytes memory nl) external pure returns (uint256 nNand, uint256 nLatch) {
        return NetlistScan.burnOf(nl);
    }
}

/// @notice NetlistScan against TapeOut's own `NetlistVM.burnOf` (vendored, unmodified) and against
///         hand-built records.
contract NetlistScanTest is Test {
    ScanHarness internal scan;
    NetlistOracle internal oracle;

    bytes internal constant NAND3 = hex"000000020000030000000400000400000005000005";

    function setUp() public {
        scan = new ScanHarness();
        oracle = new NetlistOracle();
    }

    // ------------------------------------------------------------------ record builders

    function _nand(uint24 a, uint24 b) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), a, b);
    }

    function _latch(uint24 d) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), d);
    }

    function _ref(address cpu, uint64 id, uint8 nIns, uint8 nOuts, uint256 seed)
        internal
        pure
        returns (bytes memory r)
    {
        r = abi.encodePacked(uint8(2), cpu, id, nIns, nOuts);
        for (uint256 i = 0; i < nIns; i++) {
            r = bytes.concat(r, abi.encodePacked(uint24(uint256(keccak256(abi.encode(seed, i))))));
        }
    }

    /// @dev a random well-formed netlist, with the offset at which every record starts
    function _random(uint256 seed, uint256 records)
        internal
        pure
        returns (bytes memory nl, uint256[] memory starts, uint256 nNand, uint256 nLatch)
    {
        starts = new uint256[](records + 1);
        for (uint256 i = 0; i < records; i++) {
            starts[i] = nl.length;
            uint256 r = uint256(keccak256(abi.encode(seed, "record", i)));
            uint256 kind = r % 10;
            if (kind < 5) {
                nl = bytes.concat(nl, _nand(uint24(r >> 8), uint24(r >> 32)));
                nNand++;
            } else if (kind < 8) {
                nl = bytes.concat(nl, _latch(uint24(r >> 8)));
                nLatch++;
            } else {
                // operands are random on purpose: 0x00, 0x01 and 0x02 bytes inside a record must not be read as opcodes
                uint8 nIns = kind == 8 ? uint8((r >> 8) % 6) : uint8(r >> 8);
                nl = bytes.concat(nl, _ref(address(uint160(r >> 16)), uint64(r >> 100), nIns, uint8(r >> 180), r));
            }
        }
        starts[records] = nl.length;
    }

    // ------------------------------------------------------------------ fixed vectors

    function test_empty() public view {
        (uint256 nNand, uint256 nLatch) = scan.burnOf("");
        assertEq(nNand, 0);
        assertEq(nLatch, 0);
    }

    function test_theThreeNandNetlist() public view {
        (uint256 nNand, uint256 nLatch) = scan.burnOf(NAND3);
        assertEq(nNand, 3);
        assertEq(nLatch, 0);
    }

    function test_recordSizes() public pure {
        assertEq(_nand(1, 2).length, 7);
        assertEq(_latch(1).length, 4);
        assertEq(_ref(address(1), 1, 0, 1, 0).length, 31);
        assertEq(_ref(address(1), 1, 2, 1, 0).length, 37);
        assertEq(_ref(address(1), 1, 255, 1, 0).length, 31 + 3 * 255);
    }

    function test_refCountsZero() public view {
        bytes memory nl = _ref(address(0xC0FFEE), 7, 2, 1, 1);
        (uint256 nNand, uint256 nLatch) = scan.burnOf(nl);
        assertEq(nNand, 0);
        assertEq(nLatch, 0);
    }

    function test_refWithNoInputs_andWith255Inputs() public view {
        bytes memory nl =
            bytes.concat(_ref(address(1), 1, 0, 3, 1), _nand(2, 3), _ref(address(2), 9, 255, 255, 2), _latch(4));
        (uint256 nNand, uint256 nLatch) = scan.burnOf(nl);
        assertEq(nNand, 1);
        assertEq(nLatch, 1);
    }

    function test_onlyTopLevelRecordsCount_refOperandsAreSkipped() public view {
        // A REF whose cpu, id and input bytes are all 0x00 or 0x01: 20 + 8 + 2 + 3*4 bytes that look like opcodes.
        bytes memory ref = abi.encodePacked(
            uint8(2),
            address(0),
            uint64(0x0001000100010001),
            uint8(4),
            uint8(1),
            uint24(0),
            uint24(1),
            uint24(0x000100),
            uint24(0x010001)
        );
        bytes memory nl = bytes.concat(_nand(0, 0), ref, _latch(0x000001), _nand(0x010101, 0x020202));
        (uint256 nNand, uint256 nLatch) = scan.burnOf(nl);
        assertEq(nNand, 2);
        assertEq(nLatch, 1);
        (uint256 oNand, uint256 oLatch) = oracle.burnOf(nl);
        assertEq(oNand, 2);
        assertEq(oLatch, 1);
    }

    function test_flagshipSizedNetlist_gas() public view {
        // 2,120 NAND + 64 LATCH, the size planned for the flagship chip
        bytes memory nl;
        for (uint256 i = 0; i < 64; i++) {
            nl = bytes.concat(nl, _latch(uint24(i)));
        }
        bytes memory nands = new bytes(2120 * 7); // all-zero bytes: 2,120 NAND(0,0) records
        nl = bytes.concat(nl, nands);

        uint256 g = gasleft();
        (uint256 nNand, uint256 nLatch) = scan.burnOf(nl);
        g -= gasleft();
        assertEq(nNand, 2120);
        assertEq(nLatch, 64);
        console2.log("gas to scan a 2,184-transistor netlist (15,096 bytes), external call included:", g);
        assertLt(g, 1_000_000);
    }

    // ------------------------------------------------------------------ malformed input

    function test_unknownOpcode_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.BadOpcode.selector, 0, 3));
        scan.burnOf(hex"03");

        bytes memory nl = bytes.concat(_nand(2, 3), hex"ff000000");
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.BadOpcode.selector, 7, 0xff));
        scan.burnOf(nl);
    }

    function test_truncatedNand_reverts() public {
        bytes memory nl = bytes.concat(_nand(2, 3), hex"000000020000"); // second NAND is one byte short
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TruncatedRecord.selector, 7));
        scan.burnOf(nl);
    }

    function test_truncatedLatch_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TruncatedRecord.selector, 0));
        scan.burnOf(hex"010000");
    }

    function test_truncatedRefHeader_reverts() public {
        bytes memory full = _ref(address(1), 1, 2, 1, 0);
        bytes memory cut = new bytes(30); // one byte short of the 31-byte header
        for (uint256 i = 0; i < 30; i++) {
            cut[i] = full[i];
        }
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TruncatedRecord.selector, 0));
        scan.burnOf(cut);
    }

    function test_truncatedRefInputs_reverts() public {
        bytes memory full = _ref(address(1), 1, 2, 1, 0); // 37 bytes
        bytes memory cut = new bytes(36);
        for (uint256 i = 0; i < 36; i++) {
            cut[i] = full[i];
        }
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TruncatedRecord.selector, 0));
        scan.burnOf(cut);
    }

    /// TapeOut's scan is lenient where ours is strict: it counts a NAND whose record is cut short.
    /// (Its tape-out path rejects such netlists elsewhere, so none exists on-chain; ours never trusts that.)
    function test_strictWhereTapeOutIsLenient() public {
        bytes memory nl = hex"0000"; // 2 of the 7 bytes of a NAND
        (uint256 oNand,) = oracle.burnOf(nl);
        assertEq(oNand, 1);

        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TruncatedRecord.selector, 0));
        scan.burnOf(nl);

        // and TapeOut's panics (array out of bounds) on a cut REF, where ours reports the record
        vm.expectRevert(stdError.indexOOBError);
        oracle.burnOf(hex"02");
    }

    // ------------------------------------------------------------------ fuzz

    /// On every well-formed netlist the two scans agree, and both equal the number of records generated.
    function testFuzz_matchesTapeOutOnWellFormedNetlists(uint256 seed, uint8 records) public view {
        (bytes memory nl,, uint256 nNand, uint256 nLatch) = _random(seed, uint256(records) % 96);

        (uint256 sNand, uint256 sLatch) = scan.burnOf(nl);
        (uint256 oNand, uint256 oLatch) = oracle.burnOf(nl);

        assertEq(sNand, oNand, "NAND count differs from TapeOut's");
        assertEq(sLatch, oLatch, "LATCH count differs from TapeOut's");
        assertEq(sNand, nNand);
        assertEq(sLatch, nLatch);
    }

    /// Cutting a well-formed netlist anywhere but on a record boundary reverts and names the cut record;
    /// cutting it on a boundary gives the counts of the prefix.
    function testFuzz_truncation(uint256 seed, uint8 records, uint256 cutSeed) public {
        uint256 n = 1 + uint256(records) % 48;
        (bytes memory nl, uint256[] memory starts,,) = _random(seed, n);
        uint256 cut = cutSeed % nl.length; // 0 .. length-1
        bytes memory prefix = new bytes(cut);
        for (uint256 i = 0; i < cut; i++) {
            prefix[i] = nl[i];
        }

        // the record that contains byte `cut`
        uint256 k = 0;
        while (starts[k + 1] <= cut) k++;

        if (starts[k] == cut) {
            (uint256 sNand, uint256 sLatch) = scan.burnOf(prefix);
            (uint256 oNand, uint256 oLatch) = oracle.burnOf(prefix);
            assertEq(sNand, oNand);
            assertEq(sLatch, oLatch);
        } else {
            vm.expectRevert(abi.encodeWithSelector(NetlistScan.TruncatedRecord.selector, starts[k]));
            scan.burnOf(prefix);
        }
    }

    /// An opcode other than 0, 1, 2 at a record boundary always reverts and is reported with its offset.
    function testFuzz_unknownOpcode(uint256 seed, uint8 records, uint8 opcode, bytes calldata tail) public {
        vm.assume(opcode > 2);
        (bytes memory head,,,) = _random(seed, uint256(records) % 32);
        bytes memory nl = bytes.concat(head, abi.encodePacked(opcode), tail);

        vm.expectRevert(abi.encodeWithSelector(NetlistScan.BadOpcode.selector, head.length, opcode));
        scan.burnOf(nl);
    }

    /// Arbitrary bytes: the scan either reverts with one of its two errors or returns counts that fit the length.
    function testFuzz_arbitraryBytes(bytes calldata nl) public view {
        try scan.burnOf(nl) returns (uint256 nNand, uint256 nLatch) {
            assertLe(nNand * 7 + nLatch * 4, nl.length);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(sel == NetlistScan.BadOpcode.selector || sel == NetlistScan.TruncatedRecord.selector);
        }
    }
}
