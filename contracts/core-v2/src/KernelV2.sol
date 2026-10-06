// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Envelope, RecordFlags} from "core/interfaces/IKernelV1.sol";
import {ISealedVM, ICircuits, IBeacon} from "core/interfaces/IEvaluators.sol";
import {IIgnixManager, IDirectedVault, IIgnixToken, IUniswapV2Pair} from "core/interfaces/IIgnix.sol";
import {KernelMath} from "core/KernelMath.sol";
import {TradeMath} from "core/lib/TradeMath.sol";
import {SafeCall} from "core/lib/SafeCall.sol";

import {IKernelV2, GlobalsV2, RecordV2, IKernelFactoryV2Callback} from "./interfaces/IKernelV2.sol";
import {IQuoteToken, IUniswapV2RouterTT} from "./interfaces/IQuote.sol";
import {KernelMathV2} from "./KernelMathV2.sol";

/// @title Kernel v2
/// @notice The immutable RECIPIENT of one IGNIX Directed vault whose quote is an ERC-20 (USD₮0). It holds the
///         token's trading tax, and any USD₮0 anyone sends it (for example x402 revenue whose `payTo` is this
///         kernel), and at most once per epoch steps the token's vault chip. On the curve it routes that money by
///         the chip's output inside an immutable envelope; revenue is routed as tax there, since the kernel cannot
///         tell the two apart. After graduation the chip routes the token tax only: it does not see USD₮0 that
///         arrives then (revenue included), which a fixed rule spends on buying the token, sent to 0xdEaD.
///
///         Kernel v1 (contracts/core/src/Kernel.sol, chips/INTERFACE.md revision 2) with the quote asset
///         changed, and nothing else (chips/INTERFACE-V2.md lists every difference):
///           - books, curve buys, allowance credits and the post-graduation pot are in the quote asset;
///           - amounts are shown to the chip through a fixed code shift on the curve (KernelMathV2), so a chip
///             compiled for OKB amounts runs unchanged;
///           - a buy approves exactly its amount to the IgnixManager or the router and resets the allowance to
///             zero in the same settle;
///           - there is no native OKB path: no `receive`, no payable function. A plain OKB transfer reverts.
///             OKB forced in by SELFDESTRUCT stays here and is never routed or counted.
///
///         No owner, no upgrade path, no pause, no setter. One clone per token.
///
///         Value can leave this contract only
///           - to the IgnixManager inside `buyTo` (curve buy; the tokens come back and cannot move),
///           - to the Uniswap V2 router inside the post-graduation buy (the tokens go to 0xdEaD),
///           - as project tokens to 0xdEaD (post-graduation buy share, and `burnLocked`),
///           - to a credited payee through `withdrawCredit` (the allowance payee, or `sink` when buys are off).
///         The only approvals it ever gives are to the IgnixManager and the router, for exactly the amount of
///         one buy, cleared before `settle` returns. It makes no delegatecall and never calls a caller-chosen
///         target.
///
/// @dev    Rules the code keeps (kernel v1's, unchanged):
///           1. Nothing a chip outputs can make `settle` revert.
///           2. Nothing an external contract does can make `settle` revert, except both evaluators failing in
///              the grace period and a buy refused because the caller holds the callee's reentrancy lock.
///           3. The caller's gas limit cannot change an outcome (fixed gas per call; revert before a call that
///              the 63/64 rule would starve).
///           4. Inflow is what the contract holds beyond its books, never what a call reports.
///           5. Before graduation bought tokens cannot leave; after it they can only go to 0xdEaD.
///           6. A caught failure is one every caller would see (the lock rule of INTERFACE 8.6).
contract KernelV2 is IKernelV2, ReentrancyGuardTransient {
    // ------------------------------------------------------------------------------------------ constants

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint32 internal constant N_IN = 96;
    uint32 internal constant N_OUT = 112;

    // Gas handed to each kind of external call; each is more than three times the largest cost measured on an
    // X Layer fork at block 72,530,000, cold accounts and zero-to-non-zero writes included (NOTES.md section 4;
    // measured worst cases in brackets). test/fork/KernelV2Fork.t.sol measures each against these constants.
    uint256 internal constant G_VIEW = 100_000; // small views [USD₮0 balanceOf 14,747, allowance 10,585]
    uint256 internal constant G_NETLIST = 500_000; // Circuits.netlist(chipId) [kernel v1: 140,355]
    uint256 internal constant G_CLAIM = 350_000; // vault.claim [claim(USD₮0) 88,674; claim(token) 101,586]
    uint256 internal constant G_APPROVE = 200_000; // USD₮0 approve [53,929; approve(0) 36,792]
    uint256 internal constant G_BUY = 700_000; // IgnixManager.buyTo with an ERC-20 quote [195,364; 3.58x]
    uint256 internal constant G_TRANSFER = 200_000; // project token transfer to 0xdEaD [56,893]
    uint256 internal constant G_SWAP = 700_000; // Uniswap V2 router buy USD₮0 -> taxed token [181,968]

    uint256 internal constant CALL_MARGIN = 20_000;
    uint256 internal constant G_SELF = 600_000;
    /// Number of G_VIEW calls on the longest path (the first graduated settle whose swap succeeds: 17), plus one.
    uint256 internal constant N_VIEWS = 18;

    uint256 internal constant V2_ROUND_TRIP_FEE_BPS = 25;
    uint256 internal constant SWAP_MIN_BPS = 9_900;
    uint256 internal constant MAX_TAX_BPS = 1_000;
    uint256 internal constant SWAP_ERR_BYTES = 100;

    // ------------------------------------------------------------------------------------------ storage

    /// @dev Storage form of a RecordV2, 7 slots (kernel v1's layout; the last field is USD₮0).
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
        uint128 quoteIn;
    }

    // slot 0
    address public override token;
    uint40 public override bindTime;
    uint32 public override lastEpoch;
    bool public override graduated;
    // slot 1
    address public override vault;
    uint32 public override lastStepEpoch;
    uint32 public override count;
    // slot 2
    address public override pair;
    // slot 3
    bytes32 public override state;
    // slot 4: reserve of the regime asset (the quote asset on the curve, the project token after graduation)
    uint256 public override reserve;
    // slot 5: regime totals; both restart at graduation
    uint128 public override cumInflow;
    uint128 public override allowPaidCum;
    // slot 6
    uint128 internal _locked; // tokens bought on the curve, held here until burnLocked()
    uint128 public override burnedTokens;
    // slot 7
    uint256 public override tokenSupply;

    mapping(address payee => mapping(address asset => uint256 amount)) internal _credit;
    mapping(address asset => uint256 amount) public override totalCredits;
    mapping(uint256 n => Rec) internal _rec;

    address private immutable SELF = address(this);

    // ------------------------------------------------------------------------------------------ events, errors

    event Bound(address indexed token, address indexed vault, uint40 bindTime);
    event GraduationSeen(address indexed pair, uint256 quoteReserveReleased);
    event Credited(address indexed payee, address indexed asset, uint256 amount);
    event CreditWithdrawn(address indexed payee, address indexed asset, uint256 amount);
    /// Post-graduation quote leg: USD₮0 spent on the pair and tokens that reached 0xdEaD.
    event QuoteSwept(uint32 indexed n, uint256 quoteIn, uint256 tokensBurned);
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
    error LockHeld();

    modifier onlyClone() {
        if (address(this) == SELF) revert OnlyClone();
        _;
    }

    // ------------------------------------------------------------------------------------------ configuration

    function _cfg() internal view returns (GlobalsV2 memory g, Envelope memory e) {
        (g, e) = abi.decode(Clones.fetchCloneArgs(address(this)), (GlobalsV2, Envelope));
    }

    function envelope() external view override onlyClone returns (Envelope memory e) {
        (, e) = _cfg();
    }

    function globals() external view override onlyClone returns (GlobalsV2 memory g) {
        (g,) = _cfg();
    }

    function chipId() external view override onlyClone returns (uint256) {
        (GlobalsV2 memory g,) = _cfg();
        return g.chipId;
    }

    function quote() external view override onlyClone returns (address) {
        (GlobalsV2 memory g,) = _cfg();
        return g.quote;
    }

    function quoteShift() external view override onlyClone returns (uint256) {
        (GlobalsV2 memory g,) = _cfg();
        return g.quoteShift;
    }

    // ------------------------------------------------------------------------------------------ bind

    /// @notice Binds this kernel to `token_`, once. Anyone may call for a token the envelope's launcher created;
    ///         the launcher itself may also bind a token another wallet created.
    /// @dev    BindCheck codes: 1 no vault, 2 vault.RECIPIENT is not this kernel, 3 vault.TOKEN mismatch,
    ///         4 the vault's or the curve's quote is not this kernel's quote asset, 5 the curve cannot be read,
    ///         or neither the token's creator nor the caller is the launcher, 6 the token has no tax,
    ///         7 this kernel does not hold the chip NFT.
    function bind(address token_) external override nonReentrant onlyClone {
        if (token != address(0)) revert AlreadyBound();
        (GlobalsV2 memory g, Envelope memory e) = _cfg();

        address v = token_ == address(0) ? address(0) : IIgnixManager(g.manager).vaultOf(token_);
        if (v == address(0)) revert BindCheck(1);
        if (IDirectedVault(v).RECIPIENT() != address(this)) revert BindCheck(2);
        if (IDirectedVault(v).TOKEN() != token_) revert BindCheck(3);
        if (IDirectedVault(v).QUOTE() != g.quote) revert BindCheck(4);
        {
            (bool ok, uint256 size, bytes memory t) =
                SafeCall.staticRead(g.manager, gasleft(), abi.encodeCall(IIgnixManager.tokens, (token_)), 512);
            if (!ok || size < 512) revert BindCheck(5);
            if (address(uint160(_word(t, 5))) != g.quote) revert BindCheck(4); // the curve trades in this quote
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

        IKernelFactoryV2Callback(g.factory).noteBound(token_);
        emit Bound(token_, v, uint40(block.timestamp));
    }

    // ------------------------------------------------------------------------------------------ settle

    /// @dev Working values of one settle, kept in memory to stay inside the stack.
    struct Work {
        address tok;
        address asset; // regime asset
        address q; // the quote asset
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
        uint256 quoteIn;
    }

    /// @notice Runs one settlement. At most one per epoch; reverts when the epoch has not elapsed.
    function settle() external override nonReentrant onlyClone returns (uint32 n) {
        (GlobalsV2 memory g, Envelope memory e) = _cfg();
        Work memory w;
        w.tok = token;
        if (w.tok == address(0)) revert NotBound();
        w.epoch = (block.timestamp - bindTime) / e.epochLen;
        if (w.epoch > type(uint32).max) w.epoch = type(uint32).max;
        if (w.epoch <= lastEpoch) revert EpochNotElapsed();
        if (gasleft() < _minSettleGas(g.stepFloor, g.sealedFloor)) revert InsufficientGas();
        w.lastStep = lastStepEpoch;
        w.q = g.quote;

        // ---- 1. regime: the quote asset on the curve, the project token once the token reports its pair
        w.grad = graduated;
        if (!w.grad) {
            (bool ok, uint256 p) = _view(w.tok, abi.encodeCall(IIgnixToken.pair, ()));
            address pair_ = address(uint160(p));
            if (ok && pair_ != address(0)) {
                // The quote reserve is no longer tracked: with any later USD₮0 it is the quote pot.
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
        w.asset = w.grad ? w.tok : w.q;

        // ---- 2. claims: the quote asset always (residual tax after graduation), the token once graduated
        {
            address v = vault;
            if (_claim(v, w.q)) w.flags |= RecordFlags.CLAIM_FAILED;
            if (w.grad && _claim(v, w.tok)) w.flags |= RecordFlags.CLAIM_FAILED;
        }

        // ---- 3. inflow by balance (tax claimed now, tax pushed by anyone, revenue sent to this kernel)
        {
            uint256 free = _free(w.asset, w.grad);
            w.reserve0 = reserve;
            if (w.reserve0 > free) w.reserve0 = free;
            w.inflow = free - w.reserve0;
            w.cum = _sat128(uint256(cumInflow) + w.inflow);
        }

        // ---- 4. curve read and 5. the input word (shifted codes on the curve)
        TradeMath.Curve memory c;
        (w.curveOk, c) = _readCurve(g.manager, w.tok);
        if (!w.curveOk) w.flags |= RecordFlags.CURVE_READ_FAILED;
        uint256 s = w.grad ? 0 : g.quoteShift;
        w.inputs = _inputs(w, c, s);

        // ---- 6. evaluator (kernel v1, unchanged)
        {
            bool askSealed = _sealedMode(g);
            if (!askSealed) {
                (w.stepOk, w.newState, w.outputs) = _step(g, false, state, w.inputs);
                askSealed = !w.stepOk;
            }
            if (askSealed) {
                (w.stepOk, w.newState, w.outputs) = _step(g, true, state, w.inputs);
                if (w.stepOk) w.flags |= RecordFlags.SEALED;
            }
        }
        uint256 outWord;
        if (w.stepOk) {
            outWord = KernelMath.outputWord(w.outputs);
        } else {
            if (w.epoch - w.lastStep < e.fallbackEpochs) revert StepFailed();
            outWord = KernelMath.fallbackWord(e.fbAllow, e.relMax);
            w.outputs = KernelMath.outputBytes(outWord);
            w.newState = state;
            w.flags |= RecordFlags.FALLBACK;
        }

        // ---- 7. clip to the envelope
        KernelMath.Routed memory r =
            KernelMathV2.route(_routeEnv(e), outWord, w.inflow, w.reserve0, w.cum, allowPaidCum, w.grad, s);

        // ---- 8. effects, before any leg
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
        if (w.grad) _quoteLeg(g, e, w, c, n);

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
            quoteIn: uint128(_sat128(w.quoteIn))
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

    /// @dev Balance of the regime asset beyond what is owed or locked, capped at 128 bits. An unreadable balance
    ///      is "exactly what the books say": nothing new, nothing lost.
    function _free(address asset, bool grad) private view returns (uint256 free) {
        uint256 owed = totalCredits[asset];
        if (grad) owed += _locked; // tokens bought on the curve are never fresh inflow
        (bool ok, uint256 b) = _balanceOf(asset, address(this));
        uint256 bal = ok ? b : owed + reserve;
        free = _sat128(_sub0(bal, owed));
    }

    /// @dev Reads the curve words of IgnixManager.tokens(token) (kernel v1, unchanged).
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

    /// @dev The input word. TAX, TAXCUM and RES are lg8(amount << s): s is the quote shift on the curve and 0
    ///      after graduation. Everything else is kernel v1's.
    function _inputs(Work memory w, TradeMath.Curve memory c, uint256 s) private view returns (bytes12) {
        KernelMath.InputFields memory f;
        f.tax = KernelMathV2.lg8s(w.inflow, s);
        f.taxCum = KernelMathV2.lg8s(w.cum, s);
        f.res = KernelMathV2.lg8s(w.reserve0, s);
        // rev, revCum and esc stay 0: revenue paid to the kernel is part of TAX (chips/INTERFACE-V2.md)
        f.prog = KernelMath.progCode(w.curveOk ? c.sold : 0, w.curveOk ? c.sellable : 0, w.grad);
        f.lock = KernelMath.lockCode(uint256(_locked) + burnedTokens, tokenSupply);
        f.dt = KernelMath.dtCode(w.epoch, w.lastStep);
        f.grad = w.grad ? 1 : 0;
        return KernelMath.inputBytes(KernelMath.packInput(f));
    }

    // ------------------------------------------------------------------------------------------ settle: evaluator

    /// @dev Kernel v1's four pin comparisons, unchanged.
    function _sealedMode(GlobalsV2 memory g) private view returns (bool) {
        (bool ok, uint256 impl) = _view(g.beacon, abi.encodeCall(IBeacon.implementation, ()));
        if (!ok || impl != uint256(uint160(g.impl0))) return true;
        if (g.impl0.codehash != g.impl0Hash) return true;
        {
            _needGas(G_VIEW);
            (bool ok2, uint256 size, bytes memory info) =
                SafeCall.staticRead(g.circuits, G_VIEW, abi.encodeCall(ICircuits.circuitInfo, (g.chipId)), 128);
            if (
                !ok2 || size != 128 || _word(info, 0) != N_IN || _word(info, 1) != N_OUT || _word(info, 2) != g.nState
                    || _word(info, 3) != g.gateCount
            ) return true;
        }
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

    /// @dev One beat on one evaluator (kernel v1, unchanged).
    function _step(GlobalsV2 memory g, bool sealedMode, bytes32 st, bytes12 inp)
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
        if (l1 < 32) newState &= bytes32(~(type(uint256).max >> (8 * l1)));
        outputs = bytes14(outputs);
        ok = true;
    }

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
    ///      Both assets are ERC-20s here: the vault pays by plain transfer, with no callback into this contract.
    function _claim(address v, address asset) private returns (bool failed) {
        (bool okB, uint256 held) = _balanceOf(asset, v);
        if (!okB) held = 1; // unreadable: try the claim
        if (held == 0) return false; // the vault reverts NothingToClaim on a zero balance
        _needGas(G_CLAIM);
        (bool ok,) = SafeCall.exec(v, G_CLAIM, 0, abi.encodeCall(IDirectedVault.claim, (asset)));
        return !ok;
    }

    /// @dev Curve regime: one IgnixManager.buyTo to this contract, paid by an exact allowance.
    function _curveLeg(GlobalsV2 memory g, uint256 capT, Work memory w, TradeMath.Curve memory c, uint256 decided)
        private
    {
        if (!w.curveOk) {
            w.flags |= RecordFlags.BUY_SKIPPED;
            return;
        }
        if (_buyGuarded(g.manager, w.tok)) {
            w.flags |= RecordFlags.BUY_SKIPPED;
            return;
        }
        (uint256 amt, uint256 out, bool shrunk) = TradeMath.curveBuy(c, decided, capT);
        if (shrunk) w.flags |= RecordFlags.BUY_SHRUNK;
        if (out == 0) {
            w.flags |= RecordFlags.BUY_SKIPPED;
            return;
        }
        _execCurveBuy(g.manager, w, amt, out);
    }

    /// @dev True while `snipeBpsNow(token) > 0` or `founderRound(token).endsAt > now` (kernel v1, unchanged).
    function _buyGuarded(address manager, address tok) private view returns (bool) {
        (bool okS, uint256 snipe) = _view(manager, abi.encodeCall(IIgnixManager.snipeBpsNow, (tok)));
        if (okS && snipe != 0) return true;
        _needGas(G_VIEW);
        (bool okF, uint256 size, bytes memory fr) =
            SafeCall.staticRead(manager, G_VIEW, abi.encodeCall(IIgnixManager.founderRound, (tok)), 64);
        return okF && size >= 64 && block.timestamp < (_word(fr, 1) & type(uint64).max);
    }

    /// @dev approve(manager, amt), buyTo(token, amt, exactQuote, this), allowance back to zero. What moved is
    ///      measured on both sides by balance: the quote that left this contract and the tokens that arrived.
    function _execCurveBuy(address manager, Work memory w, uint256 amt, uint256 out) private {
        (bool okQ0, uint256 q0) = _balanceOf(w.q, address(this));
        (bool okT0, uint256 tok0) = _balanceOf(w.tok, address(this));
        bool ok;
        bytes4 err;
        if (_approve(w.q, manager, amt)) {
            _needGas(G_BUY);
            (ok, err) = SafeCall.exec(
                manager, G_BUY, 0, abi.encodeCall(IIgnixManager.buyTo, (w.tok, amt, out, address(this)))
            );
        }
        _clearApproval(w.q, manager);
        if (!ok) {
            // The Manager's reentrancy lock is held: this settle runs inside a call into the Manager. No other
            // caller would see this failure, so nothing is recorded and the epoch stays open (INTERFACE 8.6).
            if (err == IIgnixManager.ReentrancyGuardReentrantCall.selector) revert LockHeld();
            bool guard = err == IIgnixManager.FounderOnly.selector || err == IIgnixManager.Paused.selector;
            w.flags |= guard ? RecordFlags.BUY_SKIPPED : RecordFlags.BUY_FAILED;
            return;
        }
        (bool okQ1, uint256 q1) = _balanceOf(w.q, address(this));
        w.executed = okQ0 && okQ1 ? _sub0(q0, q1) : amt;
        if (w.executed < amt) w.flags |= RecordFlags.BUY_FAILED; // part came back: less moved than decided
        (bool okT1, uint256 tok1) = _balanceOf(w.tok, address(this));
        uint256 got = okT0 && okT1 ? _sub0(tok1, tok0) : out;
        w.tokensOut = got;
        _locked = uint128(_sat128(uint256(_locked) + got));
    }

    /// @dev Graduated regime: the decided buy amount of project tokens goes to 0xdEaD (kernel v1, unchanged).
    function _burnLeg(Work memory w, uint256 decided) private {
        (uint256 sent, uint256 burned, bool ok) = _toDead(w.tok, decided, G_TRANSFER);
        if (!ok || sent < decided) w.flags |= RecordFlags.BUY_FAILED;
        w.executed = sent;
        w.tokensOut = burned;
        burnedTokens = uint128(_sat128(uint256(burnedTokens) + burned));
    }

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

    /// @dev Graduated regime: the quote pot (residual USD₮0 tax, the USD₮0 reserve left at graduation, and any
    ///      USD₮0 that arrives later) buys the token on its V2 pair with 0xdEaD as recipient, capped like the
    ///      curve buy. No allowance is taken from it. With buys disabled the same USD₮0 is credited to `sink`.
    function _quoteLeg(GlobalsV2 memory g, Envelope memory e, Work memory w, TradeMath.Curve memory c, uint32 n)
        private
    {
        (bool okQ0, uint256 q0) = _balanceOf(w.q, address(this));
        if (!okQ0) return; // unreadable: nothing is known to be there
        uint256 pot = _sub0(q0, totalCredits[w.q]);
        if (pot == 0) return;
        if (!e.buyEnabled) {
            _addCredit(e.sink, w.q, pot);
            return;
        }
        (uint256 amt, uint256 minOut) = _sizeSwap(w.q, e.capT, w, c, _sat128(pot));
        if (amt == 0 || minOut == 0) {
            w.flags |= RecordFlags.BUY_SKIPPED;
            return;
        }

        (bool ok, uint256 burned) = _execSwap(g.v2Router, w, q0, amt, minOut);
        if (!ok) {
            w.flags |= RecordFlags.BUY_FAILED;
            return;
        }
        w.tokensOut += burned;
        if (w.quoteIn < amt) w.flags |= RecordFlags.BUY_FAILED; // less moved than was decided
        burnedTokens = uint128(_sat128(uint256(burnedTokens) + burned));
        emit QuoteSwept(n, w.quoteIn, burned);
    }

    /// @dev approve(router, amt), the router buy, allowance back to zero; then what reached 0xdEaD and what left
    ///      this contract, both by balance. `q0` is this contract's quote balance before the swap.
    function _execSwap(address router, Work memory w, uint256 q0, uint256 amt, uint256 minOut)
        private
        returns (bool ok, uint256 burned)
    {
        (bool okD0, uint256 d0) = _balanceOf(w.tok, DEAD);
        ok = _approve(w.q, router, amt) && _swap(router, w.q, w.tok, amt, minOut);
        _clearApproval(w.q, router);
        if (!ok) return (false, 0);
        (bool okD1, uint256 d1) = _balanceOf(w.tok, DEAD);
        burned = okD0 && okD1 ? _sub0(d1, d0) : minOut;
        (bool okQ1, uint256 q1) = _balanceOf(w.q, address(this));
        w.quoteIn = okQ1 ? _sub0(q0, q1) : amt;
    }

    /// @dev The router buy itself: `amt` of the quote asset for the project token, sent to 0xdEaD. A failure
    ///      under the pair's reentrancy lock reverts the whole settle (kernel v1's rule, unchanged).
    function _swap(address router, address q, address tok, uint256 amt, uint256 minOut) private returns (bool ok) {
        address[] memory path = new address[](2);
        path[0] = q;
        path[1] = tok;
        _needGas(G_SWAP);
        bytes memory err;
        (ok, err) = SafeCall.execCatch(
            router,
            G_SWAP,
            0,
            abi.encodeCall(
                IUniswapV2RouterTT.swapExactTokensForTokensSupportingFeeOnTransferTokens,
                (amt, minOut, path, DEAD, block.timestamp)
            ),
            SWAP_ERR_BYTES
        );
        if (!ok && (_lockedError(err) || _pairLockHeld())) revert LockHeld();
    }

    /// @dev True if the pair's reentrancy lock is held right now (kernel v1, unchanged).
    function _pairLockHeld() private view returns (bool) {
        _needGas(G_VIEW);
        (bool ok,, bytes memory ret) =
            SafeCall.staticRead(pair, G_VIEW, abi.encodeCall(IUniswapV2Pair.sync, ()), SWAP_ERR_BYTES);
        return !ok && _lockedError(ret);
    }

    /// @dev True if `err` is Error("UniswapV2: LOCKED") (kernel v1, unchanged).
    function _lockedError(bytes memory err) private pure returns (bool) {
        if (err.length < SWAP_ERR_BYTES) return false;
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

    /// @dev Size and minimum output of the post-graduation swap: the impact cap with Q = the pair's quote
    ///      reserve and F = 25 bps, and 99% of the exact quote (kernel v1's rule, the quote asset for WOKB).
    function _sizeSwap(address q, uint256 capT, Work memory w, TradeMath.Curve memory c, uint256 pot)
        private
        view
        returns (uint256 amt, uint256 minOut)
    {
        (uint256 rToken, uint256 rQuote) = _pairReserves(w.tok, q);
        if (rToken == 0 || rQuote == 0) return (0, 0);
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

    /// @dev Reserves of the graduated pair as (project token, quote asset); (0, 0) if they cannot be read.
    function _pairReserves(address tok, address q) private view returns (uint256 rToken, uint256 rQuote) {
        _needGas(G_VIEW);
        (bool ok, uint256 size, bytes memory rs) =
            SafeCall.staticRead(pair, G_VIEW, abi.encodeCall(IUniswapV2Pair.getReserves, ()), 64);
        if (!ok || size < 64) return (0, 0);
        rToken = _word(rs, 0) & type(uint112).max;
        rQuote = _word(rs, 1) & type(uint112).max;
        if (tok > q) (rToken, rQuote) = (rQuote, rToken); // token0 is the lower address
    }

    /// @dev approve(spender, amount) on the quote asset, gas-capped. Its return value is not trusted: whether
    ///      the allowance was usable shows in the balances the caller measures afterwards.
    function _approve(address q, address spender, uint256 amount) private returns (bool ok) {
        _needGas(G_APPROVE);
        (ok,) = SafeCall.exec(q, G_APPROVE, 0, abi.encodeCall(IQuoteToken.approve, (spender, amount)));
    }

    /// @dev Leaves no allowance behind: reads it, and approves zero unless it reads zero. Made after every
    ///      approve, whether the buy went through or not.
    function _clearApproval(address q, address spender) private {
        (bool ok, uint256 left) = _view(q, abi.encodeCall(IQuoteToken.allowance, (address(this), spender)));
        if (ok && left == 0) return;
        _approve(q, spender, 0);
    }

    // ------------------------------------------------------------------------------------------ locked tokens

    /// @notice After graduation, sends the tokens this kernel bought on the curve to 0xdEaD. Anyone may call.
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

    /// @notice Pays `payee` everything credited to it in `asset` (the quote asset, or the project token for a
    ///         sink). Anyone may call; only `payee` is paid. Reverts, leaving the credit in place, unless the
    ///         transfer succeeded and this contract's balance fell by exactly the credit.
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
        // A credit exists only in this kernel's quote asset or its bound token, so `asset` is never caller-chosen.
        (bool ok0, uint256 b0) = _balanceOf(asset, address(this));
        bytes memory data = abi.encodeCall(IIgnixToken.transfer, (payee, paid));
        uint256 gasCap = gasleft();
        gasCap -= gasCap / 8; // keeps enough for the balance read below
        bool ok;
        assembly ("memory-safe") {
            ok := call(gasCap, asset, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            // a token that returns nothing is accepted; one that returns false is not
            if and(ok, gt(returndatasize(), 0x1f)) { ok := eq(mload(0x00), 1) }
        }
        (bool ok1, uint256 b1) = _balanceOf(asset, address(this));
        if (!ok || !ok0 || !ok1 || b0 < b1 || b0 - b1 != paid) revert PayFailed();
        emit CreditWithdrawn(payee, asset, paid);
    }

    function creditOf(address payee, address asset) external view override returns (uint256) {
        return _credit[payee][asset];
    }

    // ------------------------------------------------------------------------------------------ receiving

    /// @notice Accepts exactly one NFT by safe transfer: this kernel's chip, from the processor.
    /// @dev    There is no `receive` and no fallback: a plain OKB transfer reverts, and the kernel does not
    ///         answer token0(), token1() or fee(), which the IGNIX token probes during its protection window.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        (GlobalsV2 memory g,) = _cfg();
        if (msg.sender != g.circuits || tokenId != g.chipId) revert NotAccepted();
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------------------------------ views

    function records(uint32 n) external view override returns (RecordV2 memory r) {
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
        r.quoteIn = s.quoteIn;
    }

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

    function evaluator() external view override onlyClone returns (address vm, bool sealedMode) {
        (GlobalsV2 memory g,) = _cfg();
        sealedMode = _sealedMode(g);
        vm = sealedMode ? g.sealedVM : g.circuits;
    }

    /// @notice Gas limit with which a settle never reverts for lack of gas, sent directly or by a contract
    ///         that has this much gas left when it calls (the KeeperTank).
    function minSettleGas() external view override onlyClone returns (uint256) {
        (GlobalsV2 memory g,) = _cfg();
        uint256 m = _minSettleGas(g.stepFloor, g.sealedFloor) + 40_000;
        m = m + m / 63 + 5_000;
        m = m + m / 63 + 5_000;
        return m + 30_000;
    }

    /// @dev `virtual` only so that tests can switch this first check off and sweep each per-call guard.
    function _minSettleGas(uint256 stepFloor, uint256 sealedFloor) internal pure virtual returns (uint256) {
        uint256 approvals = 2 * _withMargin(G_APPROVE); // the approve and the reset of one buy
        uint256 curveLeg = _withMargin(G_BUY) + approvals;
        uint256 gradLegs = _withMargin(G_TRANSFER) + _withMargin(G_SWAP) + approvals;
        return G_SELF + 2 * _withMargin(G_CLAIM) + N_VIEWS * _withMargin(G_VIEW) + _withMargin(G_NETLIST)
            + _withMargin(stepFloor) + _withMargin(sealedFloor) + (curveLeg > gradLegs ? curveLeg : gradLegs);
    }

    // ------------------------------------------------------------------------------------------ helpers

    function _withMargin(uint256 g) private pure returns (uint256) {
        return g + g / 63 + CALL_MARGIN;
    }

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
