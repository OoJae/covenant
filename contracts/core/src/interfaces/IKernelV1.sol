// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Covenant kernel ABI v1 (chips/INTERFACE.md section 10)
/// @notice `chipId()` and `settle()` are frozen forever: the immutable KeeperTank calls them.

/// The two functions the KeeperTank calls. `settle()` reverts when it does no work.
interface IKernelMin {
    function chipId() external view returns (uint256);
    function settle() external returns (uint32 n);
}

/// One settle. `stateBefore` is the previous record's `stateAfter` (zero for n = 1).
struct Record {
    uint32 epoch;
    uint40 time;
    uint16 clampBits;
    uint8 flags; // see RecordFlags
    bytes12 inputs; // exactly the bytes passed to step
    bytes14 outputs; // exactly the bytes returned by step (or the fallback word)
    bytes32 stateAfter;
    uint128 inflow; // regime asset
    uint128 reserveBefore; // regime asset: reserve0 of section 8.1
    uint128 allow; // OKB credited to the allowance payee (0 after graduation)
    uint128 buyDecided; // regime asset
    uint128 buyExecuted; // regime asset: OKB spent on the curve, or tokens that left for 0xdEaD
    uint128 tokensOut; // tokens received on the curve, or tokens that reached 0xdEaD (both legs) after graduation
    uint128 nativeIn; // OKB spent by the post-graduation router buy (0 on the curve)
}

/// The immutable envelope of one kernel (chips/INTERFACE.md section 7). The field order is the order of that
/// table; the ranges are what the kernel factory accepts.
struct Envelope {
    address launcher; // the wallet that creates the token; non-zero
    uint32 epochLen; // seconds per epoch, 300..86400
    address allowancePayee; // receives the allowance as a pull credit; non-zero
    uint16 capT; // maximum T_ALLOW, 0..128
    uint16 capV; // maximum V_ALLOW, 0..255 (kernel v2; unused by v1)
    uint16 allowCumBps; // lifetime allowance is at most this share of cumulative inflow, 0..5000
    uint16 ceilMax; // lg8 code: maximum allowance per settle; 1023 means none
    uint16 relMax; // maximum REL, 1..256
    // minimum REL while lg8(reserve) >= floorMin, 1..relMax, and epochLen * 178 <= 2592000 * floorRel
    uint16 floorRel;
    uint16 floorMin; // lg8 code at or above which the floor applies, 1..425
    // epochs without a persisted step after which the fallback word applies, >= 2, and
    // epochLen * fallbackEpochs <= 30 days
    uint16 fallbackEpochs;
    uint16 fbAllow; // allowance share used by the fallback word, 0..capT
    bool buyEnabled; // must be true: the kernel v1 factory refuses false (the sink would be a second payee)
    address sink; // pull-credit payee used only when buyEnabled is false; ignored by kernels of this factory
}

/// Bits of Record.flags. After graduation 16, 32 and 128 cover both legs (the burn and the router buy).
library RecordFlags {
    uint8 internal constant FALLBACK = 1; // the fallback word was applied
    uint8 internal constant SEALED = 2; // the sealed evaluator's answer was used
    uint8 internal constant CLAIM_FAILED = 4; // the vault held something and a claim failed
    uint8 internal constant CURVE_READ_FAILED = 8; // the curve words could not be read or were out of range
    uint8 internal constant BUY_SKIPPED = 16; // a buy was skipped by a guard, or the capped amount was zero
    uint8 internal constant BUY_FAILED = 32; // a buy or burn call failed, or moved less than decided
    uint8 internal constant GRADUATED = 64; // the record was written in the graduated regime
    uint8 internal constant BUY_SHRUNK = 128; // a buy was shrunk by a cap
}

interface IKernelV1 is IKernelMin {
    event Settled(
        uint32 indexed n,
        uint32 epoch,
        bytes12 inputs,
        bytes14 outputs,
        uint16 clampBits,
        uint8 flags,
        bytes32 stateAfter,
        uint128 inflow,
        uint128 allow,
        uint128 buyDecided,
        uint128 buyExecuted,
        uint128 tokensOut
    );

    function bind(address token) external;
    function withdrawCredit(address payee, address asset) external returns (uint256 paid); // anyone may call; pays only payee
    function burnLocked() external returns (uint256 burned); // after graduation; anyone may call
    function token() external view returns (address);
    function vault() external view returns (address);
    function count() external view returns (uint32); // number of records; records are 1-indexed
    function records(uint32 n) external view returns (Record memory); // all zero for n = 0 or n > count
    /// Regime totals after settle `n` (cumulative inflow, cumulative allowance); they restart at graduation.
    function cums(uint32 n) external view returns (uint128 cumInflow, uint128 allowPaidCum);
    function state() external view returns (bytes32);
    function epochNow() external view returns (uint32);
    function lastEpoch() external view returns (uint32); // epoch of the last settle
    function lastStepEpoch() external view returns (uint32); // epoch of the last persisted step
    function bindTime() external view returns (uint40);
    function reserve() external view returns (uint256); // regime asset, as of the last settle
    function creditOf(address payee, address asset) external view returns (uint256);
    function totalCredits(address asset) external view returns (uint256);
    function lockedTokens() external view returns (uint256);
    function burnedTokens() external view returns (uint128);
    function graduated() external view returns (bool); // as of the last settle
    function pair() external view returns (address);
    function envelope() external view returns (Envelope memory);
    function evaluator() external view returns (address vm, bool sealedMode); // what the next settle would ask first
    function minSettleGas() external view returns (uint256);
}
