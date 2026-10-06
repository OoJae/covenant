// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LocalBase} from "../utils/LocalBase.sol";
import {Splitter} from "../../src/Splitter.sol";
import {HeavyWallet} from "../mocks/Hostile.sol";

/// @dev A wallet that refuses, cheaply, unless it is offered (almost) the whole MAINTAINER_GAS + stipend.
contract FullGasWallet {
    receive() external payable {
        require(gasleft() >= 52_000, "wallet: not the full 50,000 + 2,300");
    }
}

/// @notice Review tests (splitter lens). Properties the suite did not pin when it was reviewed: each of the
///         one-line mutants named below survived it then and is killed by the matching test here.
///         Adapted since: the constructor's arguments. The two tests of the launchpad socket went with the
///         socket (NOTES.md, section 9).
contract MutantKillersTest is LocalBase {
    function setUp() public {
        _deployLocal(maintainer);
    }

    /// Mutant: claimMaintainer() sends with MAINTAINER_GAS instead of all gas.
    /// NOTES.md section 2: "claimMaintainer() ... pays only the maintainer, with all available gas".
    function test_claimMaintainer_forwardsAllGas_soASlowWalletIsStillPaid() public {
        HeavyWallet heavy = new HeavyWallet();
        Splitter s = new Splitter{value: factory.deployFee()}(address(factory), address(heavy), COMMIT);
        vm.deal(address(s), 1 ether);

        s.pull(); // the push offers 50,000 gas: not enough, the share is credited
        assertEq(s.maintainerOwed(), 0.15 ether);
        assertEq(address(heavy).balance, 0);

        s.claimMaintainer(); // all gas: enough
        assertEq(address(heavy).balance, 0.15 ether);
        assertEq(s.maintainerOwed(), 0);
    }

    /// Mutant: PUSH_MIN_GAS lowered from 90,000 to 60,000.
    /// Splitter.sol: "With 90,000 left the callee is always offered the full MAINTAINER_GAS".
    function test_push_isAlwaysOfferedTheFullMaintainerGas() public {
        FullGasWallet wallet = new FullGasWallet();
        Splitter s = new Splitter{value: factory.deployFee()}(address(factory), address(wallet), COMMIT);
        vm.deal(address(s), 1 ether);

        uint256 succeeded;
        for (uint256 gasLimit = 60_000; gasLimit <= 200_000; gasLimit += 97) {
            uint256 snap = vm.snapshotState();
            try s.pull{gas: gasLimit}() {
                succeeded++;
                assertEq(s.maintainerOwed(), 0, "the push was offered less than the full MAINTAINER_GAS");
                assertEq(address(wallet).balance, 0.15 ether);
            } catch {
                assertEq(address(s).balance, 1 ether);
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0);
    }
}
