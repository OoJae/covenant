// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Record, Envelope, RecordFlags} from "./interfaces/IKernelV1.sol";
import {Globals, IKernelExt} from "./interfaces/IKernelExt.sol";
import {ISealedVM, ICircuits} from "./interfaces/IEvaluators.sol";
import {KernelMath} from "./KernelMath.sol";

/// @title Lens
/// @notice Read-only audit tools for kernels. Stateless, holds nothing, can be redeployed at any time; no
///         kernel depends on it. Every function is meant for `eth_call` (free, no wallet).
///
///         Paging: one evaluator step of a large chip costs millions of gas and public RPCs cap `eth_call`
///         at 50M, so the range functions stop early when the remaining gas could not pay for another step
///         and return the next record number to continue from.
contract Lens {
    uint32 internal constant N_IN = 96;
    uint32 internal constant N_OUT = 112;

    /// Bits of the output word that decide routing in kernel v1: the T_* shares, REL and CEIL.
    uint256 internal constant ROUTE_MASK = ((uint256(1) << 36) - 1) | (((uint256(1) << 19) - 1) << 72);

    /// Gas given to one step of a shadow chip: what the factory gives TapeOut's evaluator for the largest
    /// chip it accepts (3,400 gates, 256 of them latches).
    uint256 internal constant SHADOW_GAS = 200_000 + 2_600 * 3_400 + 800 * 256;

    error PageTooLarge();
    error BadRange();

    // ------------------------------------------------------------------------------------------ replay

    struct Replay {
        bool ok; // every check below passed
        bool ran; // the evaluator answered with the right lengths (always true for a fallback record)
        bool outputsMatch; // evaluator output == stored outputs (fallback record: the fallback word)
        bool stateMatch; // evaluator next state == stored stateAfter (fallback record: state unchanged)
        bool amountsMatch; // KernelMath.route over the stored values == stored clampBits, allow, buyDecided
        bool inputsMatch; // TAX, TAXCUM, RES, GRAD and the zero fields of the stored input word fit the record
        bool sealedUsed; // evaluator this replay used
        bytes14 outputs; // what the evaluator returns now
        bytes32 stateAfter;
    }

    /// @notice Recomputes record `n` from the previous state and the stored inputs through the evaluator the
    ///         record says was used, and through KernelMath, and compares with what the kernel stored.
    function replay(address kernel, uint32 n) external view returns (Replay memory) {
        Record memory r = IKernelExt(kernel).records(n);
        return _replay(kernel, n, r, r.flags & RecordFlags.SEALED != 0);
    }

    /// @notice The same replay through a chosen evaluator: `useSealed` false is TapeOut's `Circuits.step`.
    function replayOn(address kernel, uint32 n, bool useSealed) external view returns (Replay memory) {
        return _replay(kernel, n, IKernelExt(kernel).records(n), useSealed);
    }

    /// @notice Replays records fromN..toN on one evaluator. Stops early when gas runs low.
    /// @return next     first record not replayed (toN + 1 when the page was completed)
    /// @return firstBad first record whose replay failed, or 0
    function replayRange(address kernel, uint32 fromN, uint32 toN, bool useSealed)
        external
        view
        returns (uint32 next, uint32 firstBad)
    {
        if (fromN == 0 || toN < fromN || toN > IKernelExt(kernel).count()) revert BadRange();
        uint256 floor = IKernelExt(kernel).globals().stepFloor;
        next = fromN;
        while (next <= toN && gasleft() > 2 * floor + 1_000_000) {
            Replay memory p = _replay(kernel, next, IKernelExt(kernel).records(next), useSealed);
            if (!p.ok && firstBad == 0) firstBad = next;
            next++;
        }
    }

    function _replay(address kernel, uint32 n, Record memory r, bool useSealed) private view returns (Replay memory p) {
        IKernelExt k = IKernelExt(kernel);
        if (n == 0 || n > k.count()) revert BadRange();
        Globals memory g = k.globals();
        Envelope memory e = k.envelope();
        bytes32 stateBefore = n == 1 ? bytes32(0) : k.records(n - 1).stateAfter;
        p.sealedUsed = useSealed;

        uint256 outWord;
        if (r.flags & RecordFlags.FALLBACK != 0) {
            // the evaluator had failed: the kernel applied the fallback word and left the state alone
            outWord = KernelMath.fallbackWord(e.fbAllow, e.relMax);
            p.ran = true;
            p.outputs = KernelMath.outputBytes(outWord);
            p.stateAfter = stateBefore;
        } else {
            (p.ran, p.stateAfter, p.outputs) = _step(_own(g, useSealed), stateBefore, r.inputs);
            outWord = KernelMath.outputWord(p.outputs);
        }
        p.outputsMatch = p.ran && p.outputs == r.outputs;
        p.stateMatch = p.ran && p.stateAfter == r.stateAfter;

        (p.amountsMatch, p.inputsMatch) = _checkRecord(k, n, r, e);
        p.ok = p.ran && p.outputsMatch && p.stateMatch && p.amountsMatch && p.inputsMatch;
    }

    /// @dev Checks that do not need the evaluator: the stored amounts are KernelMath.route of the STORED output
    ///      word, and the stored input word carries the lg8 codes of the stored amounts.
    function _checkRecord(IKernelExt k, uint32 n, Record memory r, Envelope memory e)
        private
        view
        returns (bool amountsMatch, bool inputsMatch)
    {
        (uint128 cum, uint128 paidAfter) = k.cums(n);
        if (paidAfter < r.allow) return (false, false);
        bool grad = r.flags & RecordFlags.GRADUATED != 0;
        KernelMath.Routed memory rt = KernelMath.route(
            _routeEnv(e), KernelMath.outputWord(r.outputs), r.inflow, r.reserveBefore, cum, paidAfter - r.allow, grad
        );
        amountsMatch = rt.clamp == r.clampBits && rt.allow == r.allow && rt.buyDecided == r.buyDecided
            && r.buyExecuted <= r.buyDecided;

        uint256 inWord = KernelMath.inputWord(r.inputs);
        KernelMath.InputFields memory f = KernelMath.unpackInput(inWord);
        inputsMatch = f.tax == KernelMath.lg8(r.inflow) && f.taxCum == KernelMath.lg8(cum)
            && f.res == KernelMath.lg8(r.reserveBefore) && f.grad == (grad ? 1 : 0) && f.rev == 0 && f.revCum == 0
            && f.esc == 0 && (!grad || f.prog == 255) && inWord >> 81 == 0 && f.dt != 0;
    }

    // ------------------------------------------------------------------------------------------ counterfactual

    struct Totals {
        uint256 inflow;
        uint256 allow;
        uint256 buy; // decided buy-and-lock amount
        uint256 reserveEnd; // reserve after the last record of the page in this regime
    }

    struct Counterfactual {
        Totals chip; // what the records say the chip routed
        uint256 chipBuyExecuted; // of chip.buy, what actually executed
        Totals fixedSplit; // the envelope's fallback word applied on every settle instead
        Totals alwaysBuy; // every inflow bought in the settle that received it: no allowance, no reserve
    }

    /// Running state of the fixed-split baseline, for paging.
    struct CfCursor {
        uint256 reserve;
        uint256 allowPaid;
        bool grad;
    }

    /// @notice What a fixed split and an always-buy baseline would have routed on the same inflows.
    ///         Amounts on the curve are native OKB; after graduation they are project tokens, so the two
    ///         regimes are reported separately. The baselines start empty at `fromN`.
    function counterfactual(address kernel, uint32 fromN, uint32 toN)
        external
        view
        returns (Counterfactual memory curve, Counterfactual memory graduated, CfCursor memory next)
    {
        CfCursor memory cur;
        return counterfactualFrom(kernel, fromN, toN, cur);
    }

    /// @notice The same, continuing a previous page: pass the `next` cursor that page returned.
    function counterfactualFrom(address kernel, uint32 fromN, uint32 toN, CfCursor memory cur)
        public
        view
        returns (Counterfactual memory curve, Counterfactual memory graduated, CfCursor memory next)
    {
        IKernelExt k = IKernelExt(kernel);
        if (fromN == 0 || toN < fromN || toN > k.count()) revert BadRange();
        Envelope memory e = k.envelope();
        KernelMath.RouteEnv memory env = _routeEnv(e);
        uint256 fb = KernelMath.fallbackWord(e.fbAllow, e.relMax);
        for (uint32 n = fromN; n <= toN; n++) {
            _cfOne(k, env, fb, n, cur, curve, graduated);
        }
        next = cur;
    }

    function _cfOne(
        IKernelExt k,
        KernelMath.RouteEnv memory env,
        uint256 fb,
        uint32 n,
        CfCursor memory cur,
        Counterfactual memory curve,
        Counterfactual memory graduated
    ) private view {
        Record memory r = k.records(n);
        (uint128 cum,) = k.cums(n);
        bool grad = r.flags & RecordFlags.GRADUATED != 0;
        if (grad && !cur.grad) {
            // the regime asset changes at graduation: both totals start again
            cur.grad = true;
            cur.reserve = 0;
            cur.allowPaid = 0;
        }
        Counterfactual memory c = grad ? graduated : curve;
        c.chip.inflow += r.inflow;
        c.chip.allow += r.allow;
        c.chip.buy += r.buyDecided;
        c.chipBuyExecuted += r.buyExecuted;
        c.chip.reserveEnd = uint256(r.reserveBefore) + r.inflow - r.allow - r.buyExecuted;

        KernelMath.Routed memory rt = KernelMath.route(env, fb, r.inflow, cur.reserve, cum, cur.allowPaid, grad);
        cur.reserve = rt.reserveAfter;
        cur.allowPaid += rt.allow;
        c.fixedSplit.inflow += r.inflow;
        c.fixedSplit.allow += rt.allow;
        c.fixedSplit.buy += rt.buyDecided;
        c.fixedSplit.reserveEnd = cur.reserve;

        c.alwaysBuy.inflow += r.inflow;
        c.alwaysBuy.buy += r.inflow;
    }

    // ------------------------------------------------------------------------------------------ shadow run

    /// Running state of a shadow run, for paging. Start with all zeros at record 1.
    struct ShadowCursor {
        bytes32 state;
        uint256 reserve;
        uint256 allowPaid;
        bool grad;
    }

    struct ShadowStep {
        uint32 n;
        bool ran; // false: the shadow chip failed and the fallback word was applied, as the kernel would
        bytes12 inputs; // the recorded inputs with RES replaced by the shadow chip's own reserve
        bytes14 outputs;
        uint16 clampBits;
        uint128 allow;
        uint128 buyDecided;
        uint128 reserveAfter; // if the whole decided buy executes
    }

    /// @notice Runs ANOTHER taped chip (same processor) over the inflows recorded by `kernel`, with the
    ///         kernel's own envelope and routing arithmetic. The shadow chip sees its own reserve: RES in
    ///         each input word is recomputed from the shadow run; every other input is the recorded one.
    ///         Decided buys are assumed to execute in full.
    function shadowChip(address kernel, uint256 chipId, uint32 fromN, uint32 toN, ShadowCursor memory cur)
        external
        view
        returns (ShadowStep[] memory steps, ShadowCursor memory next, uint32 nextN)
    {
        Target memory t;
        t.vm = IKernelExt(kernel).globals().circuits;
        t.chipId = chipId;
        t.gasCap = SHADOW_GAS;
        return _shadow(kernel, t, fromN, toN, cur);
    }

    /// @notice The same for any netlist stored at an SSTORE2 pointer (0x00 followed by the netlist bytes),
    ///         evaluated by the sealed evaluator. No tape-out and no transistors are needed.
    function shadowSnapshot(address kernel, address snapshot, uint32 fromN, uint32 toN, ShadowCursor memory cur)
        external
        view
        returns (ShadowStep[] memory steps, ShadowCursor memory next, uint32 nextN)
    {
        Target memory t;
        t.vm = IKernelExt(kernel).globals().sealedVM;
        t.sealedVm = true;
        t.snapshot = snapshot;
        t.gasCap = SHADOW_GAS;
        return _shadow(kernel, t, fromN, toN, cur);
    }

    function _shadow(address kernel, Target memory t, uint32 fromN, uint32 toN, ShadowCursor memory cur)
        private
        view
        returns (ShadowStep[] memory steps, ShadowCursor memory next, uint32 nextN)
    {
        IKernelExt k = IKernelExt(kernel);
        if (fromN == 0 || toN < fromN || toN > k.count()) revert BadRange();
        Envelope memory e = k.envelope();
        steps = new ShadowStep[](toN - fromN + 1);
        nextN = fromN;
        uint256 done;
        // a shadow chip may be as large as the limit allows: keep gas for one worst-case step
        while (nextN <= toN && gasleft() > SHADOW_GAS + 2_000_000) {
            steps[done] = _shadowOne(k, e, t, nextN, cur);
            done++;
            nextN++;
        }
        assembly ("memory-safe") {
            mstore(steps, done)
        }
        next = cur;
    }

    function _shadowOne(IKernelExt k, Envelope memory e, Target memory t, uint32 n, ShadowCursor memory cur)
        private
        view
        returns (ShadowStep memory s)
    {
        Record memory r = k.records(n);
        (uint128 cum,) = k.cums(n);
        bool grad = r.flags & RecordFlags.GRADUATED != 0;
        if (grad && !cur.grad) {
            cur.grad = true;
            cur.reserve = 0;
            cur.allowPaid = 0;
        }
        s.n = n;
        // RES is bits 40..49 of the input word
        uint256 inWord = KernelMath.inputWord(r.inputs);
        inWord = (inWord & ~(uint256(0x3ff) << 40)) | (KernelMath.lg8(cur.reserve) << 40);
        s.inputs = KernelMath.inputBytes(inWord);

        bytes32 ns;
        (s.ran, ns, s.outputs) = _step(t, cur.state, s.inputs);
        uint256 outWord;
        if (s.ran) {
            cur.state = ns;
            outWord = KernelMath.outputWord(s.outputs);
        } else {
            outWord = KernelMath.fallbackWord(e.fbAllow, e.relMax);
            s.outputs = KernelMath.outputBytes(outWord);
        }
        KernelMath.Routed memory rt =
            KernelMath.route(_routeEnv(e), outWord, r.inflow, cur.reserve, cum, cur.allowPaid, grad);
        cur.reserve = rt.reserveAfter;
        cur.allowPaid += rt.allow;
        s.clampBits = rt.clamp;
        s.allow = uint128(rt.allow);
        s.buyDecided = uint128(rt.buyDecided);
        s.reserveAfter = uint128(rt.reserveAfter);
    }

    // ------------------------------------------------------------------------------------------ state matters

    /// @notice Did the stored state change the route of settle `n`? Steps the chip twice on the inputs of
    ///         record `n`: from the state the kernel held, and from the all-zero state (the state every chip
    ///         starts in, so it is reachable). `matters` is true when the T_* shares, REL or CEIL differ.
    function stateMatters(address kernel, uint32 n)
        external
        view
        returns (bool matters, bytes14 withState, bytes14 withZeroState)
    {
        return stateMattersVs(kernel, n, bytes32(0));
    }

    /// @notice The same against any other state, for example the state before another record.
    function stateMattersVs(address kernel, uint32 n, bytes32 otherState)
        public
        view
        returns (bool matters, bytes14 withState, bytes14 withOtherState)
    {
        IKernelExt k = IKernelExt(kernel);
        if (n == 0 || n > k.count()) revert BadRange();
        Globals memory g = k.globals();
        Record memory r = k.records(n);
        bool useSealed = r.flags & RecordFlags.SEALED != 0;
        bytes32 stateBefore = n == 1 ? bytes32(0) : k.records(n - 1).stateAfter;
        Target memory t = _own(g, useSealed);
        bool ranA;
        bool ranB;
        (ranA,, withState) = _step(t, stateBefore, r.inputs);
        (ranB,, withOtherState) = _step(t, otherState, r.inputs);
        matters = ranA && ranB
            && (KernelMath.outputWord(withState) & ROUTE_MASK) != (KernelMath.outputWord(withOtherState) & ROUTE_MASK);
    }

    // ------------------------------------------------------------------------------------------ preflight

    struct Preflight {
        bool sealedModeNow; // true: the next settle would go straight to the sealed evaluator
        bool tapeoutRan; // TapeOut's step answered within the gas the kernel gives it (stepFloor)
        bool sealedRan; // the sealed evaluator answered within the gas the kernel gives it (sealedFloor)
        bool agree; // both ran and returned identical state and outputs
        uint256 tapeoutGas;
        uint256 sealedGas;
        uint256 stepFloor;
        uint256 sealedFloor;
        uint256 minSettleGas;
    }

    /// @notice Run before a token is launched against a kernel: steps the kernel's chip once on both
    ///         evaluators (zero state, zero inputs) with exactly the gas a settle gives them.
    function preflight(address kernel) external view returns (Preflight memory p) {
        IKernelExt k = IKernelExt(kernel);
        Globals memory g = k.globals();
        (, p.sealedModeNow) = k.evaluator();
        p.stepFloor = g.stepFloor;
        p.sealedFloor = g.sealedFloor;
        p.minSettleGas = k.minSettleGas();
        bytes32 sA;
        bytes32 sB;
        bytes14 oA;
        bytes14 oB;
        uint256 g0 = gasleft();
        (p.tapeoutRan, sA, oA) = _step(_own(g, false), bytes32(0), bytes12(0));
        p.tapeoutGas = g0 - gasleft();
        g0 = gasleft();
        (p.sealedRan, sB, oB) = _step(_own(g, true), bytes32(0), bytes12(0));
        p.sealedGas = g0 - gasleft();
        p.agree = p.tapeoutRan && p.sealedRan && sA == sB && oA == oB;
    }

    // ------------------------------------------------------------------------------------------ internals

    function _routeEnv(Envelope memory e) private pure returns (KernelMath.RouteEnv memory) {
        return KernelMath.RouteEnv({
            capT: e.capT,
            allowCumBps: e.allowCumBps,
            ceilMax: e.ceilMax,
            relMax: e.relMax,
            floorRel: e.floorRel,
            floorMin: e.floorMin
        });
    }

    /// What to step: a chip on TapeOut's Circuits contract, or a snapshot on the sealed evaluator.
    struct Target {
        address vm;
        bool sealedVm;
        address snapshot;
        uint256 chipId;
        uint256 nState; // 0 accepts any state length up to 32 bytes (shadow chips)
        uint256 gasCap;
    }

    /// @dev The kernel's own chip on one of its two evaluators, with the gas a settle gives it.
    function _own(Globals memory g, bool useSealed) private pure returns (Target memory t) {
        t.vm = useSealed ? g.sealedVM : g.circuits;
        t.sealedVm = useSealed;
        t.snapshot = g.snapshot;
        t.chipId = g.chipId;
        t.nState = g.nState;
        t.gasCap = useSealed ? g.sealedFloor : g.stepFloor;
    }

    /// @dev One beat. The state must be exactly ceil(nState / 8) bytes and the outputs 14 bytes, as in the
    ///      kernel; anything else is `ran = false`.
    function _step(Target memory t, bytes32 st, bytes12 inp)
        private
        view
        returns (bool ran, bytes32 newState, bytes14 outputs)
    {
        if (gasleft() < t.gasCap + t.gasCap / 63 + 50_000) revert PageTooLarge();
        bytes memory a;
        bytes memory b;
        if (t.sealedVm) {
            try ISealedVM(t.vm).step{gas: t.gasCap}(
                t.snapshot, N_IN, N_OUT, abi.encodePacked(st), abi.encodePacked(inp)
            ) returns (
                bytes memory x, bytes memory y
            ) {
                (a, b) = (x, y);
            } catch {
                return (false, 0, 0);
            }
        } else {
            try ICircuits(t.vm).step{gas: t.gasCap}(t.chipId, abi.encodePacked(st), abi.encodePacked(inp)) returns (
                bytes memory x, bytes memory y
            ) {
                (a, b) = (x, y);
            } catch {
                return (false, 0, 0);
            }
        }
        if (b.length != KernelMath.OUT_BYTES) return (false, 0, 0);
        if (t.nState == 0 ? a.length > 32 : a.length != (t.nState + 7) / 8) return (false, 0, 0);
        return (true, KernelMath.stateToBytes32(a), bytes14(b));
    }
}
