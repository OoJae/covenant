// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ICircuits, ITransistors} from "../src/interfaces/ITapeOut.sol";
import {NetlistScan} from "../src/lib/NetlistScan.sol";

/// @title TapeoutProbe - mints exactly the transistors a netlist burns and tapes it out.
///
/// @notice IRREVERSIBLE when broadcast (transistors are burned, fees are paid). Run it WITHOUT --broadcast
///         first. See README.md for the exact commands.
///
///         Environment:
///           CIRCUITS     the processor: address of its Circuits contract
///           NETLIST_HEX  the netlist bytes as hex (with or without 0x)
///           N_IN         number of input pins
///           N_OUT        number of output pins
///
///         What it sends, from the broadcasting account:
///           - one mint call per transistor type the netlist needs and the account does not already hold,
///             each paying mintPrice * amount + protocolFee exactly;
///           - one tapeout call paying TAPEOUT_FEE exactly (0.0013 OKB).
contract TapeoutProbe is Script {
    uint256 internal constant NAND = 0;
    uint256 internal constant LATCH = 1;
    uint256 internal constant EXPECTED_TAPEOUT_FEE = 0.0013 ether;

    struct Plan {
        ICircuits circuits;
        ITransistors transistors;
        address sender;
        uint256 nNand; // NAND transistors the tape-out burns
        uint256 nLatch; // LATCH transistors the tape-out burns
        uint256 mintNand; // of those, how many the sender still has to buy
        uint256 mintLatch;
        uint256 mintPrice;
        uint256 protocolFee;
        uint256 tapeoutFee;
        uint256 nandCost; // value of the NAND mint call (zero when no call is needed)
        uint256 latchCost;
    }

    function run() external returns (uint256 circuitId) {
        address circuits = vm.envAddress("CIRCUITS");
        bytes memory netlist = parseHex(vm.envString("NETLIST_HEX"));
        uint256 nIn = vm.envUint("N_IN");
        uint256 nOut = vm.envUint("N_OUT");
        require(nIn <= type(uint32).max && nOut <= type(uint32).max, "TapeoutProbe: pin count out of range");
        return probe(circuits, netlist, uint32(nIn), uint32(nOut));
    }

    function probe(address circuits, bytes memory netlist, uint32 nIn, uint32 nOut) public returns (uint256 circuitId) {
        require(netlist.length != 0, "TapeoutProbe: empty netlist");
        require(circuits.code.length != 0, "TapeoutProbe: CIRCUITS has no code");

        vm.startBroadcast();
        Plan memory p = _plan(circuits, netlist);
        _logPlan(p, netlist.length, nIn, nOut);

        if (p.mintNand != 0) p.transistors.mint{value: p.nandCost}(NAND, p.mintNand);
        if (p.mintLatch != 0) p.transistors.mint{value: p.latchCost}(LATCH, p.mintLatch);
        circuitId = p.circuits.tapeout{value: p.tapeoutFee}(netlist, nIn, nOut);
        vm.stopBroadcast();

        require(p.circuits.ownerOf(circuitId) == p.sender, "TapeoutProbe: circuit not minted to the sender");
        require(keccak256(p.circuits.netlist(circuitId)) == keccak256(netlist), "TapeoutProbe: stored netlist differs");
        _logResult(p.circuits, circuitId);
    }

    /// @notice Hex to bytes, with or without a 0x prefix.
    function parseHex(string memory text) public pure returns (bytes memory) {
        bytes memory t = bytes(text);
        bool prefixed = t.length >= 2 && t[0] == "0" && t[1] == "x";
        return vm.parseBytes(prefixed ? text : string.concat("0x", text));
    }

    /// @dev Reads everything the run needs. Must be called while broadcasting, so that the caller it reads
    ///      is the account that will sign.
    function _plan(address circuits, bytes memory netlist) private view returns (Plan memory p) {
        p.circuits = ICircuits(circuits);
        p.transistors = ITransistors(p.circuits.transistors());
        (, p.sender,) = vm.readCallers();

        // What the tape-out will burn: top-level NAND and LATCH records. REF records burn nothing.
        (p.nNand, p.nLatch) = NetlistScan.burnOf(netlist);

        p.mintPrice = p.transistors.mintPrice();
        p.protocolFee = p.transistors.protocolFee();
        p.tapeoutFee = p.circuits.TAPEOUT_FEE();
        require(p.tapeoutFee == EXPECTED_TAPEOUT_FEE, "TapeoutProbe: TAPEOUT_FEE is no longer 0.0013 OKB");

        p.mintNand = _shortfall(p.nNand, p.transistors.balanceOf(p.sender, NAND));
        p.mintLatch = _shortfall(p.nLatch, p.transistors.balanceOf(p.sender, LATCH));
        require(
            p.transistors.minted() + p.mintNand + p.mintLatch <= p.transistors.supplyCap(), "TapeoutProbe: supply cap"
        );
        p.nandCost = p.mintNand == 0 ? 0 : p.mintPrice * p.mintNand + p.protocolFee;
        p.latchCost = p.mintLatch == 0 ? 0 : p.mintPrice * p.mintLatch + p.protocolFee;
    }

    function _logPlan(Plan memory p, uint256 netlistBytes, uint32 nIn, uint32 nOut) private view {
        console2.log("== Tape-out probe ==");
        console2.log("chain id / block      ", block.chainid, block.number);
        console2.log("processor (Circuits)  ", address(p.circuits));
        console2.log("transistors           ", address(p.transistors));
        console2.log("sender                ", p.sender);
        console2.log("  balance (wei)       ", p.sender.balance);
        console2.log("netlist bytes         ", netlistBytes);
        console2.log("pins in / out         ", nIn, nOut);
        console2.log("burns NAND / LATCH    ", p.nNand, p.nLatch);
        console2.log("mints NAND / LATCH    ", p.mintNand, p.mintLatch);
        console2.log("mint price (wei)      ", p.mintPrice);
        console2.log("TapeOut mint fee (wei)", p.protocolFee);
        console2.log("tape-out fee (wei)    ", p.tapeoutFee);
        console2.log("total value sent (wei)", p.nandCost + p.latchCost + p.tapeoutFee);
    }

    function _logResult(ICircuits circuits, uint256 circuitId) private view {
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = circuits.circuitInfo(circuitId);
        console2.log("");
        console2.log("== Taped out ==");
        console2.log("circuit id            ", circuitId);
        console2.log("owner                 ", circuits.ownerOf(circuitId));
        console2.log("nIn / nOut            ", nIn, nOut);
        console2.log("nState / gateCount    ", nState, gateCount);
        console2.log("(the id above comes from this run; after a broadcast confirm it in the TapedOut event)");
    }

    function _shortfall(uint256 needed, uint256 held) private pure returns (uint256) {
        return needed > held ? needed - held : 0;
    }
}
