// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {XLayerFork} from "./XLayerFork.sol";
import {Story} from "../../script/lib/Story.sol";
import {Ignite} from "../../script/Ignite.s.sol";
import {TapeoutProbe} from "../../script/TapeoutProbe.s.sol";
import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {ICircuitFactory, ICircuits, ITransistors} from "../../src/interfaces/ITapeOut.sol";

/// @dev Ignite with a plan that is wrong on purpose, in one place. Whatever the creation produces then
///      differs from what was announced, and the script must stop.
contract IgniteWithAWrongPlan is Ignite {
    /// @dev 0 = one character of the story; 1 to 5 = one of the five addresses
    uint256 internal immutable WRONG;

    constructor(uint256 wrong) {
        WRONG = wrong;
    }

    function plan(address deployer, address maintainer, bytes20 commit) public view override returns (Plan memory p) {
        p = super.plan(deployer, maintainer, commit);
        address elsewhere = address(0xdead);
        if (WRONG == 0) {
            bytes memory text = bytes(p.story);
            text[text.length - 2] = text[text.length - 2] == "0" ? bytes1("1") : bytes1("0");
        }
        if (WRONG == 1) p.splitter = elsewhere;
        if (WRONG == 2) p.registry = elsewhere;
        if (WRONG == 3) p.tank = elsewhere;
        if (WRONG == 4) p.transistors = elsewhere;
        if (WRONG == 5) p.circuits = elsewhere;
    }
}

