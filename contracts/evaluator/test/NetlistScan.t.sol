// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {BadOpcode, FutureSignal, LatchOutOfRange, TooFewSignals, TruncatedRecord} from "../src/lib/NetlistErrors.sol";
import {NetlistScan} from "../src/lib/NetlistScan.sol";
import {NetlistBuilder} from "./utils/NetlistBuilder.sol";
import {INetlistVMHarness} from "./utils/Oracles.sol";
import {ScanHarness} from "./utils/ScanHarness.sol";
import {V1Reference} from "./utils/V1Reference.sol";

/// @notice The v1 chip shape (chips/INTERFACE.md, section 2) as NetlistScan enforces it.
contract NetlistScanTest is Test {
    ScanHarness internal h;
    INetlistVMHarness internal oracle;

    uint256 internal constant FIRST = 98; // 2 constants + 96 inputs

    function setUp() public {
        h = new ScanHarness();
        oracle = INetlistVMHarness(deployCode("NetlistVMHarness.sol:NetlistVMHarness"));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev `k` LATCH records (d = input 0) then `n` NAND records (inputs 0 and 1).
    function _shape(uint256 k, uint256 n) internal pure returns (bytes memory nl) {
        nl = new bytes(4 * k + 7 * n);
        for (uint256 i = 0; i < k; i++) {
            nl[4 * i] = 0x01;
            nl[4 * i + 3] = 0x02;
        }
        for (uint256 j = 0; j < n; j++) {
            nl[4 * k + 7 * j + 3] = 0x02;
            nl[4 * k + 7 * j + 6] = 0x03;
        }
    }

    // ------------------------------------------------------------------ accepted shapes

    function test_constants_matchTheInterface() public pure {
        assertEq(NetlistScan.N_IN, 96);
        assertEq(NetlistScan.N_OUT, 112);
        assertEq(NetlistScan.MAX_STATE, 256);
        assertEq(NetlistScan.MAX_GATES, 3400);
        assertEq(NetlistScan.MAX_BYTES, 24000);
    }

    function test_accepts_minimalChips() public view {
        uint256[5] memory ks = [uint256(1), 2, 64, 255, 256];
        for (uint256 i = 0; i < ks.length; i++) {
            (uint256 nNand, uint256 nLatch) = h.scan(NetlistBuilder.minimalV1(ks[i]));
            assertEq(nNand, 112);
            assertEq(nLatch, ks[i]);
        }
    }

    function test_accepts_theBoundaries() public view {
        // exactly 112 records: one LATCH and 111 NAND
        (uint256 nNand, uint256 nLatch) = h.scan(_shape(1, 111));
        assertEq(nNand, 111);
        assertEq(nLatch, 1);

        // exactly 112 records, all LATCH: every output is a LATCH output and no NAND is needed
        (nNand, nLatch) = h.scan(_shape(112, 0));
        assertEq(nNand, 0);
        assertEq(nLatch, 112);

        // exactly 3,400 gates, with 1 and with 256 state bits
        (nNand, nLatch) = h.scan(_shape(1, 3399));
        assertEq(nNand + nLatch, 3400);
        (nNand, nLatch) = h.scan(_shape(256, 3144));
        assertEq(nNand, 3144);
        assertEq(nLatch, 256);
    }

    function test_accepts_latchReadingAnySignal() public view {
        // one LATCH and 111 NAND: 210 signals. The LATCH may take the last one (a forward reference),
        // itself, a constant or an input.
        uint256[5] memory ds = [uint256(209), FIRST, 0, 1, 97];
        for (uint256 i = 0; i < ds.length; i++) {
            bytes memory nl = _shape(1, 111);
            nl[1] = bytes1(uint8(ds[i] >> 16));
            nl[2] = bytes1(uint8(ds[i] >> 8));
            nl[3] = bytes1(uint8(ds[i]));
            h.scan(nl);
        }
    }

    function test_accepts_nandReadingTheSignalJustBeforeIt() public view {
        bytes memory nl = _shape(1, 111);
        // last NAND produces signal 209; let it read 208 twice
        uint256 p = nl.length - 7;
        nl[p + 3] = bytes1(uint8(208));
        nl[p + 6] = bytes1(uint8(208));
        h.scan(nl);
    }

    // ------------------------------------------------------------------ rejections

    function test_revert_netlistTooLong() public {
        bytes memory nl = _shape(1, 3429); // 24,007 bytes
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.NetlistTooLong.selector, 24007));
        h.scan(nl);
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.NetlistTooLong.selector, 24001));
        h.scan(new bytes(24001));
    }

    function test_revert_stateCountOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.StateCountOutOfRange.selector, 0));
        h.scan(_shape(0, 200)); // combinational: no LATCH
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.StateCountOutOfRange.selector, 0));
        h.scan("");
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.StateCountOutOfRange.selector, 257));
        h.scan(_shape(257, 10));
        // 6,000 LATCH records: exactly 24,000 bytes, so the length check passes and this one answers
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.StateCountOutOfRange.selector, 6000));
        h.scan(_shape(6000, 0));
    }

    function test_revert_tooManyGates() public {
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TooManyGates.selector, 3401));
        h.scan(_shape(1, 3400));
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TooManyGates.selector, 3401));
        h.scan(_shape(256, 3145));
    }

    function test_revert_tooFewSignals() public {
        vm.expectRevert(abi.encodeWithSelector(TooFewSignals.selector, 111));
        h.scan(_shape(1, 110));
        vm.expectRevert(abi.encodeWithSelector(TooFewSignals.selector, 111));
        h.scan(_shape(111, 0));
        vm.expectRevert(abi.encodeWithSelector(TooFewSignals.selector, 1));
        h.scan(_shape(1, 0));
    }

    function test_revert_refNotAllowed() public {
        // a REF record where the first NAND should be
        bytes memory ref = abi.encodePacked(uint8(0x02), address(0xaa), uint64(1), uint8(1), uint8(1), uint24(2));
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.RefNotAllowed.selector, 4));
        h.scan(bytes.concat(_shape(1, 0), ref, _shape(0, 120)));

        // a REF after some gates
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.RefNotAllowed.selector, 4 + 7 * 120));
        h.scan(bytes.concat(_shape(1, 120), ref));

        // a REF as the very first record
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.RefNotAllowed.selector, 0));
        h.scan(bytes.concat(ref, _shape(1, 120)));
    }

    function test_revert_badOpcode() public {
        bytes memory nl = _shape(2, 120);
        nl[8] = 0x03; // the first NAND's opcode
        vm.expectRevert(abi.encodeWithSelector(BadOpcode.selector, 8, 3));
        h.scan(nl);

        nl = _shape(2, 120);
        nl[8 + 7 * 50] = 0xff;
        vm.expectRevert(abi.encodeWithSelector(BadOpcode.selector, 8 + 7 * 50, 255));
        h.scan(nl);
    }

    function test_revert_latchAfterNand() public {
        // LATCH, NAND, LATCH, then enough NAND records
        bytes memory nl = bytes.concat(_shape(1, 1), _shape(1, 120));
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.LatchAfterNand.selector, 11));
        h.scan(nl);

        // a NAND first, LATCH records later
        nl = bytes.concat(_shape(0, 1), _shape(4, 120));
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.LatchAfterNand.selector, 7));
        h.scan(nl);

        // a LATCH as the last record
        nl = bytes.concat(_shape(1, 120), _shape(1, 0));
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.LatchAfterNand.selector, 4 + 7 * 120));
        h.scan(nl);
    }

    function test_revert_futureSignal() public {
        // the first NAND produces signal 99 (one LATCH before it): it may read 0 .. 98
        bytes memory nl = _shape(1, 120);
        nl[4 + 3] = bytes1(uint8(99)); // a = its own signal
        vm.expectRevert(abi.encodeWithSelector(FutureSignal.selector, 4));
        h.scan(nl);

        nl = _shape(1, 120);
        nl[4 + 6] = bytes1(uint8(100)); // b = a later signal
        vm.expectRevert(abi.encodeWithSelector(FutureSignal.selector, 4));
        h.scan(nl);

        nl = _shape(1, 120);
        nl[4 + 7 * 119 + 1] = 0xff; // a = 0xff0002 in the last NAND
        vm.expectRevert(abi.encodeWithSelector(FutureSignal.selector, 4 + 7 * 119));
        h.scan(nl);
    }

    function test_revert_latchOutOfRange() public {
        // one LATCH and 111 NAND: 210 signals, so d = 210 does not exist
        bytes memory nl = _shape(1, 111);
        nl[3] = bytes1(uint8(210));
        vm.expectRevert(abi.encodeWithSelector(LatchOutOfRange.selector, 210, 210));
        h.scan(nl);

        nl = _shape(3, 120);
        nl[4 + 1] = 0xff; // second LATCH: d = 0xff0002
        vm.expectRevert(abi.encodeWithSelector(LatchOutOfRange.selector, 0xff0002, 98 + 123));
        h.scan(nl);
    }

    function test_revert_truncatedRecord_everyCut() public {
        bytes memory good = _shape(2, 120);
        for (uint256 cut = 1; cut <= 6; cut++) {
            vm.expectRevert(TruncatedRecord.selector);
            h.scan(NetlistBuilder.head(good, good.length - cut));
        }
        // a cut LATCH: 112 complete LATCH records and part of one more
        good = _shape(113, 0);
        for (uint256 cut = 1; cut <= 3; cut++) {
            vm.expectRevert(TruncatedRecord.selector);
            h.scan(NetlistBuilder.head(good, good.length - cut));
        }
    }

    function test_truncatedRecord_isNotMaskedByFollowingCalldata() public view {
        // A cut NAND reads the bytes that follow the netlist in calldata. Whatever they are, the scan
        // must reject: here the missing bytes would complete a valid record if they were read.
        bytes memory good = _shape(1, 120);
        bytes memory cut = NetlistBuilder.head(good, good.length - 3);
        (bool ok, bytes memory ret) = address(h)
            .staticcall(bytes.concat(abi.encodeCall(ScanHarness.scan, (cut)), hex"000003000000000000000000000000"));
        assertFalse(ok);
        assertEq(bytes4(ret), TruncatedRecord.selector);
    }

    // ------------------------------------------------------------------ properties

    /// @notice A random valid v1 chip is accepted with the right counts, and TapeOut's own tape-out
    ///         check accepts it with the same counts.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_acceptsEveryValidChip(uint256 seed, uint16 latchSeed, uint16 nandSeed) public view {
        uint256 k = 1 + (uint256(latchSeed) % 256);
        uint256 lo = k >= 112 ? 0 : 112 - k;
        uint256 n = lo + (uint256(nandSeed) % (3400 - k - lo + 1));
        bytes memory nl = NetlistBuilder.randomV1(seed, k, n);

        (uint256 nNand, uint256 nLatch) = h.scan(nl);
        assertEq(nNand, n);
        assertEq(nLatch, k);

        (uint256 tNand, uint256 tLatch, uint32 tState, uint32 tGates) = oracle.analyze(nl, 96, 112);
        assertEq(tNand, n);
        assertEq(tLatch, k);
        assertEq(tState, k);
        assertEq(tGates, n + k);
    }

    /// @notice NetlistScan agrees with the plain reading of section 2 on damaged chips, and whatever
    ///         it accepts TapeOut's tape-out check accepts too, with the same counts.
    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 20000
    function testFuzz_agreesWithTheReference(uint256 seed) public view {
        bytes memory nl = V1Reference.mutant(seed);
        (bool want, uint256 wNand, uint256 wLatch) = V1Reference.check(nl);

        (bool ok, bytes memory ret) = address(h).staticcall(abi.encodeCall(ScanHarness.scan, (nl)));
        assertEq(ok, want, "NetlistScan and the reference disagree");
        if (!ok) return;

        (uint256 nNand, uint256 nLatch) = abi.decode(ret, (uint256, uint256));
        assertEq(nNand, wNand);
        assertEq(nLatch, wLatch);

        (uint256 tNand, uint256 tLatch, uint32 tState, uint32 tGates) = oracle.analyze(nl, 96, 112);
        assertEq(tNand, nNand);
        assertEq(tLatch, nLatch);
        assertEq(tState, nLatch);
        assertEq(tGates, nNand + nLatch);
    }

    /// @notice The damage reaches every rejection of the scan, and leaves enough chips valid.
    function test_census_ofDamagedChips() public view {
        uint256 accepted;
        bytes4[9] memory sels = [
            TruncatedRecord.selector,
            NetlistScan.RefNotAllowed.selector,
            BadOpcode.selector,
            NetlistScan.LatchAfterNand.selector,
            NetlistScan.StateCountOutOfRange.selector,
            TooFewSignals.selector,
            FutureSignal.selector,
            LatchOutOfRange.selector,
            NetlistScan.NetlistTooLong.selector
        ];
        uint256[9] memory hits;
        for (uint256 seed = 0; seed < 4000; seed++) {
            bytes memory nl = V1Reference.mutant(seed);
            (bool want,,) = V1Reference.check(nl);
            (bool ok, bytes memory ret) = address(h).staticcall(abi.encodeCall(ScanHarness.scan, (nl)));
            assertEq(ok, want);
            if (ok) {
                accepted++;
                continue;
            }
            bool known;
            for (uint256 i = 0; i < sels.length; i++) {
                if (bytes4(ret) == sels[i]) {
                    hits[i]++;
                    known = true;
                }
            }
            assertTrue(known, "unexpected revert");
        }
        console2.log("damaged chips accepted:", accepted);
        string[9] memory names = [
            "TruncatedRecord",
            "RefNotAllowed",
            "BadOpcode",
            "LatchAfterNand",
            "StateCountOutOfRange",
            "TooFewSignals",
            "FutureSignal",
            "LatchOutOfRange",
            "NetlistTooLong"
        ];
        for (uint256 i = 0; i < 9; i++) {
            console2.log(names[i], hits[i]);
        }
        assertGt(accepted, 800);
        // every rejection the damage can produce; the two size limits are covered by the unit tests above
        for (uint256 i = 0; i < 8; i++) {
            assertGt(hits[i], 15, names[i]);
        }
    }
}
