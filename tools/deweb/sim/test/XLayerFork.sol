// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SitePublisher} from "../src/SitePublisher.sol";
import {XLayer, IFactory, ITransistors, ICircuits} from "../src/DeWeb.sol";

/// @notice X Layer mainnet (chain 196) forked at a pinned block. The tests talk to the REAL TapeOut factory,
///         container opener, SiteRegistry and DomainBinding; nothing is mocked. The only things created on the
///         fork are a throwaway processor (through the real factory) and a three-gate circuit on it.
///
///         RPC: env XLAYER_RPC_URL, default https://rpc.xlayer.tech, fallback https://xlayerrpc.okx.com.
abstract contract XLayerFork is Test, SitePublisher {
    /// @dev 2026-10-04 20:17:16 UTC. Base fee 0.02 gwei, 275 processors, opening fee 0.08 OKB, name fee 0.026 OKB.
    uint256 internal constant FORK_BLOCK = 72_376_000;

    string internal constant PRIMARY_RPC = "https://rpc.xlayer.tech";
    string internal constant FALLBACK_RPC = "https://xlayerrpc.okx.com";

    /// @dev What a transaction pays per gas on X Layer at the pinned block: base fee 0.02 gwei + 1 wei tip.
    ///      Receipts carry l1Fee = 0 (both L1 fee scalars are zero), so this is the whole cost of gas.
    uint256 internal constant GAS_PRICE = 0.02 gwei + 1;

    /// @dev Three NAND gates computing AND-ish of two inputs: the smallest useful netlist (TAP-20).
    bytes internal constant NAND3 = hex"000000020000030000000400000400000005000005";
    uint256 internal constant MINT_PRICE = 0.00002 ether;

    string internal constant WEB_DIST = "../../../web/dist";
    string internal constant FIXTURE = "test/fixtures/site";
    string internal constant FIXTURE_V2 = "test/fixtures/site-v2";

    ICircuits internal circuits;
    ITransistors internal transistors;

    function _fork() internal {
        string memory url = vm.envOr("XLAYER_RPC_URL", PRIMARY_RPC);
        try vm.createSelectFork(url, FORK_BLOCK) {}
        catch {
            vm.createSelectFork(FALLBACK_RPC, FORK_BLOCK);
        }
        assertEq(block.chainid, XLayer.CHAIN_ID, "not X Layer");
        assertEq(block.number, FORK_BLOCK);
        assertEq(FACTORY.cpuCount(), 275, "processors at the pinned block");
    }

    /// @dev `creator` creates a processor through the real factory, paying the real deploy fee.
    function _createProcessor(address creator) internal {
        uint256 fee = FACTORY.deployFee();
        vm.deal(creator, creator.balance + fee);
        vm.prank(creator);
        (address t, address c) = FACTORY.createCPU{value: fee}(
            "DeWEB publication test", "DWT", "A throwaway processor that exists only on a local fork.", 1_000_000, MINT_PRICE
        );
        transistors = ITransistors(t);
        circuits = ICircuits(c);
        assertTrue(FACTORY.isCPU(c), "the new processor is registered");
        assertEq(FACTORY.cpuAt(275), c, "it is processor number 275");
    }

    /// @dev `who` buys three NAND transistors and tapes out the three-gate netlist; `who` then holds the circuit.
    function _tapeout(address who) internal returns (uint256 circuitId) {
        uint256 mintCost = MINT_PRICE * 3 + transistors.protocolFee();
        uint256 fee = circuits.TAPEOUT_FEE();
        vm.deal(who, who.balance + mintCost + fee);
        vm.prank(who);
        transistors.mint{value: mintCost}(0, 3);
        vm.prank(who);
        circuitId = circuits.tapeout{value: fee}(NAND3, 2, 1);
        assertEq(circuits.ownerOf(circuitId), who, "the circuit belongs to the address that taped it out");
    }

    /// @dev web/dist when the build output exists, otherwise the fixture (and says so).
    function _siteDir() internal view returns (string memory dir, bool isBuild) {
        isBuild = vm.isFile(string.concat(vm.projectRoot(), "/", WEB_DIST, "/index.html"));
        dir = isBuild ? WEB_DIST : FIXTURE;
        if (!isBuild) console2.log("NOTE: web/dist/index.html is missing; the fixture site is used instead");
    }

    struct Measured {
        uint256[] gasUsed; // what a receipt would show: gas used minus refund
        uint256 totalGas;
        uint256 totalValue;
    }

    /// @dev Executes the plan as `sender`, one call per transaction (the project runs tests in isolate mode),
    ///      and returns the gas of each.
    function _execute(Step[] memory steps, address sender) internal returns (Measured memory m) {
        m.gasUsed = new uint256[](steps.length);
        vm.deal(sender, sender.balance + valueOf(steps));
        for (uint256 i; i < steps.length; i++) {
            vm.prank(sender, sender);
            (bool ok, bytes memory ret) = steps[i].target.call{value: steps[i].value}(steps[i].data);
            Vm.Gas memory g = vm.lastFrameGas();
            if (!ok) {
                console2.log("step failed:", steps[i].label);
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            m.gasUsed[i] = uint256(g.gasTotalUsed) - uint256(int256(g.gasRefunded));
            m.totalGas += m.gasUsed[i];
            m.totalValue += steps[i].value;
        }
    }

    function _logMeasured(string memory title, Step[] memory steps, Measured memory m) internal pure {
        console2.log("");
        console2.log(title);
        for (uint256 i; i < steps.length; i++) {
            console2.log(string.concat("  ", vm.toString(i + 1), ". ", steps[i].label));
            console2.log("       gas / calldata bytes / value (wei):", m.gasUsed[i], steps[i].data.length, steps[i].value);
        }
        console2.log("  transactions            ", steps.length);
        console2.log("  total gas               ", m.totalGas);
        console2.log("  gas cost (wei, 0.02 gwei + 1 wei per gas)", m.totalGas * GAS_PRICE);
        console2.log("  protocol fees (wei)     ", m.totalValue);
        console2.log("  total cost (wei)        ", m.totalGas * GAS_PRICE + m.totalValue);
    }

    /// @dev Leaves the measurement in measured/<name>.json for tools/deweb/test/plan-vs-fork.test.ts.
    function _writeMeasured(
        string memory name,
        string memory siteDir,
        Target memory t,
        Options memory o,
        Step[] memory steps,
        Measured memory m
    ) internal {
        vm.serializeString(name, "siteDir", siteDir);
        vm.serializeUint(name, "forkBlock", block.number);
        _serializeTarget(name, t);
        vm.serializeUint(name, "months", o.months);
        vm.serializeString(name, "fallbackPath", o.fallbackPath);
        vm.serializeBool(name, "prune", o.prune);
        _serializeSteps(name, steps);
        vm.serializeUint(name, "gasUsed", m.gasUsed);
        string memory json = vm.serializeUint(name, "totalGas", m.totalGas);
        vm.createDir("measured", true);
        vm.writeJson(json, string.concat("measured/", name, ".json"));
    }

    function _serializeTarget(string memory k, Target memory t) private {
        vm.serializeAddress(k, "processor", t.processor);
        vm.serializeUint(k, "processorNumber", t.processorNumber);
        vm.serializeUint(k, "circuitId", t.circuitId);
        vm.serializeAddress(k, "holder", t.holder);
        vm.serializeAddress(k, "container", t.container);
        vm.serializeString(k, "name", t.name);
        vm.serializeBool(k, "opened", t.opened);
        vm.serializeBool(k, "live", t.live);
        // as strings: the fees do not fit a JavaScript number
        vm.serializeString(k, "openFee", vm.toString(t.openFee));
        vm.serializeString(k, "monthlyFee", vm.toString(t.monthlyFee));
    }

    function _serializeSteps(string memory k, Step[] memory steps) private {
        uint256 n = steps.length;
        uint256[] memory kinds = new uint256[](n);
        address[] memory targets = new address[](n);
        string[] memory values = new string[](n);
        bytes32[] memory hashes = new bytes32[](n);
        uint256[] memory sizes = new uint256[](n);
        string[] memory labels = new string[](n);
        for (uint256 i; i < n; i++) {
            kinds[i] = steps[i].kind;
            targets[i] = steps[i].target;
            values[i] = vm.toString(steps[i].value);
            hashes[i] = keccak256(steps[i].data);
            sizes[i] = steps[i].data.length;
            labels[i] = steps[i].label;
        }
        vm.serializeUint(k, "kinds", kinds);
        vm.serializeAddress(k, "targets", targets);
        vm.serializeString(k, "values", values);
        vm.serializeBytes32(k, "calldataHashes", hashes);
        vm.serializeUint(k, "calldataBytes", sizes);
        vm.serializeString(k, "labels", labels);
    }
}
