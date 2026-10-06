// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IFabV1} from "./interfaces/IFabV1.sol";
import {ITapeOutCircuits, ITapeOutTransistors} from "./interfaces/ITapeOut.sol";
import {NetlistScan} from "./lib/NetlistScan.sol";
import {SSTORE2} from "./lib/SSTORE2.sol";

/// @title Fab: the only way to make a chip a Covenant kernel will accept
/// @notice Tapes out a circuit on one TapeOut processor, and only if its netlist is a Covenant v1 chip
///         (chips/INTERFACE.md, section 2: 96 inputs, 112 outputs, 1 to 256 leading LATCH records,
///         NAND and LATCH only, at most 3,400 gates and 24,000 bytes). For each chip it keeps its own
///         copy of the exact netlist bytes, so an evaluator that does not depend on TapeOut's
///         upgradeable processor logic can run the chip (see SealedVM).
///
///         One call does everything: it mints exactly the transistors the netlist needs, tapes the
///         circuit out, stores the snapshot, records the chip and hands the circuit NFT to the caller.
///
///         No owner, no upgrade path, no pause, no way to change a recorded chip.
///
///         Value: a call must carry exactly `quote(netlist).cost`, and every wei of it is paid on to
///         TapeOut inside the call (two mints and the tape-out fee). The three prices are read from
///         TapeOut in the same call, so the Fab keeps working when TapeOut changes one of them. The Fab
///         has no `receive`, no `fallback` and no function that sends value anywhere else, so a call
///         leaves its balance as it found it. OKB forced into the Fab from outside stays there for good;
///         nobody can take it out.
///
///         Transistors: the Fab holds transistors only between its own mint and TapeOut's burn, inside
///         one call. Its receiver hook refuses every other transfer, and every tape-out ends with a check
///         that the Fab holds no transistor and that TapeOut owes it no refund.
contract Fab is IFabV1, IERC1155Receiver, IERC721Receiver, ReentrancyGuardTransient {
    /// @notice Pin counts of a v1 chip.
    uint32 public constant N_IN = 96;
    uint32 public constant N_OUT = 112;

    /// @dev Transistor token ids of a TapeOut processor (`Transistors.NAND` and `Transistors.LATCH`).
    uint256 private constant NAND = 0;
    uint256 private constant LATCH = 1;

    /// @notice The processor this Fab tapes out on: its circuit contract (ERC-721).
    ITapeOutCircuits public immutable CIRCUITS;
    /// @notice The processor's transistor contract (ERC-1155).
    ITapeOutTransistors public immutable TRANSISTORS;

    /// @dev What the Fab records for a chip. Written once, when the chip is taped out.
    struct Chip {
        address snapshot; // SSTORE2 pointer: runtime code 0x00, then the netlist
        uint32 nState;
        uint32 gateCount;
        bytes32 netlistHash;
        address author;
        bytes32 manifestHash;
    }

    mapping(uint256 chipId => Chip) private _chips;

    /// @notice A chip was taped out through this Fab.
    /// @param chipId       the circuit id on the processor
    /// @param author       the caller of the Fab
    /// @param manifestHash the caller's commitment to the chip's pin manifest, recorded as given
    /// @param netlistHash  keccak256 of the netlist bytes
    /// @param nState       number of LATCH records
    /// @param gateCount    number of NAND and LATCH records, which is the number of transistors burned
    event ChipTaped(
        uint256 indexed chipId,
        address indexed author,
        bytes32 indexed manifestHash,
        bytes32 netlistHash,
        uint32 nState,
        uint32 gateCount
    );

    /// @notice The two constructor arguments are not the circuit and transistor contracts of one processor.
    error NotAProcessor();
    /// @notice The call carried `sent` wei; at TapeOut's prices of this moment the netlist costs exactly `cost`.
    error WrongValue(uint256 sent, uint256 cost);
    /// @notice The NFT recipient is the zero address or the Fab itself.
    error BadRecipient();
    /// @notice The processor did not record the circuit the Fab asked for (pins, state, gates or bytes differ).
    error TapeoutMismatch();
    /// @notice The processor returned a circuit id this Fab has already recorded.
    error ChipExists(uint256 chipId);
    /// @notice `chipId` was not taped out through this Fab.
    error NotAChip(uint256 chipId);
    /// @notice The Fab accepts transistors only from its own mint, and a circuit NFT only from the processor
    ///         during its own tape-out.
    error UnexpectedTokens();
    /// @notice At the end of a tape-out the Fab still held transistors, or TapeOut owed it a refund.
    error LeftOver();

    /// @param circuits    the circuit contract (ERC-721) of the processor
    /// @param transistors the transistor contract (ERC-1155) of the same processor
    constructor(address circuits, address transistors) {
        if (circuits.code.length == 0 || transistors.code.length == 0) revert NotAProcessor();
        if (
            ITapeOutCircuits(circuits).transistors() != transistors
                || ITapeOutTransistors(transistors).circuits() != circuits
                || ITapeOutTransistors(transistors).NAND() != NAND || ITapeOutTransistors(transistors).LATCH() != LATCH
        ) revert NotAProcessor();

        CIRCUITS = ITapeOutCircuits(circuits);
        TRANSISTORS = ITapeOutTransistors(transistors);
    }

    // ------------------------------------------------------------------ tape-out

    /// @inheritdoc IFabV1
    /// @dev The circuit NFT goes to the caller, with `transferFrom`: the caller may be a contract and no
    ///      receiver hook is called.
    function tapeoutChip(bytes calldata netlist, bytes32 manifestHash)
        external
        payable
        nonReentrant
        returns (uint256 chipId)
    {
        return _tapeout(netlist, manifestHash, msg.sender);
    }

    /// @inheritdoc IFabV1
    /// @dev Same as `tapeoutChip`, with the circuit NFT sent to `to`. The recorded author is still the caller.
    function tapeoutChipTo(bytes calldata netlist, bytes32 manifestHash, address to)
        external
        payable
        nonReentrant
        returns (uint256 chipId)
    {
        if (to == address(0) || to == address(this)) revert BadRecipient();
        return _tapeout(netlist, manifestHash, to);
    }

    function _tapeout(bytes calldata netlist, bytes32 manifestHash, address to) private returns (uint256 chipId) {
        // 1. The netlist is a v1 chip. Reverts otherwise.
        (uint256 nNand, uint256 nLatch) = NetlistScan.scan(netlist);

        // 2 and 3. The call carries exactly what TapeOut charges right now, and exactly the transistors
        //    the netlist burns are minted.
        uint256 tapeoutFee = _payAndMint(nNand, nLatch);

        // 4. Tape out. TapeOut burns the transistors from the Fab and mints the circuit NFT to it.
        chipId = CIRCUITS.tapeout{value: tapeoutFee}(netlist, N_IN, N_OUT);

        // 5. Self-check: the processor recorded this netlist, with these pins and counts.
        //    The casts cannot truncate: the scan bounds nLatch by 256 and nNand + nLatch by 3,400.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 nState = uint32(nLatch);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 gateCount = uint32(nNand + nLatch);
        bytes32 netlistHash = keccak256(netlist);
        {
            (uint32 nIn_, uint32 nOut_, uint32 nState_, uint32 gateCount_) = CIRCUITS.circuitInfo(chipId);
            if (nIn_ != N_IN || nOut_ != N_OUT || nState_ != nState || gateCount_ != gateCount) {
                revert TapeoutMismatch();
            }
            if (keccak256(CIRCUITS.netlist(chipId)) != netlistHash) revert TapeoutMismatch();
        }

        // 6. Record the chip, once, with our own copy of the netlist.
        Chip storage chip = _chips[chipId];
        if (chip.snapshot != address(0)) revert ChipExists(chipId);
        chip.snapshot = SSTORE2.write(netlist);
        chip.nState = nState;
        chip.gateCount = gateCount;
        chip.netlistHash = netlistHash;
        chip.author = msg.sender;
        chip.manifestHash = manifestHash;
        // The chip id exists only after TapeOut's call, so the event cannot come before it. Every entry
        // point that reaches this line holds the reentrancy lock.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ChipTaped(chipId, msg.sender, manifestHash, netlistHash, nState, gateCount);

        // 7. Hand over the circuit NFT.
        CIRCUITS.transferFrom(address(this), to, chipId);

        // 8. Nothing of this call is left behind: every transistor the Fab minted was burned, and TapeOut
        //    kept none of the payment as a refund owed to the Fab (which the Fab could never collect).
        if (
            TRANSISTORS.balanceOf(address(this), NAND) != 0 || TRANSISTORS.balanceOf(address(this), LATCH) != 0
                || TRANSISTORS.owed(address(this)) != 0
        ) revert LeftOver();
    }

    /// @dev Reads TapeOut's three prices, requires the call to carry exactly what this chip costs at those
    ///      prices, and mints exactly the transistors the netlist burns, one call per transistor type in
    ///      use. A v1 chip always has a LATCH; it has no NAND when its 112 outputs are all LATCH outputs.
    /// @return tapeoutFee what is left of msg.value: the fee `Circuits.tapeout` takes
    function _payAndMint(uint256 nNand, uint256 nLatch) private returns (uint256 tapeoutFee) {
        uint256 mintPrice;
        uint256 protocolFee;
        (mintPrice, protocolFee, tapeoutFee) = _prices();
        uint256 cost = _cost(nNand, nLatch, mintPrice, protocolFee, tapeoutFee);
        if (msg.value != cost) revert WrongValue(msg.value, cost);
        if (nNand != 0) TRANSISTORS.mint{value: mintPrice * nNand + protocolFee}(NAND, nNand);
        TRANSISTORS.mint{value: mintPrice * nLatch + protocolFee}(LATCH, nLatch);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IFabV1
    /// @dev `cost` is what a tape-out of this netlist must carry if it is made at TapeOut's prices of this
    ///      moment. Reverts with the reason the netlist is not a v1 chip, exactly as `tapeoutChip` would.
    ///      It does not check the processor's remaining transistor supply.
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost) {
        (nNand, nLatch) = NetlistScan.scan(netlist);
        (uint256 mintPrice, uint256 protocolFee, uint256 tapeoutFee) = _prices();
        cost = _cost(nNand, nLatch, mintPrice, protocolFee, tapeoutFee);
    }

    /// @inheritdoc IFabV1
    function isChip(uint256 chipId) external view returns (bool) {
        return _chips[chipId].snapshot != address(0);
    }

    /// @inheritdoc IFabV1
    /// @dev Reverts with `NotAChip` for an id that was not taped out through this Fab.
    function chipInfo(uint256 chipId)
        external
        view
        returns (
            address snapshot_,
            bytes32 netlistHash,
            uint32 nState,
            uint32 gateCount,
            address author,
            bytes32 manifestHash
        )
    {
        Chip storage chip = _chip(chipId);
        return (chip.snapshot, chip.netlistHash, chip.nState, chip.gateCount, chip.author, chip.manifestHash);
    }

    /// @inheritdoc IFabV1
    /// @dev Returns the netlist bytes stored for the chip. Reverts with `NotAChip` for an unknown id.
    function snapshot(uint256 chipId) external view returns (bytes memory) {
        return SSTORE2.read(_chip(chipId).snapshot);
    }

    // ------------------------------------------------------------------ ERC-1155 receiver

    /// @notice Accepts transistors only when the Fab itself mints them on its own processor.
    /// @dev `Transistors.mint` mints to its caller and runs this acceptance check, so the Fab must answer it.
    ///      A mint reaches the Fab only from its own `_tapeout`: operator is the Fab and `from` is zero.
    function onERC1155Received(address operator, address from, uint256, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(TRANSISTORS) || operator != address(this) || from != address(0)) {
            revert UnexpectedTokens();
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @notice Always refuses: the Fab never receives a batch.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnexpectedTokens();
    }

    // ------------------------------------------------------------------ ERC-721 receiver

    /// @notice Accepts a circuit NFT only from the processor's circuit contract, and only while the Fab is
    ///         inside its own tape-out.
    /// @dev TapeOut mints the circuit NFT to the caller of `tapeout` with `_mint`, which calls no hook. If its
    ///      logic is ever changed to `_safeMint`, this is the hook that mint calls, and the Fab keeps
    ///      working. Outside a tape-out, and for any other NFT contract, it reverts: no safe transfer that
    ///      someone sends to the Fab is accepted. The operator and the previous owner are not examined, so
    ///      besides the new chip itself, any other circuit that the processor's own code hands over during
    ///      a tape-out is accepted too. Such a circuit, like an NFT sent with a plain `transferFrom` (which
    ///      no contract can refuse), stays in the Fab for good and changes nothing for the Fab or anyone else.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(CIRCUITS) || !_reentrancyGuardEntered()) revert UnexpectedTokens();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------ internals

    /// @dev TapeOut's prices right now: the price of one transistor and the fee per `mint` call (from the
    ///      transistor contract), and the fee per tape-out (from the circuit contract). The processor's logic
    ///      is upgradeable, so they are read on every call and never stored.
    function _prices() private view returns (uint256 mintPrice, uint256 protocolFee, uint256 tapeoutFee) {
        mintPrice = TRANSISTORS.mintPrice();
        protocolFee = TRANSISTORS.protocolFee();
        tapeoutFee = CIRCUITS.TAPEOUT_FEE();
    }

    /// @dev mintPrice per transistor, TapeOut's protocol fee per mint call, and the tape-out fee.
    function _cost(uint256 nNand, uint256 nLatch, uint256 mintPrice, uint256 protocolFee, uint256 tapeoutFee)
        private
        pure
        returns (uint256)
    {
        uint256 mintCalls = nNand == 0 ? 1 : 2;
        return mintPrice * (nNand + nLatch) + protocolFee * mintCalls + tapeoutFee;
    }

    function _chip(uint256 chipId) private view returns (Chip storage chip) {
        chip = _chips[chipId];
        if (chip.snapshot == address(0)) revert NotAChip(chipId);
    }
}
