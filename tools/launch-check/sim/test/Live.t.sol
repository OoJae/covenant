// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {LaunchSim} from "../src/LaunchSim.sol";

/// @notice The launch-day simulation. It reads the transaction the wallet shows and runs it on a fork.
///
///         Input: LAUNCH_INPUT = path of a JSON file inside sim/inputs, written by tools/launch-check/simulate.ts:
///               { "from": "0x..", "to": "0x..", "value": "0", "data": "0x..", "kernel": "0x..",
///                 "block": 0, "skipKernelChecks": false,
///                 "deployment": { "kernelFactory": "0x..", "circuits": "0x..", "fab": "0x..",
///                                 "sealedVM": "0x..", "lens": "0x..", "chipId": "2" } }
///         "block" 0 (or absent) forks the latest block and runs the transaction at the later of the chain's
///         clock and this machine's clock; a block number forks that block and runs the transaction in the next.
///         The fork is of XLAYER_RPC_URL (default https://rpc.xlayer.tech): a local anvil fork works the same way.
///
///         The full simulation REQUIRES "deployment": it runs against the deployed Covenant contracts and
///         refuses a kernel that does not belong to them. Without inputs both tests are SKIPPED (never passed);
///         simulate.ts turns a skip into a failure.
contract LiveLaunch is LaunchSim {
    function _inputs() internal view returns (bool has, Inputs memory inp, uint256 forkBlock) {
        string memory path = vm.envOr("LAUNCH_INPUT", string(""));
        if (bytes(path).length == 0) return (false, inp, 0);
        string memory json = vm.readFile(path);
        inp.from = vm.parseJsonAddress(json, ".from");
        inp.to = vm.parseJsonAddress(json, ".to");
        inp.value = vm.parseJsonUint(json, ".value");
        inp.data = vm.parseJsonBytes(json, ".data");
        inp.kernel = vm.parseJsonAddress(json, ".kernel");
        if (vm.keyExistsJson(json, ".block")) forkBlock = vm.parseJsonUint(json, ".block");
        if (vm.keyExistsJson(json, ".skipKernelChecks")) inp.skipKernel = vm.parseJsonBool(json, ".skipKernelChecks");
        if (vm.keyExistsJson(json, ".deployment")) {
            inp.dep.present = true;
            inp.dep.kernelFactory = vm.parseJsonAddress(json, ".deployment.kernelFactory");
            inp.dep.circuits = vm.parseJsonAddress(json, ".deployment.circuits");
            inp.dep.fab = vm.parseJsonAddress(json, ".deployment.fab");
            inp.dep.sealedVM = vm.parseJsonAddress(json, ".deployment.sealedVM");
            inp.dep.lens = vm.parseJsonAddress(json, ".deployment.lens");
            inp.dep.chipId = vm.parseJsonUint(json, ".deployment.chipId");
        }
        return (true, inp, forkBlock);
    }

    function _fork(uint256 forkBlock) internal {
        if (forkBlock == 0) {
            vm.createSelectFork(_rpcUrl());
            uint256 forked = block.number;
            uint256 chainTime = block.timestamp;
            uint256 wallClock = vm.unixTime() / 1000;
            vm.roll(forked + 1);
            vm.warp(wallClock > chainTime ? wallClock : chainTime + 1);
            console2.log("forked X Layer at the latest block", forked);
        } else {
            vm.createSelectFork(_rpcUrl(), forkBlock);
            vm.roll(forkBlock + 1);
            vm.warp(block.timestamp + 1);
            console2.log("forked X Layer at block", forkBlock);
        }
        console2.log("the transaction runs at unix time", block.timestamp);
    }

    /// @notice The full simulation: the kernel against the deployment, create, bind, an outsider's buy, settle.
    function test_launch_simulation_full() public {
        (bool has, Inputs memory inp, uint256 forkBlock) = _inputs();
        if (!has || inp.skipKernel) {
            vm.skip(true);
            return;
        }
        require(
            inp.dep.present,
            "sim: no deployment was given: the full simulation runs against the deployed Covenant contracts (simulate.ts --deployment)"
        );
        _fork(forkBlock);
        _simulate(inp);
        console2.log("SIMULATION COMPLETE: the kernel belongs to the deployment; create, bind, buy and settle all succeeded on the fork.");
    }

    /// @notice Harness self-test only: stops after the creation. It approves nothing.
    function test_launch_simulation_create_only_KERNEL_CHECKS_SKIPPED() public {
        (bool has, Inputs memory inp, uint256 forkBlock) = _inputs();
        if (!has || !inp.skipKernel) {
            vm.skip(true);
            return;
        }
        inp.allowFirstBuy = true;
        _fork(forkBlock);
        _simulate(inp);
        console2.log("SIMULATION INCOMPLETE: only the creation ran. This is not a launch approval.");
    }
}
