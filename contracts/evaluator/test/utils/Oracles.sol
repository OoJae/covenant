// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interfaces of the two test harnesses that wrap TapeOut's vendored sources.
/// @dev The harnesses are compiled with via-IR (TapeOut's NetlistVM does not compile otherwise). Tests
///      deploy them with `deployCode` and talk to them through these interfaces, so no test file imports
///      them and every contract under test stays on the production compiler settings.

interface INetlistVMHarness {
    function run(bytes memory nl, uint32 nIn, uint32 nOut, bytes memory state, bytes memory inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);

    function analyze(bytes memory nl, uint32 nIn, uint32 nOut)
        external
        view
        returns (uint256 nNand, uint256 nLatch, uint32 nState, uint32 gateCount);
}

interface ILocalTapeOut {
    function factory() external view returns (address);
    function treasury() external view returns (address);
}

/// @notice The parts of TapeOut's factory the tests use (verified source: CircuitFactory.sol).
interface ITapeOutFactory {
    function deployFee() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function isCPU(address circuits) external view returns (bool);
    function owner() external view returns (address);
    function circuitBeacon() external view returns (address);
    function transistorBeacon() external view returns (address);
    function upgradeCircuits(address newImpl) external;
    function upgradeTransistors(address newImpl) external;
    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 transistorSupply,
        uint256 mintPrice
    ) external payable returns (address transistors, address circuits);
}

/// @notice The read side of a processor's circuit contract, plus what the tests need from ERC-721.
interface ICircuitsView {
    function step(uint256 circuitId, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
    function netlist(uint256 circuitId) external view returns (bytes memory);
    function circuitInfo(uint256 circuitId)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function nextId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
    function TREASURY() external view returns (address);
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
}

/// @notice The read side of a processor's transistor contract, plus what the tests need from ERC-1155.
interface ITransistorsView {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function minted() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    function owed(address account) external view returns (uint256);
    function creator() external view returns (address);
    function protocolWallet() external view returns (address);
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function mint(uint256 id, uint256 amount) external payable;
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external;
}
