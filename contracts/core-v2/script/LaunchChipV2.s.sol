// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Envelope} from "core/interfaces/IKernelV1.sol";
import {KernelFactoryV2} from "../src/KernelFactoryV2.sol";
import {KernelMathV2} from "../src/KernelMathV2.sol";
import {KernelV2} from "../src/KernelV2.sol";
import {LensV2} from "../src/LensV2.sol";

interface IFabLaunchV2 {
    function CIRCUITS() external view returns (address);
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
    function tapeoutChip(bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256 chipId);
}

interface ICircuitsLaunchV2 {
    function ownerOf(uint256 id) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

/// @title LaunchChipV2: tapes the Flow Governor out through the Fab, creates its v2 kernel, hands the chip over
/// @notice Three transactions from one account: `Fab.tapeoutChip`, `KernelFactoryV2.create` and the transfer of
///         the circuit NFT to the kernel. Afterwards the kernel holds its chip and waits for `bind(token)`; the
///         token is launched at ignix.bot as a Directed token quoted in USD₮0 with the kernel as recipient.
///
///         Inputs (environment):
///           COVENANT_FACTORY_V2, COVENANT_LENS_V2   the contracts DeployCoreV2 created
///           ALLOWANCE_PAYEE   receives the allowance, in USD₮0. Not the KeeperTank: it has no way to move an
///                             ERC-20, so USD₮0 credited to it would stay there for ever
///           COVENANT_FAB      optional, default the live Fab
///           NETLIST_HEX       optional, default chips/out/fg.hex (the Flow Governor, chip 2's netlist)
///           MANIFEST_HASH     optional, default the Flow Governor's manifest hash (deployments/xlayer.json)
///           SALT              optional, bytes32, default 0
///         The envelope is the reference envelope of the Flow Governor (chips/rtl/fg_params.json), number for
///         number, in the chip's code space: through the 33-bit shift, ceilMax 440 caps the allowance at
///         3.932160 USD₮0 per settle and floorMin 1 applies the reserve floor to any non-zero reserve.
///
///         Chain guard: X Layer (196) only, unless REHEARSAL=true on another chain id (ignored on 196). Simulate
///         first, from a scratch copy:
///           forge script script/LaunchChipV2.s.sol --rpc-url https://rpc.xlayer.tech --sender <launcher>
contract LaunchChipV2 is Script {
    uint256 internal constant XLAYER_CHAIN_ID = 196;
    address internal constant DEFAULT_FAB = 0xdCAc8c47aF534dC0cDE30f60056bCe7D63a79aFE;
    address internal constant KEEPER_TANK = 0xb89BCe53822a99503A937C22974F1224D9Ab6352;
    bytes32 internal constant FG_MANIFEST_HASH = 0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209;
    bytes32 internal constant FG_NETLIST_KECCAK = 0xe548768a1adafa7331faacfd029e1a829b00af3f7d769657f3b234ccdd7143b4;

    struct Inputs {
        IFabLaunchV2 fab;
        KernelFactoryV2 factory;
        LensV2 lens;
        bytes netlist;
        bytes32 manifestHash;
        address payee;
        bytes32 salt;
    }

    /// The reference v2 envelope. Same numbers as kernel v1's (LaunchChip.referenceEnvelope); what they mean in
    /// USD₮0 is in NOTES.md section 3.
    function referenceEnvelope(address launcher, address allowancePayee) public pure returns (Envelope memory e) {
        e.launcher = launcher;
        e.epochLen = 900;
        e.allowancePayee = allowancePayee;
        e.capT = 48; // at most 18.75% of a settle's USD₮0 inflow
        e.capV = 0;
        e.allowCumBps = 1875; // at most 18.75% of all USD₮0 inflow on the curve
        e.ceilMax = 440; // exp8(440) >> 33 = 3,932,160 base units: 3.932160 USD₮0 per settle
        e.relMax = 128;
        e.floorRel = 2;
        e.floorMin = 1; // lg8(reserve << 33) >= 1 for every reserve of at least one base unit
        e.fallbackEpochs = 16;
        e.fbAllow = 8;
        e.buyEnabled = true;
        e.sink = address(0);
    }

    function run() external {
        Inputs memory p;
        p.fab = IFabLaunchV2(vm.envOr("COVENANT_FAB", DEFAULT_FAB));
        p.factory = KernelFactoryV2(vm.envAddress("COVENANT_FACTORY_V2"));
        p.lens = LensV2(vm.envAddress("COVENANT_LENS_V2"));
        p.payee = vm.envAddress("ALLOWANCE_PAYEE");
        p.manifestHash = vm.envOr("MANIFEST_HASH", FG_MANIFEST_HASH);
        p.salt = vm.envOr("SALT", bytes32(0));
        p.netlist = vm.envOr("NETLIST_HEX", bytes(""));
        if (p.netlist.length == 0) {
            p.netlist = vm.parseBytes(vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/../../chips/out/fg.hex"))));
            require(keccak256(p.netlist) == FG_NETLIST_KECCAK, "LaunchChipV2: chips/out/fg.hex is not chip 2's netlist");
        }
        launch(p);
    }

    /// @notice REHEARSAL=true counts only on a chain other than X Layer (as in DeployCoreV2).
    function rehearsalAllowed() public view returns (bool) {
        return vm.envOr("REHEARSAL", false) && block.chainid != XLAYER_CHAIN_ID;
    }

    function launch(Inputs memory p) public returns (uint256 chipId, address kernel) {
        require(
            block.chainid == XLAYER_CHAIN_ID || rehearsalAllowed(), "LaunchChipV2: not X Layer (196); REHEARSAL=true only"
        );
        require(address(p.fab).code.length != 0, "LaunchChipV2: the Fab has no code");
        require(address(p.factory).code.length != 0, "LaunchChipV2: the factory has no code");
        require(address(p.lens).code.length != 0, "LaunchChipV2: the Lens has no code");
        require(address(p.lens.FACTORY()) == address(p.factory), "LaunchChipV2: the Lens reads another factory");
        require(p.factory.fab() == address(p.fab), "LaunchChipV2: the factory was built for another Fab");
        require(p.payee != address(0), "LaunchChipV2: ALLOWANCE_PAYEE is zero");
        require(p.payee != KEEPER_TANK, "LaunchChipV2: the KeeperTank cannot move USDT0; choose another payee");
        require(p.manifestHash != bytes32(0), "LaunchChipV2: MANIFEST_HASH is zero");

        ICircuitsLaunchV2 circuits = ICircuitsLaunchV2(p.fab.CIRCUITS());
        (uint256 nNand, uint256 nLatch, uint256 cost) = p.fab.quote(p.netlist);

        vm.startBroadcast();
        (, address launcher,) = vm.readCallers();
        Envelope memory env = referenceEnvelope(launcher, p.payee);
        chipId = p.fab.tapeoutChip{value: cost}(p.netlist, p.manifestHash);
        kernel = p.factory.create(env, chipId, p.salt);
        circuits.safeTransferFrom(launcher, kernel, chipId);
        vm.stopBroadcast();

        KernelV2 k = KernelV2(kernel);
        require(circuits.ownerOf(chipId) == kernel, "LaunchChipV2: the kernel does not hold its chip");
        require(k.chipId() == chipId, "LaunchChipV2: kernel chip id mismatch");
        require(k.token() == address(0), "LaunchChipV2: kernel already bound");
        require(k.quote() == p.factory.quote() && k.quoteShift() == p.factory.quoteShift(), "LaunchChipV2: quote pins");
        LensV2.Preflight memory pf = p.lens.preflight(kernel);
        require(pf.tapeoutRan && pf.sealedRan && pf.agree, "LaunchChipV2: preflight failed");

        console2.log("chip: NAND, LATCH, bytes", nNand, nLatch, p.netlist.length);
        console2.log("tape-out cost (wei)", cost);
        console2.log("chip id", chipId);
        console2.log("kernel (the Directed vault's recipient, and the x402 payTo)", kernel);
        console2.log("launcher (must create the token, quote USDT0)", launcher);
        console2.log("allowance payee (USDT0)", p.payee);
        console2.log("allowance ceiling per settle (USDT0 base units)", KernelMathV2.exp8s(env.ceilMax, k.quoteShift()));
        console2.log("preflight: TapeOut step gas", pf.tapeoutGas, "of", pf.stepFloor);
        console2.log("preflight: sealed step gas", pf.sealedGas, "of", pf.sealedFloor);
        console2.log("minSettleGas", pf.minSettleGas);
    }
}
