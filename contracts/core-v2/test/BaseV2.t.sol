// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {KernelV2} from "../src/KernelV2.sol";
import {KernelFactoryV2} from "../src/KernelFactoryV2.sol";
import {LensV2} from "../src/LensV2.sol";
import {KernelMathV2} from "../src/KernelMathV2.sol";
import {IKernelV2, GlobalsV2, RecordV2} from "../src/interfaces/IKernelV2.sol";
import {KernelMath} from "core/KernelMath.sol";
import {TradeMath} from "core/lib/TradeMath.sol";
import {Envelope, RecordFlags, IKernelMin} from "core/interfaces/IKernelV1.sol";
import {ICircuits, ISealedVM} from "core/interfaces/IEvaluators.sol";

import {MockToken, MockPair} from "core-test/mocks/MockIgnix.sol";
import {
    ChipModel,
    MockImpl,
    MockImplV2,
    MockBeacon,
    MockCircuits,
    MockSealedVM,
    MockFab
} from "core-test/mocks/MockTapeOut.sol";
import {MockUSDT0, MockVaultV2, MockManagerV2, MockRouterV2} from "./mocks/MockIgnixV2.sol";

/// @notice A complete mock world for kernel v2: USD₮0, IGNIX with a USD₮0 quote (manager, token, vault, V2 pair and
///         router), TapeOut (circuits, beacon), the Fab, the sealed evaluator, the v2 factory and the v2 Lens.
///         Tests build a chip, a kernel and a token in the order real life uses: tape out, create the kernel,
///         launch the token against its address, move the chip, bind.
///
///         Every USD₮0 payment into a kernel in these tests comes from an address that has nothing to do with the
///         launcher or the allowance payee (`payer`): a team wallet must never pay revenue into a kernel that
///         buys the team's token (NOTES.md section 1).
abstract contract BaseV2 is Test {
    using stdStorage for StdStorage;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint32 internal constant EPOCH = 900;
    uint256 internal constant GRADUATION = 8_000e6; // IGNIX's USD₮0 graduation target (GET /v1/ignix/params)
    uint256 internal constant SHIFT = 33; // NOTES.md section 3

    address internal launcher = makeAddr("launcher");
    address internal payee = makeAddr("allowance payee");
    address internal sinkAddr = makeAddr("sink");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal whale = makeAddr("whale");
    address internal payer = makeAddr("x402 buyer (unrelated to the team)");

    MockUSDT0 internal usdt;
    MockManagerV2 internal manager;
    MockRouterV2 internal router;
    MockImpl internal impl;
    MockBeacon internal beacon;
    MockCircuits internal circuits;
    MockFab internal fab;
    MockSealedVM internal sealedVM;
    KernelFactoryV2 internal factory;
    LensV2 internal lens;

    KernelV2 internal kernel;
    MockToken internal token;
    MockVaultV2 internal vault;
    uint256 internal chipId;

    function setUp() public virtual {
        vm.warp(1_791_000_000);
        usdt = new MockUSDT0();
        manager = new MockManagerV2(address(usdt));
        router = new MockRouterV2(address(manager), address(usdt));
        impl = new MockImpl();
        beacon = new MockBeacon(address(impl));
        circuits = new MockCircuits();
        fab = new MockFab(circuits);
        sealedVM = new MockSealedVM();
        factory = _newFactory(SHIFT);
        lens = new LensV2(address(factory));
    }

    function _newFactory(uint256 shift) internal returns (KernelFactoryV2) {
        return new KernelFactoryV2(
            address(manager),
            address(router),
            address(usdt),
            shift,
            address(circuits),
            address(fab),
            address(sealedVM),
            address(beacon),
            address(impl),
            address(impl).codehash
        );
    }

    // ------------------------------------------------------------------ envelope and words

    function _env() internal view returns (Envelope memory e) {
        e.launcher = launcher;
        e.epochLen = EPOCH;
        e.allowancePayee = payee;
        e.capT = 64;
        e.capV = 128;
        e.allowCumBps = 2500;
        e.ceilMax = 1023;
        e.relMax = 128;
        e.floorRel = 2;
        e.floorMin = 400;
        e.fallbackEpochs = 4;
        e.fbAllow = 32;
        e.buyEnabled = true;
        e.sink = address(0);
    }

    /// The reference envelope of the Flow Governor (chips/rtl/fg_params.json), the one LaunchChipV2 uses.
    function _refEnv() internal view returns (Envelope memory e) {
        e = _env();
        e.capT = 48;
        e.capV = 0;
        e.allowCumBps = 1875;
        e.ceilMax = 440;
        e.floorMin = 1;
        e.fallbackEpochs = 16;
        e.fbAllow = 8;
    }

    function _word(uint256 tb, uint256 th, uint256 ta, uint256 tr, uint256 rel, uint256 ceil)
        internal
        pure
        returns (bytes14)
    {
        KernelMath.OutputFields memory o;
        o.tBuy = tb;
        o.tHold = th;
        o.tAllow = ta;
        o.tRes = tr;
        o.rel = rel;
        o.ceil = ceil;
        return KernelMath.outputBytes(KernelMath.packOutput(o));
    }

    // ------------------------------------------------------------------ building a kernel

    struct Built {
        KernelV2 kernel;
        MockToken token;
        MockVaultV2 vault;
        uint256 chipId;
    }

    function _build(bytes memory netlist, uint32 gateCount, Envelope memory e, uint16 taxBps, bytes32 salt)
        internal
        returns (Built memory b)
    {
        return _buildOn(factory, netlist, gateCount, e, taxBps, salt);
    }

    function _buildOn(
        KernelFactoryV2 f,
        bytes memory netlist,
        uint32 gateCount,
        Envelope memory e,
        uint16 taxBps,
        bytes32 salt
    ) internal returns (Built memory b) {
        vm.prank(launcher);
        b.chipId = fab.tapeoutChip(netlist, gateCount);
        b.kernel = e.buyEnabled
            ? KernelV2(f.create(e, b.chipId, salt))
            : KernelV2(_cloneOutsideTheFactory(f, e, b.chipId, salt));
        (address t, address v) = manager.createToken(launcher, address(b.kernel), taxBps, taxBps, 0, 0, GRADUATION);
        b.token = MockToken(t);
        b.vault = MockVaultV2(v);
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(b.kernel), b.chipId);
        b.kernel.bind(t);
    }

    /// @dev The factory refuses buys disabled; the kernel's code for that case is reached with a clone the
    ///      factory did not make (kernel v1's test technique, unchanged).
    function _cloneOutsideTheFactory(KernelFactoryV2 f, Envelope memory e, uint256 id, bytes32 salt)
        internal
        returns (address k)
    {
        e.buyEnabled = true;
        address twin = f.create(e, id, keccak256(abi.encode(salt, "twin")));
        e.buyEnabled = false;
        GlobalsV2 memory g = IKernelV2(twin).globals();
        k = Clones.cloneDeterministicWithImmutableArgs(f.kernelImpl(), abi.encode(g, e), salt);
        stdstore.target(address(f)).sig("isKernel(address)").with_key(k).checked_write(true);
        assertTrue(f.isKernel(k));
    }

    function _fixture(bytes14 word) internal {
        _fixtureWith(ChipModel.fixedChip(64, word), _env());
    }

    function _fixtureWith(bytes memory netlist, Envelope memory e) internal {
        Built memory b = _build(netlist, 2200, e, 300, bytes32("default"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        chipId = b.chipId;
    }

    // ------------------------------------------------------------------ actions

    function _fund(address who, uint256 amount) internal {
        usdt.mint(who, amount);
    }

    function _buy(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.startPrank(who);
        usdt.approve(address(manager), amount);
        manager.buy(address(token), amount, 0);
        vm.stopPrank();
    }

    function _sell(address who, uint256 tokens) internal {
        vm.startPrank(who);
        token.approve(address(manager), tokens);
        manager.sell(address(token), tokens, 0);
        vm.stopPrank();
    }

    /// @dev Revenue: a plain USD₮0 transfer into the kernel from an address unrelated to the team (what an x402
    ///      "exact" settlement with payTo = the kernel amounts to on chain).
    function _revenue(uint256 amount) internal {
        _fund(payer, amount);
        vm.prank(payer);
        usdt.transfer(address(kernel), amount);
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }

    function _settle() internal returns (uint32 n) {
        vm.prank(keeper);
        n = kernel.settle();
    }

    function _settleAsked() internal returns (bool ok, bytes4 err, uint256 tapeOutAsked, uint256 sealedAsked) {
        vm.startStateDiffRecording();
        vm.prank(keeper);
        bytes memory ret;
        (ok, ret) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        if (!ok && ret.length >= 4) err = bytes4(ret);
        for (uint256 i = 0; i < acc.length; i++) {
            if (acc[i].data.length < 4) continue;
            bytes4 sel = bytes4(acc[i].data);
            if (acc[i].account == address(circuits) && sel == ICircuits.step.selector) tapeOutAsked++;
            if (acc[i].account == address(sealedVM) && sel == ISealedVM.step.selector) sealedAsked++;
        }
    }

    function _killBoth(uint8 mode) internal {
        circuits.setStepMode(mode);
        sealedVM.setStepMode(mode);
    }

    function _rec(uint32 n) internal view returns (RecordV2 memory) {
        return kernel.records(n);
    }

    function _in(uint32 n) internal view returns (KernelMath.InputFields memory) {
        return KernelMath.unpackInput(KernelMath.inputWord(kernel.records(n).inputs));
    }

    /// @dev A whale buys the rest of the curve; graduation runs inside the buy.
    function _graduate() internal returns (MockPair pair) {
        uint256 cost = manager.costToGraduate(address(token));
        _fund(whale, cost + 10e6);
        vm.startPrank(whale);
        usdt.approve(address(manager), cost + 10e6);
        manager.buy(address(token), cost + 10e6, 0);
        vm.stopPrank();
        pair = MockPair(manager.pairOf(address(token)));
        assertTrue(address(pair) != address(0), "did not graduate");
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    /// @dev A V2 buy by `who` (pays the token's buy tax to the vault, in the token).
    function _v2Buy(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.startPrank(who);
        usdt.approve(address(router), amount);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, _path(address(usdt), address(token)), who, block.timestamp
        );
        vm.stopPrank();
    }

    function _v2Sell(address who, uint256 tokens) internal {
        vm.startPrank(who);
        token.approve(address(router), tokens);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokens, 0, _path(address(token), address(usdt)), who, block.timestamp
        );
        vm.stopPrank();
    }

    function _curve() internal view returns (TradeMath.Curve memory c) {
        MockManagerV2.Token memory t = manager.raw(address(token));
        c.buyFeeBps = t.buyFeeBps;
        c.sellFeeBps = t.sellFeeBps;
        c.taxBuyBps = t.taxBuyBps;
        c.taxSellBps = t.taxSellBps;
        c.vQuote = t.vQuote;
        c.vToken = t.vToken;
        c.sold = t.sold;
        c.sellable = t.sellable;
    }

    function _pairReserves(MockPair p) internal view returns (uint256 rToken, uint256 rQuote) {
        (uint112 a, uint112 b,) = p.getReserves();
        (rToken, rQuote) = p.token0() == address(token) ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
    }

    function _has(uint8 flags, uint8 bit) internal pure returns (bool) {
        return flags & bit != 0;
    }

    function _qbal(address who) internal view returns (uint256) {
        return usdt.balanceOf(who);
    }
}
