// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IKernelV1, Record, Envelope, RecordFlags} from "./interfaces/IKernelV1.sol";
import {Globals, IKernelExt, IKernelFactoryCallback} from "./interfaces/IKernelExt.sol";
import {ISealedVM, ICircuits, IBeacon} from "./interfaces/IEvaluators.sol";
import {IIgnixManager, IDirectedVault, IIgnixToken, IUniswapV2Pair, IUniswapV2Router02} from "./interfaces/IIgnix.sol";
import {KernelMath} from "./KernelMath.sol";
import {TradeMath} from "./lib/TradeMath.sol";
import {SafeCall} from "./lib/SafeCall.sol";

/// @title Kernel v1
/// @notice The immutable RECIPIENT of one IGNIX Directed vault. It holds a token's trading tax and, at most
///         once per epoch, steps the token's vault chip and routes the money by the chip's output inside an
///         immutable envelope (chips/INTERFACE.md sections 7 to 10).
///
///         No owner, no upgrade path, no pause, no setter. One clone per token; the envelope and every
///         address the kernel talks to are the clone's own bytecode.
///
///         Value can leave this contract only
///           - to the IgnixManager inside `buyTo` (curve buy; the tokens come back and cannot move),
///           - to the Uniswap V2 router inside the post-graduation buy (the tokens go to 0xdEaD),
///           - as project tokens to 0xdEaD (post-graduation buy share, and `burnLocked`),
///           - to a credited payee through `withdrawCredit` (the allowance payee, or `sink` when buys are off).
///         The kernel's code makes no delegatecall and never calls a caller-chosen target.
///
/// @dev    Rules the code keeps:
///           1. Nothing a chip outputs can make `settle` revert (KernelMath.route clips; it never throws).
///           2. Nothing an external contract does can make `settle` revert, with two exceptions: both
///              evaluators failing inside the grace period, and a buy refused because the caller of `settle`
///              holds the callee's reentrancy lock (rule 6). Every external call is a gas-capped low-level
///              call whose effect is measured by balance deltas (lib/SafeCall.sol).
///           3. The caller's gas limit cannot change an outcome: every external call gets a fixed amount of
///              gas, and `settle` reverts BEFORE the call if the 63/64 rule would hand over less. A settle
///              therefore either reverts as a whole or writes the same record for every gas limit.
///           4. Inflow is what the contract holds beyond its books (credits, reserve, locked tokens), never
///              the amount a claim call reports. Money that arrived between settles (project tokens pushed by
///              the platform or by anyone, forced native transfers) is counted the same way.
///           5. Before graduation the kernel has no approve, sell, transfer or generic call path, so tokens it
///              bought cannot leave it. After graduation they can only go to 0xdEaD.
///           6. A caught failure is one every caller would see. A buy that fails because the IgnixManager's or
///              the pair's reentrancy lock is held fails only for a caller that settles from inside a call into
///              that contract, so it is not recorded: the whole settle reverts and the epoch stays open.
contract Kernel is IKernelExt, ReentrancyGuardTransient {
    // ------------------------------------------------------------------------------------------ constants

    address internal constant NATIVE = address(0);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint32 internal constant N_IN = 96;
    uint32 internal constant N_OUT = 112;

    // Gas handed to each kind of external call. Each is more than three times the largest cost measured on
    // an X Layer fork at block 72,369,000 (contracts/probes/FINDINGS.md section 9; NOTES.md), so a failure
    // inside the callee is never caused by this limit. Measured worst cases are given in brackets.
    // G_VIEW is also what the pair-lock probe gets: a pair whose lock is held answers in under 1,000 gas,
    // and one whose lock is free fails by design at its first write, whatever it is given.
    uint256 internal constant G_VIEW = 100_000; // small views [tokens() 22,573]
    uint256 internal constant G_NETLIST = 500_000; // Circuits.netlist(chipId) [140,355 for 23,032 bytes]
    uint256 internal constant G_CLAIM = 200_000; // vault.claim(asset), with this contract's receive() [53,496]
    uint256 internal constant G_BUY = 500_000; // IgnixManager.buyTo, never a graduating buy [135,037]
    uint256 internal constant G_TRANSFER = 200_000; // project token transfer to 0xdEaD [53,349]
    uint256 internal constant G_SWAP = 700_000; // Uniswap V2 router buy of the taxed token [210,269]

    /// Gas kept on top of 64/63 of a call's allowance for the CALL itself (cold account, value, memory).
    uint256 internal constant CALL_MARGIN = 20_000;
    /// Upper bound of the gas `settle` spends outside external calls (storage, record, events, hashing).
    uint256 internal constant G_SELF = 600_000;
    /// Number of G_VIEW calls on the longest path (14: the settle that sees graduation and whose swap fails,
    /// which adds the pair-lock probe), plus one.
    uint256 internal constant N_VIEWS = 15;

    /// Round-trip trading fee, in bps, that no trader can recover on the Uniswap V2 pair. A swap costs 0.30%
    /// per side, but the pair's liquidity is locked in IGNIX's V2 locker, which pays the token creator half of
    /// the LP fee. IGNIX documents the split as 0.125% per side, so only 0.125% + 0.125% is counted.
    uint256 internal constant V2_ROUND_TRIP_FEE_BPS = 25;
    /// A swap must deliver at least this share of the exact quote. The quote is exact when the pair is in
    /// sync; the slack only keeps a rounding difference in the token's tax from blocking the exit. Sandwich
    /// protection is the impact cap, not this number.
    uint256 internal constant SWAP_MIN_BPS = 9_900;
    /// Tax assumed for the swap's minimum output when the Manager cannot be read: IGNIX's maximum (10%).
    uint256 internal constant MAX_TAX_BPS = 1_000;
    /// Revert data read from a failed swap and from the pair-lock probe: Error(string) with a string of up to
    /// 32 bytes (4 + 32 + 32 + 32).
    uint256 internal constant SWAP_ERR_BYTES = 100;

    // ------------------------------------------------------------------------------------------ storage

    /// @dev Storage form of a Record, 7 slots. `cumInflow` and `allowPaidCum` are the regime totals after
    ///      this settle; they make every record replayable on its own (see Lens).
    struct Rec {
        uint32 epoch;
        uint40 time;
        uint16 clampBits;
        uint8 flags;
        bytes12 inputs;
        // slot 1
        bytes14 outputs;
        uint128 inflow;
        // slot 2
        bytes32 stateAfter;
        // slot 3
        uint128 reserveBefore;
        uint128 allow;
        // slot 4
        uint128 buyDecided;
        uint128 buyExecuted;
        // slot 5
        uint128 tokensOut;
        uint128 cumInflow;
        // slot 6
        uint128 allowPaidCum;
        uint128 nativeIn;
    }

    // slot 0
    address public override token;
    uint40 public override bindTime;
    uint32 public override lastEpoch; // epoch of the last settle
    bool public override graduated; // latched by the first settle in which the token reports a pair
    // slot 1
    address public override vault;
    uint32 public override lastStepEpoch; // epoch of the last persisted step (0 = bind)
    uint32 public override count;
    // slot 2
    address public override pair; // IgnixToken.pair() as read when `graduated` latched
    // slot 3
    bytes32 public override state;
    // slot 4: reserve of the regime asset (native OKB on the curve, the project token after graduation)
    uint256 public override reserve;
    // slot 5: regime totals; both restart at graduation
    uint128 public override cumInflow;
    uint128 public override allowPaidCum;
    // slot 6
    uint128 internal _locked; // tokens bought on the curve, held here until burnLocked()
    uint128 public override burnedTokens; // tokens this kernel sent or bought to 0xdEaD
    // slot 7
    uint256 public override tokenSupply; // token.totalSupply() at bind (IGNIX supply is fixed)

    mapping(address payee => mapping(address asset => uint256 amount)) internal _credit;
    mapping(address asset => uint256 amount) public override totalCredits;
    mapping(uint256 n => Rec) internal _rec;

    /// @dev The implementation itself. Clones run this code through their fixed proxy, so `address(this)`
    ///      differs from SELF there.
    address private immutable SELF = address(this);

    /// @dev The one address native OKB may arrive from right now: the vault while this contract is inside
    ///      its own claim, the Manager while it is inside its own buyTo, nobody otherwise. Transient storage:
    ///      it cannot outlive the call that set it.
    address private transient _payer;

    // ------------------------------------------------------------------------------------------ events, errors

    event Bound(address indexed token, address indexed vault, uint40 bindTime);
    event GraduationSeen(address indexed pair, uint256 nativeReserveReleased);
    event Credited(address indexed payee, address indexed asset, uint256 amount);
    event CreditWithdrawn(address indexed payee, address indexed asset, uint256 amount);
    /// Post-graduation native leg: OKB spent on the pair and tokens that reached 0xdEaD.
    event NativeSwept(uint32 indexed n, uint256 nativeIn, uint256 tokensBurned);
    event LockedBurned(uint256 amount);

    error OnlyClone();
    error AlreadyBound();
    error NotBound();
    error BindCheck(uint8 which);
    error EpochNotElapsed();
    error InsufficientGas();
    error StepFailed();
    error PayFailed();
    error NotAccepted();
    error NotGraduated();
    /// A buy was refused because the caller of `settle` holds the callee's reentrancy lock.
    error LockHeld();

    modifier onlyClone() {
        if (address(this) == SELF) revert OnlyClone();
        _;
    }

    // ------------------------------------------------------------------------------------------ configuration

    function _cfg() internal view returns (Globals memory g, Envelope memory e) {
        (g, e) = abi.decode(Clones.fetchCloneArgs(address(this)), (Globals, Envelope));
    }

    function envelope() external view override onlyClone returns (Envelope memory e) {
        (, e) = _cfg();
    }

    function globals() external view override onlyClone returns (Globals memory g) {
        (g,) = _cfg();
    }

    function chipId() external view override onlyClone returns (uint256) {
        (Globals memory g,) = _cfg();
        return g.chipId;
    }

    // ------------------------------------------------------------------------------------------ bind

    /// @notice Binds this kernel to `token_`, once. Anyone may call for a token the envelope's launcher
    ///         created; the launcher itself may also bind a token that another wallet created.
    /// @dev    BindCheck codes: 1 no vault, 2 vault.RECIPIENT is not this kernel, 3 vault.TOKEN mismatch,
    ///         4 quote is not native OKB, 5 the curve cannot be read, or neither the token's creator nor the
    ///         caller is the envelope's launcher, 6 the token has no tax (such a token graduates to Uniswap V4,
    ///         where this kernel has no exit for native OKB), 7 this kernel does not hold the chip NFT.
    function bind(address token_) external override nonReentrant onlyClone {
        if (token != address(0)) revert AlreadyBound();
        (Globals memory g, Envelope memory e) = _cfg();

        address v = token_ == address(0) ? address(0) : IIgnixManager(g.manager).vaultOf(token_);
        if (v == address(0)) revert BindCheck(1);
        if (IDirectedVault(v).RECIPIENT() != address(this)) revert BindCheck(2);
        if (IDirectedVault(v).TOKEN() != token_) revert BindCheck(3);
        if (IDirectedVault(v).QUOTE() != NATIVE) revert BindCheck(4);
        {
            (bool ok, uint256 size, bytes memory t) =
                SafeCall.staticRead(g.manager, gasleft(), abi.encodeCall(IIgnixManager.tokens, (token_)), 512);
            if (!ok || size < 512) revert BindCheck(5);
            if (address(uint160(_word(t, 0))) != e.launcher && msg.sender != e.launcher) revert BindCheck(5);
            if (_word(t, 3) == 0 && _word(t, 4) == 0) revert BindCheck(6);
        }
        if (ICircuits(g.circuits).ownerOf(g.chipId) != address(this)) revert BindCheck(7);

        token = token_;
        vault = v;
        bindTime = uint40(block.timestamp);
        (bool okSupply, uint256 supply) =
            SafeCall.staticWord(token_, G_VIEW, abi.encodeCall(IIgnixToken.totalSupply, ()));
        tokenSupply = okSupply ? supply : 0;

        IKernelFactoryCallback(g.factory).noteBound(token_);
        emit Bound(token_, v, uint40(block.timestamp));
    }

    // ------------------------------------------------------------------------------------------ settle

    /// @dev Working values of one settle, kept in memory to stay inside the stack.
    struct Work {
        address tok;
        address asset; // regime asset
        uint256 epoch;
        uint256 lastStep;
        bool grad;
        bool curveOk;
        bool stepOk;
        uint8 flags;
        uint256 inflow;
        uint256 reserve0;
        uint256 cum;
        bytes12 inputs;
        bytes14 outputs;
        bytes32 newState;
        uint256 executed;
        uint256 tokensOut;
        uint256 nativeIn;
    }

    /// @notice Runs one settlement. At most one per epoch; reverts when the epoch has not elapsed.
    /// @return n the number of the record written (records are 1-indexed)
    function settle() external override nonReentrant onlyClone returns (uint32 n) {
        (Globals memory g, Envelope memory e) = _cfg();
        Work memory w;
        w.tok = token;
        if (w.tok == address(0)) revert NotBound();
        w.epoch = (block.timestamp - bindTime) / e.epochLen;
        if (w.epoch > type(uint32).max) w.epoch = type(uint32).max;
        if (w.epoch <= lastEpoch) revert EpochNotElapsed();
        if (gasleft() < _minSettleGas(g.stepFloor, g.sealedFloor)) revert InsufficientGas();
        w.lastStep = lastStepEpoch;

        // ---- 1. regime: native OKB on the curve, the project token once the token itself reports its pair.
        //         A failed read neither sets nor clears the latch.
        w.grad = graduated;
        if (!w.grad) {
            (bool ok, uint256 p) = _view(w.tok, abi.encodeCall(IIgnixToken.pair, ()));
            address pair_ = address(uint160(p));
            if (ok && pair_ != address(0)) {
                // Graduation. The token becomes the regime asset; its totals start at zero. The OKB reserve is
                // no longer tracked: together with any later OKB it is the "native pot" of the V2 leg.
                w.grad = true;
                graduated = true;
                pair = pair_;
                emit GraduationSeen(pair_, reserve);
                reserve = 0;
                cumInflow = 0;
                allowPaidCum = 0;
            }
        }
        if (w.grad) w.flags |= RecordFlags.GRADUATED;
        w.asset = w.grad ? w.tok : NATIVE;

        // ---- 2. claims (a failure is a flag, never a revert)
        {
            address v = vault;
            if (_claim(v, NATIVE, w.tok)) w.flags |= RecordFlags.CLAIM_FAILED;
            if (w.grad && _claim(v, w.tok, w.tok)) w.flags |= RecordFlags.CLAIM_FAILED;
        }

        // ---- 3. inflow by balance: whatever this contract holds beyond credits and locked tokens is either
        //         reserve or fresh inflow. Pushes by third parties (claimFor, the platform's daily token
        //         payout) are counted here exactly like the kernel's own claim.
        {
            uint256 free = _free(w.asset, w.grad);
            w.reserve0 = reserve;
            if (w.reserve0 > free) w.reserve0 = free; // never route more than is there
            w.inflow = free - w.reserve0;
            w.cum = _sat128(uint256(cumInflow) + w.inflow);
        }

        // ---- 4. curve read (a failure is a flag) and 5. the input word
        TradeMath.Curve memory c;
        (w.curveOk, c) = _readCurve(g.manager, w.tok);
        if (!w.curveOk) w.flags |= RecordFlags.CURVE_READ_FAILED;
        w.inputs = _inputs(w, c);

        // ---- 6. evaluator: TapeOut's step while its pins hold. The sealed evaluator is asked when they do not,
        //         and also when TapeOut's step fails for any reason. The beat fails only if neither answers.
        {
            bool askSealed = _sealedMode(g);
            if (!askSealed) {
                (w.stepOk, w.newState, w.outputs) = _step(g, false, state, w.inputs);
                askSealed = !w.stepOk;
            }
            if (askSealed) {
                (w.stepOk, w.newState, w.outputs) = _step(g, true, state, w.inputs);
                if (w.stepOk) w.flags |= RecordFlags.SEALED; // its answer is the one used
            }
        }
        uint256 outWord;
        if (w.stepOk) {
            outWord = KernelMath.outputWord(w.outputs);
        } else {
            // Inside the grace period nothing moves: the whole call reverts, the claim included.
            if (w.epoch - w.lastStep < e.fallbackEpochs) revert StepFailed();
            outWord = KernelMath.fallbackWord(e.fbAllow, e.relMax);
            w.outputs = KernelMath.outputBytes(outWord);
            w.newState = state; // unchanged
            w.flags |= RecordFlags.FALLBACK;
        }

        // ---- 7. clip to the envelope (no allowance in the graduated regime, whatever the word says)
        KernelMath.Routed memory r =
            KernelMath.route(_routeEnv(e), outWord, w.inflow, w.reserve0, w.cum, allowPaidCum, w.grad);

        // ---- 8. effects, before any leg. The decided buy stays in the reserve until it has executed.
        if (w.stepOk) {
            state = w.newState;
            lastStepEpoch = uint32(w.epoch);
        }
        lastEpoch = uint32(w.epoch);
        n = ++count;
        cumInflow = uint128(w.cum);
        allowPaidCum = uint128(_sat128(uint256(allowPaidCum) + r.allow));
        reserve = w.reserve0 + w.inflow - r.allow;
        if (r.allow != 0) _addCredit(e.allowancePayee, w.asset, r.allow);

        // ---- 9. legs
        if (r.buyDecided != 0) {
            if (!e.buyEnabled) {
                _addCredit(e.sink, w.asset, r.buyDecided);
                w.executed = r.buyDecided;
            } else if (w.grad) {
                _burnLeg(w, r.buyDecided);
            } else {
                _curveLeg(g, e.capT, w, c, r.buyDecided);
            }
            reserve = _sub0(reserve, w.executed);
        }
        if (w.grad) _nativeLeg(g, e, w, c, n);

        // ---- 10. record
        _write(n, w, r);
    }

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

    function _write(uint32 n, Work memory w, KernelMath.Routed memory r) private {
        uint128 decided = uint128(_sat128(r.buyDecided));
        uint128 executed = uint128(_sat128(w.executed));
        uint128 out = uint128(_sat128(w.tokensOut));
        _rec[n] = Rec({
            epoch: uint32(w.epoch),
            time: uint40(block.timestamp),
            clampBits: r.clamp,
            flags: w.flags,
            inputs: w.inputs,
            outputs: w.outputs,
            inflow: uint128(w.inflow),
            stateAfter: w.newState,
            reserveBefore: uint128(w.reserve0),
            allow: uint128(r.allow),
            buyDecided: decided,
            buyExecuted: executed,
            tokensOut: out,
            cumInflow: uint128(w.cum),
            allowPaidCum: allowPaidCum,
            nativeIn: uint128(_sat128(w.nativeIn))
        });
        emit Settled(
            n,
            uint32(w.epoch),
            w.inputs,
            w.outputs,
            r.clamp,
            w.flags,
            w.newState,
            uint128(w.inflow),
            uint128(r.allow),
            decided,
            executed,
            out
        );
    }

    // ------------------------------------------------------------------------------------------ settle: reads

    /// @dev Balance of the regime asset beyond what is owed or locked, capped at 128 bits.
    function _free(address asset, bool grad) private view returns (uint256 free) {
        uint256 owed = totalCredits[asset];
        uint256 bal;
        if (!grad) {
            bal = address(this).balance;
        } else {
            owed += _locked; // tokens bought on the curve are never fresh inflow
            (bool ok, uint256 b) = _balanceOf(asset, address(this));
            // An unreadable balance is treated as "exactly what the books say": nothing new, nothing lost.
            bal = ok ? b : owed + reserve;
        }
        free = _sat128(_sub0(bal, owed));
    }

    /// @dev Reads the curve words of IgnixManager.tokens(token). The struct is append-only upstream: any
    ///      return of at least 512 bytes is accepted and the first 16 words are decoded.
    function _readCurve(address manager, address tok) private view returns (bool ok, TradeMath.Curve memory c) {
        _needGas(G_VIEW);
        uint256 size;
        bytes memory t;
        (ok, size, t) = SafeCall.staticRead(manager, G_VIEW, abi.encodeCall(IIgnixManager.tokens, (tok)), 512);
        if (!ok || size < 512) return (false, c);
        c.buyFeeBps = _word(t, 1);
        c.sellFeeBps = _word(t, 2);
        c.taxBuyBps = _word(t, 3);
        c.taxSellBps = _word(t, 4);
        c.vQuote = _word(t, 9);
        c.vToken = _word(t, 10);
        c.sold = _word(t, 11);
        c.sellable = _word(t, 13);
        ok = TradeMath.sane(c);
    }

    function _inputs(Work memory w, TradeMath.Curve memory c) private view returns (bytes12) {
        KernelMath.InputFields memory f;
        f.tax = KernelMath.lg8(w.inflow);
        f.taxCum = KernelMath.lg8(w.cum);
        f.res = KernelMath.lg8(w.reserve0);
        // rev, revCum and esc stay 0 in kernel v1
        f.prog = KernelMath.progCode(w.curveOk ? c.sold : 0, w.curveOk ? c.sellable : 0, w.grad);
        f.lock = KernelMath.lockCode(uint256(_locked) + burnedTokens, tokenSupply);
        f.dt = KernelMath.dtCode(w.epoch, w.lastStep);
        f.grad = w.grad ? 1 : 0;
        return KernelMath.inputBytes(KernelMath.packInput(f));
    }

    // ------------------------------------------------------------------------------------------ settle: evaluator

    /// @dev True when the TapeOut evaluator can no longer be assumed to be the code and the netlist that were
    ///      pinned at creation: the beacon points elsewhere, the implementation's code changed, the chip's pin
    ///      counts changed, or its netlist bytes changed. Checked on every settle; there is no switch. The
    ///      settle then goes straight to the sealed evaluator.
    function _sealedMode(Globals memory g) private view returns (bool) {
        (bool ok, uint256 impl) = _view(g.beacon, abi.encodeCall(IBeacon.implementation, ()));
        if (!ok || impl != uint256(uint160(g.impl0))) return true;
        if (g.impl0.codehash != g.impl0Hash) return true;

        // pin counts: `step` interprets the netlist through them
        {
            _needGas(G_VIEW);
            (bool ok2, uint256 size, bytes memory info) =
                SafeCall.staticRead(g.circuits, G_VIEW, abi.encodeCall(ICircuits.circuitInfo, (g.chipId)), 128);
            if (
                !ok2 || size != 128 || _word(info, 0) != N_IN || _word(info, 1) != N_OUT || _word(info, 2) != g.nState
                    || _word(info, 3) != g.gateCount
            ) return true;
        }
        // the netlist bytes themselves: abi.encode(bytes) = offset, length, data padded to a word
        {
            uint256 len = g.netlistLen;
            uint256 expect = 64 + ((len + 31) & ~uint256(31));
            _needGas(G_NETLIST);
            (bool ok3, uint256 size, bytes memory nl) =
                SafeCall.staticRead(g.circuits, G_NETLIST, abi.encodeCall(ICircuits.netlist, (g.chipId)), expect);
            if (!ok3 || size != expect || _word(nl, 0) != 32 || _word(nl, 1) != len) return true;
            bytes32 h;
            assembly ("memory-safe") {
                h := keccak256(add(nl, 0x60), len)
            }
            if (h != g.netlistHash) return true;
        }
        return false;
    }

    /// @dev One beat on one evaluator. It gets exactly its own fixed amount of gas for every caller (`stepFloor`
    ///      for TapeOut's, `sealedFloor` for the sealed one); at most 256 bytes of its answer are read. Any
    ///      failure (revert, out of gas, malformed or wrongly sized answer) is `ok = false`.
    function _step(Globals memory g, bool sealedMode, bytes32 st, bytes12 inp)
        private
        view
        returns (bool ok, bytes32 newState, bytes14 outputs)
    {
        bytes memory data = sealedMode
            ? abi.encodeCall(ISealedVM.step, (g.snapshot, N_IN, N_OUT, abi.encodePacked(st), abi.encodePacked(inp)))
            : abi.encodeCall(ICircuits.step, (g.chipId, abi.encodePacked(st), abi.encodePacked(inp)));
        (bool callOk, uint256 size, bytes memory ret) =
            sealedMode ? _stepCall(g.sealedVM, g.sealedFloor, data) : _stepCall(g.circuits, g.stepFloor, data);
        if (!callOk || size > 256 || size < 128) return (false, 0, 0);

        // abi.decode(ret, (bytes, bytes)) by hand: the decoder would revert on malformed data
        uint256 o1 = _word(ret, 0);
        uint256 o2 = _word(ret, 1);
        if (o1 > size - 32 || o2 > size - 32) return (false, 0, 0);
        uint256 l1;
        uint256 l2;
        assembly ("memory-safe") {
            l1 := mload(add(add(ret, 0x20), o1))
            l2 := mload(add(add(ret, 0x20), o2))
        }
        if (l1 != (uint256(g.nState) + 7) / 8 || l2 != KernelMath.OUT_BYTES) return (false, 0, 0);
        if (o1 + 32 + l1 > size || o2 + 32 + l2 > size) return (false, 0, 0);
        assembly ("memory-safe") {
            newState := mload(add(add(ret, 0x40), o1))
            outputs := mload(add(add(ret, 0x40), o2))
        }
        // keep exactly the returned bytes; anything past them in memory is not part of the answer
        if (l1 < 32) newState &= bytes32(~(type(uint256).max >> (8 * l1)));
        outputs = bytes14(outputs);
        ok = true;
    }

    /// @dev The evaluator call itself: `gasCap` gas, or the whole settle reverts before the call is made.
    function _stepCall(address target, uint256 gasCap, bytes memory data)
        private
        view
        returns (bool ok, uint256 size, bytes memory ret)
    {
        _needGas(gasCap);
        return SafeCall.staticRead(target, gasCap, data, 256);
    }

    // ------------------------------------------------------------------------------------------ settle: legs

    /// @dev Claims one asset from the vault. Returns true only if the vault held something and the claim failed.
    function _claim(address v, address asset, address tok) private returns (bool failed) {
        uint256 held;
        if (asset == NATIVE) {
            held = v.balance;
        } else {
            (bool okB, uint256 b) = _balanceOf(tok, v);
            held = okB ? b : 1; // unreadable: try the claim
        }
        if (held == 0) return false; // the vault reverts NothingToClaim on a zero balance
        _needGas(G_CLAIM);
        _payer = v; // the vault pays native OKB by calling receive() inside claim
        (bool ok,) = SafeCall.exec(v, G_CLAIM, 0, abi.encodeCall(IDirectedVault.claim, (asset)));
        _payer = address(0);
        return !ok;
    }

    /// @dev Curve regime: one IgnixManager.buyTo to this contract. Bought tokens cannot move before
    ///      graduation (the token reverts CurveOnly); after it they can only go to 0xdEaD (burnLocked).
    function _curveLeg(Globals memory g, uint256 capT, Work memory w, TradeMath.Curve memory c, uint256 decided)
        private
    {
        if (!w.curveOk) {
            w.flags |= RecordFlags.BUY_SKIPPED;
            return;
        }
        // anti-snipe window (the surcharge goes to the platform) or an open founder round (public buys
        // revert): never buy into either
        if (_buyGuarded(g.manager, w.tok)) {
            w.flags |= RecordFlags.BUY_SKIPPED;
            return;
        }
        // amount = min(decided, impact cap, largest buy that leaves the curve open); `out` is its exact quote
        (uint256 amt, uint256 out, bool shrunk) = TradeMath.curveBuy(c, decided, capT);
        if (shrunk) w.flags |= RecordFlags.BUY_SHRUNK;
        if (out == 0) {
            w.flags |= RecordFlags.BUY_SKIPPED; // the Manager would revert SoldOut
            return;
        }
        _execCurveBuy(g.manager, w, amt, out);
    }

    /// @dev True while `snipeBpsNow(token) > 0` or `founderRound(token).endsAt > now`. An unreadable Manager
    ///      is not a guard: the buy is then tried, and the exact minimum output protects it.
    function _buyGuarded(address manager, address tok) private view returns (bool) {
        (bool okS, uint256 snipe) = _view(manager, abi.encodeCall(IIgnixManager.snipeBpsNow, (tok)));
        if (okS && snipe != 0) return true;
        _needGas(G_VIEW);
        (bool okF, uint256 size, bytes memory fr) =
            SafeCall.staticRead(manager, G_VIEW, abi.encodeCall(IIgnixManager.founderRound, (tok)), 64);
        return okF && size >= 64 && block.timestamp < (_word(fr, 1) & type(uint64).max);
    }

    function _execCurveBuy(address manager, Work memory w, uint256 amt, uint256 out) private {
        uint256 native0 = address(this).balance;
        (bool okT0, uint256 tok0) = _balanceOf(w.tok, address(this));
        _needGas(G_BUY);
        // minTokensOut is the exact quote from the state read in this call: any other fee, surcharge or
        // formula makes the Manager revert Slippage and the amount stays in the reserve.
        _payer = manager; // a refund, if the Manager ever sends one, comes back by a native call
        (bool ok, bytes4 err) =
            SafeCall.exec(manager, G_BUY, amt, abi.encodeCall(IIgnixManager.buyTo, (w.tok, amt, out, address(this))));
        _payer = address(0);
        if (!ok) {
            // The Manager's reentrancy lock is held: this settle is running inside a call into the Manager.
            // No other caller would see this failure, so nothing is recorded and the epoch stays open.
            if (err == IIgnixManager.ReentrancyGuardReentrantCall.selector) revert LockHeld();
            // founder round or BUY pause: a guard, not a failure
            bool guard = err == IIgnixManager.FounderOnly.selector || err == IIgnixManager.Paused.selector;
            w.flags |= guard ? RecordFlags.BUY_SKIPPED : RecordFlags.BUY_FAILED;
            return;
        }
        w.executed = _sub0(native0, address(this).balance);
        if (w.executed < amt) w.flags |= RecordFlags.BUY_FAILED; // part came back: less moved than was decided
        (bool okT1, uint256 tok1) = _balanceOf(w.tok, address(this));
        uint256 got = okT0 && okT1 ? _sub0(tok1, tok0) : out;
        w.tokensOut = got;
        _locked = uint128(_sat128(uint256(_locked) + got));
    }

    /// @dev Graduated regime: the decided buy amount of project tokens goes to 0xdEaD (the token has no burn).
    function _burnLeg(Work memory w, uint256 decided) private {
        (uint256 sent, uint256 burned, bool ok) = _toDead(w.tok, decided, G_TRANSFER);
        if (!ok || sent < decided) w.flags |= RecordFlags.BUY_FAILED;
        w.executed = sent;
        w.tokensOut = burned;
        burnedTokens = uint128(_sat128(uint256(burnedTokens) + burned));
    }

    /// @dev Transfers `amount` project tokens to 0xdEaD and measures both sides.
    /// @return sent   what left this contract
    /// @return burned what arrived at 0xdEaD
    function _toDead(address tok, uint256 amount, uint256 gasCap)
        private
        returns (uint256 sent, uint256 burned, bool ok)
    {
        (bool okA0, uint256 a0) = _balanceOf(tok, address(this));
        (bool okD0, uint256 d0) = _balanceOf(tok, DEAD);
        _needGas(gasCap);
        (ok,) = SafeCall.exec(tok, gasCap, 0, abi.encodeCall(IIgnixToken.transfer, (DEAD, amount)));
        (bool okA1, uint256 a1) = _balanceOf(tok, address(this));
        (bool okD1, uint256 d1) = _balanceOf(tok, DEAD);
        sent = okA0 && okA1 ? _sub0(a0, a1) : (ok ? amount : 0);
        burned = okD0 && okD1 ? _sub0(d1, d0) : sent;
    }

    /// @dev Graduated regime: native OKB (residual tax and the OKB reserve left at graduation) buys the token
    ///      on the V2 pair with 0xdEaD as recipient, capped like the curve buy. No allowance is taken from it.
    ///      With buys disabled the same OKB is credited to `sink`.
    function _nativeLeg(Globals memory g, Envelope memory e, Work memory w, TradeMath.Curve memory c, uint32 n)
        private
    {
        uint256 pot = _sub0(address(this).balance, totalCredits[NATIVE]);
        if (pot == 0) return;
        if (!e.buyEnabled) {
            _addCredit(e.sink, NATIVE, pot);
            return;
        }
        (uint256 amt, uint256 minOut) = _sizeSwap(g.wokb, e.capT, w, c, _sat128(pot));
        if (amt == 0 || minOut == 0) {
            w.flags |= RecordFlags.BUY_SKIPPED;
            return;
        }

        uint256 native0 = address(this).balance;
        (bool okD0, uint256 d0) = _balanceOf(w.tok, DEAD);
        if (!_swap(g.v2Router, g.wokb, w.tok, amt, minOut)) {
            w.flags |= RecordFlags.BUY_FAILED;
            return;
        }
        (bool okD1, uint256 d1) = _balanceOf(w.tok, DEAD);
        uint256 burned = okD0 && okD1 ? _sub0(d1, d0) : minOut;
        w.tokensOut += burned;
        w.nativeIn = _sub0(native0, address(this).balance);
        if (w.nativeIn < amt) w.flags |= RecordFlags.BUY_FAILED; // part came back: less moved than was decided
        burnedTokens = uint128(_sat128(uint256(burnedTokens) + burned));
        emit NativeSwept(n, w.nativeIn, burned);
    }

    /// @dev The router buy itself: `amt` of native OKB for the project token, sent to 0xdEaD.
    /// @return ok false when the swap failed in a way every caller would see. When it failed while the pair's
    ///            reentrancy lock is held, this settle is running inside a call into the pair (a flash swap):
    ///            no other caller would see that failure, so the whole settle reverts instead. The router
    ///            passes on the pair's "UniswapV2: LOCKED" when it gets as far as the pair; when the flash
    ///            swap borrowed more WOKB than this buy brings, the router fails earlier, on its own
    ///            arithmetic ("ds-math-sub-underflow"), so the lock itself is asked as well.
    function _swap(address router, address wokb, address tok, uint256 amt, uint256 minOut) private returns (bool ok) {
        address[] memory path = new address[](2);
        path[0] = wokb;
        path[1] = tok;
        _needGas(G_SWAP);
        bytes memory err;
        (ok, err) = SafeCall.execCatch(
            router,
            G_SWAP,
            amt,
            abi.encodeCall(
                IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens,
                (minOut, path, DEAD, block.timestamp)
            ),
            SWAP_ERR_BYTES
        );
        if (!ok && (_lockedError(err) || _pairLockHeld())) revert LockHeld();
    }

    /// @dev True if the pair's reentrancy lock is held right now. `sync()` is asked by static call: with the
    ///      lock held it reverts "UniswapV2: LOCKED" before it does anything; without it, it fails at its
    ///      first storage write (a static call cannot write) and returns no data. Nothing changes either way.
    function _pairLockHeld() private view returns (bool) {
        _needGas(G_VIEW);
        (bool ok,, bytes memory ret) =
            SafeCall.staticRead(pair, G_VIEW, abi.encodeCall(IUniswapV2Pair.sync, ()), SWAP_ERR_BYTES);
        return !ok && _lockedError(ret);
    }

    /// @dev True if `err`, the start of a call's revert data, is Error("UniswapV2: LOCKED"): the pair's
    ///      reentrancy lock. The string is decoded (selector, offset, length, bytes); the 15 bytes that follow
    ///      its 17 in the last word are padding and are not compared.
    function _lockedError(bytes memory err) private pure returns (bool) {
        if (err.length < SWAP_ERR_BYTES) return false; // a whole Error(string): selector and three words
        uint256 head;
        uint256 offset;
        uint256 length;
        uint256 str;
        assembly ("memory-safe") {
            head := mload(add(err, 0x20))
            offset := mload(add(err, 0x24))
            length := mload(add(err, 0x44))
            str := mload(add(err, 0x64))
        }
        return head >> 224 == 0x08c379a0 && offset == 32 && length == 17
            && str >> 120 == uint136(bytes17("UniswapV2: LOCKED"));
    }

    /// @dev Size and minimum output of the post-graduation swap. Returns (0, 0) when the pair cannot be read.
    function _sizeSwap(address wokb, uint256 capT, Work memory w, TradeMath.Curve memory c, uint256 pot)
        private
        view
        returns (uint256 amt, uint256 minOut)
    {
        (uint256 rToken, uint256 rQuote) = _pairReserves(w.tok, wokb);
        if (rToken == 0 || rQuote == 0) return (0, 0);
        // An unreadable Manager means unknown tax: assume none for the cap (the smallest cap) and the maximum
        // for the minimum output.
        uint256 taxBuy = w.curveOk ? c.taxBuyBps : 0;
        uint256 taxSell = w.curveOk ? c.taxSellBps : 0;
        uint256 cap = TradeMath.impactCap(rQuote, V2_ROUND_TRIP_FEE_BPS, taxBuy, taxSell, capT);
        amt = pot;
        if (amt > cap) {
            amt = cap;
            w.flags |= RecordFlags.BUY_SHRUNK;
        }
        if (!w.curveOk) taxBuy = MAX_TAX_BPS;
        minOut = (TradeMath.v2NetOut(amt, rQuote, rToken, taxBuy) * SWAP_MIN_BPS) / TradeMath.BPS;
    }

    /// @dev Reserves of the graduated pair as (project token, WOKB); (0, 0) if they cannot be read.
    function _pairReserves(address tok, address wokb) private view returns (uint256 rToken, uint256 rQuote) {
        _needGas(G_VIEW);
        (bool ok, uint256 size, bytes memory rs) =
            SafeCall.staticRead(pair, G_VIEW, abi.encodeCall(IUniswapV2Pair.getReserves, ()), 64);
        if (!ok || size < 64) return (0, 0);
        rToken = _word(rs, 0) & type(uint112).max;
        rQuote = _word(rs, 1) & type(uint112).max;
        if (tok > wokb) (rToken, rQuote) = (rQuote, rToken); // token0 is the lower address
    }

    // ------------------------------------------------------------------------------------------ locked tokens

    /// @notice After graduation, sends the tokens this kernel bought on the curve to 0xdEaD. Anyone may call.
    /// @dev    Before graduation those tokens cannot move at all (the token reverts CurveOnly). This is their
    ///         only exit; it is not part of `settle`, so a failure here can never block a settlement.
    function burnLocked() external override nonReentrant onlyClone returns (uint256 burned) {
        if (!graduated) revert NotGraduated();
        uint256 amount = _locked;
        if (amount == 0) return 0;
        _locked = 0;
        (uint256 sent,, bool ok) = _toDead(token, amount, gasleft() - gasleft() / 8);
        if (!ok || sent != amount) revert PayFailed();
        burned = sent;
        burnedTokens = uint128(_sat128(uint256(burnedTokens) + sent));
        emit LockedBurned(sent);
    }

    // ------------------------------------------------------------------------------------------ credits

    function _addCredit(address payee, address asset, uint256 amount) private {
        _credit[payee][asset] += amount;
        totalCredits[asset] += amount;
        emit Credited(payee, asset, amount);
    }

    /// @notice Pays `payee` everything credited to it in `asset` (address(0) = native OKB). Anyone may call;
    ///         only `payee` is paid. Reverts if the payee refuses the payment, leaving the credit in place.
    function withdrawCredit(address payee, address asset)
        external
        override
        nonReentrant
        onlyClone
        returns (uint256 paid)
    {
        paid = _credit[payee][asset];
        if (paid == 0) return 0;
        _credit[payee][asset] = 0;
        totalCredits[asset] -= paid;
        if (asset == NATIVE) {
            // all remaining gas: a contract payee (the KeeperTank) needs more than a stipend
            (bool ok,) = SafeCall.exec(payee, gasleft(), paid, "");
            if (!ok) revert PayFailed();
        } else {
            // A credit in a token exists only for the bound project token, so `asset` is never caller-chosen.
            bytes memory data = abi.encodeCall(IIgnixToken.transfer, (payee, paid));
            bool ok;
            assembly ("memory-safe") {
                ok := call(gas(), asset, 0, add(data, 0x20), mload(data), 0x00, 0x20)
                // a token that returns nothing is accepted; one that returns false is not
                if and(ok, gt(returndatasize(), 0x1f)) { ok := eq(mload(0x00), 1) }
            }
            if (!ok) revert PayFailed();
        }
        emit CreditWithdrawn(payee, asset, paid);
    }

    function creditOf(address payee, address asset) external view override returns (uint256) {
        return _credit[payee][asset];
    }

    // ------------------------------------------------------------------------------------------ receiving

    /// @notice Native OKB is accepted only from the vault while this contract is inside its own claim, and from
    ///         the IgnixManager while it is inside its own buyTo. Every other transfer reverts: nobody can send
    ///         money into a kernel that buys, not through a plain transfer and not through IGNIX's refund or
    ///         claimFor paths. (A third party's claimFor of native OKB therefore reverts and the tax waits in
    ///         the vault for the next settle. Forced transfers and donations made to the vault itself cannot be
    ///         refused; they are inflow like any other.)
    /// @dev    There is deliberately no fallback function: the kernel must not answer token0(), token1() or
    ///         fee(), which the IGNIX token probes on contracts during its protection window.
    receive() external payable {
        if (msg.sender != _payer) revert NotAccepted();
    }

    /// @notice Accepts exactly one NFT by safe transfer: this kernel's chip, from the processor.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        (Globals memory g,) = _cfg();
        if (msg.sender != g.circuits || tokenId != g.chipId) revert NotAccepted();
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------------------------------ views

    function records(uint32 n) external view override returns (Record memory r) {
        Rec storage s = _rec[n];
        r.epoch = s.epoch;
        r.time = s.time;
        r.clampBits = s.clampBits;
        r.flags = s.flags;
        r.inputs = s.inputs;
        r.outputs = s.outputs;
        r.stateAfter = s.stateAfter;
        r.inflow = s.inflow;
        r.reserveBefore = s.reserveBefore;
        r.allow = s.allow;
        r.buyDecided = s.buyDecided;
        r.buyExecuted = s.buyExecuted;
        r.tokensOut = s.tokensOut;
        r.nativeIn = s.nativeIn;
    }

    /// @notice Regime totals after settle `n`: cumulative inflow and cumulative allowance credited. With the
    ///         record they are everything needed to recompute settle `n` (the totals restart at graduation).
    function cums(uint32 n) external view override returns (uint128 cumInflow_, uint128 allowPaidCum_) {
        Rec storage s = _rec[n];
        return (s.cumInflow, s.allowPaidCum);
    }

    function lockedTokens() external view override returns (uint256) {
        return _locked;
    }

    function epochNow() public view override returns (uint32) {
        if (token == address(0)) return 0;
        (, Envelope memory e) = _cfg();
        uint256 ep = (block.timestamp - bindTime) / e.epochLen;
        return ep > type(uint32).max ? type(uint32).max : uint32(ep);
    }

    /// @notice The evaluator the next settle would ask first, decided by the same checks. (If TapeOut's step
    ///         then fails, that settle asks the sealed evaluator as well.)
    function evaluator() external view override onlyClone returns (address vm, bool sealedMode) {
        (Globals memory g,) = _cfg();
        sealedMode = _sealedMode(g);
        vm = sealedMode ? g.sealedVM : g.circuits;
    }

    /// @notice Gas limit with which a settle never reverts for lack of gas, whether it is sent as a direct
    ///         transaction or made by a contract that has this much gas left when it calls (the KeeperTank).
    function minSettleGas() external view override onlyClone returns (uint256) {
        (Globals memory g,) = _cfg();
        uint256 m = _minSettleGas(g.stepFloor, g.sealedFloor) + 40_000; // what settle spends before its own first check
        m = m + m / 63 + 5_000; // the clone's call into the implementation keeps 1/64
        m = m + m / 63 + 5_000; // a calling contract keeps 1/64
        return m + 30_000; // transaction base cost and calldata when sent directly
    }

    /// @dev `virtual` only so that tests can switch this first check off and sweep the gas limit across
    ///      each per-call guard on its own. Nothing in production overrides it.
    ///      Both evaluators are budgeted: the costliest settle is one in which TapeOut's step uses up its
    ///      gas and fails, and the sealed evaluator then answers.
    function _minSettleGas(uint256 stepFloor, uint256 sealedFloor) internal pure virtual returns (uint256) {
        uint256 curveLeg = _withMargin(G_BUY);
        uint256 gradLegs = _withMargin(G_TRANSFER) + _withMargin(G_SWAP);
        return G_SELF + 2 * _withMargin(G_CLAIM) + N_VIEWS * _withMargin(G_VIEW) + _withMargin(G_NETLIST)
            + _withMargin(stepFloor) + _withMargin(sealedFloor) + (curveLeg > gradLegs ? curveLeg : gradLegs);
    }

    // ------------------------------------------------------------------------------------------ helpers

    /// @dev Gas needed in hand so that a call asking for `g` receives all of it under the 63/64 rule.
    function _withMargin(uint256 g) private pure returns (uint256) {
        return g + g / 63 + CALL_MARGIN;
    }

    /// @dev Reverts the whole call if the next external call could not be given its full allowance. This is
    ///      what makes a caught failure genuine: no caller can starve a callee into failing.
    function _needGas(uint256 g) private view {
        if (gasleft() < _withMargin(g)) revert InsufficientGas();
    }

    function _view(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        _needGas(G_VIEW);
        return SafeCall.staticWord(target, G_VIEW, data);
    }

    function _balanceOf(address tok, address who) private view returns (bool ok, uint256 bal) {
        return _view(tok, abi.encodeCall(IIgnixToken.balanceOf, (who)));
    }

    /// @dev Word `i` of `b`. Callers check the length first.
    function _word(bytes memory b, uint256 i) private pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := mload(add(add(b, 0x20), mul(i, 0x20)))
        }
    }

    function _sub0(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _sat128(uint256 x) private pure returns (uint256) {
        return x > type(uint128).max ? type(uint128).max : x;
    }
}
