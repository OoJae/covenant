// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {ICircuitFactory, ICircuits, ITransistors} from "../../src/interfaces/ITapeOut.sol";

/// @dev The parts of TapeOut's ICPU the fork tests use to show a taped-out circuit really evaluates.
interface ICpuEval {
    function eval(uint256 circuitId, bytes calldata inputs) external view returns (bytes memory outputs);
}

/// @notice X Layer mainnet (chain 196) forked at a pinned block. Every test here talks to the REAL TapeOut
///         factory; nothing on the fork is mocked except kernels, keepers and maintainers, which do not exist
///         yet.
///
///         RPC: env XLAYER_RPC_URL, default https://rpc.xlayer.tech, fallback https://xlayerrpc.okx.com.
abstract contract XLayerFork is Test {
    address internal constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;

    /// @dev 2026-10-04 18:37:16 UTC. Base fee 0.02 gwei, 275 processors, deployFee 0.0066 OKB.
    uint256 internal constant FORK_BLOCK = 72_370_000;

    string internal constant PRIMARY_RPC = "https://rpc.xlayer.tech";
    string internal constant FALLBACK_RPC = "https://xlayerrpc.okx.com";

    bytes internal constant NAND3 = hex"000000020000030000000400000400000005000005";
    bytes20 internal constant COMMIT = hex"a1b2c3d4e5f60718293a4b5c6d7e8f9001234567";

    uint256 internal constant PRICE = 0.00002 ether;
    uint256 internal constant PROTOCOL_FEE = 0.00066 ether;
    uint256 internal constant TAPEOUT_FEE = 0.0013 ether;

    bytes32 internal constant REFUNDED_SIG = keccak256("Refunded(uint256,address,address,uint256,uint256)");

    address internal maintainer = makeAddr("maintainer");
    address internal user = makeAddr("user");
    address internal keeper = makeAddr("keeper");

    Splitter internal splitter;
    KeeperTank internal tank;
    TeamRegistry internal registry;
    ITransistors internal transistors;
    ICircuits internal circuits;

    /// @dev gas of the transaction that deployed the Splitter (intrinsic gas included)
    uint256 internal igniteGas;
    uint256 internal gasPrice;

    function _fork() internal {
        string memory url = vm.envOr("XLAYER_RPC_URL", PRIMARY_RPC);
        try vm.createSelectFork(url, FORK_BLOCK) {}
        catch {
            vm.createSelectFork(FALLBACK_RPC, FORK_BLOCK);
        }
        assertEq(block.chainid, 196, "not X Layer");
        assertEq(block.number, FORK_BLOCK);

        // Transactions in these tests pay what a transaction pays on X Layer at this block: base fee + 1 wei.
        // The base fee is re-applied with vm.fee on purpose: in forge's isolate mode a forked block's base fee
        // reads as zero inside a transaction until it is set explicitly (forge 1.8.3; see NOTES.md).
        // The value read here is the fork block's own base fee, and vm.fee sets it to that same value.
        // forge-lint: disable-next-line(environment-read-across-mutation)
        uint256 baseFee = block.basefee;
        assertEq(baseFee, 0.02 gwei, "base fee at the pinned block");
        vm.fee(baseFee);
        gasPrice = baseFee + 1;
        vm.txGasPrice(gasPrice);
    }

    function _ignite(address maintainer_) internal returns (Splitter s) {
        uint256 fee = ICircuitFactory(FACTORY).deployFee();
        s = new Splitter{value: fee}(FACTORY, maintainer_, COMMIT);
        igniteGas = vm.lastFrameGas().gasTotalUsed;
    }

    function _forkAndIgnite() internal {
        _fork();
        splitter = _ignite(maintainer);
        tank = KeeperTank(payable(splitter.TANK()));
        registry = TeamRegistry(splitter.REGISTRY());
        transistors = ITransistors(splitter.TRANSISTORS());
        circuits = ICircuits(splitter.CIRCUITS());
        vm.deal(user, 100 ether);
    }

    function _mint(address who, uint256 id, uint256 amount) internal {
        vm.deal(who, who.balance + PRICE * amount + PROTOCOL_FEE);
        vm.prank(who);
        transistors.mint{value: PRICE * amount + PROTOCOL_FEE}(id, amount);
    }

    /// @dev `who` buys three NAND transistors and tapes out the 3-NAND netlist
    function _tapeoutNand3(address who) internal returns (uint256 chipId) {
        _mint(who, 0, 3);
        vm.deal(who, who.balance + TAPEOUT_FEE);
        vm.prank(who);
        chipId = circuits.tapeout{value: TAPEOUT_FEE}(NAND3, 2, 1);
    }

    struct Settled {
        uint256 gasCounted;
        uint256 paid;
        uint256 txGas;
        uint256 txGasBilled;
    }

    function _settleAs(address caller, address kernel) internal returns (Settled memory r) {
        vm.recordLogs();
        vm.prank(caller, caller);
        tank.settleAndRefund(kernel);
        Vm.Gas memory g = vm.lastFrameGas();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(tank) && logs[i].topics[0] == REFUNDED_SIG) {
                (r.gasCounted, r.paid) = abi.decode(logs[i].data, (uint256, uint256));
                found = true;
            }
        }
        require(found, "no Refunded event");
        r.txGas = g.gasTotalUsed;
        r.txGasBilled = g.gasTotalUsed - uint256(int256(g.gasRefunded));
    }
}
