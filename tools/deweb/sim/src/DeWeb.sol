// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Minimal views of the TapeOut and DeWEB contracts on X Layer (chain 196) that a site publication touches.
// Written from the verified sources on OKLink and from TAP-10 Appendix A; every signature and selector is
// listed in ../../NOTES.md with the command that checked it. Only the members this project uses are declared.

/// @notice Addresses on X Layer. Source: TAP-10 "Deployments", confirmed on chain (see NOTES.md).
library XLayer {
    uint256 internal constant CHAIN_ID = 196;
    /// @dev The chain's area code in on-chain names and gateway hosts (TAP-10 section 2.1).
    uint256 internal constant AREA_CODE = 2;

    address internal constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant OPENER = 0x536adD8F30f03b69f6fbF29d425A816A0dC50106;
    address internal constant SITE_REGISTRY = 0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6;
    address internal constant DOMAIN_BINDING = 0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9;

    /// @dev The only implementations the official gateway accepts behind the two proxies (TapeKit
    ///      kernel/src/config.js, `L2_CONTRACTS.expectedImpl`). If either proxy points elsewhere the gateway
    ///      answers `store-changed` (HTTP 503) for every site on the chain.
    address internal constant SITE_REGISTRY_IMPL = 0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f;
    address internal constant DOMAIN_BINDING_IMPL = 0x5eBF29b80789e548907C707530C3C7607C4347Df;

    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev `SiteRegistry.CHUNK_MAX`: bytes per chunk. `CHUNKS_MAX`: chunks per file.
    uint256 internal constant CHUNK_MAX = 24_000;
    uint256 internal constant CHUNKS_MAX = 350;
}

/// @notice TapeOut's processor factory.
interface IFactory {
    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 transistorSupply,
        uint256 mintPrice
    ) external payable returns (address transistors, address circuits);

    function deployFee() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256 i) external view returns (address);
    function isCPU(address circuits) external view returns (bool);
}

/// @notice A processor's transistors (ERC-1155; NAND = id 0, LATCH = id 1).
interface ITransistors {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

/// @notice A processor's circuits (ERC-721). Its address is the processor's identity.
interface ICircuits {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256 circuitId);
    function ownerOf(uint256 circuitId) external view returns (address);
    function transferFrom(address from, address to, uint256 circuitId) external;
    function transistors() external view returns (address);
    function name() external view returns (string memory);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// @notice `CircuitAccountOpener`: not upgradeable, no owner.
interface IOpener {
    /// @dev Anyone may open the container of any circuit of a registered processor. Requires
    ///      `msg.value >= FEE()`; the excess is sent back. Reverts `AlreadyOpened()` when it is already paid.
    function open(address circuits, uint256 tokenId) external payable returns (address account);

    /// @dev The container's address (ERC-6551, CREATE2); defined before the container is deployed.
    function accountOf(address circuits, uint256 tokenId) external view returns (address);

    /// @dev True once the opening fee has been paid (not merely "has code").
    function isOpened(address circuits, uint256 tokenId) external view returns (bool);
    function isDeployed(address circuits, uint256 tokenId) external view returns (bool);
    function FEE() external view returns (uint256);
    function treasury() external view returns (address);
    function payments() external view returns (address);
}

/// @notice The container: an ERC-6551 account bound to one circuit.
interface IContainer {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function owner() external view returns (address);

    /// @dev Returns 0x523e3260 only when `signer` is the circuit's current holder, the container is opened and
    ///      the circuit is not listed on TapeOut's market. This is the SiteRegistry's permission test.
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4);
}

/// @notice `SiteRegistry` (UUPS proxy): files stored by (container, path).
interface ISiteRegistry {
    /// @dev Writes the first chunk (at most 24,000 bytes) and REPLACES the file if the path already exists.
    ///      `sha256Hash` is stored as given; the contract does not check it.
    function putFile(
        address container,
        string calldata path,
        string calldata contentType,
        bytes32 sha256Hash,
        bytes calldata data
    ) external;

    /// @dev Appends one chunk; reverts `BadIndex()` unless `expectIndex` equals the current chunk count.
    function appendChunk(address container, string calldata path, uint256 expectIndex, bytes calldata data) external;
    function removeFile(address container, string calldata path) external;
    function setFallback(address container, string calldata path) external;
    function setOperator(address container, address op, uint256 ttl) external;

    function fileInfo(address container, string calldata path)
        external
        view
        returns (uint32 size, string memory contentType, bytes32 sha256Hash, uint40 updatedAt, uint256 chunkCount);
    function read(address container, string calldata path) external view returns (bytes memory);
    function readRange(address container, string calldata path, uint256 offset, uint256 len)
        external
        view
        returns (bytes memory);
    function pathCount(address container) external view returns (uint256);
    function pathsRange(address container, uint256 from, uint256 n) external view returns (string[] memory);
    function paths(address container) external view returns (string[] memory);
    function fallbackPath(address container) external view returns (string memory);
    function chunksOf(address container, string calldata path) external view returns (address[] memory);

    function isOwner(address container, address who) external view returns (bool);
    function canEdit(address container, address who) external view returns (bool);
    function isOpenedContainer(address container) external view returns (bool);
    function operatorOf(address container) external view returns (address);
    function CHUNK_MAX() external view returns (uint256);
    function CHUNKS_MAX() external view returns (uint256);
    function OPERATOR_TTL_MAX() external view returns (uint256);
}

/// @notice `DomainBinding` (UUPS proxy): records until when a name is paid for a container.
interface IDomainBinding {
    /// @dev Requires `msg.value == months * monthlyFee()` exactly, `1 <= months <= 120`, an opened container
    ///      and `SiteRegistry.isOwner(container, msg.sender)`. The fee is not refundable.
    function bind(string calldata name, address container, uint256 months) external payable;
    function monthlyFee() external view returns (uint256);
    function isLive(string calldata name, address container) external view returns (bool);
    function isContainerLive(address container) external view returns (bool);
    function containerPaidUntil(address container) external view returns (uint40);
    function paidUntil(bytes32 nameHash, address container) external view returns (uint40);
}
