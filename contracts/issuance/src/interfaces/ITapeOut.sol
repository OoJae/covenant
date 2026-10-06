// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal views of TapeOut's verified contracts on X Layer (chain 196).
// Source of truth: contracts/vendor/tapeout-xlayer/src/{CircuitFactory,Transistors,Circuits}.sol
// Only the members the issuance contracts, their tests and their scripts use are declared.

/// @notice TapeOut's factory (0x1f09daefa827f02cbb40967cc91b259763760761 on X Layer).
interface ICircuitFactory {
    /// @dev `msg.sender` becomes the immutable `creator` of the Transistors clone.
    ///      Requires `msg.value >= deployFee()`; any excess is credited to `owed[msg.sender]`.
    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 transistorSupply,
        uint256 mintPrice
    ) external payable returns (address transistors, address circuits);

    function deployFee() external view returns (uint256);

    /// @dev Copied into every Transistors clone at creation.
    function protocolFee() external view returns (uint256);

    function isCPU(address circuits) external view returns (bool);

    /// @dev True once TapeOut's owner has given up every admin right, upgrades of processor logic included.
    function isSealed() external view returns (bool);

    function owed(address account) external view returns (uint256);
}

/// @notice A processor's transistors (ERC-1155; NAND = id 0, LATCH = id 1).
interface ITransistors {
    /// @dev Requires `msg.value >= mintPrice() * amount + protocolFee()`. Proceeds accrue to `owed[creator()]`.
    function mint(uint256 id, uint256 amount) external payable;

    /// @dev Pays `owed[msg.sender]` to `msg.sender`. Reverts with "nothing owed" when it is zero.
    function withdraw() external;

    function creator() external view returns (address);

    function circuits() external view returns (address);

    function mintPrice() external view returns (uint256);

    function supplyCap() external view returns (uint256);

    function minted() external view returns (uint256);

    function protocolFee() external view returns (uint256);

    function owed(address account) external view returns (uint256);

    function story() external view returns (string memory);

    function cpuName() external view returns (string memory);

    function cpuSymbol() external view returns (string memory);

    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @notice A processor's circuits (ERC-721). Its address is the processor's identity.
interface ICircuits {
    /// @dev Requires `msg.value == TAPEOUT_FEE()` exactly. Burns one transistor per top-level NAND and
    ///      LATCH record from `msg.sender` and mints the circuit NFT to `msg.sender`.
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256 circuitId);

    function netlist(uint256 circuitId) external view returns (bytes memory);

    /// @dev `gateCount` is recursive through REF records; it is NOT the number of transistors burned.
    function circuitInfo(uint256 circuitId)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);

    function ownerOf(uint256 circuitId) external view returns (address);

    function transistors() external view returns (address);

    function TAPEOUT_FEE() external view returns (uint256);

    function nextId() external view returns (uint256);

    function transferFrom(address from, address to, uint256 circuitId) external;
}
