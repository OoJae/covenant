// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LocalBase} from "../utils/LocalBase.sol";
import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {MockFactory, MockTransistors, MockCircuits} from "../mocks/MockTapeOut.sol";
import {ToggleMaintainer, SlowMaintainer, PickyMaintainer, GuzzlerMaintainer} from "../mocks/Hostile.sol";

// Review tests (splitter lens): attacks on the Splitter's constructor and on pull(), written by the reviewer.
// Adapted since: the constructor's arguments, and the hostile factory answers isSealed() like TapeOut's does.

// ---------------------------------------------------------------------------------------------- helpers

/// @dev Forces OKB into an address that has no say in it.
contract ForceFeeder {
    constructor() payable {}

    function boom(address payable to) external {
        selfdestruct(to);
    }
}

/// @dev A factory that behaves like TapeOut's, but calls back into its caller (the Splitter that is being
///      constructed) and tries to hijack the tank before it returns.
contract CallbackFactory {
    uint256 public deployFee = 0.0066 ether;
    uint256 public protocolFee = 0.00066 ether;
    bool public isSealed;
    mapping(address => bool) public isCPU;
    mapping(address => uint256) public owed;

    uint256 public callerCodeSize;
    bool public pullOk;
    uint256 public pullRetLen;
    bool public claimOk;
    bool public sendOk;
    bool public initOk;
    bytes public initRet;
    address public tankSeen;
    address public tankCircuitsDuringCreate;

    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 transistorSupply,
        uint256 price
    ) external payable returns (address transistorsAddr, address circuitsAddr) {
        require(msg.value >= deployFee, "deploy fee");

        // --- the attack: everything a hostile factory could try against a half-built Splitter ---
        callerCodeSize = msg.sender.code.length;
        bytes memory ret;
        (pullOk, ret) = msg.sender.call(abi.encodeWithSignature("pull()"));
        pullRetLen = ret.length;
        (claimOk,) = msg.sender.call(abi.encodeWithSignature("claimMaintainer()"));
        (sendOk,) = msg.sender.call{value: 1}("");
        // the tank is the Splitter's second CREATE (nonce 2)
        address tank = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), msg.sender, bytes1(0x02)))))
        );
        tankSeen = tank;
        tankCircuitsDuringCreate = KeeperTank(payable(tank)).circuits();
        (initOk, initRet) = tank.call(abi.encodeWithSignature("init(address,address)", address(this), address(this)));

        // --- then an honest creation ---
        MockCircuits circuits = new MockCircuits(0.0013 ether);
        MockTransistors.Init memory i;
        i.name = name;
        i.symbol = symbol;
        i.story = story;
        i.creator = msg.sender;
        i.supplyCap = transistorSupply;
        i.mintPrice = price;
        i.protocolWallet = address(0xFEE);
        i.protocolFee = protocolFee;
        i.circuits = address(circuits);
        MockTransistors transistors = new MockTransistors(i);
        circuits.setTransistors(address(transistors));
        isCPU[address(circuits)] = true;
        owed[address(0xFEE)] += deployFee;
        return (address(transistors), address(circuits));
    }

    function mintPrice() external pure returns (uint256) {
        return 1;
    }
}

/// @dev What a TapeOut logic upgrade could turn Transistors.withdraw() into. Etched over the mock.
contract HostileTransistors {
    // mode: 1 = re-enter pull(), 2 = re-enter claimMaintainer(), 3 = revert with 100 kB, 4 = return 100 kB,
    //       5 = burn all gas, 6 = pay then revert, 7 = pay double (send what it has), 8 = plain revert
    uint256 public mode;
    bool public reentryBlocked;
    uint256 public reentryAttempts;

    function setMode(uint256 m) external {
        mode = m;
    }

    function withdraw() external {
        uint256 m = mode;
        if (m == 1 || m == 2) {
            (bool ok, bytes memory err) = msg.sender
                .call(m == 1 ? abi.encodeWithSignature("pull()") : abi.encodeWithSignature("claimMaintainer()"));
            reentryAttempts++;
            reentryBlocked = !ok && bytes4(err) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
            // pay whatever this contract holds, like a withdrawal would
            (ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok);
        } else if (m == 3) {
            assembly {
                revert(0, 100000)
            }
        } else if (m == 4) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok);
            assembly {
                return(0, 100000)
            }
        } else if (m == 5) {
            while (true) {}
        } else if (m == 6) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            ok;
            revert("after paying");
        } else if (m == 8) {
            revert("nothing owed");
        } else {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok);
        }
    }

    receive() external payable {}
}

