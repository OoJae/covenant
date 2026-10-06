// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Splitter} from "../src/Splitter.sol";
import {KeeperTank} from "../src/KeeperTank.sol";
import {ICircuitFactory, ICircuits, ITransistors} from "../src/interfaces/ITapeOut.sol";
import {IOwnable} from "../src/interfaces/IOwnable.sol";
import {Story} from "./lib/Story.sol";

/// @title Ignite - deploys the Splitter, which creates the Covenant processor, the KeeperTank and the
///        TeamRegistry.
///
/// @notice IRREVERSIBLE when broadcast. The human runs script/ignite.sh, never this script by hand: the
///         wrapper checks that the source is committed and public, sets COMMIT and simulates first.
///         See README.md for the exact commands.
///
///         Environment:
///           MAINTAINER  address that receives 15% of mint proceeds. Must be the deploying account.
///           COMMIT      git commit of the source, 40 hex characters (with or without 0x)
///           REHEARSAL   optional, `true` only for a rehearsal on a local fork whose chain id is not 196
///
///         Before anything is sent it prints every planned address, the whole story and the first 600
///         characters of the story (all that TapeOut's own site shows). After the creation it stops with an
///         error unless the story on-chain is that planned story, byte for byte.
contract Ignite is Script {
    /// @dev TapeOut's CircuitFactory on X Layer.
    address internal constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    uint256 internal constant X_LAYER_CHAIN_ID = 196;

    /// @dev What a creation by `deployer` at its current nonce will produce, known before anything is sent.
    struct Plan {
        address splitter;
        address registry;
        address tank;
        address transistors; // created by TapeOut's factory: holds only if no other processor is created first
        address circuits; // the same
        string story;
    }

    function run() external returns (Splitter splitter) {
        address maintainer = vm.envAddress("MAINTAINER");
        bytes20 commit = parseCommit(vm.envString("COMMIT"));
        return ignite(maintainer, commit, vm.envOr("REHEARSAL", false));
    }

    function ignite(address maintainer, bytes20 commit, bool rehearsal) public returns (Splitter splitter) {
        require(
            block.chainid == X_LAYER_CHAIN_ID || rehearsal,
            "Ignite: not X Layer (chain id 196); only a rehearsal (REHEARSAL=true) may run elsewhere"
        );
        require(commit != bytes20(0), "Ignite: COMMIT is zero");
        require(FACTORY.code.length != 0, "Ignite: factory has no code");

        address deployer = _signer();
        require(maintainer == deployer, "Ignite: MAINTAINER is not the deploying account");

        // Everything is read, planned and printed before the one transaction is put together.
        uint256 deployFee = ICircuitFactory(FACTORY).deployFee();
        Plan memory p = plan(deployer, maintainer, commit);
        _announce(p, deployer, commit, deployFee);

        vm.startBroadcast();
        splitter = new Splitter{value: deployFee}(FACTORY, maintainer, commit);
        vm.stopBroadcast();

        _verify(splitter, p);
    }

    /// @dev The account `vm.startBroadcast()` sends from: the one that signs.
    function _signer() internal returns (address who) {
        vm.startBroadcast();
        (, who,) = vm.readCallers();
        vm.stopBroadcast();
    }

    /// @notice Accepts a git SHA-1 as 40 hex characters, with or without a 0x prefix.
    function parseCommit(string memory text) public pure returns (bytes20) {
        bytes memory t = bytes(text);
        bool prefixed = t.length >= 2 && t[0] == "0" && t[1] == "x";
        bytes memory raw = vm.parseBytes(prefixed ? text : string.concat("0x", text));
        require(raw.length == 20, "Ignite: COMMIT must be exactly 20 bytes (40 hex characters)");
        return bytes20(raw);
    }

    /// @notice The addresses and the story of a creation sent by `deployer` at its current nonce.
    /// @dev    A contract's nonce starts at 1. The Splitter creates the registry and then the tank; TapeOut's
    ///         factory creates the Transistors clone and then the Circuits clone.
    function plan(address deployer, address maintainer, bytes20 commit) public view virtual returns (Plan memory p) {
        p.splitter = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        p.registry = vm.computeCreateAddress(p.splitter, 1);
        p.tank = vm.computeCreateAddress(p.splitter, 2);
        uint256 factoryNonce = vm.getNonce(FACTORY);
        p.transistors = vm.computeCreateAddress(FACTORY, factoryNonce);
        p.circuits = vm.computeCreateAddress(FACTORY, factoryNonce + 1);
        p.story = Story.expected(p.splitter, p.tank, maintainer, p.registry, commit);
    }

    /// @dev Everything the human signs off, printed before the creation transaction exists.
    function _announce(Plan memory p, address deployer, bytes20 commit, uint256 deployFee) internal view {
        console2.log("== Covenant ignition ==");
        console2.log("chain id              ", block.chainid);
        console2.log("block                 ", block.number);
        console2.log("TapeOut factory       ", FACTORY);
        console2.log("  deployFee (wei)     ", deployFee);
        console2.log("  protocolFee (wei)   ", ICircuitFactory(FACTORY).protocolFee());
        console2.log("  sealed              ", ICircuitFactory(FACTORY).isSealed());
        console2.log("  owner right now     ", IOwnable(FACTORY).owner());
        console2.log("deployer = maintainer ", deployer);
        console2.log("  nonce               ", vm.getNonce(deployer));
        console2.log("  balance (wei)       ", deployer.balance);
        console2.log("commit                ", Story.commitHex(commit));
        console2.log("");
        console2.log("== Planned addresses (nothing has been sent yet) ==");
        console2.log("Splitter (creator)    ", p.splitter);
        console2.log("TeamRegistry          ", p.registry);
        console2.log("KeeperTank            ", p.tank);
        console2.log("Transistors (ERC-1155)", p.transistors);
        console2.log("Circuits (ERC-721)    ", p.circuits);
        console2.log("(the last two are created by TapeOut's factory: they hold only if nobody else creates a");
        console2.log(" processor first, and they are not part of the story)");
        console2.log("");
        console2.log("== Planned story (nothing has been sent yet) ==");
        console2.log("length (bytes)        ", bytes(p.story).length);
        console2.log("keccak256             ", vm.toString(keccak256(bytes(p.story))));
        console2.log(p.story);
        console2.log("");
        console2.log("== Its first 600 characters: all that TapeOut's own site shows ==");
        console2.log(Story.shown(p.story));
    }

    /// @dev What was created must be what was announced. Then the same checks the fork tests make, repeated
    ///      on whatever this run produced.
    function _verify(Splitter splitter, Plan memory p) internal view {
        ITransistors transistors = ITransistors(splitter.TRANSISTORS());
        ICircuits circuits = ICircuits(splitter.CIRCUITS());
        KeeperTank tank = KeeperTank(payable(splitter.TANK()));
        address registry = splitter.REGISTRY();
        string memory story = transistors.story();

        require(keccak256(bytes(story)) == keccak256(bytes(p.story)), "Ignite: story differs from the planned story");
        require(
            address(splitter) == p.splitter && registry == p.registry && address(tank) == p.tank
                && address(transistors) == p.transistors && address(circuits) == p.circuits,
            "Ignite: an address differs from the plan"
        );
        require(ICircuitFactory(FACTORY).isCPU(address(circuits)), "Ignite: processor not registered");
        require(transistors.creator() == address(splitter), "Ignite: creator is not the splitter");
        require(transistors.supplyCap() == 67_108_864, "Ignite: supply");
        require(transistors.mintPrice() == 0.00002 ether, "Ignite: price");
        require(tank.SPLITTER() == address(splitter) && tank.circuits() == address(circuits), "Ignite: tank wiring");
        require(ICircuitFactory(FACTORY).owed(address(splitter)) == 0, "Ignite: overpaid the deploy fee");

        console2.log("");
        console2.log("== Created in this run (story on-chain equals the planned story: checked) ==");
        console2.log("Splitter (creator)    ", address(splitter));
        console2.log("TeamRegistry          ", registry);
        console2.log("KeeperTank            ", address(tank));
        console2.log("Transistors (ERC-1155)", address(transistors));
        console2.log("Circuits (ERC-721)    ", address(circuits));
        console2.log("Maintainer            ", splitter.MAINTAINER());
        console2.log("name / symbol         ", transistors.cpuName(), "/", transistors.cpuSymbol());
        console2.log("supply cap            ", transistors.supplyCap());
        console2.log("mint price (wei)      ", transistors.mintPrice());
        console2.log("(after a broadcast, read TRANSISTORS() and CIRCUITS() from the Splitter: see README.md)");
    }
}