/// @notice The two scripts, run inside the fork exactly as `forge script` runs them (minus the signing).
///         In a test the "broadcaster" is forge's default sender.
contract ScriptsForkTest is XLayerFork {
    address internal broadcaster = DEFAULT_SENDER;

    function setUp() public {
        _fork();
        vm.deal(broadcaster, 1 ether);
    }

    // ------------------------------------------------------------------ Ignite

    /// The only test that reads or sets MAINTAINER, COMMIT and REHEARSAL. The environment is shared by every
    /// test of a run, so everything that goes through run() happens here, one step after the other.
    function test_fork_script_ignite_fromEnvironment() public {
        vm.setEnv("MAINTAINER", vm.toString(broadcaster));
        vm.setEnv("COMMIT", "a1b2c3d4e5f60718293a4b5c6d7e8f9001234567"); // as `git rev-parse HEAD` prints it
        vm.setEnv("REHEARSAL", "false");

        uint256 before = broadcaster.balance;
        Splitter s = new Ignite().run();

        assertEq(before - broadcaster.balance, 0.0066 ether, "the deployer pays exactly the deploy fee");
        ITransistors t = ITransistors(s.TRANSISTORS());
        assertTrue(ICircuitFactory(FACTORY).isCPU(s.CIRCUITS()));
        assertEq(t.creator(), address(s));
        assertEq(s.MAINTAINER(), broadcaster);
        assertEq(t.story(), Story.expected(address(s), s.TANK(), broadcaster, s.REGISTRY(), COMMIT));

        // the deploying account is the root of the team registry
        TeamRegistry r = TeamRegistry(s.REGISTRY());
        assertEq(r.count(), 1);
        (address founder, string memory role,) = r.at(0);
        assertEq(founder, broadcaster);
        assertEq(role, "deployer");

        // MAINTAINER must be given, and must be the deploying account
        Ignite script = new Ignite();
        vm.setEnv("MAINTAINER", "");
        vm.expectRevert();
        script.run();
        vm.setEnv("MAINTAINER", vm.toString(maintainer));
        vm.expectRevert(bytes("Ignite: MAINTAINER is not the deploying account"));
        script.run();
        vm.setEnv("MAINTAINER", vm.toString(broadcaster));

        // on another chain id the script refuses, unless REHEARSAL says this is a rehearsal
        vm.chainId(31337);
        vm.expectRevert(
            bytes("Ignite: not X Layer (chain id 196); only a rehearsal (REHEARSAL=true) may run elsewhere")
        );
        script.run();
        vm.setEnv("REHEARSAL", "true");
        Splitter rehearsed = script.run();
        assertEq(ITransistors(rehearsed.TRANSISTORS()).creator(), address(rehearsed));
        vm.setEnv("REHEARSAL", "false");
    }

    /// Every address the script announces before it sends anything is the address the creation produces,
    /// and the story it announces is the story the processor carries.
    function test_fork_script_ignite_planIsWhatTheCreationProduces() public {
        Ignite script = new Ignite();
        Ignite.Plan memory p = script.plan(broadcaster, broadcaster, COMMIT);

        Splitter s = script.ignite(broadcaster, COMMIT, false);

        assertEq(address(s), p.splitter);
        assertEq(s.REGISTRY(), p.registry);
        assertEq(s.TANK(), p.tank);
        assertEq(s.TRANSISTORS(), p.transistors);
        assertEq(s.CIRCUITS(), p.circuits);
        assertEq(ITransistors(s.TRANSISTORS()).story(), p.story);

        // five different contracts, the planned story names three of them and nothing of the last two
        assertTrue(vm.contains(p.story, vm.toString(p.splitter)));
        assertTrue(vm.contains(p.story, vm.toString(p.registry)));
        assertTrue(vm.contains(p.story, vm.toString(p.tank)));
        assertFalse(vm.contains(p.story, vm.toString(p.transistors)));
        assertFalse(vm.contains(p.story, vm.toString(p.circuits)));
    }

    /// The plan follows the deployer's nonce: another nonce, other addresses, another story.
    function test_fork_script_ignite_planDependsOnTheDeployersNonce() public {
        Ignite script = new Ignite();
        Ignite.Plan memory first = script.plan(broadcaster, broadcaster, COMMIT);
        vm.setNonce(broadcaster, vm.getNonce(broadcaster) + 1);
        Ignite.Plan memory second = script.plan(broadcaster, broadcaster, COMMIT);

        assertTrue(first.splitter != second.splitter);
        assertTrue(keccak256(bytes(first.story)) != keccak256(bytes(second.story)));
        assertEq(first.transistors, second.transistors, "those two depend on TapeOut's factory, not on the deployer");

        Splitter s = script.ignite(broadcaster, COMMIT, false);
        assertEq(address(s), second.splitter);
        assertEq(ITransistors(s.TRANSISTORS()).story(), second.story);
    }

    /// If what is created is not what was announced, the script stops: one test per thing announced.
    function test_fork_script_ignite_stopsIfTheStoryIsNotThePlannedOne() public {
        Ignite script = new IgniteWithAWrongPlan(0);
        vm.expectRevert(bytes("Ignite: story differs from the planned story"));
        script.ignite(broadcaster, COMMIT, false);
    }

    function test_fork_script_ignite_stopsIfAnAddressIsNotThePlannedOne() public {
        for (uint256 wrong = 1; wrong <= 5; wrong++) {
            Ignite script = new IgniteWithAWrongPlan(wrong);
            vm.expectRevert(bytes("Ignite: an address differs from the plan"));
            script.ignite(broadcaster, COMMIT, false);
        }
        // the harness with nothing wrong goes through: the reverts above came from the wrong plan alone
        new IgniteWithAWrongPlan(6).ignite(broadcaster, COMMIT, false);
    }

    function test_fork_script_ignite_acceptsCommitWithOrWithoutPrefix() public {
        Ignite script = new Ignite();
        assertEq(script.parseCommit("a1b2c3d4e5f60718293a4b5c6d7e8f9001234567"), COMMIT);
        assertEq(script.parseCommit("0xa1b2c3d4e5f60718293a4b5c6d7e8f9001234567"), COMMIT);
        assertEq(script.parseCommit("0xA1B2C3D4E5F60718293A4B5C6D7E8F9001234567"), COMMIT);

        vm.expectRevert(bytes("Ignite: COMMIT must be exactly 20 bytes (40 hex characters)"));
        script.parseCommit("a1b2c3d4e5f60718293a4b5c6d7e8f90012345"); // a short SHA
        vm.expectRevert(bytes("Ignite: COMMIT must be exactly 20 bytes (40 hex characters)"));
        script.parseCommit("a1b2c3d4e5f60718293a4b5c6d7e8f9001234567a1b2c3d4e5f60718293a4b5c"); // a SHA-256
    }

    /// The maintainer is the deploying account, or nothing is sent.
    function test_fork_script_ignite_refusesAMaintainerThatIsNotTheDeployer() public {
        Ignite script = new Ignite();
        uint256 before = broadcaster.balance;

        vm.expectRevert(bytes("Ignite: MAINTAINER is not the deploying account"));
        script.ignite(maintainer, COMMIT, false);
        vm.expectRevert(bytes("Ignite: MAINTAINER is not the deploying account"));
        script.ignite(address(0), COMMIT, false);
        vm.expectRevert(bytes("Ignite: MAINTAINER is not the deploying account"));
        script.ignite(address(script), COMMIT, false);

        assertEq(broadcaster.balance, before);
    }

    function test_fork_script_ignite_refusesAZeroCommit() public {
        Ignite script = new Ignite();
        vm.expectRevert(bytes("Ignite: COMMIT is zero"));
        script.ignite(broadcaster, bytes20(0), false);
    }

    /// Chain 196, or an explicit rehearsal.
    function test_fork_script_ignite_refusesAnotherChain_unlessItIsARehearsal() public {
        Ignite script = new Ignite();
        vm.chainId(31337);

        vm.expectRevert(
            bytes("Ignite: not X Layer (chain id 196); only a rehearsal (REHEARSAL=true) may run elsewhere")
        );
        script.ignite(broadcaster, COMMIT, false);

        // the same state under a rehearsal's chain id, with the flag: it runs
        Splitter s = script.ignite(broadcaster, COMMIT, true);
        assertEq(ITransistors(s.TRANSISTORS()).creator(), address(s));

        // on X Layer the flag changes nothing
        vm.chainId(196);
        script.ignite(broadcaster, COMMIT, true);
    }

    /// Where TapeOut's factory does not exist (a bare local node, another chain reached with the rehearsal
    /// flag) the script says so, before it reads or sends anything.
    function test_fork_script_ignite_refusesAChainWithoutTheFactory() public {
        Ignite script = new Ignite();
        bytes memory factoryCode = FACTORY.code;

        vm.etch(FACTORY, "");
        vm.expectRevert(bytes("Ignite: factory has no code"));
        script.ignite(broadcaster, COMMIT, true);
        vm.etch(FACTORY, factoryCode);

        // with the factory back the same call goes through
        script.ignite(broadcaster, COMMIT, true);
    }

    // ------------------------------------------------------------------ TapeoutProbe

    function _processor() internal returns (ICircuits c, ITransistors t, KeeperTank k) {
        Splitter s = _ignite(maintainer);
        c = ICircuits(s.CIRCUITS());
        t = ITransistors(s.TRANSISTORS());
        k = KeeperTank(payable(s.TANK()));
    }

    function test_fork_script_tapeoutProbe_fromEnvironment() public {
        (ICircuits c, ITransistors t, KeeperTank k) = _processor();
        vm.setEnv("CIRCUITS", vm.toString(address(c)));
        vm.setEnv("NETLIST_HEX", "000000020000030000000400000400000005000005"); // no 0x: accepted
        vm.setEnv("N_IN", "2");
        vm.setEnv("N_OUT", "1");

        uint256 before = broadcaster.balance;
        uint256 circuitId = new TapeoutProbe().run();

        assertEq(circuitId, 1, "first circuit of the processor");
        assertEq(c.ownerOf(circuitId), broadcaster);
        assertEq(c.netlist(circuitId), NAND3);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = c.circuitInfo(circuitId);
        assertEq(nIn, 2);
        assertEq(nOut, 1);
        assertEq(nState, 0);
        assertEq(gateCount, 3);

        // exactly three NAND minted and burned, one mint call, one tape-out
        assertEq(t.minted(), 3);
        assertEq(t.balanceOf(broadcaster, 0), 0);
        assertEq(before - broadcaster.balance, 3 * PRICE + PROTOCOL_FEE + TAPEOUT_FEE);
        assertEq(t.owed(broadcaster), 0, "nothing overpaid");
        assertEq(k.burnedOf(circuitId), 3);
    }

    function test_fork_script_tapeoutProbe_bothTransistorTypes_twoMintCalls() public {
        (ICircuits c, ITransistors t, KeeperTank k) = _processor();
        // LATCH d=5 -> signal 4; NAND(in0, latch) -> signal 5; NAND(signal 5, in1) -> signal 6 (the output)
        bytes memory netlist = hex"01000005" hex"00000002000004" hex"00000005000003";

        uint256 before = broadcaster.balance;
        uint256 circuitId = new TapeoutProbe().probe(address(c), netlist, 2, 1);

        (,, uint32 nState, uint32 gateCount) = c.circuitInfo(circuitId);
        assertEq(nState, 1);
        assertEq(gateCount, 3);
        assertEq(t.minted(), 3);
        assertEq(t.balanceOf(broadcaster, 0), 0);
        assertEq(t.balanceOf(broadcaster, 1), 0);
        // two mint calls, each paying TapeOut's per-call fee
        assertEq(before - broadcaster.balance, 3 * PRICE + 2 * PROTOCOL_FEE + TAPEOUT_FEE);
        assertEq(t.owed(broadcaster), 0);
        assertEq(k.burnedOf(circuitId), 3);
    }

    /// The real probe circuit (chips/probe/probe.hex: an 8-bit saturating counter, 109 NAND and 9 LATCH,
    /// 2 inputs, 10 outputs) through the script, on the real TapeOut contracts.
    function test_fork_script_tapeoutProbe_theRealProbeCircuit() public {
        (ICircuits c, ITransistors t, KeeperTank k) = _processor();
        bytes memory netlist = vm.parseBytes(vm.trim(vm.readFile("test/fixtures/probe.hex")));
        assertEq(netlist.length, 799);
        assertEq(keccak256(netlist), 0xbe0a646df5b58df69e5dc50f492dcc5bdcffa440c3188b8b786ff506cb181325);

        uint256 before = broadcaster.balance;
        uint256 circuitId = new TapeoutProbe().probe(address(c), netlist, 2, 10);

        assertEq(c.ownerOf(circuitId), broadcaster);
        assertEq(keccak256(c.netlist(circuitId)), keccak256(netlist));
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = c.circuitInfo(circuitId);
        assertEq(nIn, 2);
        assertEq(nOut, 10);
        assertEq(nState, 9);
        assertEq(gateCount, 118);
        assertEq(t.minted(), 118);
        assertEq(before - broadcaster.balance, 118 * PRICE + 2 * PROTOCOL_FEE + TAPEOUT_FEE);
        assertEq(before - broadcaster.balance, 0.00498 ether);

        // its allowance in the tank: 118 transistors at 85% of the price
        assertEq(k.burnedOf(circuitId), 118);
        assertEq(k.allowanceOf(circuitId), 118 * PRICE * 85 / 100);
    }

    function test_fork_script_tapeoutProbe_mintsOnlyWhatIsMissing() public {
        (ICircuits c, ITransistors t,) = _processor();
        // the broadcaster already holds two NAND (say, from an earlier run whose tape-out failed)
        vm.prank(broadcaster);
        t.mint{value: 2 * PRICE + PROTOCOL_FEE}(0, 2);

        uint256 before = broadcaster.balance;
        uint256 circuitId = new TapeoutProbe().probe(address(c), NAND3, 2, 1);

        assertEq(c.ownerOf(circuitId), broadcaster);
        assertEq(t.minted(), 3, "one more minted, not three");
        assertEq(t.balanceOf(broadcaster, 0), 0);
        assertEq(before - broadcaster.balance, 1 * PRICE + PROTOCOL_FEE + TAPEOUT_FEE);
    }

    /// A second run after a first one that got only as far as its NAND mint: with the real probe circuit the
    /// script buys the nine LATCH that are missing and nothing else.
    function test_fork_script_tapeoutProbe_rerunAfterAPartialRun_mintsOnlyTheMissingType() public {
        (ICircuits c, ITransistors t,) = _processor();
        bytes memory netlist = vm.parseBytes(vm.trim(vm.readFile("test/fixtures/probe.hex")));
        vm.prank(broadcaster);
        t.mint{value: 109 * PRICE + PROTOCOL_FEE}(0, 109);

        uint256 before = broadcaster.balance;
        uint256 circuitId = new TapeoutProbe().probe(address(c), netlist, 2, 10);

        assertEq(c.ownerOf(circuitId), broadcaster);
        assertEq(t.minted(), 118, "nine more minted, not another 118");
        assertEq(t.balanceOf(broadcaster, 0), 0);
        assertEq(t.balanceOf(broadcaster, 1), 0);
        assertEq(before - broadcaster.balance, 9 * PRICE + PROTOCOL_FEE + TAPEOUT_FEE, "one mint call, for the LATCH");
    }

    function test_fork_script_tapeoutProbe_refOnly_mintsNothing() public {
        (ICircuits c, ITransistors t, KeeperTank k) = _processor();
        TapeoutProbe script = new TapeoutProbe();
        uint256 base = script.probe(address(c), NAND3, 2, 1);

        bytes memory refNetlist =
            abi.encodePacked(uint8(2), address(c), uint64(base), uint8(2), uint8(1), uint24(2), uint24(3));
        uint256 before = broadcaster.balance;
        uint256 refChip = script.probe(address(c), refNetlist, 2, 1);

        assertEq(before - broadcaster.balance, TAPEOUT_FEE, "only the tape-out fee");
        assertEq(t.minted(), 3);
        assertEq(k.burnedOf(refChip), 0);
        (,,, uint32 gateCount) = c.circuitInfo(refChip);
        assertEq(gateCount, 3);
    }

    function test_fork_script_tapeoutProbe_refusesBadInput() public {
        (ICircuits c,,) = _processor();
        TapeoutProbe script = new TapeoutProbe();

        vm.expectRevert(bytes("TapeoutProbe: empty netlist"));
        script.probe(address(c), "", 2, 1);
        vm.expectRevert(bytes("TapeoutProbe: CIRCUITS has no code"));
        script.probe(makeAddr("nowhere"), NAND3, 2, 1);
        // a malformed netlist is caught before any transaction is sent
        vm.expectRevert();
        script.probe(address(c), hex"0000000200", 2, 1);

        assertEq(script.parseHex("0x00ff"), hex"00ff");
        assertEq(script.parseHex("00ff"), hex"00ff");
    }
}