/// @dev Calls pull() with an exact gas limit after warming whatever the attacker wants warm.
contract WarmCaller {
    function go(Splitter s, address[] calldata warm, uint256 gasLimit) external returns (bool ok, bytes memory err) {
        uint256 sink;
        for (uint256 i = 0; i < warm.length; i++) {
            sink += warm[i].balance;
        }
        sink;
        (ok, err) = address(s).call{gas: gasLimit}(abi.encodeCall(Splitter.pull, ()));
    }
}

/// @dev A maintainer wallet behind a proxy, like a Safe: its receive hook delegates to an implementation.
contract WalletImpl {
    event Received(address indexed from, uint256 value);

    fallback() external payable {
        emit Received(msg.sender, msg.value);
    }
}

contract ProxyWallet {
    address internal immutable IMPL;

    constructor(address impl) {
        IMPL = impl;
    }

    fallback() external payable {
        address impl = IMPL;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @dev Recurses to a chosen call depth and then calls pull().
contract DepthCaller {
    function dive(Splitter s, uint256 depth) external returns (bool ok) {
        if (depth == 0) {
            (ok,) = address(s).call(abi.encodeCall(Splitter.pull, ()));
            return ok;
        }
        (bool success, bytes memory ret) = address(this).call(abi.encodeCall(this.dive, (s, depth - 1)));
        if (!success) return false;
        return abi.decode(ret, (bool));
    }
}

// ---------------------------------------------------------------------------------------------- tests

contract SplitterAttackTest is LocalBase {
    function setUp() public {
        _deployLocal(maintainer);
    }

    function _newSplitter(address maintainer_) internal returns (Splitter) {
        return new Splitter{value: factory.deployFee()}(address(factory), maintainer_, COMMIT);
    }

    // ============================================================ constructor

    /// A third party sends OKB to the address the Splitter will have, before it is deployed.
    function test_attack_prefundTheFutureSplitter() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.deal(predicted, 1 ether);

        Splitter s = _newSplitter(maintainer);
        assertEq(address(s), predicted, "prediction");

        // creation still works, exactly the fee went to the factory, the stray OKB is simply there
        assertEq(address(s).balance, 1 ether);
        assertEq(factory.owed(address(s)), 0);
        assertEq(s.maintainerOwed(), 0);

        uint256 m0 = maintainer.balance;
        s.pull();
        assertEq(s.TANK().balance, 0.85 ether);
        assertEq(maintainer.balance - m0, 0.15 ether);
        assertEq(address(s).balance, 0);
    }

    /// The same for the two contracts the Splitter creates (its CREATE nonces 1 and 2).
    function test_attack_prefundTheFuturePayees() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address registry_ = vm.computeCreateAddress(predicted, 1);
        address tank_ = vm.computeCreateAddress(predicted, 2);
        vm.deal(registry_, 1 ether);
        vm.deal(tank_, 2 ether);

        Splitter s = _newSplitter(maintainer);
        assertEq(s.REGISTRY(), registry_, "registry is the first CREATE");
        assertEq(s.TANK(), tank_, "tank is the second CREATE");
        assertEq(vm.getNonce(address(s)), 3, "and there is no third");
        assertEq(registry_.balance, 1 ether); // stuck forever: the registry has no way out (attacker's own money)
        assertEq(tank_.balance, 2 ether); // unattributed backing
        assertEq(KeeperTank(payable(tank_)).circuits(), s.CIRCUITS());
    }

    /// A factory that calls back into the half-built Splitter and tries to initialise its tank.
    function test_attack_factoryCallsBackDuringConstruction() public {
        CallbackFactory evil = new CallbackFactory();
        Splitter s = new Splitter{value: 0.0066 ether}(address(evil), maintainer, COMMIT);

        assertEq(evil.callerCodeSize(), 0, "the Splitter has no code while its constructor runs");
        assertTrue(evil.pullOk(), "a call to a code-less address succeeds");
        assertEq(evil.pullRetLen(), 0, "and does nothing");
        assertTrue(evil.claimOk());
        assertTrue(evil.sendOk(), "value sent to the half-built Splitter is accepted");
        assertEq(evil.tankSeen(), s.TANK());
        assertEq(evil.tankCircuitsDuringCreate(), address(0), "the tank exists un-initialised during createCPU");
        assertFalse(evil.initOk(), "but only the Splitter can initialise it");
        assertEq(bytes4(evil.initRet()), KeeperTank.NotSplitter.selector);

        // wiring is what the Splitter decided, not what the factory tried
        KeeperTank t = KeeperTank(payable(s.TANK()));
        assertEq(t.circuits(), s.CIRCUITS());
        assertEq(t.transistors(), s.TRANSISTORS());
        assertEq(t.mintPrice(), 0.00002 ether);
        assertEq(t.SPLITTER(), address(s));
        assertEq(s.maintainerOwed(), 0);

        // the 1 wei pushed in during construction is split like any stray OKB
        assertEq(address(s).balance, 1);
        s.pull();
        assertEq(s.TANK().balance, 1);
        assertEq(address(s).balance, 0);
    }

    /// A reverted creation leaves nothing behind (the last possible failure point: after every `new` and after
    /// createCPU has run).
    function test_revertedCreation_leavesNothingBehind() public {
        uint256 fee = factory.deployFee();
        uint256 cpusBefore = factory.cpuCount();
        uint256 factoryBalance = address(factory).balance;
        uint256 myBalance = address(this).balance;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        factory.setSabotage(MockFactory.Sabotage.NotRegistered);
        try new Splitter{value: fee}(address(factory), maintainer, COMMIT) {
            revert("should have reverted");
        } catch {}

        assertEq(predicted.code.length, 0);
        assertEq(vm.computeCreateAddress(predicted, 1).code.length, 0, "registry");
        assertEq(vm.computeCreateAddress(predicted, 2).code.length, 0, "tank");
        assertEq(factory.cpuCount(), cpusBefore, "no processor");
        assertEq(address(factory).balance, factoryBalance, "no fee taken");
        assertEq(address(this).balance, myBalance, "value returned");
    }

    // ============================================================ pull(): gas

    /// Fine sweep (every single gas value in a wide window around each threshold is too slow; a prime step
    /// plus a 1-gas sweep around the first success covers the boundaries).
    function _sweep(Splitter s, address m, uint256 from, uint256 to, uint256 step)
        internal
        returns (uint256 firstSuccess, uint256 credited)
    {
        for (uint256 gasLimit = from; gasLimit <= to; gasLimit += step) {
            uint256 snap = vm.snapshotState();
            try s.pull{gas: gasLimit}() {
                if (firstSuccess == 0) firstSuccess = gasLimit;
                if (s.maintainerOwed() != 0) credited++;
                else assertEq(m.balance, 0.15 ether, "not paid in full");
            } catch {
                assertEq(address(s).balance, 1 ether, "a reverted pull moved OKB");
            }
            vm.revertToState(snap);
        }
    }

    function _fineSweep(address m, string memory label) internal {
        Splitter s = _newSplitter(m);
        vm.deal(address(s), 1 ether);
        (uint256 first, uint256 credited) = _sweep(s, m, 40_000, 260_000, 97);
        assertEq(credited, 0, "push starved into the credit path");
        assertGt(first, 0);
        // every single gas value around the first success
        (uint256 exact, uint256 credited2) = _sweep(s, m, first - 1_500, first + 1_500, 1);
        assertEq(credited2, 0, "push starved into the credit path (1-gas sweep)");
        console2.log(label, "first gas limit at which pull() succeeds:", exact);
    }

    function test_attack_starveTheMaintainerPush_fineSweep_slow() public {
        _fineSweep(address(new SlowMaintainer()), "slow maintainer:");
    }

    function test_attack_starveTheMaintainerPush_fineSweep_picky() public {
        _fineSweep(address(new PickyMaintainer()), "picky maintainer:");
    }

    function test_attack_starveTheMaintainerPush_fineSweep_proxyWallet() public {
        _fineSweep(address(new ProxyWallet(address(new WalletImpl()))), "proxy wallet:");
    }

    /// The same when the attacker warms every address first (cheaper CALLs change every offset).
    function test_attack_starveTheMaintainerPush_withWarmAddresses() public {
        WarmCaller caller = new WarmCaller();
        address[2] memory maintainers = [address(new SlowMaintainer()), address(new PickyMaintainer())];
        for (uint256 k = 0; k < maintainers.length; k++) {
            Splitter s = _newSplitter(maintainers[k]);
            vm.deal(address(s), 1 ether);
            address[] memory warm = new address[](5);
            warm[0] = maintainers[k];
            warm[1] = s.TANK();
            warm[2] = s.REGISTRY();
            warm[3] = s.TRANSISTORS();
            warm[4] = address(s);

            uint256 succeeded;
            for (uint256 gasLimit = 40_000; gasLimit <= 300_000; gasLimit += 53) {
                uint256 snap = vm.snapshotState();
                (bool ok,) = caller.go{gas: gasLimit + 200_000}(s, warm, gasLimit);
                if (ok) {
                    succeeded++;
                    assertEq(s.maintainerOwed(), 0, "credited");
                    assertEq(maintainers[k].balance, 0.15 ether);
                } else {
                    assertEq(address(s).balance, 1 ether);
                }
                vm.revertToState(snap);
            }
            assertGt(succeeded, 0);
        }
    }

    /// A maintainer that burns everything it is given is credited at EVERY gas limit at which pull succeeds,
    /// and pull is never left half done.
    function test_guzzlerMaintainer_everyGasLimit_creditedOrReverted() public {
        address m = address(new GuzzlerMaintainer());
        Splitter s = _newSplitter(m);
        vm.deal(address(s), 1 ether);
        uint256 succeeded;
        for (uint256 gasLimit = 40_000; gasLimit <= 300_000; gasLimit += 41) {
            uint256 snap = vm.snapshotState();
            try s.pull{gas: gasLimit}() {
                succeeded++;
                assertEq(s.maintainerOwed(), 0.15 ether);
                assertEq(address(s).balance, 0.15 ether);
                assertEq(s.TANK().balance, 0.85 ether);
            } catch {
                assertEq(address(s).balance, 1 ether);
                assertEq(s.maintainerOwed(), 0);
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0);
    }

    /// Call depth: a proxy wallet's receive hook needs one more call level. If pull() could be entered at
    /// depth 1023 its push to such a wallet would fail and be credited. Measure how deep a caller can get
    /// while still leaving pull() enough gas.
    function test_attack_callDepth_isOutOfReach() public {
        address impl = address(new WalletImpl());
        address m = address(new ProxyWallet(impl));
        Splitter s = _newSplitter(m);
        vm.deal(address(s), 1 ether);
        DepthCaller diver = new DepthCaller();

        // with a whole X Layer block of gas (210M), how deep can the caller go and still have pull() succeed?
        uint256 deepest;
        uint256 creditedAtAnyDepth;
        for (uint256 depth = 0; depth <= 1020; depth += 60) {
            uint256 snap = vm.snapshotState();
            bool ok;
            try diver.dive{gas: 210_000_000}(s, depth) returns (bool r) {
                ok = r;
            } catch {}
            if (ok) {
                deepest = depth;
                if (s.maintainerOwed() != 0) creditedAtAnyDepth++;
            }
            vm.revertToState(snap);
        }
        console2.log("deepest call depth at which pull() still succeeds with 210M gas:", deepest);
        assertEq(creditedAtAnyDepth, 0, "depth starved the push");
        assertLt(deepest, 1000, "the 63/64 rule keeps a caller far from the 1024 depth limit");
    }

    // ============================================================ pull(): forced balance and accounting

    function test_attack_forcedBalance_whileACreditIsOutstanding() public {
        ToggleMaintainer m = new ToggleMaintainer();
        Splitter s = _newSplitter(address(m));
        vm.deal(address(s), 1 ether);
        s.pull();
        assertEq(s.maintainerOwed(), 0.15 ether);

        // force 1 ether in with SELFDESTRUCT (no receive hook runs)
        ForceFeeder f = new ForceFeeder{value: 1 ether}();
        f.boom(payable(address(s)));
        assertEq(address(s).balance, 1.15 ether);

        s.pull();
        assertEq(s.TANK().balance, 1.7 ether);
        assertEq(s.maintainerOwed(), 0.3 ether, "only the forced ether was split; the credit was not re-split");
        assertEq(address(s).balance, 0.3 ether);

        m.setAccept(true);
        s.claimMaintainer();
        assertEq(address(m).balance, 0.3 ether);
        assertEq(address(s).balance, 0);
    }

    /// Fuzz: any interleaving of pulls, forced balance, refusals and claims keeps
    ///   balance >= maintainerOwed   (pull() can never underflow and brick)
    ///   and every wei that entered is with a payee, credited, or still unsplit.
    function testFuzz_attack_accountingNeverUnderflows(uint64[8] memory amounts, uint8[8] memory ops) public {
        ToggleMaintainer m = new ToggleMaintainer();
        Splitter s = _newSplitter(address(m));
        uint256 entered;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint8 op = ops[i] % 5;
            if (op == 0) {
                vm.deal(address(s), address(s).balance + amounts[i]);
                entered += amounts[i];
            } else if (op == 1) {
                m.setAccept(amounts[i] % 2 == 0);
            } else if (op == 2) {
                s.pull();
            } else if (op == 3) {
                if (s.maintainerOwed() != 0 && m.accept()) s.claimMaintainer();
            } else {
                ForceFeeder f = new ForceFeeder{value: amounts[i]}();
                f.boom(payable(address(s)));
                entered += amounts[i];
            }
            assertGe(address(s).balance, s.maintainerOwed(), "balance below the credit: pull() would brick");
            assertEq(s.TANK().balance + address(m).balance + address(s).balance, entered);
        }
        // and pull() still works
        s.pull();
        assertEq(address(s).balance, s.maintainerOwed());
    }

    // ============================================================ pull(): a hostile Transistors (TapeOut upgrade)

    function _hostile(uint256 mode) internal returns (HostileTransistors h) {
        HostileTransistors code = new HostileTransistors();
        vm.etch(address(transistors), address(code).code);
        h = HostileTransistors(payable(address(transistors)));
        h.setMode(mode);
    }

    function test_attack_withdrawReentersPull() public {
        _mint(user, 0, 1000); // 0.02 OKB sits in the Transistors contract
        HostileTransistors h = _hostile(1);
        vm.deal(address(splitter), 1 ether);
        uint256 m0 = maintainer.balance;
        uint256 attempts0 = h.reentryAttempts(); // the etched code shares storage with the mock it replaced

        splitter.pull();

        assertTrue(h.reentryBlocked(), "nested pull() must hit the guard");
        assertEq(h.reentryAttempts(), attempts0 + 1);
        // split exactly once: the stray ether plus everything the hostile contract paid out
        uint256 total = 1 ether + 1000 * PRICE + PROTOCOL_FEE;
        assertEq(address(splitter).balance, 0);
        assertEq(address(tank).balance + (maintainer.balance - m0), total);
        assertEq(maintainer.balance - m0, total * 1500 / 10_000);
    }

    function test_attack_withdrawReentersClaim() public {
        ToggleMaintainer m = new ToggleMaintainer();
        Splitter s = _newSplitter(address(m));
        vm.deal(address(s), 1 ether);
        s.pull(); // credit 0.15
        m.setAccept(true);

        HostileTransistors code = new HostileTransistors();
        vm.etch(s.TRANSISTORS(), address(code).code);
        HostileTransistors h = HostileTransistors(payable(s.TRANSISTORS()));
        h.setMode(2);

        vm.deal(address(s), address(s).balance + 1 ether);
        s.pull();
        assertTrue(h.reentryBlocked(), "claimMaintainer() inside pull() must hit the guard");
        assertEq(s.maintainerOwed(), 0.15 ether, "the credit is untouched");
        assertEq(address(m).balance, 0.15 ether, "only the new share was pushed");
    }

    function test_attack_withdrawReturnBombs_areNotCopied() public {
        vm.deal(address(splitter), 1 ether);

        // baseline: plain "nothing owed" revert
        _hostile(8);
        uint256 snap = vm.snapshotState();
        splitter.pull();
        uint256 plain = vm.lastFrameGas().gasTotalUsed;
        vm.revertToState(snap);

        // revert with 100 kB
        _hostile(3);
        snap = vm.snapshotState();
        splitter.pull();
        uint256 revertBomb = vm.lastFrameGas().gasTotalUsed;
        assertEq(address(tank).balance, 0.85 ether);
        vm.revertToState(snap);

        // success returning 100 kB
        _hostile(4);
        splitter.pull();
        uint256 returnBomb = vm.lastFrameGas().gasTotalUsed;
        assertEq(address(tank).balance, 0.85 ether);

        console2.log("pull gas: plain revert", plain);
        console2.log("pull gas: 100 kB revert", revertBomb);
        console2.log("pull gas: 100 kB return", returnBomb);
        // The callee pays 28,448 gas to expand its own memory to 100 kB. Copying it into the Splitter would cost
        // the Splitter another 28,448 + 9,375. Allow the callee's own cost plus slack, nothing more.
        assertLt(revertBomb, plain + 28_448 + 2_000, "the Splitter copied the revert data");
        assertLt(returnBomb, plain + 28_448 + 12_000, "the Splitter copied the return data");
    }

    function test_attack_withdrawBurnsAllGas_pullStillSplitsWhatIsHere() public {
        _hostile(5);
        vm.deal(address(splitter), 1 ether);
        uint256 m0 = maintainer.balance;

        // 63/64 is burnt by withdraw(); what is left (1/64) must cover the split: needs a big enough limit
        splitter.pull{gas: 12_000_000}();
        assertEq(address(tank).balance, 0.85 ether);
        assertEq(maintainer.balance - m0, 0.15 ether);

        // smallest limit that works, for the record
        vm.deal(address(splitter), 1 ether);
        uint256 lo = 100_000;
        uint256 hi = 12_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok;
            try splitter.pull{gas: mid}() {
                ok = true;
            } catch {}
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        console2.log("gas limit pull() needs when withdraw() burns everything it is given:", hi);
    }

    function test_attack_withdrawPaysThenReverts_nothingIsLost() public {
        _mint(user, 0, 1000);
        uint256 held = address(transistors).balance;
        _hostile(6);
        vm.deal(address(splitter), 1 ether);
        splitter.pull();
        // the payment was rolled back with the revert: only the stray ether was split
        assertEq(address(tank).balance, 0.85 ether);
        assertEq(address(transistors).balance, held);
    }

    // ============================================================ who can receive value, ever

    /// Every address that gains OKB across an arbitrary sequence of calls from arbitrary callers is one of the
    /// two payees. (Callers are EOAs here; contracts as callers are covered by the re-entrancy tests.)
    function testFuzz_attack_onlyThePayeesEverGain(address[4] memory callers, uint8[4] memory which, uint64 stray)
        public
    {
        _mint(user, 0, 321);
        vm.deal(address(splitter), stray);
        uint256[4] memory before;
        for (uint256 i = 0; i < 4; i++) {
            vm.assume(callers[i] != address(tank) && callers[i] != maintainer);
            vm.assume(callers[i] != address(splitter) && callers[i] != address(transistors));
            vm.assume(uint160(callers[i]) > 0xffff); // not a precompile
            before[i] = callers[i].balance;
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(callers[i]);
            if (which[i] % 2 == 0) {
                splitter.pull();
            } else {
                try splitter.claimMaintainer() {} catch {}
            }
        }
        vm.prank(callers[0]);
        splitter.pull();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(callers[i].balance, before[i], "a caller gained OKB");
        }
        assertEq(address(splitter).balance, 0);
        assertEq(address(tank).balance + maintainer.balance, 321 * PRICE + stray);
    }

    // ============================================================ drift

    /// 85 / 15 over many pulls. Proceeds are multiples of 0.00002 OKB, whose 15% is whole wei, so an attacker
    /// who triggers a pull after every single mint, and adds his own dust to shift the rounding, cannot move
    /// one wei of PROCEEDS away from the maintainer.
    function testFuzz_attack_driftOverManyPulls(uint16[12] memory mints, uint16[12] memory dust) public {
        uint256 proceeds;
        uint256 donated;
        uint256 m0 = maintainer.balance;
        for (uint256 i = 0; i < mints.length; i++) {
            uint256 n = uint256(mints[i]) % 50 + 1;
            _mint(user, i % 2, n);
            proceeds += n * PRICE;
            vm.deal(address(splitter), address(splitter).balance + dust[i]);
            donated += dust[i];
            splitter.pull();
        }
        uint256 toMaintainer = maintainer.balance - m0;
        uint256 toTank = address(tank).balance;
        assertEq(toMaintainer + toTank, proceeds + donated);
        assertGe(toMaintainer, proceeds * 15 / 100, "maintainer lost proceeds to rounding");
        assertGe(toTank, proceeds * 85 / 100, "tank lost proceeds");
        // total rounding loss of the maintainer is below 1 wei per pull
        assertLt((proceeds + donated) * 15 / 100 - toMaintainer, mints.length + 1);
    }

    // ============================================================ bytecode facts

    /// The Splitter's runtime code contains no SELFDESTRUCT, DELEGATECALL, CALLCODE or CREATE, and it never
    /// executes RETURNDATACOPY outside the constructor.
    function test_runtimeBytecode_hasNoDangerousOpcodes() public view {
        bytes memory code = address(splitter).code;
        (uint256 sd, uint256 dc, uint256 cc, uint256 cr, uint256 cr2, uint256 rdc, uint256 calls) = _count(code);
        console2.log("Splitter runtime: CALL count", calls);
        console2.log("Splitter runtime: RETURNDATACOPY count", rdc);
        assertEq(sd, 0, "SELFDESTRUCT");
        assertEq(dc, 0, "DELEGATECALL");
        assertEq(cc, 0, "CALLCODE");
        assertEq(cr, 0, "CREATE");
        assertEq(cr2, 0, "CREATE2");

        code = address(registry).code;
        (sd, dc, cc, cr, cr2, rdc, calls) = _count(code);
        console2.log("Registry runtime: CALL count", calls);
        assertEq(sd + dc + cc + cr + cr2 + calls, 0, "registry makes no calls at all");
    }

    /// @dev Walks the code skipping PUSH data. The CBOR metadata at the end is data, not code; a stray match
    ///      there would only make this stricter.
    function _count(bytes memory code)
        internal
        pure
        returns (uint256 sd, uint256 dc, uint256 cc, uint256 cr, uint256 cr2, uint256 rdc, uint256 calls)
    {
        // strip CBOR metadata: last two bytes are its length
        uint256 end = code.length;
        if (end >= 2) {
            uint256 metaLen = (uint256(uint8(code[end - 2])) << 8) | uint256(uint8(code[end - 1]));
            if (metaLen + 2 <= end) end -= metaLen + 2;
        }
        for (uint256 i = 0; i < end; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (op == 0xff) sd++;
            if (op == 0xf4) dc++;
            if (op == 0xf2) cc++;
            if (op == 0xf0) cr++;
            if (op == 0xf5) cr2++;
            if (op == 0x3e) rdc++;
            if (op == 0xf1) calls++;
        }
    }
}
