// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {KernelFactory} from "../../src/KernelFactory.sol";
import {Globals} from "../../src/interfaces/IKernelExt.sol";
import {Envelope} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel, MockFab, MockCircuits} from "../mocks/MockTapeOut.sol";
import {MockToken, MockVault, LyingVault} from "../mocks/MockIgnix.sol";

/// @notice KernelFactory.create / predict and Kernel.bind.
contract BindFactoryTest is Base {
    bytes14 internal W = _word(128, 64, 48, 16, 0, 1023);
    bytes internal NL;

    function setUp() public override {
        super.setUp();
        NL = ChipModel.fixedChip(64, W);
    }

    function _tape() internal returns (uint256 id) {
        vm.prank(launcher);
        id = fab.tapeoutChip(NL, 2200);
    }

    function _unbound() internal returns (Kernel k, uint256 id) {
        id = _tape();
        k = Kernel(payable(factory.create(_env(), id, bytes32("s"))));
    }

    // ------------------------------------------------------------------ create

    function test_create_is_deterministic_and_independent_of_the_token() public {
        uint256 id = _tape();
        address predicted = factory.predict(_env(), id, bytes32("s"));
        assertEq(predicted.code.length, 0, "nothing there yet");
        // the token does not exist yet: the address is known first, then the token is launched against it
        (address t,) = manager.createToken(launcher, predicted, 300, 300, 0, 0, GRADUATION);
        address k = factory.create(_env(), id, bytes32("s"));
        assertEq(k, predicted);
        assertTrue(factory.isKernel(k));
        assertEq(factory.kernelOf(t), address(0), "not bound yet");
        assertGt(k.code.length, 0);
    }

    function test_create_twice_returns_the_same_kernel() public {
        uint256 id = _tape();
        address a = factory.create(_env(), id, bytes32("s"));
        vm.prank(alice); // a front-runner changes nothing
        address b = factory.create(_env(), id, bytes32("s"));
        assertEq(a, b);
    }

    function test_address_commits_to_envelope_chip_and_salt() public {
        uint256 id = _tape();
        uint256 id2 = _tape();
        address a = factory.predict(_env(), id, bytes32("s"));
        assertTrue(a != factory.predict(_env(), id, bytes32("t")), "salt");
        assertTrue(a != factory.predict(_env(), id2, bytes32("s")), "chip");
        Envelope memory e = _env();
        e.capT = 65;
        assertTrue(a != factory.predict(e, id, bytes32("s")), "envelope");
    }

    function test_clone_carries_envelope_and_globals_as_bytecode() public {
        (Kernel k, uint256 id) = _unbound();
        Envelope memory e = k.envelope();
        Envelope memory x = _env();
        assertEq(abi.encode(e), abi.encode(x), "envelope round trip");
        Globals memory g = k.globals();
        assertEq(g.manager, address(manager));
        assertEq(g.v2Router, address(router));
        assertEq(g.wokb, address(wokb));
        assertEq(g.factory, address(factory));
        assertEq(g.circuits, address(circuits));
        assertEq(g.fab, address(fab));
        assertEq(g.sealedVM, address(sealedVM));
        assertEq(g.beacon, address(beacon));
        assertEq(g.impl0, address(impl));
        assertEq(g.impl0Hash, address(impl).codehash);
        (address snap, bytes32 h,,,,) = fab.chipInfo(id);
        assertEq(g.snapshot, snap);
        assertEq(g.netlistHash, h);
        assertEq(g.netlistHash, keccak256(NL));
        assertEq(g.chipId, id);
        assertEq(k.chipId(), id);
        assertEq(g.nState, 64);
        assertEq(g.gateCount, 2200);
        assertEq(g.netlistLen, NL.length);
        // the two step-gas amounts, fixed at creation from the chip's counts (2,200 records, 64 of them latches)
        assertEq(g.stepFloor, 200_000 + 2_600 * 2200 + 800 * 64, "TapeOut's evaluator");
        assertEq(g.sealedFloor, 40_000 + 200 * (2200 - 64) + 400 * 64, "the sealed evaluator");
        // no storage was written: the configuration cannot be changed by anything
        assertEq(vm.load(address(k), bytes32(uint256(0))), bytes32(0));
    }

    function test_minSettleGas_grows_with_the_chip() public {
        (Kernel k,) = _unbound();
        vm.prank(launcher);
        uint256 big = fab.tapeoutChip(NL, 3400);
        Kernel kBig = Kernel(payable(factory.create(_env(), big, bytes32("s"))));
        assertGt(kBig.minSettleGas(), k.minSettleGas());
        // the chip with the largest floors: 3,400 records, 256 of them latches
        vm.prank(launcher);
        uint256 widest = fab.tapeoutChip(ChipModel.fixedChip(256, W), 3400);
        Kernel kMax = Kernel(payable(factory.create(_env(), widest, bytes32("s"))));
        assertEq(kMax.globals().stepFloor, 200_000 + 2_600 * 3400 + 800 * 256);
        assertEq(kMax.globals().sealedFloor, 40_000 + 200 * 3144 + 400 * 256);
        assertGt(kMax.minSettleGas(), kBig.minSettleGas(), "latches cost more than NANDs on both evaluators");
        assertLt(kMax.minSettleGas(), 15_500_000, "the largest chip stays 1.2M below a 16,777,216 transaction cap");
    }

    /// Each floor is its own formula of the chip's two counts (chips/INTERFACE.md section 2).
    function test_step_gas_formulas() public {
        assertEq(factory.STEP_BASE(), 200_000);
        assertEq(factory.STEP_PER_GATE(), 2_600);
        assertEq(factory.STEP_PER_LATCH(), 800);
        assertEq(factory.SEALED_BASE(), 40_000);
        assertEq(factory.SEALED_PER_NAND(), 200);
        assertEq(factory.SEALED_PER_LATCH(), 400);
        // (latches, records): the smallest chip, a chip with no NAND, the largest chip
        uint32[2][5] memory shapes =
            [[uint32(1), 112], [uint32(112), 112], [uint32(256), 256], [uint32(1), 3400], [uint32(256), 3400]];
        for (uint256 i = 0; i < shapes.length; i++) {
            (uint256 k, uint256 gates) = (shapes[i][0], shapes[i][1]);
            vm.prank(launcher);
            uint256 id = fab.tapeoutChip(ChipModel.fixedChip(k, W), uint32(gates));
            Globals memory g = Kernel(payable(factory.create(_env(), id, bytes32("shape")))).globals();
            assertEq(g.stepFloor, 200_000 + 2_600 * gates + 800 * k, "TapeOut: per record, plus per latch");
            assertEq(g.sealedFloor, 40_000 + 200 * (gates - k) + 400 * k, "sealed: per NAND and per latch");
            // what each evaluator needs at most for any chip of this shape (INTERFACE section 2)
            assertGt(g.stepFloor, 101_730 + 2_293 * (gates - k) + 3_059 * k);
            assertGt(g.sealedFloor, 20_000 + 160 * (gates - k) + 280 * k);
        }
    }

    /// chips/INTERFACE.md section 7, row by row: the first value outside each range is refused.
    function test_envelope_checks() public {
        uint256 id = _tape();
        Envelope memory e;

        e = _env();
        e.launcher = address(0);
        _expectBadEnvelope(e, id, 1);
        e = _env();
        e.epochLen = 299;
        _expectBadEnvelope(e, id, 2);
        e = _env();
        e.epochLen = 86_401;
        e.floorRel = 128; // so that only the epoch length is out of range
        e.fallbackEpochs = 2;
        _expectBadEnvelope(e, id, 2);
        e = _env();
        e.allowancePayee = address(0);
        _expectBadEnvelope(e, id, 3);
        e = _env();
        e.capT = 129;
        _expectBadEnvelope(e, id, 4);
        e = _env();
        e.capV = 256;
        _expectBadEnvelope(e, id, 5);
        e = _env();
        e.allowCumBps = 5001;
        _expectBadEnvelope(e, id, 6);
        e = _env();
        e.ceilMax = 1024;
        _expectBadEnvelope(e, id, 7);
        e = _env();
        e.relMax = 0;
        _expectBadEnvelope(e, id, 8);
        e = _env();
        e.relMax = 257;
        _expectBadEnvelope(e, id, 8);
        e = _env();
        e.floorRel = 0;
        _expectBadEnvelope(e, id, 9);
        e = _env();
        e.floorRel = e.relMax + 1;
        _expectBadEnvelope(e, id, 9);
        e = _env();
        e.floorMin = 0;
        _expectBadEnvelope(e, id, 10);
        e = _env();
        e.floorMin = 426;
        _expectBadEnvelope(e, id, 10);
        e = _env();
        e.fallbackEpochs = 1;
        _expectBadEnvelope(e, id, 11);
        e = _env();
        e.fallbackEpochs = 0;
        _expectBadEnvelope(e, id, 11);
        e = _env();
        e.fbAllow = e.capT + 1;
        _expectBadEnvelope(e, id, 12);
        // buys disabled, whoever the sink is: the sink would be a second payee outside guarantee 1
        e = _env();
        e.buyEnabled = false; // sink is zero
        _expectBadEnvelope(e, id, 13);
        e.sink = sinkAddr;
        _expectBadEnvelope(e, id, 13);
        e.sink = e.allowancePayee;
        _expectBadEnvelope(e, id, 13);
        e.sink = e.launcher;
        _expectBadEnvelope(e, id, 13);
        e = _env();
        e.epochLen = 1 days;
        e.floorRel = 128;
        e.fallbackEpochs = 31; // the fallback would be 31 days away
        _expectBadEnvelope(e, id, 14);
        e = _env();
        e.epochLen = 14_562; // 14,562 * 178 > 2,592,000 * 1: the reserve would take more than 30 days to halve
        e.floorRel = 1;
        _expectBadEnvelope(e, id, 15);
        e = _env();
        e.epochLen = 1 days;
        e.floorRel = 5; // 86,400 * 178 = 15,379,200 > 2,592,000 * 5
        e.fallbackEpochs = 2;
        _expectBadEnvelope(e, id, 15);
    }

    /// The last value inside each range is accepted.
    function test_envelope_edges_that_must_pass() public {
        uint256 id = _tape();
        Envelope memory e;

        // every upper edge at once, with the shortest epoch
        e = _env();
        e.epochLen = 300;
        e.capT = 128;
        e.capV = 255;
        e.allowCumBps = 5000;
        e.ceilMax = 1023;
        e.relMax = 256;
        e.floorRel = 256;
        e.floorMin = 425;
        e.fallbackEpochs = 2;
        e.fbAllow = 128;
        e.sink = sinkAddr; // ignored: buys are enabled
        factory.create(e, id, bytes32("upper"));

        // every lower edge at once
        e = _env();
        e.epochLen = 300;
        e.capT = 0;
        e.capV = 0;
        e.allowCumBps = 0;
        e.ceilMax = 0;
        e.relMax = 1;
        e.floorRel = 1;
        e.floorMin = 1;
        e.fallbackEpochs = 2;
        e.fbAllow = 0;
        factory.create(e, id, bytes32("lower"));

        // the longest epoch, with the slowest drain and the latest fallback it allows
        e = _env();
        e.epochLen = 86_400;
        e.floorRel = 6; // 86,400 * 178 = 15,379,200 <= 2,592,000 * 6
        e.fallbackEpochs = 30; // exactly 30 days
        factory.create(e, id, bytes32("day"));

        // the slowest drain of all: floorRel 1 needs an epoch of at most 14,561 s
        e = _env();
        e.epochLen = 14_561; // 14,561 * 178 = 2,591,858 <= 2,592,000
        e.floorRel = 1;
        factory.create(e, id, bytes32("slow"));
        e.epochLen = 29_123; // 29,123 * 178 = 5,183,894 <= 5,184,000
        e.floorRel = 2;
        factory.create(e, id, bytes32("slow2"));
        e.epochLen = 29_124; // 5,184,072 > 5,184,000
        _expectBadEnvelope(e, id, 15);

        // a sink is needed only when buys are off
        e = _env();
        e.sink = address(0);
        factory.create(e, id, bytes32("nosink"));
    }

    /// What the drain bound buys (INTERFACE section 7, guarantee 3). A reserve above the floor threshold loses
    /// floorRel / 256 per settle, so (256 - floorRel)^n / 256^n of it is left after n settles. At the longest
    /// epoch the factory accepts for each floorRel, a settle every epoch halves it within 30 days plus one
    /// epoch. (Not always within 30 days exactly: 178 / floorRel is not a whole number of settles.)
    function test_drain_bound_halves_the_reserve_within_30_days_and_one_epoch() public pure {
        for (uint256 rel = 1; rel <= 5; rel++) {
            uint256 maxEpoch = (uint256(2_592_000) * rel) / 178; // epochLen * 178 <= 2,592,000 * floorRel
            assertLt(maxEpoch, 86_400, "for floorRel 6 and above every epoch up to a day is accepted");
            uint256 settles = uint256(30 days) / maxEpoch + 1;
            assertLe(_left(rel, settles), 0.5e36, "halved one epoch after day 30 at the latest");
        }
        // floorRel 5 with the longest epoch it allows (72,808 s): the 35 settles that fit in 30 days leave 50.1%
        assertGt(_left(5, 35), 0.5e36);
        assertLt(_left(5, 35), 0.502e36);
        // one day epochs need floorRel 6 or more: 30 settles leave 49.1%
        assertLt(_left(6, 30), 0.5e36);
    }

    /// @dev Share of a reserve left after `n` settles at the floor rate, scaled by 1e36.
    function _left(uint256 rel, uint256 n) internal pure returns (uint256 left) {
        left = 1e36;
        for (uint256 i = 0; i < n; i++) {
            left = (left * (256 - rel)) / 256;
        }
    }

    function _expectBadEnvelope(Envelope memory e, uint256 id, uint8 which) internal {
        vm.expectRevert(abi.encodeWithSelector(KernelFactory.BadEnvelope.selector, which));
        factory.create(e, id, bytes32("x"));
        vm.expectRevert(abi.encodeWithSelector(KernelFactory.BadEnvelope.selector, which));
        factory.predict(e, id, bytes32("x"));
    }

    function test_chip_checks() public {
        uint256 id = _tape();
        (address snap, bytes32 h,,,,) = fab.chipInfo(id);

        _expectBadChip(999, 1); // never taped out through the Fab

        fab.forge(50, snap, h, 0, 2200);
        _expectBadChip(50, 2);
        fab.forge(51, snap, h, 257, 2200);
        _expectBadChip(51, 2);
        fab.forge(52, snap, h, 64, 3401);
        _expectBadChip(52, 3);
        fab.forge(53, snap, h, 64, 63);
        _expectBadChip(53, 3);
        fab.forge(54, makeAddr("no code"), h, 64, 2200);
        _expectBadChip(54, 4);
        // a pointer whose code does not start with the SSTORE2 0x00 byte
        address bad = makeAddr("bad pointer");
        vm.etch(bad, hex"01aabbcc");
        fab.forge(55, bad, keccak256(hex"aabbcc"), 64, 2200);
        _expectBadChip(55, 4);
        // a pointer longer than one 24,000-byte chunk
        address long_ = makeAddr("long pointer");
        vm.etch(long_, new bytes(24_002));
        fab.forge(56, long_, keccak256(new bytes(24_001)), 64, 2200);
        _expectBadChip(56, 4);
        // a snapshot whose bytes do not hash to what the Fab recorded
        fab.forge(57, snap, bytes32(uint256(h) ^ 1), 64, 2200);
        _expectBadChip(57, 5);

        // the largest chip passes
        address max_ = makeAddr("max pointer");
        vm.etch(max_, new bytes(24_001));
        fab.forge(58, max_, keccak256(new bytes(24_000)), 256, 3400);
        factory.create(_env(), 58, bytes32("max"));
    }

    function _expectBadChip(uint256 id, uint8 which) internal {
        vm.expectRevert(abi.encodeWithSelector(KernelFactory.BadChip.selector, which));
        factory.create(_env(), id, bytes32("x"));
    }

    function test_constructor_rejects_missing_contracts() public {
        address none = makeAddr("none");
        address[7] memory a = [
            address(manager),
            address(router),
            address(wokb),
            address(circuits),
            address(fab),
            address(sealedVM),
            address(beacon)
        ];
        for (uint8 i = 0; i < 7; i++) {
            address[7] memory b = a;
            b[i] = none;
            vm.expectRevert(abi.encodeWithSelector(KernelFactory.BadPin.selector, i + 1));
            new KernelFactory(b[0], b[1], b[2], b[3], b[4], b[5], b[6], address(impl), address(impl).codehash);
        }
        vm.expectRevert(abi.encodeWithSelector(KernelFactory.BadPin.selector, uint8(8)));
        new KernelFactory(a[0], a[1], a[2], a[3], a[4], a[5], a[6], address(0), bytes32(uint256(1)));
        // a Fab built for another processor
        MockFab other = new MockFab(new MockCircuits());
        vm.expectRevert(abi.encodeWithSelector(KernelFactory.BadPin.selector, uint8(9)));
        new KernelFactory(a[0], a[1], a[2], a[3], address(other), a[5], a[6], address(impl), address(impl).codehash);
    }

    function test_pinsLive() public {
        assertTrue(factory.pinsLive());
        beacon.upgradeTo(makeAddr("v2"));
        assertFalse(factory.pinsLive());
    }

    function test_noteBound_only_from_kernels() public {
        vm.expectRevert(KernelFactory.NotKernel.selector);
        factory.noteBound(address(1));
    }

    function test_implementation_itself_cannot_be_used() public {
        Kernel implK = Kernel(payable(factory.kernelImpl()));
        vm.expectRevert(Kernel.OnlyClone.selector);
        implK.bind(address(1));
        vm.expectRevert(Kernel.OnlyClone.selector);
        implK.settle();
        vm.expectRevert(Kernel.OnlyClone.selector);
        implK.withdrawCredit(payee, NATIVE);
        vm.expectRevert(Kernel.OnlyClone.selector);
        implK.burnLocked();
        vm.expectRevert(Kernel.OnlyClone.selector);
        implK.envelope();
        vm.deal(address(manager), 1 ether);
        vm.prank(address(manager));
        (bool ok,) = address(implK).call{value: 1}("");
        assertFalse(ok, "the implementation accepts no value from anyone");
        assertFalse(factory.isKernel(address(implK)));
    }

    // ------------------------------------------------------------------ bind

    function _launch(address recipient) internal returns (MockToken t, MockVault v) {
        (address ta, address va) = manager.createToken(launcher, recipient, 300, 300, 0, 0, GRADUATION);
        (t, v) = (MockToken(ta), MockVault(payable(va)));
    }

    function _moveChip(Kernel k, uint256 id) internal {
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(k), id);
    }

    function test_bind_records_token_vault_time_and_tells_the_factory() public {
        (Kernel k, uint256 id) = _unbound();
        (MockToken t, MockVault v) = _launch(address(k));
        _moveChip(k, id);
        assertEq(k.epochNow(), 0);
        vm.warp(block.timestamp + 12_345);
        vm.expectEmit(true, true, false, true, address(k));
        emit Kernel.Bound(address(t), address(v), uint40(block.timestamp));
        vm.prank(bob); // anyone may call
        k.bind(address(t));
        assertEq(k.token(), address(t));
        assertEq(k.vault(), address(v));
        assertEq(k.bindTime(), block.timestamp);
        assertEq(k.tokenSupply(), 1_000_000_000e18);
        assertEq(factory.kernelOf(address(t)), address(k));
        assertEq(k.epochNow(), 0);
        assertEq(k.lastEpoch(), 0);
        assertEq(k.count(), 0);
        assertFalse(k.graduated());
    }

    function test_bind_once() public {
        (Kernel k, uint256 id) = _unbound();
        (MockToken t,) = _launch(address(k));
        _moveChip(k, id);
        k.bind(address(t));
        vm.expectRevert(Kernel.AlreadyBound.selector);
        k.bind(address(t));
    }

    function test_settle_before_bind_reverts() public {
        (Kernel k,) = _unbound();
        vm.expectRevert(Kernel.NotBound.selector);
        k.settle();
    }

    function _expectBindCheck(Kernel k, address t, uint8 which) internal {
        vm.expectRevert(abi.encodeWithSelector(Kernel.BindCheck.selector, which));
        k.bind(t);
    }

    function test_bind_checks() public {
        (Kernel k, uint256 id) = _unbound();

        // 1: not an IGNIX token
        _expectBindCheck(k, address(0), 1);
        _expectBindCheck(k, makeAddr("random"), 1);

        // 2: a token whose vault pays someone else
        (MockToken other,) = _launch(alice);
        _expectBindCheck(k, address(other), 2);

        // 3 and 4: a vault that names another token, or a non-native quote
        (MockToken t, MockVault v) = _launch(address(k));
        manager.setVault(address(t), address(new LyingVault(address(k), address(other), address(0))));
        _expectBindCheck(k, address(t), 3);
        manager.setVault(address(t), address(new LyingVault(address(k), address(t), address(wokb))));
        _expectBindCheck(k, address(t), 4);
        manager.setVault(address(t), address(v));

        // 5: launched by somebody other than the envelope's launcher, and bound by somebody other than it
        manager.setCreator(address(t), alice);
        _expectBindCheck(k, address(t), 5);
        vm.prank(alice); // the wallet that did create it is not the launcher either
        _expectBindCheck(k, address(t), 5);
        manager.setCreator(address(t), launcher);

        // 5 again: the curve cannot be read, whoever calls
        manager.setTokensMode(2);
        _expectBindCheck(k, address(t), 5);
        vm.prank(launcher);
        _expectBindCheck(k, address(t), 5);
        manager.setTokensMode(1);
        vm.prank(launcher);
        _expectBindCheck(k, address(t), 5);
        manager.setTokensMode(0);

        // 7: the chip NFT is not in the kernel yet
        _expectBindCheck(k, address(t), 7);
        _moveChip(k, id);
        k.bind(address(t));
    }

    /// INTERFACE section 10: either the token's creator is the launcher (then anyone may call), or the caller
    /// is the launcher (so a token launched from the wrong wallet can still be bound, by the launcher only).
    function test_bind_by_the_launcher_of_a_token_created_by_another_wallet() public {
        (Kernel k, uint256 id) = _unbound();
        _moveChip(k, id);
        (address t,) = manager.createToken(alice, address(k), 300, 300, 0, 0, GRADUATION); // the wrong wallet
        // nobody but the launcher can bind it: not a stranger, not its creator, not the allowance payee
        address[4] memory others = [bob, alice, payee, keeper];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            _expectBindCheck(k, t, 5);
        }
        assertEq(k.token(), address(0));
        vm.prank(launcher);
        k.bind(t);
        assertEq(k.token(), t);
        assertEq(factory.kernelOf(t), address(k));
    }

    /// The launcher's own call is held to every other check: only the creator check is replaced.
    function test_bind_by_the_launcher_still_needs_everything_else() public {
        (Kernel k, uint256 id) = _unbound();
        vm.startPrank(launcher);
        _expectBindCheck(k, address(0), 1);
        (MockToken other,) = _launch(alice); // a vault that pays somebody else
        _expectBindCheck(k, address(other), 2);
        (address untaxed,) = manager.createToken(alice, address(k), 0, 0, 0, 0, GRADUATION);
        _expectBindCheck(k, untaxed, 6);
        (address t,) = manager.createToken(alice, address(k), 300, 300, 0, 0, GRADUATION);
        _expectBindCheck(k, t, 7); // the chip NFT is not in the kernel yet
        circuits.transferFrom(launcher, address(k), id);
        k.bind(t);
        vm.expectRevert(Kernel.AlreadyBound.selector);
        k.bind(t);
        vm.stopPrank();
    }

    function test_bind_rejects_an_untaxed_token() public {
        (Kernel k, uint256 id) = _unbound();
        _moveChip(k, id);
        (address t,) = manager.createToken(launcher, address(k), 0, 0, 0, 0, GRADUATION);
        _expectBindCheck(k, t, 6);
        // one-sided tax is enough
        (address t2,) = manager.createToken(launcher, address(k), 0, 100, 0, 0, GRADUATION);
        k.bind(t2);
    }

    function test_bind_accepts_a_struct_that_grew_upstream() public {
        (Kernel k, uint256 id) = _unbound();
        (MockToken t,) = _launch(address(k));
        _moveChip(k, id);
        manager.setTokensMode(3); // 544 bytes
        k.bind(address(t));
        assertEq(k.token(), address(t));
    }

    function test_bind_survives_a_token_without_totalSupply() public {
        (Kernel k, uint256 id) = _unbound();
        (MockToken t,) = _launch(address(k));
        _moveChip(k, id);
        vm.mockCallRevert(address(t), abi.encodeWithSignature("totalSupply()"), "nope");
        k.bind(address(t));
        assertEq(k.tokenSupply(), 0, "LOCK will read 0; nothing else depends on it");
    }

    // ------------------------------------------------------------------ the chip NFT

    function test_chip_can_arrive_by_safeTransferFrom() public {
        (Kernel k, uint256 id) = _unbound();
        vm.prank(launcher);
        circuits.safeTransferFrom(launcher, address(k), id);
        assertEq(circuits.ownerOf(id), address(k));
    }

    function test_other_nfts_are_refused_by_the_receiver_hook() public {
        (Kernel k,) = _unbound();
        uint256 otherChip = _tape();
        vm.prank(launcher);
        vm.expectRevert();
        circuits.safeTransferFrom(launcher, address(k), otherChip);
        // and a different NFT contract altogether, even with the right id
        uint256 own = k.chipId();
        vm.expectRevert(Kernel.NotAccepted.selector);
        k.onERC721Received(address(this), address(this), own, "");
    }

    function test_chip_can_never_leave_the_kernel() public {
        (Kernel k, uint256 id) = _unbound();
        _moveChip(k, id);
        // the kernel has no function that calls transferFrom, approve or setApprovalForAll on the processor;
        // nobody else is the owner
        vm.prank(launcher);
        vm.expectRevert();
        circuits.transferFrom(address(k), launcher, id);
        assertEq(circuits.ownerOf(id), address(k));
    }
}
