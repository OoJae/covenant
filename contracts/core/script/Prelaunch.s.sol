// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IFabPrelaunch {
    function CIRCUITS() external view returns (address);
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
    function tapeoutChip(bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256 chipId);
}

interface ICircuitsPrelaunch {
    function ownerOf(uint256 id) external view returns (address);
    function netlist(uint256 id) external view returns (bytes memory);
}

interface ITeamRegistryPrelaunch {
    function isTeam(address wallet) external view returns (bool);
    function isInvited(address wallet) external view returns (bool);
    function invite(address wallet) external;
}

/// @title Prelaunch: the deployer's last transactions before the reference token is launched
/// @notice Up to three transactions from one account:
///           1. `Fab.tapeoutChip` of the Glutton (asks for the whole tax as allowance, every beat);
///           2. `Fab.tapeoutChip` of the Glutton512 (share groups that sum to 512, which the kernel refuses);
///           3. `TeamRegistry.invite(keeper)`, so the keeper wallet can declare itself before it acts.
///         The two hostile chips stay with the deployer. They are never bound to a kernel: `Lens.shadowChip`
///         runs them over the reference kernel's recorded inputs, inside its envelope, for free.
///         The invite is skipped if the keeper is already invited or listed.
///
///         Inputs (environment):
///           COVENANT_FAB, COVENANT_REGISTRY   this deployment's contracts
///           KEEPER                            the keeper wallet (docs/WALLETS.md)
///           GLUTTON_HEX, GLUTTON512_HEX       the netlists, $(cat chips/cells/glutton/glutton.hex) and glutton512.hex
///           GLUTTON_MANIFEST_HASH             SHA-256 of chips/cells/glutton/glutton.pins.json (both share it)
///
///         Simulate first (sends nothing):
///           forge script script/Prelaunch.s.sol --rpc-url https://rpc.xlayer.tech --sender <deployer>
contract Prelaunch is Script {
    uint256 internal constant XLAYER_CHAIN_ID = 196;

    function run() external {
        if (block.chainid != XLAYER_CHAIN_ID && !vm.envOr("REHEARSAL", false)) {
            revert("Prelaunch: not X Layer (chain id 196); only a rehearsal (REHEARSAL=true) may run elsewhere");
        }
        IFabPrelaunch fab = IFabPrelaunch(vm.envAddress("COVENANT_FAB"));
        ITeamRegistryPrelaunch registry = ITeamRegistryPrelaunch(vm.envAddress("COVENANT_REGISTRY"));
        address keeper = vm.envAddress("KEEPER");
        bytes memory glutton = vm.envBytes("GLUTTON_HEX");
        bytes memory glutton512 = vm.envBytes("GLUTTON512_HEX");
        bytes32 manifestHash = vm.envBytes32("GLUTTON_MANIFEST_HASH");

        require(address(fab).code.length != 0, "Prelaunch: COVENANT_FAB has no code");
        require(address(registry).code.length != 0, "Prelaunch: COVENANT_REGISTRY has no code");
        require(keeper != address(0) && keeper.code.length == 0, "Prelaunch: KEEPER must be a wallet");
        require(manifestHash != bytes32(0), "Prelaunch: GLUTTON_MANIFEST_HASH is zero");
        require(keccak256(glutton) != keccak256(glutton512), "Prelaunch: the two netlists are the same");
        ICircuitsPrelaunch circuits = ICircuitsPrelaunch(fab.CIRCUITS());

        (,, uint256 cost) = fab.quote(glutton);
        (,, uint256 cost512) = fab.quote(glutton512);
        bool invite = !registry.isInvited(keeper) && !registry.isTeam(keeper);
        console2.log("Glutton tape-out cost (wei)   ", cost);
        console2.log("Glutton512 tape-out cost (wei)", cost512);
        console2.log("keeper invite                 ", invite ? "yes" : "no (already invited or listed)");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        uint256 id = fab.tapeoutChip{value: cost}(glutton, manifestHash);
        uint256 id512 = fab.tapeoutChip{value: cost512}(glutton512, manifestHash);
        if (invite) registry.invite(keeper);
        vm.stopBroadcast();

        require(circuits.ownerOf(id) == deployer && circuits.ownerOf(id512) == deployer, "Prelaunch: chip owner");
        require(keccak256(circuits.netlist(id)) == keccak256(glutton), "Prelaunch: Glutton netlist");
        require(keccak256(circuits.netlist(id512)) == keccak256(glutton512), "Prelaunch: Glutton512 netlist");
        require(registry.isInvited(keeper) || registry.isTeam(keeper), "Prelaunch: keeper not invited");

        console2.log("Glutton chip id   ", id);
        console2.log("Glutton512 chip id", id512);
        console2.log("held by           ", deployer);
        console2.log("keeper invited    ", keeper);
    }
}
