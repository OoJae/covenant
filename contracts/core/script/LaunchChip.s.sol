// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Envelope} from "../src/interfaces/IKernelV1.sol";
import {IKernelExt} from "../src/interfaces/IKernelExt.sol";
import {KernelFactory} from "../src/KernelFactory.sol";
import {Lens} from "../src/Lens.sol";

interface IFabLaunch {
    function CIRCUITS() external view returns (address);
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
    function tapeoutChip(bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256 chipId);
}

interface ICircuitsLaunch {
    function ownerOf(uint256 id) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

/// @title LaunchChip: tapes a chip out through the Fab, creates its kernel and hands the chip to the kernel
/// @notice Three transactions from one account: `Fab.tapeoutChip`, `KernelFactory.create`, and the transfer of
///         the circuit NFT to the kernel. Afterwards the kernel holds its chip and waits for `bind(token)`; the
///         token is launched at ignix.bot with the kernel as the Directed vault's recipient.
///
///         Inputs (environment):
///           COVENANT_FAB, COVENANT_FACTORY, COVENANT_LENS   this deployment's contracts
///           NETLIST_HEX     the chip's netlist bytes (0x...), e.g. $(cat chips/out/fg.hex)
///           MANIFEST_HASH   SHA-256 of the chip's pin manifest (bytes32)
///           ALLOWANCE_PAYEE the envelope's allowance payee (the KeeperTank for the reference token)
///           SALT            optional, bytes32, default 0
///         The envelope is the reference token's (chips/rtl/fg_params.json): epoch 900 s, capT 48,
///         allowCumBps 1875, ceilMax 440, relMax 128, floorRel 2, floorMin 1, fallbackEpochs 16, fbAllow 8,
///         buys enabled. The launcher is the account that runs this script.
///
///         Simulate first (sends nothing):
///           forge script script/LaunchChip.s.sol --rpc-url https://rpc.xlayer.tech --sender <deployer>
contract LaunchChip is Script {
    uint256 internal constant XLAYER_CHAIN_ID = 196;

    function referenceEnvelope(address launcher, address allowancePayee) public pure returns (Envelope memory e) {
        e.launcher = launcher;
        e.epochLen = 900;
        e.allowancePayee = allowancePayee;
        e.capT = 48;
        e.capV = 0;
        e.allowCumBps = 1875;
        e.ceilMax = 440;
        e.relMax = 128;
        e.floorRel = 2;
        e.floorMin = 1;
        e.fallbackEpochs = 16;
        e.fbAllow = 8;
        e.buyEnabled = true;
        e.sink = address(0);
    }

    function run() external {
        if (block.chainid != XLAYER_CHAIN_ID && !vm.envOr("REHEARSAL", false)) {
            revert("LaunchChip: not X Layer (chain id 196); only a rehearsal (REHEARSAL=true) may run elsewhere");
        }
        IFabLaunch fab = IFabLaunch(vm.envAddress("COVENANT_FAB"));
        KernelFactory factory = KernelFactory(vm.envAddress("COVENANT_FACTORY"));
        Lens lens = Lens(vm.envAddress("COVENANT_LENS"));
        bytes memory netlist = vm.envBytes("NETLIST_HEX");
        bytes32 manifestHash = vm.envBytes32("MANIFEST_HASH");
        address payee = vm.envAddress("ALLOWANCE_PAYEE");
        bytes32 salt = vm.envOr("SALT", bytes32(0));

        require(address(fab).code.length != 0, "LaunchChip: COVENANT_FAB has no code");
        require(address(factory).code.length != 0, "LaunchChip: COVENANT_FACTORY has no code");
        require(address(lens).code.length != 0, "LaunchChip: COVENANT_LENS has no code");
        require(payee.code.length != 0, "LaunchChip: ALLOWANCE_PAYEE has no code (expected the KeeperTank)");
        require(manifestHash != bytes32(0), "LaunchChip: MANIFEST_HASH is zero");
        require(factory.fab() == address(fab), "LaunchChip: the factory was built for another Fab");

        ICircuitsLaunch circuits = ICircuitsLaunch(fab.CIRCUITS());
        (uint256 nNand, uint256 nLatch, uint256 cost) = fab.quote(netlist);
        console2.log("chip: NAND, LATCH", nNand, nLatch);
        console2.log("chip: netlist bytes", netlist.length);
        console2.log("tape-out cost (wei)", cost);

        vm.startBroadcast();
        (, address launcher,) = vm.readCallers();
        Envelope memory env = referenceEnvelope(launcher, payee);

        uint256 chipId = fab.tapeoutChip{value: cost}(netlist, manifestHash);
        address kernel = factory.create(env, chipId, salt);
        circuits.safeTransferFrom(launcher, kernel, chipId);
        vm.stopBroadcast();

        require(circuits.ownerOf(chipId) == kernel, "LaunchChip: the kernel does not hold its chip");
        require(IKernelExt(kernel).chipId() == chipId, "LaunchChip: kernel chip id mismatch");
        require(IKernelExt(kernel).token() == address(0), "LaunchChip: kernel already bound");
        Lens.Preflight memory p = lens.preflight(kernel);
        require(p.tapeoutRan && p.sealedRan && p.agree, "LaunchChip: preflight failed");

        console2.log("chip id", chipId);
        console2.log("kernel", kernel);
        console2.log("launcher (must create the token)", launcher);
        console2.log("preflight: TapeOut step gas", p.tapeoutGas, "of", p.stepFloor);
        console2.log("preflight: sealed step gas", p.sealedGas, "of", p.sealedFloor);
        console2.log("minSettleGas", p.minSettleGas);
    }
}
