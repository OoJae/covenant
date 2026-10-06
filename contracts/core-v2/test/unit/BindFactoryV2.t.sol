// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";
import {MockVault} from "core-test/mocks/MockIgnix.sol";

contract NoDecimals {}

contract EighteenDecimals {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract SevenDecimals {
    function decimals() external pure returns (uint8) {
        return 7;
    }
}

contract ShortDecimals {
    function decimals() external pure {
        assembly {
            mstore(0, 6)
            return(0x1f, 1)
        }
    }
}

contract WrongFab {
    address public CIRCUITS = address(0xdead);
}

/// @notice KernelFactoryV2 (pins, envelope checks, determinism) and KernelV2.bind (the quote checks).
contract BindFactoryV2Test is BaseV2 {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    // ------------------------------------------------------------------ factory

    function test_pins_and_constants() public view {
        assertEq(factory.manager(), address(manager));
        assertEq(factory.v2Router(), address(router));
        assertEq(factory.quote(), address(usdt));
        assertEq(factory.quoteShift(), 33);
        assertEq(factory.codeShift(), 264);
        assertEq(factory.QUOTE_DECIMALS(), 6);
        assertEq(factory.MAX_QUOTE_SHIFT(), 40);
        assertEq(factory.circuits(), address(circuits));
        assertEq(factory.fab(), address(fab));
        assertEq(factory.sealedVM(), address(sealedVM));
        assertEq(factory.beacon(), address(beacon));
        assertEq(factory.impl0(), address(impl));
        assertTrue(factory.kernelImpl().code.length > 0);
        assertTrue(factory.pinsLive());
    }

    /// The constructor's arguments, one struct so that a single external entry point can take them.
    struct FactoryArgs {
        address manager;
        address router;
        address quote;
        uint256 shift;
        address circuits;
        address fab;
        address sealedVM;
        address beacon;
        address impl0;
        bytes32 impl0Hash;
    }

    /// @dev External on purpose. Forge links tests dynamically (`dynamic_test_linking`, on by default in forge 1.8),
    ///      which turns a `new` written in a test function into a `vm.deployCode` call. The revert of that call ends
    ///      the test function and satisfies a pending `expectRevert`, so in a test written as a list of
    ///      `expectRevert; new ...` pairs only the first check ever runs (review B-F1: the earlier form of this test
    ///      passed at 24,798 gas). Through this function each check is its own call and the test goes on after it.
    function deployFactory(FactoryArgs memory p) external returns (KernelFactoryV2) {
        return new KernelFactoryV2(
            p.manager, p.router, p.quote, p.shift, p.circuits, p.fab, p.sealedVM, p.beacon, p.impl0, p.impl0Hash
        );
    }

    function _goodArgs() internal view returns (FactoryArgs memory p) {
        p = FactoryArgs({
            manager: address(manager),
            router: address(router),
            quote: address(usdt),
            shift: 33,
            circuits: address(circuits),
            fab: address(fab),
            sealedVM: address(sealedVM),
            beacon: address(beacon),
            impl0: address(impl),
            impl0Hash: address(impl).codehash
        });
    }

    function _expectBadPin(FactoryArgs memory p, uint8 which) internal {
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadPin.selector, which));
        this.deployFactory(p);
        checksReached++;
    }

    uint256 internal checksReached;

    function test_constructor_rejects_bad_pins() public {
        FactoryArgs memory p;
        p = _goodArgs();
        p.manager = address(0);
        _expectBadPin(p, 1);
        p = _goodArgs();
        p.manager = address(0xbeef); // no code
        _expectBadPin(p, 1);
        p = _goodArgs();
        p.router = address(0);
        _expectBadPin(p, 2);
        p = _goodArgs();
        p.quote = address(0);
        _expectBadPin(p, 3);
        p = _goodArgs();
        p.quote = address(new NoDecimals()); // decimals() reverts
        _expectBadPin(p, 3);
        p = _goodArgs();
        p.quote = address(new EighteenDecimals()); // WOKB's 18 decimals: the shift would mean nothing
        _expectBadPin(p, 3);
        p = _goodArgs();
        p.quote = address(new SevenDecimals());
        _expectBadPin(p, 3);
        p = _goodArgs();
        p.quote = address(new ShortDecimals()); // answers fewer than 32 bytes
        _expectBadPin(p, 3);
        p = _goodArgs();
        p.circuits = address(0);
        _expectBadPin(p, 4);
        p = _goodArgs();
        p.fab = address(0);
        _expectBadPin(p, 5);
        p = _goodArgs();
        p.sealedVM = address(0);
        _expectBadPin(p, 6);
        p = _goodArgs();
        p.beacon = address(0);
        _expectBadPin(p, 7);
        p = _goodArgs();
        p.impl0 = address(0);
        _expectBadPin(p, 8);
        p = _goodArgs();
        p.impl0Hash = bytes32(0);
        _expectBadPin(p, 8);
        p = _goodArgs();
        p.fab = address(new WrongFab());
        _expectBadPin(p, 9);
        p = _goodArgs();
        p.shift = 41;
        _expectBadPin(p, 10);
        p = _goodArgs();
        p.shift = type(uint256).max;
        _expectBadPin(p, 10);
        assertEq(checksReached, 17, "every check was reached");

        // the bounds themselves are accepted
        p = _goodArgs();
        p.shift = 40;
        KernelFactoryV2 f40 = this.deployFactory(p);
        assertEq(f40.quoteShift(), 40);
        assertEq(f40.codeShift(), 320);
        p.shift = 0;
        assertEq(this.deployFactory(p).quoteShift(), 0);
        p = _goodArgs();
        assertEq(this.deployFactory(p).quote(), address(usdt), "the good pins deploy");
    }

    bool internal canaryReached;

    /// @dev The canary's body: an expected revert of a `new`, then a state write that only happens if the test
    ///      function goes on after it.
    function canaryProbe() external {
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadPin.selector, uint8(1)));
        new KernelFactoryV2(
            address(0),
            address(router),
            address(usdt),
            33,
            address(circuits),
            address(fab),
            address(sealedVM),
            address(beacon),
            address(impl),
            address(impl).codehash
        );
        canaryReached = true;
    }

    /// Canary for the pitfall above: fails if `vm.expectRevert(); new ...` ends the function it is written in, so
    /// that a test written that way anywhere in this tree would check nothing after its first line. It holds
    /// because foundry.toml turns dynamic test linking off.
    function test_canary_an_expected_revert_of_new_does_not_end_the_test() public {
        try this.canaryProbe() {} catch {}
        assertTrue(canaryReached, "an expectRevert'd `new` ended the test function: set dynamic_test_linking = false");
    }

    function _chip() internal returns (uint256 id) {
        vm.prank(launcher);
        id = fab.tapeoutChip(ChipModel.fixedChip(64, W), 2200);
    }

    function test_create_is_deterministic_and_predictable() public {
        uint256 id = _chip();
        Envelope memory e = _env();
        address p = factory.predict(e, id, bytes32("s"));
        address k = factory.create(e, id, bytes32("s"));
        assertEq(k, p);
        assertTrue(factory.isKernel(k));
        assertEq(factory.create(e, id, bytes32("s")), k, "twice: the same kernel");
        assertTrue(factory.predict(e, id, bytes32("t")) != k, "the salt matters");
        e.capT = 63;
        assertTrue(factory.predict(e, id, bytes32("s")) != k, "the envelope matters");
    }

    function test_a_factory_with_another_shift_gives_other_kernels() public {
        uint256 id = _chip();
        KernelFactoryV2 f0 = _newFactory(0);
        address k0 = f0.create(_env(), id, bytes32("s"));
        assertEq(KernelV2(k0).quoteShift(), 0);
        assertEq(KernelV2(factory.create(_env(), id, bytes32("s"))).quoteShift(), 33);
    }

    function test_clone_carries_globals_and_envelope_as_bytecode() public {
        uint256 id = _chip();
        KernelV2 k = KernelV2(factory.create(_env(), id, bytes32("s")));
        GlobalsV2 memory g = k.globals();
        assertEq(g.quote, address(usdt));
        assertEq(g.quoteShift, 33);
        assertEq(g.manager, address(manager));
        assertEq(g.v2Router, address(router));
        assertEq(g.factory, address(factory));
        assertEq(g.chipId, id);
        assertEq(g.nState, 64);
        assertEq(g.gateCount, 2200);
        assertEq(g.stepFloor, 200_000 + 2_600 * 2200 + 800 * 64);
        assertEq(g.sealedFloor, 40_000 + 200 * (2200 - 64) + 400 * 64);
        assertEq(keccak256(abi.encode(k.envelope())), keccak256(abi.encode(_env())));
    }

    function test_envelope_checks_are_kernel_v1s() public {
        uint256 id = _chip();
        Envelope memory e;
        e = _env();
        e.launcher = address(0);
        _expectBad(e, id, 1);
        e = _env();
        e.epochLen = 299;
        _expectBad(e, id, 2);
        e = _env();
        e.epochLen = 86_401;
        _expectBad(e, id, 2);
        e = _env();
        e.allowancePayee = address(0);
        _expectBad(e, id, 3);
        e = _env();
        e.capT = 129;
        _expectBad(e, id, 4);
        e = _env();
        e.capV = 256;
        _expectBad(e, id, 5);
        e = _env();
        e.allowCumBps = 5001;
        _expectBad(e, id, 6);
        e = _env();
        e.ceilMax = 1024;
        _expectBad(e, id, 7);
        e = _env();
        e.relMax = 0;
        _expectBad(e, id, 8);
        e = _env();
        e.relMax = 257;
        _expectBad(e, id, 8);
        e = _env();
        e.floorRel = 0;
        _expectBad(e, id, 9);
        e = _env();
        e.floorRel = 129;
        _expectBad(e, id, 9);
        e = _env();
        e.floorMin = 0;
        _expectBad(e, id, 10);
        e = _env();
        e.floorMin = 426;
        _expectBad(e, id, 10);
        e = _env();
        e.fallbackEpochs = 1;
        _expectBad(e, id, 11);
        e = _env();
        e.fbAllow = 65;
        _expectBad(e, id, 12);
        e = _env();
        e.buyEnabled = false;
        _expectBad(e, id, 13);
        e = _env();
        e.fallbackEpochs = 2881;
        _expectBad(e, id, 14);
        e = _env();
        e.epochLen = 86_400;
        e.floorRel = 5;
        _expectBad(e, id, 15);
        // the reference envelope passes
        factory.create(_refEnv(), id, bytes32("ref"));
    }

    function _expectBad(Envelope memory e, uint256 id, uint8 which) internal {
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadEnvelope.selector, which));
        factory.create(e, id, bytes32("bad"));
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadEnvelope.selector, which));
        factory.predict(e, id, bytes32("bad"));
    }

    function test_chip_checks() public {
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadChip.selector, uint8(1)));
        factory.create(_env(), 777, bytes32("x"));
        uint256 id = _chip();
        (address ptr,,,,,) = fab.chipInfo(id);
        fab.forge(id, ptr, bytes32(uint256(1)), 64, 2200);
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadChip.selector, uint8(5)));
        factory.create(_env(), id, bytes32("x"));
        fab.forge(id, ptr, keccak256(ChipModel.fixedChip(64, W)), 0, 2200);
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadChip.selector, uint8(2)));
        factory.create(_env(), id, bytes32("x"));
        fab.forge(id, ptr, keccak256(ChipModel.fixedChip(64, W)), 64, 3401);
        vm.expectRevert(abi.encodeWithSelector(KernelFactoryV2.BadChip.selector, uint8(3)));
        factory.create(_env(), id, bytes32("x"));
    }

    function test_noteBound_only_from_kernels() public {
        vm.expectRevert(KernelFactoryV2.NotKernel.selector);
        factory.noteBound(address(1));
    }

    function test_implementation_itself_cannot_be_used() public {
        KernelV2 impl_ = KernelV2(factory.kernelImpl());
        vm.expectRevert(KernelV2.OnlyClone.selector);
        impl_.settle();
        vm.expectRevert(KernelV2.OnlyClone.selector);
        impl_.bind(address(1));
        vm.expectRevert(KernelV2.OnlyClone.selector);
        impl_.chipId();
    }

    // ------------------------------------------------------------------ bind

    function test_bind_records_token_vault_time_and_tells_the_factory() public {
        _fixture(W);
        assertEq(kernel.token(), address(token));
        assertEq(kernel.vault(), address(vault));
        assertEq(kernel.bindTime(), block.timestamp);
        assertEq(kernel.tokenSupply(), 1_000_000_000e18);
        assertEq(factory.kernelOf(address(token)), address(kernel));
        vm.expectRevert(KernelV2.AlreadyBound.selector);
        kernel.bind(address(token));
    }

    function test_settle_before_bind_reverts() public {
        uint256 id = _chip();
        KernelV2 k = KernelV2(factory.create(_env(), id, bytes32("unbound")));
        vm.expectRevert(KernelV2.NotBound.selector);
        k.settle();
    }

    function _unbound() internal returns (KernelV2 k, uint256 id) {
        id = _chip();
        k = KernelV2(factory.create(_env(), id, bytes32("b")));
    }

    function test_bind_checks() public {
        (KernelV2 k, uint256 id) = _unbound();
        // 1: no vault
        vm.expectRevert(abi.encodeWithSelector(KernelV2.BindCheck.selector, uint8(1)));
        k.bind(address(0x1234));
        // 2: the vault pays someone else
        (address t2,) = manager.createToken(launcher, alice, 300, 300, 0, 0, GRADUATION);
        vm.expectRevert(abi.encodeWithSelector(KernelV2.BindCheck.selector, uint8(2)));
        k.bind(t2);
        // 4: a native-quoted vault (kernel v1's) is refused
        (address t4,) = manager.createToken(launcher, address(k), 300, 300, 0, 0, GRADUATION);
        manager.setVault(t4, address(new MockVault(t4, address(k), address(manager))));
        vm.expectRevert(abi.encodeWithSelector(KernelV2.BindCheck.selector, uint8(4)));
        k.bind(t4);
        // 4: the vault says USD0 but the curve trades in another quote
        (address t5,) = manager.createToken(launcher, address(k), 300, 300, 0, 0, GRADUATION);
        manager.setQuoteOf(t5, address(0));
        vm.expectRevert(abi.encodeWithSelector(KernelV2.BindCheck.selector, uint8(4)));
        k.bind(t5);
        // 5: created by another wallet and bound by a stranger
        (address t6,) = manager.createToken(alice, address(k), 300, 300, 0, 0, GRADUATION);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KernelV2.BindCheck.selector, uint8(5)));
        k.bind(t6);
        // 6: untaxed
        (address t7,) = manager.createToken(launcher, address(k), 0, 0, 0, 0, GRADUATION);
        vm.expectRevert(abi.encodeWithSelector(KernelV2.BindCheck.selector, uint8(6)));
        k.bind(t7);
        // 7: the kernel does not hold its chip
        (address t8,) = manager.createToken(launcher, address(k), 300, 300, 0, 0, GRADUATION);
        vm.expectRevert(abi.encodeWithSelector(KernelV2.BindCheck.selector, uint8(7)));
        k.bind(t8);
        // and with the chip, it binds
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(k), id);
        k.bind(t8);
        assertEq(k.token(), t8);
    }

    function test_bind_by_the_launcher_of_a_token_created_by_another_wallet() public {
        (KernelV2 k, uint256 id) = _unbound();
        (address t,) = manager.createToken(alice, address(k), 300, 300, 0, 0, GRADUATION);
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(k), id);
        vm.prank(launcher);
        k.bind(t);
        assertEq(k.token(), t);
    }

    function test_chip_can_arrive_by_safeTransferFrom_and_other_nfts_are_refused() public {
        (KernelV2 k, uint256 id) = _unbound();
        vm.prank(launcher);
        circuits.safeTransferFrom(launcher, address(k), id);
        assertEq(circuits.ownerOf(id), address(k));
        uint256 other = _chip();
        vm.prank(launcher);
        vm.expectRevert();
        circuits.safeTransferFrom(launcher, address(k), other);
    }
}
