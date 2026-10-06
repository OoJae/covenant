// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// The surface of IGNIX and of a Covenant kernel that the launch simulation touches.
//
// IGNIX: from the verified IgnixManager source vendored in contracts/vendor/ignix-xlayer and from
// contracts/probes/src/interfaces (our own fork probes; the vault interface was recovered from bytecode there).
// Kernel: chips/INTERFACE.md revision 2, section 7 (Envelope) and section 10 (kernel ABI v1, Record, factory),
// and contracts/core/src/interfaces/IKernelExt.sol (Globals, globals()). The structs are copies, so that this
// project compiles without contracts/core; tools/launch-check/test/kernel-abi.test.ts fails if a copy and the
// kernel's own declaration ever differ.

/// @notice `IgnixManager.tokens(token)`: 16 static words. Declared as a struct because a call to the flat
///         16-value getter does not compile without via_ir (contracts/probes/FINDINGS.md section 5).
struct CurveToken {
    address creator;
    uint16 buyFeeBps;
    uint16 sellFeeBps;
    uint16 taxBuyBps;
    uint16 taxSellBps;
    address quote;
    uint16 snipeStartBps;
    uint16 snipeMins;
    uint64 createdAt;
    uint128 vQuote;
    uint128 vToken;
    uint128 sold;
    uint128 collected;
    uint128 sellable;
    uint128 reserve;
    bytes32 poolId;
}

interface IIgnixManager {
    struct CreateParams {
        string name;
        string symbol;
        string metadataURI;
        bytes32 salt;
        address quote;
        uint256 graduation;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint16 taxBuyBps;
        uint16 taxSellBps;
        uint16 snipeStartBps;
        uint16 snipeMins;
        uint256 listingFee;
        uint256 firstBuy;
        uint16 founderBps;
        uint32 founderSecs;
        bytes32 founderRoot;
    }

    /// selector 0xef44bdf2
    function createToken(
        CreateParams calldata p,
        uint16 templateId,
        bytes calldata vaultData,
        uint64 deadline,
        address factory,
        uint8 venue,
        uint64 graduationProtectionSecs,
        bytes calldata sig
    ) external payable returns (address token);

    function tokens(address token) external view returns (CurveToken memory);
    function vaultOf(address token) external view returns (address);
    function pairOf(address token) external view returns (address);
    function snipeBpsNow(address token) external view returns (uint256);
    function founderRound(address token)
        external
        view
        returns (bytes32 root, uint64 endsAt, uint128 capTotal, uint128 spentTotal);
    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable;

    function signer() external view returns (address);
    function REGISTRY() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function LAUNCH_FACTORY() external view returns (address);
}

interface IVaultRegistry {
    function factoryOf(uint16 id) external view returns (address);
}

/// @notice IGNIX "Directed" vault (template 3).
interface IDirectedVault {
    function RECIPIENT() external view returns (address);
    function TOKEN() external view returns (address);
    function QUOTE() external view returns (address);
    function claim(address asset) external returns (uint256 amount);
}

interface IERC20Min {
    function balanceOf(address a) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IERC721Min {
    function ownerOf(uint256 id) external view returns (address);
}

/// @notice The immutable envelope of one kernel (chips/INTERFACE.md section 7).
struct Envelope {
    address launcher;
    uint32 epochLen;
    address allowancePayee;
    uint16 capT;
    uint16 capV;
    uint16 allowCumBps;
    uint16 ceilMax;
    uint16 relMax;
    uint16 floorRel;
    uint16 floorMin;
    uint16 fallbackEpochs;
    uint16 fbAllow;
    bool buyEnabled;
    address sink;
}

/// @notice Everything a kernel knows besides its envelope (contracts/core IKernelExt.sol; not frozen).
struct Globals {
    address manager;
    address v2Router;
    address wokb;
    address factory;
    address circuits;
    address fab;
    address sealedVM;
    address beacon;
    address impl0;
    bytes32 impl0Hash;
    address snapshot;
    bytes32 netlistHash;
    uint256 chipId;
    uint32 nState;
    uint32 gateCount;
    uint32 netlistLen;
    uint256 stepFloor;
    uint256 sealedFloor;
}

/// @notice One settlement record (chips/INTERFACE.md section 10).
struct Record {
    uint32 epoch;
    uint40 time;
    uint16 clampBits;
    uint8 flags;
    bytes12 inputs;
    bytes14 outputs;
    bytes32 stateAfter;
    uint128 inflow;
    uint128 reserveBefore;
    uint128 allow;
    uint128 buyDecided;
    uint128 buyExecuted;
    uint128 tokensOut;
    uint128 nativeIn;
}

/// @notice Kernel ABI v1 as far as the simulation uses it (chips/INTERFACE.md section 10).
interface IKernelV1 {
    function chipId() external view returns (uint256);
    function settle() external returns (uint32 n);
    function bind(address token) external;
    function token() external view returns (address);
    function vault() external view returns (address);
    function count() external view returns (uint32);
    function records(uint32 n) external view returns (Record memory);
    function epochNow() external view returns (uint32);
    function lastEpoch() external view returns (uint32);
    function reserve() external view returns (uint256);
    function envelope() external view returns (Envelope memory);
}

/// @notice Kernel v1 members outside the frozen ABI (contracts/core IKernelExt.sol).
interface IKernelExt is IKernelV1 {
    function globals() external view returns (Globals memory);
}

/// @notice Kernel v2's globals (contracts/core-v2/src/interfaces/IKernelV2.sol): kernel v1's Globals with the quote
///         asset in place of `wokb` and the code shift (bits) last. A copy; kernel-abi.test.ts compares it.
struct GlobalsV2 {
    address manager;
    address v2Router;
    address quote;
    address factory;
    address circuits;
    address fab;
    address sealedVM;
    address beacon;
    address impl0;
    bytes32 impl0Hash;
    address snapshot;
    bytes32 netlistHash;
    uint256 chipId;
    uint32 nState;
    uint32 gateCount;
    uint32 netlistLen;
    uint256 stepFloor;
    uint256 sealedFloor;
    uint256 quoteShift;
}

/// @notice Kernel v2 (USD₮0 quote, chips/INTERFACE-V2.md): kernel v1's ABI (records() returns RecordV2, whose
///         14-word layout is Record's with `quoteIn` in place of `nativeIn`), GlobalsV2, the quote and its shift.
interface IKernelExtV2 is IKernelV1 {
    function globals() external view returns (GlobalsV2 memory);
    function quote() external view returns (address);
    function quoteShift() external view returns (uint256);
}

/// @notice The kernel factory (chips/INTERFACE.md section 10, IKernelFactoryV1; KernelFactoryV2 has the same two).
interface IKernelFactoryV1 {
    function isKernel(address kernel) external view returns (bool);
    function kernelOf(address token) external view returns (address);
}

/// @notice The Covenant Lens (contracts/core/src/Lens.sol): one step of the kernel's chip on both evaluators,
///         with exactly the gas a settle gives them.
interface ILens {
    struct Preflight {
        bool sealedModeNow;
        bool tapeoutRan;
        bool sealedRan;
        bool agree;
        uint256 tapeoutGas;
        uint256 sealedGas;
        uint256 stepFloor;
        uint256 sealedFloor;
        uint256 minSettleGas;
    }

    function preflight(address kernel) external view returns (Preflight memory);
}

/// @notice The Covenant Fab (chips/INTERFACE.md section 11), as far as the simulation reads it.
interface IFabV1 {
    function isChip(uint256 chipId) external view returns (bool);
}
