// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {XLayerFork} from "../fork/XLayerFork.sol";
import {Story} from "../../script/lib/Story.sol";
import {Splitter} from "../../src/Splitter.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {ICircuitFactory, ITransistors} from "../../src/interfaces/ITapeOut.sol";

/// @dev A contract that mints transistors and calls Splitter.pull() from inside TapeOut's ERC-1155
///      acceptance hook, i.e. while Transistors' own re-entrancy lock is held.
contract HookMinter {
    Splitter internal immutable SPLITTER;
    ITransistors internal immutable T;
    bool public pulledInsideHook;
    uint256 public owedSeenInsideHook;
    uint256 public splitterBalanceAfterInnerPull;

    constructor(Splitter s) {
        SPLITTER = s;
        T = ITransistors(s.TRANSISTORS());
    }

    function mint(uint256 n) external payable {
        T.mint{value: msg.value}(0, n);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        owedSeenInsideHook = T.owed(address(SPLITTER));
        SPLITTER.pull();
        pulledInsideHook = true;
        splitterBalanceAfterInnerPull = address(SPLITTER).balance;
        return this.onERC1155Received.selector;
    }
}

/// @notice Review tests (splitter lens) against the real TapeOut factory and a real Safe at the pinned block.
///         Adapted since the review: the constructor's arguments and the registry that now starts with the
///         deployer. The socket tests went with the socket (NOTES.md, section 9).
contract ReviewForkTest is XLayerFork {
    address internal constant DEPLOYER = 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D;
    /// @dev A real Safe on X Layer (the one that owns IgnixManager), used here only as a maintainer wallet.
    address internal constant IGNIX_SAFE = 0x9147C109F903eeA66DD0b512531ae9cE0377E76a;

    function setUp() public {
        _forkAndIgnite();
    }

    // ------------------------------------------------------------------ the real deployer, nonce 0

    function test_fork_review_deployFromTheRealDeployerAtNonce0() public {
        assertEq(DEPLOYER.code.length, 0, "deployer is a plain EOA at the pinned block");
        console2.log("deployer nonce at the pinned block:", vm.getNonce(DEPLOYER));
        console2.log("deployer balance at the pinned block (wei):", DEPLOYER.balance);

        uint256 nonce = vm.getNonce(DEPLOYER);
        assertEq(nonce, 0);
        address predicted = vm.computeCreateAddress(DEPLOYER, nonce);
        vm.deal(DEPLOYER, 1 ether);
        uint256 fee = ICircuitFactory(FACTORY).deployFee();
        vm.prank(DEPLOYER);
        Splitter s = new Splitter{value: fee}(FACTORY, DEPLOYER, COMMIT);
        uint256 gasUsed = vm.lastFrameGas().gasTotalUsed;

        assertEq(address(s), predicted);
        assertEq(address(s), 0xfd73b7Bc92cDa68ec57799987fd3449BA5daDD88);
        assertEq(s.REGISTRY(), vm.computeCreateAddress(predicted, 1));
        assertEq(s.TANK(), vm.computeCreateAddress(predicted, 2));
        assertEq(s.REGISTRY(), 0x6f1a330b7FfAc901205704EACA8e46ee4091F3A2);
        assertEq(s.TANK(), 0xAfed3eC2196BDc8F5a933D8f280c945f0D2D826e);
        assertEq(DEPLOYER.balance, 1 ether - fee, "exactly the fee left the deployer (forge charges no gas here)");

        ITransistors t = ITransistors(s.TRANSISTORS());
        assertEq(t.creator(), address(s));
        string memory expected = Story.expected(address(s), s.TANK(), DEPLOYER, s.REGISTRY(), COMMIT);
        assertEq(t.story(), expected);

        // the deployer, which is also the maintainer, is the root of the registry
        TeamRegistry r = TeamRegistry(s.REGISTRY());
        assertEq(r.count(), 1);
        (address founder, string memory role,) = r.at(0);
        assertEq(founder, DEPLOYER);
        assertEq(role, "deployer");

        console2.log("splitter  ", address(s));
        console2.log("registry  ", s.REGISTRY());
        console2.log("tank      ", s.TANK());
        console2.log("creation gas", gasUsed);

        // the maintainer is the deployer EOA: the 15% push lands directly
        vm.deal(user, 10 ether);
        vm.prank(user);
        t.mint{value: 1000 * PRICE + PROTOCOL_FEE}(0, 1000);
        uint256 before = DEPLOYER.balance;
        vm.prank(user);
        s.pull();
        console2.log("pull() gas, EOA maintainer, real TapeOut:", vm.lastFrameGas().gasTotalUsed);
        assertEq(DEPLOYER.balance - before, 1000 * PRICE * 15 / 100);
        assertEq(s.maintainerOwed(), 0);
    }

    function test_fork_review_prefundedAddresses_realFactory() public {
        address me = address(this);
        address predicted = vm.computeCreateAddress(me, vm.getNonce(me));
        vm.deal(predicted, 0.5 ether);
        vm.deal(vm.computeCreateAddress(predicted, 1), 1 wei);
        vm.deal(vm.computeCreateAddress(predicted, 2), 1 wei);

        Splitter s = _ignite(maintainer);
        assertEq(address(s), predicted);
        assertEq(address(s).balance, 0.5 ether);
        assertEq(ICircuitFactory(FACTORY).owed(address(s)), 0);
        assertTrue(ICircuitFactory(FACTORY).isCPU(s.CIRCUITS()));

        uint256 m0 = maintainer.balance;
        s.pull();
        assertEq(s.TANK().balance, 0.425 ether + 1);
        assertEq(maintainer.balance - m0, 0.075 ether);
    }

    // ------------------------------------------------------------------ pull() against the real Transistors

    /// pull() from inside the ERC-1155 acceptance hook of a mint: TapeOut's own lock makes withdraw() revert
    /// ("reentrant"), the Splitter swallows it. Nothing is lost and nothing is split twice.
    function test_fork_review_pullFromInsideAMintHook() public {
        _mint(user, 0, 100); // 100 transistors already owed
        HookMinter minter = new HookMinter(splitter);
        vm.deal(address(splitter), 1 ether); // stray ether already in the Splitter

        vm.deal(address(this), 10 ether);
        minter.mint{value: 50 * PRICE + PROTOCOL_FEE}(50);

        assertTrue(minter.pulledInsideHook());
        assertEq(minter.owedSeenInsideHook(), 150 * PRICE, "the mint's proceeds were already credited");
        assertEq(minter.splitterBalanceAfterInnerPull(), 0, "the stray ether was split inside the hook");
        assertEq(transistors.owed(address(splitter)), 150 * PRICE, "proceeds stayed owed: withdraw was locked");
        assertEq(address(tank).balance, 0.85 ether);

        splitter.pull();
        assertEq(transistors.owed(address(splitter)), 0);
        uint256 total = 1 ether + 150 * PRICE;
        assertEq(address(tank).balance + maintainer.balance, total);
        assertEq(maintainer.balance, total * 15 / 100);
    }

    /// Every gas limit: pull() either reverts as a whole or collects AND splits. It never "succeeds" while
    /// leaving the proceeds in TapeOut (which is what a gas estimator would otherwise settle on).
    function test_fork_review_pullGasSweep_neverSucceedsWithoutWithdrawing() public {
        _mint(user, 0, 1000);
        uint256 total = 1000 * PRICE;
        uint256 succeeded;
        uint256 firstSuccess;
        uint256 silentSkips;
        for (uint256 gasLimit = 21_000; gasLimit <= 400_000; gasLimit += 149) {
            uint256 snap = vm.snapshotState();
            try splitter.pull{gas: gasLimit}() {
                succeeded++;
                if (firstSuccess == 0) firstSuccess = gasLimit;
                if (transistors.owed(address(splitter)) != 0) silentSkips++;
                else assertEq(address(tank).balance + maintainer.balance, total);
            } catch {
                assertEq(transistors.owed(address(splitter)), total);
                assertEq(address(tank).balance + maintainer.balance, 0);
            }
            vm.revertToState(snap);
        }
        console2.log("real TapeOut: first gas limit at which pull() succeeds:", firstSuccess);
        console2.log("real TapeOut: pulls that succeeded without withdrawing:", silentSkips);
        assertGt(succeeded, 0);
        assertEq(silentSkips, 0, "pull() succeeded with the proceeds still owed");
    }

    /// The same with stray ether already in the Splitter (the only case in which a swallowed out-of-gas
    /// withdraw() could be followed by a successful split).
    function test_fork_review_pullGasSweep_withStrayBalance() public {
        _mint(user, 0, 1000);
        vm.deal(address(splitter), 1 ether);
        uint256 total = 1000 * PRICE + 1 ether;
        uint256 silentSkips;
        uint256 succeeded;
        for (uint256 gasLimit = 21_000; gasLimit <= 500_000; gasLimit += 149) {
            uint256 snap = vm.snapshotState();
            try splitter.pull{gas: gasLimit}() {
                succeeded++;
                if (transistors.owed(address(splitter)) != 0) silentSkips++;
                else assertEq(address(tank).balance + maintainer.balance, total);
                assertEq(address(splitter).balance, 0);
            } catch {
                assertEq(address(splitter).balance, 1 ether);
            }
            vm.revertToState(snap);
        }
        console2.log("real TapeOut, stray balance: pulls that succeeded without withdrawing:", silentSkips);
        assertGt(succeeded, 0);
        assertEq(silentSkips, 0);
    }

    function test_fork_review_withdrawGas() public {
        _mint(user, 0, 1000);
        vm.prank(address(splitter));
        transistors.withdraw();
        console2.log("Transistors.withdraw() as a transaction from the creator (gas):", vm.lastFrameGas().gasTotalUsed);
    }

    // ------------------------------------------------------------------ a real Safe as maintainer

    function test_fork_review_realSafeAsMaintainer_isPaidWithinTheGasCap() public {
        assertGt(IGNIX_SAFE.code.length, 0, "a contract wallet");
        Splitter s = _ignite(IGNIX_SAFE);
        ITransistors t = ITransistors(s.TRANSISTORS());
        vm.deal(user, 10 ether);
        vm.prank(user);
        t.mint{value: 1000 * PRICE + PROTOCOL_FEE}(0, 1000);

        uint256 before = IGNIX_SAFE.balance;
        uint256 succeeded;
        uint256 credited;
        for (uint256 gasLimit = 60_000; gasLimit <= 400_000; gasLimit += 331) {
            uint256 snap = vm.snapshotState();
            try s.pull{gas: gasLimit}() {
                succeeded++;
                if (s.maintainerOwed() != 0) credited++;
                else assertEq(IGNIX_SAFE.balance - before, 1000 * PRICE * 15 / 100);
            } catch {}
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0);
        assertEq(credited, 0, "a real Safe was starved into the credit path");

        s.pull();
        console2.log("pull() gas with a real Safe as maintainer:", vm.lastFrameGas().gasTotalUsed);
        assertEq(IGNIX_SAFE.balance - before, 1000 * PRICE * 15 / 100);
    }
}
