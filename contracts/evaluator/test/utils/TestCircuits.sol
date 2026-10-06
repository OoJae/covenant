// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ICPU} from "tapeout/interfaces/ICPU.sol";
import {Transistors} from "tapeout/Transistors.sol";
import {NetlistVM} from "tapeout/lib/NetlistVM.sol";
import {SSTORE2} from "tapeout/lib/SSTORE2.sol";

/// @notice Test fixture: what TapeOut's circuit logic could become after an upgrade of its beacon.
///
///         This is TapeOut's `Circuits` (MIT, vendored unmodified in contracts/vendor/tapeout-xlayer/src) with
///         the same storage layout, so it can replace the implementation behind a live processor, and three
///         differences chosen at construction:
///           - the tape-out fee is a constructor argument instead of the constant 0.0013 ether;
///           - the circuit NFT can be minted with `_safeMint` (which calls the receiver's ERC-721 hook)
///             instead of `_mint`;
///           - the LATCH transistors can be left unburned.
///         Everything else is TapeOut's code, line for line. It is used by the Fab suite only, to show that
///         the Fab follows a changed fee, keeps working with a safe mint, and refuses to finish a tape-out
///         that leaves transistors behind. Compiled with via-IR like the other TapeOut harnesses and
///         deployed from its artifact.
contract TestCircuits is Initializable, ERC721Upgradeable, ICPU {
    uint256 internal constant MAX_CHUNK = 24000;

    struct Circ {
        address[] chunks;
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gateCount;
        bool exists;
    }

    uint256 internal constant MAX_PINS = 1 << 16;

    Transistors public transistorsContract;
    mapping(uint256 => Circ) internal _circ;
    uint256 public nextId;

    event TapedOut(uint256 indexed circuitId, address indexed author, uint32 gateCount, uint32 nState);
    event FeeHeld(uint256 indexed circuitId, uint256 amount);

    // ---- the three differences (immutables live in the implementation's code, not in the proxy's storage)
    uint256 public immutable TAPEOUT_FEE;
    bool public immutable SAFE_MINT;
    bool public immutable BURN_LATCH;
    address public constant TREASURY = 0xEBeceDeA36e598b64E17f8d519EB77441C539F76;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 tapeoutFee, bool safeMint, bool burnLatch) {
        TAPEOUT_FEE = tapeoutFee;
        SAFE_MINT = safeMint;
        BURN_LATCH = burnLatch;
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, address transistors_, address factory_)
        external
        initializer
    {
        __ERC721_init(name_, symbol_);
        transistorsContract = Transistors(transistors_);
        factory = factory_;
    }

    function transistors() external view returns (address) {
        return address(transistorsContract);
    }

    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256 circuitId) {
        require(msg.value == TAPEOUT_FEE, "tapeout fee");
        require(nOut > 0, "no outputs");
        require(nIn <= MAX_PINS && nOut <= MAX_PINS, "too many pins");
        (uint256 nNand, uint256 nLatch, uint32 nState, uint32 gateCount) = NetlistVM.analyze(nl, nIn, nOut, factory);

        if (nNand > 0) transistorsContract.burnFrom(msg.sender, transistorsContract.NAND(), nNand);
        if (nLatch > 0 && BURN_LATCH) transistorsContract.burnFrom(msg.sender, transistorsContract.LATCH(), nLatch);

        circuitId = ++nextId;
        Circ storage c = _circ[circuitId];
        c.nIn = nIn;
        c.nOut = nOut;
        c.nState = nState;
        c.gateCount = gateCount;
        c.exists = true;

        uint256 off = 0;
        while (off < nl.length) {
            uint256 end = off + MAX_CHUNK;
            if (end > nl.length) end = nl.length;
            c.chunks.push(SSTORE2.write(nl[off:end]));
            off = end;
        }

        if (SAFE_MINT) _safeMint(msg.sender, circuitId);
        else _mint(msg.sender, circuitId);
        emit TapedOut(circuitId, msg.sender, gateCount, nState);

        (bool ok,) = TREASURY.call{value: msg.value, gas: 30_000}("");
        if (!ok) emit FeeHeld(circuitId, msg.value);
    }

    function sweepFees() external {
        (bool ok,) = TREASURY.call{value: address(this).balance}("");
        require(ok, "sweep");
    }

    function netlist(uint256 circuitId) public view returns (bytes memory nl) {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        for (uint256 i = 0; i < c.chunks.length; i++) {
            nl = bytes.concat(nl, SSTORE2.read(c.chunks[i]));
        }
    }

    function circuitInfo(uint256 circuitId)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount)
    {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        return (c.nIn, c.nOut, c.nState, c.gateCount);
    }

    function eval(uint256 circuitId, bytes calldata inputs) external view returns (bytes memory outputs) {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        require(c.nState == 0, "has latch: use step");
        (, outputs) = NetlistVM.run(netlist(circuitId), c.nIn, c.nOut, "", inputs);
    }

    function step(uint256 circuitId, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs)
    {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        (newState, outputs) = NetlistVM.run(netlist(circuitId), c.nIn, c.nOut, state, inputs);
    }

    // ---- append-only storage, as in TapeOut's Circuits
    address public factory;
    uint256[44] private __gap;
}
