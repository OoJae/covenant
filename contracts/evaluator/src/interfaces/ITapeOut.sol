// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The parts of a TapeOut processor's circuit contract (ERC-721) that the Fab calls.
/// @dev Signatures taken from TapeOut's verified source (contracts/vendor/tapeout-xlayer/src/Circuits.sol,
///      implementation 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2 on X Layer).
interface ITapeOutCircuits {
    function TAPEOUT_FEE() external view returns (uint256);
    function transistors() external view returns (address);
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256 circuitId);
    function netlist(uint256 circuitId) external view returns (bytes memory);
    function circuitInfo(uint256 circuitId)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice The parts of a TapeOut processor's transistor contract (ERC-1155) that the Fab calls.
/// @dev Signatures taken from TapeOut's verified source (contracts/vendor/tapeout-xlayer/src/Transistors.sol).
interface ITapeOutTransistors {
    function NAND() external view returns (uint256);
    function LATCH() external view returns (uint256);
    function circuits() external view returns (address);
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function mint(uint256 id, uint256 amount) external payable;
    /// @notice ERC-1155 balance of `account` in transistor type `id`.
    function balanceOf(address account, uint256 id) external view returns (uint256);
    /// @notice Pull-payment balance: what the transistor contract holds for `account` (an overpaid `mint` is
    ///         credited here to its caller).
    function owed(address account) external view returns (uint256);
}
