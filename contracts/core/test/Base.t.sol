// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Kernel} from "../src/Kernel.sol";
import {Globals, IKernelExt} from "../src/interfaces/IKernelExt.sol";
import {KernelFactory} from "../src/KernelFactory.sol";
import {Lens} from "../src/Lens.sol";
import {KernelMath} from "../src/KernelMath.sol";
import {TradeMath} from "../src/lib/TradeMath.sol";
import {Record, Envelope, RecordFlags, IKernelMin} from "../src/interfaces/IKernelV1.sol";
import {ICircuits, ISealedVM} from "../src/interfaces/IEvaluators.sol";

import {MockToken, MockVault, MockWOKB, MockPair, MockRouter, MockManager} from "./mocks/MockIgnix.sol";
import {
    ChipModel,
    MockImpl,
    MockImplV2,
    MockBeacon,
    MockCircuits,
    MockSealedVM,
    MockFab
} from "./mocks/MockTapeOut.sol";

/// @notice A complete mock world: IGNIX (manager, token, vault, V2), TapeOut (circuits, beacon), the Fab, the
///         sealed evaluator, the factory and the Lens. Tests build a chip, a kernel and a token on top of it
///         in the order real life uses: tape out, create the kernel, launch the token, move the chip, bind.
abstract contract Base is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant NATIVE = address(0);

    uint32 internal constant EPOCH = 900;
    uint256 internal constant GRADUATION = 85 ether;

    address internal launcher = makeAddr("launcher");
    address internal payee = makeAddr("allowance payee");
    address internal sinkAddr = makeAddr("sink");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal whale = makeAddr("whale");

    MockWOKB internal wokb;
    MockManager internal manager;
    MockRouter internal router;
    MockImpl internal impl;
    MockBeacon internal beacon;
    MockCircuits internal circuits;
    MockFab internal fab;
    MockSealedVM internal sealedVM;
    KernelFactory internal factory;
    Lens internal lens;

    // the default kernel under test
    Kernel internal kernel;
    MockToken internal token;
    MockVault internal vault;
    uint256 internal chipId;

    function setUp() public virtual {
        vm.warp(1_791_000_000);
        wokb = new MockWOKB();
        manager = new MockManager(address(wokb));
        router = new MockRouter(address(wokb), address(manager));
        impl = new MockImpl();
        beacon = new MockBeacon(address(impl));
        circuits = new MockCircuits();
        fab = new MockFab(circuits);
        sealedVM = new MockSealedVM();
        factory = new KernelFactory(
            address(manager),
            address(router),
            address(wokb),
            address(circuits),
            address(fab),
            address(sealedVM),
            address(beacon),
            address(impl),
            address(impl).codehash
        );
        lens = new Lens();
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(whale, 100_000 ether);
        vm.deal(keeper, 100 ether);
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

    /// @dev A 14-byte output word from the fields that matter to kernel v1.
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
        Kernel kernel;
        MockToken token;
        MockVault vault;
        uint256 chipId;
    }

    /// @dev Tape out, create the kernel, launch the token with the kernel as vault recipient, move the chip
    ///      NFT to the kernel and bind.
    function _build(bytes memory netlist, uint32 gateCount, Envelope memory e, uint16 taxBps, bytes32 salt)
        internal
        returns (Built memory b)
    {
        vm.prank(launcher);
        b.chipId = fab.tapeoutChip(netlist, gateCount);
        b.kernel = Kernel(payable(factory.create(e, b.chipId, salt)));
        (address t, address v) = manager.createToken(launcher, address(b.kernel), taxBps, taxBps, 0, 0, GRADUATION);
        b.token = MockToken(t);
        b.vault = MockVault(payable(v));
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(b.kernel), b.chipId);
        b.kernel.bind(t);
    }

    /// @dev The default fixture: a fixed chip, 3% / 3% tax, the default envelope.
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

    function _buy(address who, uint256 amount) internal {
        vm.prank(who);
        manager.buy{value: amount}(address(token), amount, 0);
    }

    function _sell(address who, uint256 tokens) internal {
        vm.startPrank(who);
        token.approve(address(manager), tokens);
        manager.sell(address(token), tokens, 0);
        vm.stopPrank();
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }

    function _settle() internal returns (uint32 n) {
        vm.prank(keeper);
        n = kernel.settle();
    }

    /// @dev One settle attempt by the keeper, and how many times each evaluator's `step` was called in it.
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

    /// @dev Both evaluators fail in the same way: the only case in which a beat fails.
    function _killBoth(uint8 mode) internal {
        circuits.setStepMode(mode);
        sealedVM.setStepMode(mode);
    }

    function _rec(uint32 n) internal view returns (Record memory) {
        return kernel.records(n);
    }

    function _in(uint32 n) internal view returns (KernelMath.InputFields memory) {
        return KernelMath.unpackInput(KernelMath.inputWord(kernel.records(n).inputs));
    }

    /// @dev A whale buys the rest of the curve; graduation runs inside the buy.
    function _graduate() internal returns (MockPair pair) {
        uint256 cost = manager.costToGraduate(address(token));
        vm.prank(whale);
        manager.buy{value: cost + 1 ether}(address(token), cost + 1 ether, 0);
        pair = MockPair(manager.pairOf(address(token)));
        assertTrue(address(pair) != address(0), "did not graduate");
    }

    /// @dev A V2 buy by `who` (pays the token's buy tax to the vault).
    function _v2Buy(address who, uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = address(wokb);
        path[1] = address(token);
        vm.prank(who);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(0, path, who, block.timestamp);
    }

    function _v2Sell(address who, uint256 tokens) internal {
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(wokb);
        vm.startPrank(who);
        token.approve(address(router), tokens);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(tokens, 0, path, who, block.timestamp);
        vm.stopPrank();
    }

    function _curve() internal view returns (TradeMath.Curve memory c) {
        MockManager.Token memory t = manager.raw(address(token));
        c.buyFeeBps = t.buyFeeBps;
        c.sellFeeBps = t.sellFeeBps;
        c.taxBuyBps = t.taxBuyBps;
        c.taxSellBps = t.taxSellBps;
        c.vQuote = t.vQuote;
        c.vToken = t.vToken;
        c.sold = t.sold;
        c.sellable = t.sellable;
    }

    function _has(uint8 flags, uint8 bit) internal pure returns (bool) {
        return flags & bit != 0;
    }
}
