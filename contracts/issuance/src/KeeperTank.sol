// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IKernelMin} from "./interfaces/IKernelMin.sol";
import {ICircuits, ITransistors} from "./interfaces/ITapeOut.sol";
import {NetlistScan} from "./lib/NetlistScan.sol";
import {Native} from "./lib/Native.sol";

/// @title KeeperTank - prepaid settlement gas for Covenant vault chips, keyed by chip id.
///
/// @notice 85% of every transistor's mint price ends up here. A chip's allowance is
///
///             (transistors it burned at tape-out) * mintPrice * 85%  +  whatever was topped up for it
///
///         Anyone may call `settleAndRefund(kernel)`: the tank calls `kernel.settle()` and pays the caller
///         back for the gas, out of that chip's allowance. Nothing else can take money out.
///         There is no owner, no upgrade path and no pause.
///
/// @dev    What bounds a refund:
///
///           paid = min( gasCounted * price,  the chip's remaining allowance,  the tank's balance )
///           price = min( tx.gasprice, block.basefee + MAX_TIP )
///
///         `gasCounted` is the gas measured between the first line of `settleAndRefund` and the end of the
///         kernel call, plus a constant that is a LOWER bound on everything that is not measured (see
///         OVERHEAD). Whenever a refund is paid it therefore never exceeds the gas the transaction consumes,
///         and `price` never exceeds the price the caller pays per unit of gas.
///
///         That does NOT bound a refund by what the caller is charged. Gas the EVM gives back at the end
///         of a transaction for storage cleared inside `settle()` (EIP-3529) cannot be observed from inside
///         a contract: it is counted here but not billed to the caller. A storage reentrancy guard gives
///         back about 2,800 gas each time it is passed (an IGNIX claim or buy passes one); a kernel that
///         clears storage on purpose can get back up to one fifth of the transaction's gas. A caller can
///         therefore be refunded more than its transaction cost. The bound that always holds is the chip's
///         own allowance: it was prepaid by that chip's mint payments and top-ups, and a refund never
///         touches another chip's.
contract KeeperTank is ReentrancyGuardTransient {
    // ------------------------------------------------------------------ constants

    uint256 private constant BPS = 10_000;

    /// @notice Share of a burned transistor's mint price that becomes its chip's gas allowance.
    ///         Equal to the Splitter's TANK_BPS, so allowances from burns are always backed once proceeds
    ///         have been pulled.
    uint256 public constant ALLOWANCE_BPS = 8500;

    /// @notice Largest priority fee per gas the tank refunds on top of the block's base fee.
    /// @dev    A tip that is refunded costs the caller nothing, so this is also how much faster than at the
    ///         base fee alone a caller can use up a chip's allowance: 5% at X Layer's 0.02 gwei base fee.
    uint256 public constant MAX_TIP = 0.001 gwei;

    /// @notice Gas added to the measured gas for the first `settleAndRefund` of a transaction.
    ///
    /// @dev    It must never exceed the gas the measurement misses, in any transaction that is paid a refund.
    ///         What the measurement misses, each term at its minimum (Cancun/Prague gas schedule):
    ///
    ///           21,000  transaction base cost (paid once per transaction)
    ///            2,900  SSTORE of `spent[chipId]`: slot read inside the measured window, so warm; first
    ///                   change in this transaction (it is 20,000 the very first time for a chip)
    ///            6,800  CALL carrying value to a warm address: 9,000 + 100, less the 2,300 stipend that a
    ///                   callee which runs no code hands back
    ///            2,387  LOG4 with 64 bytes of data: 375 + 4 * 375 + 8 * 64
    ///              300  reentrancy guard: TLOAD and TSTORE on entry, TSTORE on exit
    ///            1,215  dispatch, ABI decoding, arithmetic and event memory outside the window
    ///           ------
    ///           34,602  measured on this bytecode and pinned by test/unit/TankOverhead.t.sol
    ///
    ///         Calldata is deliberately not counted: a direct call carries 192 to 580 gas of it, but a call
    ///         made through another contract carries none of its own and the tank cannot tell which.
    ///         So a caller is left about 1,000 gas short per settlement when `settle()` clears no storage.
    ///         When it does, the EVM gives the caller gas back that is counted here all the same, and the
    ///         caller can end up ahead (see the note on EIP-3529 at the top of this contract).
    uint256 public constant OVERHEAD = 34_000;

    /// @notice Gas added to the measured gas for every further `settleAndRefund` in the same transaction.
    ///
    /// @dev    A contract that settles several kernels in one transaction pays the 21,000 base cost once, and
    ///         a second write to the same `spent` slot costs 100, not 2,900. A repeat call therefore only
    ///         gets what is paid again every time:
    ///
    ///              100  SSTORE of an already dirty `spent` slot
    ///            6,800  CALL carrying value to a warm address
    ///            2,387  LOG4
    ///              300  reentrancy guard
    ///            1,215  dispatch, decoding, arithmetic, event memory
    ///           ------
    ///           10,802  measured
    uint256 public constant OVERHEAD_REPEAT = 10_500;

    /// @notice Gas a CONTRACT must forward when it sends OKB to the tank with a plain call.
    ///
    /// @dev    The tank probes such a sender for `chipId()` (capped at CHIP_ID_GAS) and then the processor for
    ///         `ownerOf` (capped at OWNER_OF_GAS). With too little gas a probe can fail for lack of it; if it
    ///         fails cheaply, handing the unused gas back, the transfer would be accepted without being
    ///         credited to the kernel's chip. The tank reverts instead of guessing. 200,000 leaves both probes
    ///         their full cap and 47,000 for the storage write and the event.
    ///         Does not apply to the Splitter, to addresses without code, or to `topUp`.
    uint256 public constant RECEIVE_MIN_GAS = 200_000;

    uint256 private constant CHIP_ID_GAS = 50_000;
    uint256 private constant OWNER_OF_GAS = 100_000;

    // ------------------------------------------------------------------ wiring

    /// @notice The Splitter that deployed this tank. Its payments are never probed and never revert.
    address public immutable SPLITTER;

    /// @notice The Covenant processor's Circuits contract (ERC-721). Set once by `init`.
    address public circuits;

    /// @notice The Covenant processor's Transistors contract (ERC-1155). Set once by `init`.
    address public transistors;

    /// @notice Price of one transistor in wei, read from the Transistors contract by `init`.
    uint256 public mintPrice;

    // ------------------------------------------------------------------ accounting

    /// @notice OKB added to a chip's allowance on top of what its burned transistors paid for.
    mapping(uint256 chipId => uint256 amount) public toppedUp;

    /// @notice OKB refunded so far against a chip's allowance.
    mapping(uint256 chipId => uint256 amount) public spent;

    /// @dev burned + 1, so that zero means "not scanned yet".
    mapping(uint256 chipId => uint256 burnedPlusOne) private _burnedCache;

    /// @dev True once a `settleAndRefund` in the current transaction has been granted OVERHEAD.
    bool private transient _baseCostGranted;

    // ------------------------------------------------------------------ events and errors

    event Initialised(address indexed circuits, address indexed transistors, uint256 mintPrice);
    /// @param gasUsed gas counted for the refund: measured gas plus the overhead constant. The constant assumes
    ///                a refund is paid; when `paid` is zero it overstates the gas by up to about 9,700.
    /// @param paid    wei sent to `caller`
    event Refunded(
        uint256 indexed chipId, address indexed kernel, address indexed caller, uint256 gasUsed, uint256 paid
    );
    event ToppedUp(uint256 indexed chipId, address indexed from, uint256 amount);
    /// @notice OKB that backs the pool without being attributed to a chip (this is how the Splitter pays in).
    event Funded(address indexed from, uint256 amount);

    error NotSplitter();
    error AlreadyInitialised();
    error ZeroAddress();
    error KernelDoesNotHoldChip();
    error RefundFailed();
    error InsufficientGasForAttribution();

    // ------------------------------------------------------------------ setup

    constructor() {
        SPLITTER = msg.sender;
    }

    /// @notice Wires the tank to the processor. Callable once, only by the Splitter that deployed the tank
    ///         (which does so in its own constructor, in the transaction that creates the processor).
    function init(address circuits_, address transistors_) external {
        if (msg.sender != SPLITTER) revert NotSplitter();
        if (circuits != address(0)) revert AlreadyInitialised();
        if (circuits_ == address(0) || transistors_ == address(0)) revert ZeroAddress();

        circuits = circuits_;
        transistors = transistors_;
        uint256 price = ITransistors(transistors_).mintPrice();
        mintPrice = price;

        emit Initialised(circuits_, transistors_, price);
    }

    // ------------------------------------------------------------------ views

    /// @notice Transistors burned when `chipId` was taped out: its top-level NAND and LATCH records.
    ///         REF records count zero. Reverts if the chip does not exist.
    /// @dev    The first `settleAndRefund` for a chip stores the result; later calls read the stored value.
    function burnedOf(uint256 chipId) public view returns (uint256) {
        uint256 cached = _burnedCache[chipId];
        if (cached != 0) return cached - 1;
        return _scan(chipId);
    }

    /// @notice Total OKB ever available for refunds on `chipId`.
    function allowanceOf(uint256 chipId) public view returns (uint256) {
        return _allowance(burnedOf(chipId), chipId);
    }

    /// @notice OKB still available for refunds on `chipId`.
    function remainingOf(uint256 chipId) external view returns (uint256) {
        return _saturatingSub(allowanceOf(chipId), spent[chipId]);
    }

    // ------------------------------------------------------------------ settle and refund

    /// @notice Calls `kernel.settle()` and refunds the caller's gas from the allowance of the chip the
    ///         kernel holds. If `settle()` reverts, this reverts with the same data. When the allowance or
    ///         the tank is empty the settlement still happens and the refund is smaller or zero.
    function settleAndRefund(address kernel) external nonReentrant {
        uint256 g0 = gasleft();

        uint256 chipId = IKernelMin(kernel).chipId();
        if (ICircuits(circuits).ownerOf(chipId) != kernel) revert KernelDoesNotHoldChip();
        uint256 burned = _burnedCached(chipId);

        _settle(kernel);

        // Everything below reads state after the kernel call: a kernel may top up or pull during settle().
        uint256 alreadySpent = spent[chipId];
        uint256 remaining = _saturatingSub(_allowance(burned, chipId), alreadySpent);
        uint256 price = _refundPrice();
        uint256 overhead = _overhead();
        uint256 used = g0 - gasleft() + overhead;

        uint256 pay = used * price;
        if (pay > remaining) pay = remaining;
        if (pay > address(this).balance) pay = address(this).balance;

        if (pay != 0) spent[chipId] = alreadySpent + pay;
        // Reports the gas of the kernel call, so it can only come after it. settleAndRefund is nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Refunded(chipId, kernel, msg.sender, used, pay);
        if (pay != 0 && !Native.send(msg.sender, pay, gasleft())) revert RefundFailed();
    }

    // ------------------------------------------------------------------ paying in

    /// @notice Adds `msg.value` to the allowance of `chipId`. Anyone may call. Not refundable.
    function topUp(uint256 chipId) external payable {
        toppedUp[chipId] += msg.value;
        emit ToppedUp(chipId, msg.sender, msg.value);
    }

    /// @notice Plain OKB transfers.
    ///         From a contract that answers `chipId()` and holds that chip (a kernel): credited to that chip.
    ///         From anything else, including the Splitter: unattributed backing for the whole pool.
    receive() external payable {
        if (msg.sender != SPLITTER && msg.sender.code.length != 0) {
            if (gasleft() < RECEIVE_MIN_GAS) revert InsufficientGasForAttribution();

            (bool answered, uint256 chipId) =
                _staticWord(msg.sender, abi.encodeCall(IKernelMin.chipId, ()), CHIP_ID_GAS);
            if (answered) {
                (bool exists, uint256 holder) =
                    _staticWord(circuits, abi.encodeCall(ICircuits.ownerOf, (chipId)), OWNER_OF_GAS);
                if (exists && holder == uint256(uint160(msg.sender))) {
                    toppedUp[chipId] += msg.value;
                    // The two calls above are staticcalls: nothing can re-enter or change state through them.
                    // forge-lint: disable-next-line(reentrancy-events)
                    emit ToppedUp(chipId, msg.sender, msg.value);
                    return;
                }
            }
        }
        // forge-lint: disable-next-line(reentrancy-events)
        emit Funded(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------ internals

    function _allowance(uint256 burned, uint256 chipId) private view returns (uint256) {
        return burned * mintPrice * ALLOWANCE_BPS / BPS + toppedUp[chipId];
    }

    function _burnedCached(uint256 chipId) private returns (uint256 burned) {
        uint256 cached = _burnedCache[chipId];
        if (cached != 0) return cached - 1;
        burned = _scan(chipId);
        _burnedCache[chipId] = burned + 1;
    }

    function _scan(uint256 chipId) private view returns (uint256) {
        (uint256 nNand, uint256 nLatch) = NetlistScan.burnOf(ICircuits(circuits).netlist(chipId));
        return nNand + nLatch;
    }

    /// @dev min(tx.gasprice, block.basefee + MAX_TIP): never more than the caller pays per unit of gas.
    function _refundPrice() private view returns (uint256) {
        uint256 cap = block.basefee + MAX_TIP;
        return tx.gasprice < cap ? tx.gasprice : cap;
    }

    /// @dev OVERHEAD for the first refund of a transaction, OVERHEAD_REPEAT for the rest.
    ///      The flag is transient: it clears itself at the end of the transaction, and is rolled back with
    ///      the call if this `settleAndRefund` reverts.
    function _overhead() private returns (uint256) {
        if (_baseCostGranted) return OVERHEAD_REPEAT;
        _baseCostGranted = true;
        return OVERHEAD;
    }

    /// @dev kernel.settle() with all remaining gas. Return data is not copied on success; on failure it is
    ///      copied once and re-thrown unchanged.
    function _settle(address kernel) private {
        bytes4 selector = IKernelMin.settle.selector;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            if iszero(call(gas(), kernel, 0, 0x00, 0x04, 0x00, 0x00)) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0x00, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    /// @dev Staticcall that never reverts and never copies more than one word of return data.
    /// @return ok   the call succeeded and returned at least 32 bytes
    /// @return word the first 32 bytes returned (meaningless when `ok` is false)
    function _staticWord(address target, bytes memory data, uint256 gasCap)
        private
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            word := mload(0x00)
        }
    }

    function _saturatingSub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
