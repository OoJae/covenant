// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Fab} from "../../src/Fab.sol";
import {SealedVM} from "../../src/SealedVM.sol";
import {IFabV1} from "../../src/interfaces/IFabV1.sol";
import {ISealedVM} from "../../src/interfaces/ISealedVM.sol";
import {ITapeOutCircuits, ITapeOutTransistors} from "../../src/interfaces/ITapeOut.sol";
import {
    BadOpcode,
    FutureSignal,
    LatchOutOfRange,
    TooFewSignals,
    TruncatedRecord
} from "../../src/lib/NetlistErrors.sol";
import {NetlistScan} from "../../src/lib/NetlistScan.sol";
import {NetlistBuilder} from "./NetlistBuilder.sol";
import {ICircuitsView, ITapeOutFactory, ITransistorsView} from "./Oracles.sol";
import {V1Reference} from "./V1Reference.sol";

/// @dev The two ERC-721 transfers the tests make on a processor's circuit contract.
interface IERC721Like {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev A caller that is a contract and implements no receiver hook of any kind.
contract PlainCaller {
    function tape(Fab fab, bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256) {
        return fab.tapeoutChip{value: msg.value}(netlist, manifestHash);
    }

    function mintTransistors(ITransistorsView transistors, uint256 id, uint256 amount) external payable {
        transistors.mint{value: msg.value}(id, amount);
    }
}

/// @dev Code placed at TapeOut's treasury address: when it is paid the tape-out fee it tries to tape out
///      again through the Fab, and records how that call failed.
contract ReentrantTreasury {
    address public fab;
    bytes4 public seen;

    function arm(address fab_) external {
        fab = fab_;
    }

    receive() external payable {
        (bool ok, bytes memory ret) = fab.call(abi.encodeCall(IFabV1.tapeoutChip, ("", bytes32(0))));
        if (!ok) seen = bytes4(ret);
    }
}

/// @dev Code placed at TapeOut's treasury address: when it is paid the tape-out fee, which happens inside the
///      Fab's own tape-out, it calls the Fab's ERC-721 receiver hook as if it were handing over an NFT, and
///      records how that call failed.
contract HookCallingTreasury {
    address public fab;
    bool public called;
    bool public accepted;
    bytes4 public seen;

    function arm(address fab_) external {
        fab = fab_;
    }

    receive() external payable {
        (bool ok, bytes memory ret) =
            fab.call(abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", fab, address(0), 1, ""));
        called = true;
        accepted = ok;
        if (!ok) seen = bytes4(ret);
    }
}

/// @dev A replacement circuit implementation that answers every question wrongly.
contract LyingCircuits {
    function step(uint256, bytes calldata, bytes calldata) external pure returns (bytes memory, bytes memory) {
        return (hex"ff", hex"ffffffffffffffffffffffffffff");
    }

    function netlist(uint256) external pure returns (bytes memory) {
        return hex"00000000000000";
    }
}

/// @dev A second ERC-1155 token the Fab has nothing to do with.
contract StrayToken {
    function push(address to) external returns (bytes4) {
        return IERC1155Receiver(to).onERC1155Received(address(this), address(0), 0, 1, "");
    }
}

/// @notice The Fab's behaviour, written once and run twice: against TapeOut's vendored contracts deployed
///         locally (Fab.t.sol) and against the deployed contracts on an X Layer fork (fork/Fab.fork.t.sol).
abstract contract FabSuite is Test {
    using stdStorage for StdStorage;

    // ---- the TapeOut side
    ITapeOutFactory internal factory;
    ICircuitsView internal circuits;
    ITransistorsView internal transistors;
    address internal treasury;
    address internal protocolWallet;
    uint256 internal protocolFee;
    uint256 internal tapeoutFee;

    // ---- under test
    Fab internal fab;
    SealedVM internal sealedVM;

    // ---- the processor: 2^26 transistors at 0.00002 OKB each
    uint256 internal constant SUPPLY = 67_108_864;
    uint256 internal constant MINT_PRICE = 0.00002 ether;
    address internal creator = makeAddr("splitter");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    bytes32 internal constant TEMPLATE = keccak256("flow-governor");

    uint256 internal constant NAND = 0;
    uint256 internal constant LATCH = 1;
    bytes32 internal constant TRANSFER_SINGLE = keccak256("TransferSingle(address,address,address,uint256,uint256)");

    /// @dev The TapeOut factory of the environment: a local deployment or the one on X Layer.
    function _factory() internal virtual returns (ITapeOutFactory);

    function setUp() public virtual {
        factory = _factory();
        (address t, address c) = _createProcessor(SUPPLY, MINT_PRICE);
        transistors = ITransistorsView(t);
        circuits = ICircuitsView(c);
        treasury = circuits.TREASURY();
        protocolWallet = transistors.protocolWallet();
        protocolFee = transistors.protocolFee();
        tapeoutFee = circuits.TAPEOUT_FEE();

        fab = new Fab(c, t);
        sealedVM = new SealedVM();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _createProcessor(uint256 supply, uint256 price) internal returns (address t, address c) {
        uint256 fee = factory.deployFee();
        vm.deal(creator, fee);
        vm.prank(creator);
        (t, c) = factory.createCPU{value: fee}("Covenant", "CVNT", "test processor", supply, price);
        assertTrue(factory.isCPU(c));
    }

    // ------------------------------------------------------------------ helpers

    function _cost(uint256 nNand, uint256 nLatch) internal view returns (uint256) {
        return MINT_PRICE * (nNand + nLatch) + protocolFee * (nNand == 0 ? 1 : 2) + tapeoutFee;
    }

    function _tape(address who, bytes memory nl) internal returns (uint256 chipId) {
        (,, uint256 cost) = fab.quote(nl);
        vm.prank(who);
        chipId = fab.tapeoutChip{value: cost}(nl, TEMPLATE);
    }

    /// @dev The Fab holds nothing: no OKB, no transistors, no circuit NFT, and TapeOut owes it no refund.
    function _assertFabHoldsNothing() internal view {
        assertEq(address(fab).balance, 0, "Fab holds OKB");
        assertEq(transistors.balanceOf(address(fab), NAND), 0, "Fab holds NAND transistors");
        assertEq(transistors.balanceOf(address(fab), LATCH), 0, "Fab holds LATCH transistors");
        assertEq(circuits.balanceOf(address(fab)), 0, "Fab holds a circuit NFT");
        assertEq(transistors.owed(address(fab)), 0, "TapeOut owes the Fab a refund");
    }

    function _pointer(uint256 chipId) internal view returns (address pointer) {
        (pointer,,,,,) = fab.chipInfo(chipId);
    }

    /// @dev One beat on TapeOut's evaluator and on SealedVM over the Fab's snapshot: identical return data.
    function _assertSameBeat(uint256 chipId, bytes memory state, bytes memory inputs)
        internal
        view
        returns (bytes memory newState)
    {
        (bool okT, bytes memory retT) =
            address(circuits).staticcall(abi.encodeCall(ICircuitsView.step, (chipId, state, inputs)));
        (bool okS, bytes memory retS) =
            address(sealedVM).staticcall(abi.encodeCall(ISealedVM.step, (_pointer(chipId), 96, 112, state, inputs)));
        assertTrue(okT, "Circuits.step reverted");
        assertTrue(okS, "SealedVM.step reverted");
        assertEq(retS, retT, "SealedVM and Circuits.step return different data");
        (newState,) = abi.decode(retS, (bytes, bytes));
    }

    /// @dev `n` random (state, inputs) pairs, of every length class, then a run of beats that carries the state.
    function _assertSameOnRandomVectors(uint256 chipId, uint256 nState, uint256 n, uint256 seed) internal view {
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _assertSameBeat(chipId, _vector(r, nState), _vector(r >> 64, 96));
        }
        bytes32 word;
        for (uint256 beat = 0; beat < 8; beat++) {
            bytes memory inputs = NetlistBuilder.randomBytes(uint256(keccak256(abi.encode(seed, "beat", beat))), 12);
            word = bytes32(_assertSameBeat(chipId, abi.encodePacked(word), inputs));
        }
    }

    function _vector(uint256 seed, uint256 n) internal pure returns (bytes memory out) {
        uint256 exact = NetlistBuilder.bytesFor(n);
        uint256 mode = seed % 5;
        uint256 r = uint256(keccak256(abi.encode(seed, "vector")));
        if (mode == 0) return NetlistBuilder.randomBytes(r, exact);
        if (mode == 1) return NetlistBuilder.randomBytes(r, r % exact);
        if (mode == 2) return NetlistBuilder.randomBytes(r, exact + 1 + (r % 40));
        if (mode == 3) return "";
        return NetlistBuilder.randomBytes(r, 32); // the kernel's 32-byte state word
    }

    /// @dev Sums the transistor movements in the recorded logs: minted to the Fab, burned from the Fab.
    function _transistorFlows(Vm.Log[] memory logs)
        internal
        view
        returns (uint256[2] memory minted, uint256[2] memory burned, uint256 others)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(transistors) || logs[i].topics[0] != TRANSFER_SINGLE) continue;
            address from = address(uint160(uint256(logs[i].topics[2])));
            address to = address(uint160(uint256(logs[i].topics[3])));
            (uint256 id, uint256 value) = abi.decode(logs[i].data, (uint256, uint256));
            if (from == address(0) && to == address(fab)) minted[id] += value;
            else if (from == address(fab) && to == address(0)) burned[id] += value;
            else others++;
        }
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_readsTheProcessor() public {
        assertEq(address(fab.CIRCUITS()), address(circuits));
        assertEq(address(fab.TRANSISTORS()), address(transistors));
        assertEq(fab.N_IN(), 96);
        assertEq(fab.N_OUT(), 112);
        // the live values this suite was written against
        assertEq(protocolFee, 0.00066 ether);
        assertEq(tapeoutFee, 0.0013 ether);
        // the Fab stores no price: there is nothing to read back but the two addresses
        string[3] memory removed = ["MINT_PRICE()", "PROTOCOL_FEE()", "TAPEOUT_FEE()"];
        for (uint256 i = 0; i < 3; i++) {
            (bool ok,) = address(fab).call(abi.encodeWithSignature(removed[i]));
            assertFalse(ok, removed[i]);
        }
    }

    /// The rename of the free bytes32 to manifestHash, and the declaration of tapeoutChipTo in IFabV1, moved
    /// no selector and no event topic: these are the values of the build before the rename.
    function test_abi_selectorsAndTopic_areUnchangedByTheRename() public pure {
        assertEq(IFabV1.tapeoutChip.selector, bytes4(0x310f9b25));
        assertEq(IFabV1.tapeoutChipTo.selector, bytes4(0x474c10b2));
        assertEq(IFabV1.quote.selector, bytes4(0xedfa3568));
        assertEq(IFabV1.isChip.selector, bytes4(0x5ae77099));
        assertEq(IFabV1.chipInfo.selector, bytes4(0x4c9540b3));
        assertEq(IFabV1.snapshot.selector, bytes4(0x8f1dd809));
        assertEq(Fab.tapeoutChip.selector, IFabV1.tapeoutChip.selector);
        assertEq(Fab.tapeoutChipTo.selector, IFabV1.tapeoutChipTo.selector);
        assertEq(Fab.ChipTaped.selector, 0x3571db5a1350d73a2ebbaca738dad0bc6b07958ee11f3ee157b80c2b104ce147);
        assertEq(Fab.ChipTaped.selector, keccak256("ChipTaped(uint256,address,bytes32,bytes32,uint32,uint32)"));
    }

    function test_constructor_rejectsAnythingButOneProcessor() public {
        (address t2, address c2) = _createProcessor(1000, 1);

        vm.expectRevert(Fab.NotAProcessor.selector);
        new Fab(address(circuits), t2); // transistors of another processor
        vm.expectRevert(Fab.NotAProcessor.selector);
        new Fab(c2, address(transistors));
        vm.expectRevert(Fab.NotAProcessor.selector);
        new Fab(alice, address(transistors)); // not a contract
        vm.expectRevert(Fab.NotAProcessor.selector);
        new Fab(address(circuits), address(0));
        vm.expectRevert(); // the two swapped: the calls do not exist on the other contract
        new Fab(address(transistors), address(circuits));

        new Fab(c2, t2); // a matching pair is fine
    }

    function test_hasNoWayToReceiveOrSendValue() public {
        (bool ok,) = address(fab).call{value: 1 wei}("");
        assertFalse(ok, "plain transfer accepted");
        (ok,) = address(fab).call{value: 1 wei}(hex"12345678");
        assertFalse(ok, "unknown selector accepted");
        (ok,) = address(fab).call(hex"12345678");
        assertFalse(ok, "fallback exists");
        // non-payable entry points refuse value
        (ok,) = address(fab).call{value: 1 wei}(abi.encodeCall(IFabV1.isChip, (1)));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ quote

    function test_quote() public view {
        (uint256 nNand, uint256 nLatch, uint256 cost) = fab.quote(NetlistBuilder.minimalV1(64));
        assertEq(nNand, 112);
        assertEq(nLatch, 64);
        assertEq(cost, MINT_PRICE * 176 + 2 * protocolFee + tapeoutFee);
        assertEq(cost, 0.00352 ether + 0.00132 ether + 0.0013 ether);

        // 112 LATCH records and no NAND: one mint call, one protocol fee
        bytes memory allLatch = NetlistBuilder.randomV1(5, 112, 0);
        (nNand, nLatch, cost) = fab.quote(allLatch);
        assertEq(nNand, 0);
        assertEq(nLatch, 112);
        assertEq(cost, MINT_PRICE * 112 + protocolFee + tapeoutFee);

        // the largest chip
        (nNand, nLatch, cost) = fab.quote(NetlistBuilder.randomV1(6, 256, 3144));
        assertEq(cost, MINT_PRICE * 3400 + 2 * protocolFee + tapeoutFee);
    }

    // ------------------------------------------------------------------ tape-out

    /// @dev Balances and counters on the TapeOut side.
    struct Ledger {
        uint256 payer;
        uint256 treasury;
        uint256 held; // OKB held by the transistor contract (pull payments)
        uint256 owedCreator;
        uint256 owedProtocol;
        uint256 minted;
    }

    function _ledger(address payer) internal view returns (Ledger memory l) {
        l.payer = payer.balance;
        l.treasury = treasury.balance;
        l.held = address(transistors).balance;
        l.owedCreator = transistors.owed(creator);
        l.owedProtocol = transistors.owed(protocolWallet);
        l.minted = transistors.minted();
    }

    function test_tapeoutChip_accountsForEveryWeiAndEveryTransistor() public {
        bytes memory nl = NetlistBuilder.randomV1(1, 64, 436); // 500 gates
        (uint256 nNand, uint256 nLatch, uint256 cost) = fab.quote(nl);
        assertEq(nNand, 436);
        assertEq(nLatch, 64);
        assertEq(cost, _cost(436, 64));

        uint256 id = circuits.nextId() + 1;
        Ledger memory before = _ledger(alice);

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(fab));
        emit Fab.ChipTaped(id, alice, TEMPLATE, keccak256(nl), 64, 500);
        vm.prank(alice);
        uint256 chipId = fab.tapeoutChip{value: cost}(nl, TEMPLATE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(chipId, id);

        // value: alice paid exactly the cost, and all of it went to TapeOut
        Ledger memory now_ = _ledger(alice);
        assertEq(now_.payer, before.payer - cost);
        assertEq(now_.treasury, before.treasury + tapeoutFee, "tape-out fee");
        assertEq(now_.held, before.held + cost - tapeoutFee, "mint payments");
        assertEq(now_.owedCreator, before.owedCreator + MINT_PRICE * 500, "creator proceeds");
        assertEq(now_.owedProtocol, before.owedProtocol + 2 * protocolFee, "protocol fees");

        // transistors: exactly 436 NAND and 64 LATCH minted to the Fab and burned from it
        (uint256[2] memory minted, uint256[2] memory burned, uint256 others) = _transistorFlows(logs);
        assertEq(minted[NAND], 436);
        assertEq(minted[LATCH], 64);
        assertEq(burned[NAND], 436);
        assertEq(burned[LATCH], 64);
        assertEq(others, 0, "transistors moved anywhere else");
        assertEq(now_.minted, before.minted + 500);
        assertEq(transistors.balanceOf(alice, NAND), 0);
        assertEq(transistors.balanceOf(alice, LATCH), 0);

        _assertFabHoldsNothing();
        assertEq(circuits.ownerOf(chipId), alice, "the circuit NFT is the caller's");
        _assertRecorded(chipId, nl, 64, 500, alice, TEMPLATE);
        _assertSameOnRandomVectors(chipId, 64, 24, 1);
    }

    /// @dev What TapeOut recorded and what the Fab recorded for a chip.
    function _assertRecorded(
        uint256 chipId,
        bytes memory nl,
        uint256 nState,
        uint256 gateCount,
        address author,
        bytes32 manifestHash
    ) internal view {
        {
            (uint32 tIn, uint32 tOut, uint32 tState, uint32 tGates) = circuits.circuitInfo(chipId);
            assertEq(tIn, 96);
            assertEq(tOut, 112);
            assertEq(tState, nState);
            assertEq(tGates, gateCount);
            assertEq(circuits.netlist(chipId), nl);
        }
        assertTrue(fab.isChip(chipId));
        (address pointer, bytes32 hash, uint32 fState, uint32 fGates, address fAuthor, bytes32 fManifest) =
            fab.chipInfo(chipId);
        assertEq(hash, keccak256(nl));
        assertEq(fState, nState);
        assertEq(fGates, gateCount);
        assertEq(fAuthor, author);
        assertEq(fManifest, manifestHash);
        assertEq(fab.snapshot(chipId), nl, "snapshot bytes");
        assertEq(pointer.code, abi.encodePacked(hex"00", nl), "pointer format: STOP, then the netlist");
    }

    function test_tapeoutChip_severalChips() public {
        // sizes and state counts across the allowed range, by two authors
        uint256[2][6] memory shapes = [
            [uint256(1), 111],
            [uint256(1), 3399],
            [uint256(256), 3144],
            [uint256(64), 2120],
            [uint256(256), 0],
            [uint256(7), 300]
        ];
        uint256 first = circuits.nextId() + 1;
        for (uint256 i = 0; i < shapes.length; i++) {
            bytes memory nl = NetlistBuilder.randomV1(100 + i, shapes[i][0], shapes[i][1]);
            address who = i % 2 == 0 ? alice : bob;
            uint256 before = who.balance;
            uint256 mintedBefore = transistors.minted();

            uint256 chipId = _tape(who, nl);

            assertEq(chipId, first + i, "ids follow TapeOut's counter");
            assertEq(who.balance, before - _cost(shapes[i][1], shapes[i][0]));
            assertEq(transistors.minted(), mintedBefore + shapes[i][0] + shapes[i][1]);
            assertEq(circuits.ownerOf(chipId), who);
            _assertRecorded(chipId, nl, shapes[i][0], shapes[i][0] + shapes[i][1], who, TEMPLATE);
            _assertFabHoldsNothing();
            _assertSameOnRandomVectors(chipId, shapes[i][0], 12, i);
        }
        // earlier records are untouched by later tape-outs
        assertEq(fab.snapshot(first), NetlistBuilder.randomV1(100, 1, 111));
    }

    function test_tapeoutChip_minimalChips() public {
        uint256[4] memory ks = [uint256(1), 8, 64, 256];
        for (uint256 i = 0; i < ks.length; i++) {
            bytes memory nl = NetlistBuilder.minimalV1(ks[i]);
            uint256 chipId = _tape(alice, nl);
            assertEq(fab.snapshot(chipId), nl);
            _assertFabHoldsNothing();
            _assertSameOnRandomVectors(chipId, ks[i], 16, i);
        }
    }

    function test_tapeoutChip_withoutNand_mintsOnce() public {
        bytes memory nl = NetlistBuilder.randomV1(5, 112, 0);
        uint256 owedProtocol = transistors.owed(protocolWallet);
        uint256 cost = MINT_PRICE * 112 + protocolFee + tapeoutFee;

        vm.recordLogs();
        vm.prank(alice);
        uint256 chipId = fab.tapeoutChip{value: cost}(nl, TEMPLATE);
        (uint256[2] memory minted, uint256[2] memory burned,) = _transistorFlows(vm.getRecordedLogs());

        assertEq(minted[NAND], 0);
        assertEq(minted[LATCH], 112);
        assertEq(burned[LATCH], 112);
        assertEq(transistors.owed(protocolWallet), owedProtocol + protocolFee, "one mint call, one fee");
        _assertFabHoldsNothing();
        _assertSameOnRandomVectors(chipId, 112, 12, 9);
    }

    function test_tapeoutChipTo_sendsTheNftElsewhere() public {
        bytes memory nl = NetlistBuilder.minimalV1(3);
        (,, uint256 cost) = fab.quote(nl);
        uint256 id = circuits.nextId() + 1;

        vm.expectEmit(true, true, true, true, address(fab));
        emit Fab.ChipTaped(id, alice, bytes32(uint256(7)), keccak256(nl), 3, 115);
        vm.prank(alice);
        uint256 chipId = fab.tapeoutChipTo{value: cost}(nl, bytes32(uint256(7)), bob);

        assertEq(circuits.ownerOf(chipId), bob, "NFT goes to `to`");
        (,,,, address author, bytes32 manifestHash) = fab.chipInfo(chipId);
        assertEq(author, alice, "the author is the caller");
        assertEq(manifestHash, bytes32(uint256(7)));
        _assertFabHoldsNothing();

        // the same through the interface: tapeoutChipTo is part of IFabV1
        vm.prank(alice);
        uint256 second = IFabV1(address(fab)).tapeoutChipTo{value: cost}(nl, bytes32(uint256(8)), bob);
        assertEq(circuits.ownerOf(second), bob);
        (,,,,, manifestHash) = IFabV1(address(fab)).chipInfo(second);
        assertEq(manifestHash, bytes32(uint256(8)));
    }

    function test_tapeoutChipTo_rejectsBadRecipients() public {
        bytes memory nl = NetlistBuilder.minimalV1(3);
        (,, uint256 cost) = fab.quote(nl);
        vm.startPrank(alice);
        vm.expectRevert(Fab.BadRecipient.selector);
        fab.tapeoutChipTo{value: cost}(nl, TEMPLATE, address(0));
        vm.expectRevert(Fab.BadRecipient.selector);
        fab.tapeoutChipTo{value: cost}(nl, TEMPLATE, address(fab));
        vm.stopPrank();
        _assertFabHoldsNothing();
    }

    function test_callerMayBeAContractWithoutReceiverHooks() public {
        PlainCaller caller = new PlainCaller();
        bytes memory nl = NetlistBuilder.minimalV1(2);
        (,, uint256 cost) = fab.quote(nl);
        uint256 chipId = caller.tape{value: cost}(fab, nl, TEMPLATE);
        assertEq(circuits.ownerOf(chipId), address(caller));
        (,,,, address author,) = fab.chipInfo(chipId);
        assertEq(author, address(caller));
        _assertFabHoldsNothing();
    }

    // ------------------------------------------------------------------ value

    function test_revert_wrongValue() public {
        bytes memory nl = NetlistBuilder.minimalV1(4);
        (,, uint256 cost) = fab.quote(nl);
        uint256 nextId = circuits.nextId();
        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(Fab.WrongValue.selector, cost - 1, cost));
        fab.tapeoutChip{value: cost - 1}(nl, TEMPLATE);
        vm.expectRevert(abi.encodeWithSelector(Fab.WrongValue.selector, cost + 1, cost));
        fab.tapeoutChip{value: cost + 1}(nl, TEMPLATE);
        vm.expectRevert(abi.encodeWithSelector(Fab.WrongValue.selector, 0, cost));
        fab.tapeoutChip(nl, TEMPLATE);
        vm.expectRevert(abi.encodeWithSelector(Fab.WrongValue.selector, 1 ether, cost));
        fab.tapeoutChipTo{value: 1 ether}(nl, TEMPLATE, bob);

        vm.stopPrank();
        assertEq(circuits.nextId(), nextId, "nothing was taped out");
        _assertFabHoldsNothing();
    }

    function test_forcedBalance_isNeitherSpentNorReleased() public {
        // OKB can be forced into any address. It must not subsidise a tape-out and nobody can take it out.
        vm.deal(address(fab), 5 ether);
        bytes memory nl = NetlistBuilder.minimalV1(4);
        (,, uint256 cost) = fab.quote(nl);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Fab.WrongValue.selector, cost - 1, cost));
        fab.tapeoutChip{value: cost - 1}(nl, TEMPLATE);

        uint256 before = alice.balance;
        vm.prank(alice);
        fab.tapeoutChip{value: cost}(nl, TEMPLATE);
        assertEq(alice.balance, before - cost);
        assertEq(address(fab).balance, 5 ether, "the forced balance did not move");
    }

    // ------------------------------------------------------------------ rejected netlists

    function _expectRejected(bytes memory nl, bytes memory err) internal {
        vm.expectRevert(err);
        fab.quote(nl);
        vm.prank(alice);
        vm.expectRevert(err);
        fab.tapeoutChip{value: 1 ether}(nl, TEMPLATE);
        vm.prank(alice);
        vm.expectRevert(err);
        fab.tapeoutChipTo{value: 1 ether}(nl, TEMPLATE, bob);
    }

    function test_revert_wrongShape() public {
        uint256 nextId = circuits.nextId();

        // a combinational circuit: no LATCH
        _expectRejected(
            NetlistBuilder.random(1, 96, 0, 200, true),
            abi.encodeWithSelector(NetlistScan.StateCountOutOfRange.selector, 0)
        );
        // 257 state bits
        _expectRejected(
            NetlistBuilder.randomV1(2, 257, 200), abi.encodeWithSelector(NetlistScan.StateCountOutOfRange.selector, 257)
        );
        // 111 records cannot drive 112 outputs
        _expectRejected(NetlistBuilder.randomV1(3, 1, 110), abi.encodeWithSelector(TooFewSignals.selector, 111));
        // an empty netlist
        _expectRejected("", abi.encodeWithSelector(NetlistScan.StateCountOutOfRange.selector, 0));

        assertEq(circuits.nextId(), nextId);
        _assertFabHoldsNothing();
    }

    function test_revert_refRecord() public {
        bytes memory ref = abi.encodePacked(uint8(0x02), address(circuits), uint64(1), uint8(1), uint8(1), uint24(2));
        bytes memory nl = bytes.concat(NetlistBuilder.minimalV1(2), ref);
        _expectRejected(nl, abi.encodeWithSelector(NetlistScan.RefNotAllowed.selector, 8 + 7 * 112));
    }

    function test_revert_unknownOpcode() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        nl[8] = 0x07;
        _expectRejected(nl, abi.encodeWithSelector(BadOpcode.selector, 8, 7));
    }

    function test_revert_latchAfterNand() public {
        bytes memory nl = bytes.concat(NetlistBuilder.minimalV1(2), NetlistBuilder.latch(0));
        _expectRejected(nl, abi.encodeWithSelector(NetlistScan.LatchAfterNand.selector, 8 + 7 * 112));
    }

    function test_revert_tooBig() public {
        _expectRejected(
            NetlistBuilder.randomV1(4, 64, 3337), abi.encodeWithSelector(NetlistScan.TooManyGates.selector, 3401)
        );
        _expectRejected(
            NetlistBuilder.randomV1(5, 1, 3429), abi.encodeWithSelector(NetlistScan.NetlistTooLong.selector, 24007)
        );
    }

    function test_revert_futureSignal() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        // the first NAND produces signal 100; make it read signal 100
        nl[8 + 3] = bytes1(uint8(100));
        _expectRejected(nl, abi.encodeWithSelector(FutureSignal.selector, 8));
    }

    function test_revert_latchOutOfRange() public {
        bytes memory nl = NetlistBuilder.minimalV1(2); // 98 + 114 = 212 signals
        nl[3] = bytes1(uint8(212));
        _expectRejected(nl, abi.encodeWithSelector(LatchOutOfRange.selector, 212, 212));
    }

    function test_revert_truncated() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        _expectRejected(NetlistBuilder.head(nl, nl.length - 1), abi.encodePacked(TruncatedRecord.selector));
    }

    /// @dev What the Fab accepts and what it refuses is exactly section 2, and a refusal changes nothing.
    ///      The fuzz entry points are in the concrete suites, which set their own number of runs.
    function _checkAcceptsExactlyV1Chips(uint256 seed) internal {
        bytes memory nl = V1Reference.mutant(seed);
        (bool valid, uint256 nNand, uint256 nLatch) = V1Reference.check(nl);
        uint256 nextId = circuits.nextId();
        uint256 mintedBefore = transistors.minted();
        uint256 value = valid ? _cost(nNand, nLatch) : 1 ether;

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(fab).call{value: value}(abi.encodeCall(IFabV1.tapeoutChip, (nl, TEMPLATE)));
        assertEq(ok, valid, "the Fab and the reference disagree");

        if (ok) {
            uint256 chipId = abi.decode(ret, (uint256));
            assertEq(chipId, nextId + 1);
            assertEq(fab.snapshot(chipId), nl);
            assertEq(circuits.ownerOf(chipId), alice);
            assertEq(transistors.minted(), mintedBefore + nNand + nLatch);
            _assertSameOnRandomVectors(chipId, nLatch, 4, seed);
        } else {
            assertEq(circuits.nextId(), nextId);
            assertEq(transistors.minted(), mintedBefore);
            assertFalse(fab.isChip(nextId + 1));
        }
        _assertFabHoldsNothing();
    }

    /// @dev Random valid chips of every size: exact cost, exact transistors, nothing left in the Fab,
    ///      and the two evaluators agree.
    function _checkTapeoutInvariants(uint256 seed, uint16 latchSeed, uint16 nandSeed, bool toBob) internal {
        uint256 k = 1 + (uint256(latchSeed) % 256);
        uint256 lo = k >= 112 ? 0 : 112 - k;
        uint256 n = lo + (uint256(nandSeed) % (3400 - k - lo + 1));
        bytes memory nl = NetlistBuilder.randomV1(seed, k, n);
        uint256 cost = _cost(n, k);
        Ledger memory before = _ledger(alice);

        vm.prank(alice);
        uint256 chipId =
            toBob ? fab.tapeoutChipTo{value: cost}(nl, TEMPLATE, bob) : fab.tapeoutChip{value: cost}(nl, TEMPLATE);

        Ledger memory now_ = _ledger(alice);
        assertEq(now_.payer, before.payer - cost);
        assertEq(now_.treasury, before.treasury + tapeoutFee);
        assertEq(now_.held, before.held + cost - tapeoutFee);
        assertEq(now_.minted, before.minted + n + k);
        assertEq(now_.owedCreator, before.owedCreator + MINT_PRICE * (n + k));
        assertEq(circuits.ownerOf(chipId), toBob ? bob : alice);
        _assertRecorded(chipId, nl, k, n + k, alice, TEMPLATE);
        _assertFabHoldsNothing();
        _assertSameOnRandomVectors(chipId, k, 3, seed);
    }

    // ------------------------------------------------------------------ transistors and the receiver hook

    function test_mintToAContract_runsTheAcceptanceCheck() public {
        // The fact the Fab's hook exists for: Transistors.mint to a contract without the hook reverts.
        PlainCaller caller = new PlainCaller();
        uint256 value = MINT_PRICE * 5 + protocolFee;
        vm.expectRevert(abi.encodeWithSignature("ERC1155InvalidReceiver(address)", address(caller)));
        caller.mintTransistors{value: value}(transistors, NAND, 5);
    }

    function test_hook_refusesEveryTransferButTheFabsOwnMint() public {
        // someone holding transistors cannot push them into the Fab
        vm.startPrank(alice);
        transistors.mint{value: MINT_PRICE * 10 + protocolFee}(NAND, 10);
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        transistors.safeTransferFrom(alice, address(fab), NAND, 10, "");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = NAND;
        values[0] = 10;
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        transistors.safeBatchTransferFrom(alice, address(fab), ids, values, "");
        vm.stopPrank();

        // a call that does not come from the processor's transistor contract
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        fab.onERC1155Received(address(fab), address(0), NAND, 1, "");
        StrayToken stray = new StrayToken();
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        stray.push(address(fab));

        // from the transistor contract, but not a mint by the Fab
        vm.startPrank(address(transistors));
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        fab.onERC1155Received(alice, address(0), NAND, 1, "");
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        fab.onERC1155Received(address(fab), alice, NAND, 1, "");
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        fab.onERC1155BatchReceived(address(fab), address(0), ids, values, "");
        // the one accepted shape
        assertEq(
            fab.onERC1155Received(address(fab), address(0), NAND, 1, ""), IERC1155Receiver.onERC1155Received.selector
        );
        vm.stopPrank();

        assertEq(transistors.balanceOf(alice, NAND), 10);
        _assertFabHoldsNothing();
    }

    function test_supportsInterface() public view {
        assertTrue(fab.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(fab.supportsInterface(type(IERC165).interfaceId));
        assertFalse(fab.supportsInterface(0xffffffff));
        // The ERC-721 receiver hook exists, for the processor's own mint during a tape-out only. ERC-721 does
        // not ask a receiver for ERC-165, and the Fab does not claim to accept NFTs.
        assertFalse(fab.supportsInterface(0x150b7a02));
    }

    function test_supplyCap_revertsCleanly() public {
        // a processor with room for 150 transistors: a 176-gate chip does not fit, a 115-gate chip does
        (address t, address c) = _createProcessor(150, MINT_PRICE);
        Fab small = new Fab(c, t);

        bytes memory nl = NetlistBuilder.minimalV1(64);
        (,, uint256 cost) = small.quote(nl);
        vm.prank(alice);
        vm.expectRevert(bytes("supply cap"));
        small.tapeoutChip{value: cost}(nl, TEMPLATE);
        assertEq(address(small).balance, 0);
        assertEq(ITransistorsView(t).minted(), 0);

        nl = NetlistBuilder.minimalV1(3);
        (,, cost) = small.quote(nl);
        vm.prank(alice);
        uint256 chipId = small.tapeoutChip{value: cost}(nl, TEMPLATE);
        assertEq(ICircuitsView(c).ownerOf(chipId), alice);
        assertEq(ITransistorsView(t).minted(), 115);
        assertTrue(small.isChip(chipId));
        assertFalse(fab.isChip(chipId), "a Fab knows only the chips of its own processor");
    }

    // ------------------------------------------------------------------ registry

    function test_unknownChip() public {
        assertFalse(fab.isChip(0));
        assertFalse(fab.isChip(1));
        vm.expectRevert(abi.encodeWithSelector(Fab.NotAChip.selector, 1));
        fab.chipInfo(1);
        vm.expectRevert(abi.encodeWithSelector(Fab.NotAChip.selector, 1));
        fab.snapshot(1);
    }

    function test_directTapeout_isNotAChip() public {
        // A circuit taped out on the processor without the Fab exists on TapeOut but is not registered.
        bytes memory nl = NetlistBuilder.minimalV1(2);
        vm.startPrank(alice);
        transistors.mint{value: MINT_PRICE * 112 + protocolFee}(NAND, 112);
        transistors.mint{value: MINT_PRICE * 2 + protocolFee}(LATCH, 2);
        uint256 direct = circuits.tapeout{value: tapeoutFee}(nl, 96, 112);
        vm.stopPrank();

        assertEq(circuits.ownerOf(direct), alice);
        assertFalse(fab.isChip(direct));
        vm.expectRevert(abi.encodeWithSelector(Fab.NotAChip.selector, direct));
        fab.chipInfo(direct);

        // and the Fab's ids keep following TapeOut's counter
        uint256 chipId = _tape(bob, nl);
        assertEq(chipId, direct + 1);
        assertTrue(fab.isChip(chipId));
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancy_fromTheTreasury_isBlocked() public {
        // TapeOut pays its treasury during tapeout, with 30,000 gas. Put code there that calls back.
        ReentrantTreasury impl = new ReentrantTreasury();
        vm.etch(treasury, address(impl).code);
        ReentrantTreasury(payable(treasury)).arm(address(fab));

        bytes memory nl = NetlistBuilder.minimalV1(2);
        uint256 chipId = _tape(alice, nl);

        assertEq(
            ReentrantTreasury(payable(treasury)).seen(),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "the call back into the Fab was not stopped by the lock"
        );
        assertEq(circuits.ownerOf(chipId), alice);
        _assertFabHoldsNothing();

        // the lock is released afterwards
        _tape(alice, nl);
    }

    // ------------------------------------------------------------------ TapeOut upgraded

    /// @notice The reason both contracts exist. TapeOut's owner replaces the processor logic; the chip's
    ///         snapshot and the sealed evaluator give the same answers as before, whatever TapeOut says now.
    function test_tapeOutUpgrade_doesNotChangeWhatTheSealedEvaluatorReturns() public {
        bytes memory nl = NetlistBuilder.randomV1(77, 64, 936);
        uint256 chipId = _tape(alice, nl);
        address pointer = _pointer(chipId);

        // answers before the upgrade, from TapeOut itself
        bytes[] memory states = new bytes[](6);
        bytes[] memory inputs = new bytes[](6);
        bytes[] memory answers = new bytes[](6);
        for (uint256 i = 0; i < 6; i++) {
            states[i] = NetlistBuilder.randomBytes(i, 32);
            inputs[i] = NetlistBuilder.randomBytes(i + 100, 12);
            (bool ok, bytes memory ret) =
                address(circuits).staticcall(abi.encodeCall(ICircuitsView.step, (chipId, states[i], inputs[i])));
            assertTrue(ok);
            answers[i] = ret;
        }

        // the factory owner (a 3-of-5 Safe on X Layer) swaps the circuit implementation
        LyingCircuits lying = new LyingCircuits();
        vm.prank(factory.owner());
        factory.upgradeCircuits(address(lying));

        // TapeOut now says something else about the same chip ...
        (bytes memory lieState, bytes memory lieOut) = circuits.step(chipId, states[0], inputs[0]);
        assertEq(lieState, hex"ff");
        assertEq(lieOut, hex"ffffffffffffffffffffffffffff");
        assertEq(circuits.netlist(chipId), hex"00000000000000");

        // ... and the Fab's record and the sealed evaluator do not care
        assertTrue(fab.isChip(chipId));
        assertEq(_pointer(chipId), pointer);
        assertEq(fab.snapshot(chipId), nl);
        for (uint256 i = 0; i < 6; i++) {
            (bool ok, bytes memory ret) =
                address(sealedVM).staticcall(abi.encodeCall(ISealedVM.step, (pointer, 96, 112, states[i], inputs[i])));
            assertTrue(ok);
            assertEq(ret, answers[i], "the sealed evaluator changed its answer");
        }

        // This replacement has no TAPEOUT_FEE view, so the Fab cannot read the price of a tape-out: nothing is
        // paid and nothing is recorded. (The Fab does not recognise changed logic as such.)
        (bool quoted,) = address(fab).staticcall(abi.encodeCall(IFabV1.quote, (nl)));
        assertFalse(quoted);
        uint256 before = alice.balance;
        vm.prank(alice);
        (bool taped,) = address(fab).call{value: _cost(936, 64)}(abi.encodeCall(IFabV1.tapeoutChip, (nl, TEMPLATE)));
        assertFalse(taped);
        assertEq(alice.balance, before);
        assertEq(address(fab).balance, 0);
        assertEq(transistors.balanceOf(address(fab), NAND), 0);
        assertEq(transistors.balanceOf(address(fab), LATCH), 0);
    }

    // ------------------------------------------------------------------ prices are read on every call

    /// @dev Changes what the processor really charges: the two prices of the transistor contract live in its
    ///      storage (slots found with stdstore, written with vm.store), the tape-out fee in the circuit logic
    ///      (replaced through the factory's beacon, as TapeOut's owner could).
    function _setMintPrice(uint256 v) internal {
        uint256 slot = stdstore.target(address(transistors)).sig("mintPrice()").find();
        vm.store(address(transistors), bytes32(slot), bytes32(v));
        assertEq(transistors.mintPrice(), v);
    }

    function _setProtocolFee(uint256 v) internal {
        uint256 slot = stdstore.target(address(transistors)).sig("protocolFee()").find();
        vm.store(address(transistors), bytes32(slot), bytes32(v));
        assertEq(transistors.protocolFee(), v);
    }

    function _upgradeCircuits(uint256 fee, bool safeMint, bool burnLatch) internal {
        address logic = deployCode("TestCircuits.sol:TestCircuits", abi.encode(fee, safeMint, burnLatch));
        vm.prank(factory.owner());
        factory.upgradeCircuits(logic);
        assertEq(circuits.TAPEOUT_FEE(), fee);
    }

    /// TapeOut changes each of its three prices, down and up. The Fab stores none of them: `quote` and the
    /// tape-out follow at once, the old cost is refused, the new one is paid to the wei, and TapeOut owes
    /// the Fab nothing afterwards.
    function test_prices_areReadOnEveryCall() public {
        bytes memory nl = NetlistBuilder.randomV1(31, 16, 284); // 300 gates
        (,, uint256 cost0) = fab.quote(nl);
        assertEq(cost0, MINT_PRICE * 300 + 2 * protocolFee + tapeoutFee);
        _tape(alice, nl);

        // (mint price, protocol fee, tape-out fee) after each change
        uint256[3][6] memory steps = [
            [MINT_PRICE / 2, protocolFee, tapeoutFee],
            [MINT_PRICE * 3, protocolFee, tapeoutFee],
            [MINT_PRICE * 3, protocolFee / 3, tapeoutFee],
            [MINT_PRICE * 3, protocolFee * 2, tapeoutFee],
            [MINT_PRICE * 3, protocolFee * 2, tapeoutFee / 2],
            [uint256(1), 0, tapeoutFee * 5]
        ];
        uint256 previous = cost0;
        for (uint256 i = 0; i < steps.length; i++) {
            _setMintPrice(steps[i][0]);
            _setProtocolFee(steps[i][1]);
            if (circuits.TAPEOUT_FEE() != steps[i][2]) _upgradeCircuits(steps[i][2], false, true);

            uint256 cost = steps[i][0] * 300 + 2 * steps[i][1] + steps[i][2];
            (,, uint256 quoted) = fab.quote(nl);
            assertEq(quoted, cost, "quote follows TapeOut's prices");
            assertTrue(cost != previous);

            // what was right a moment ago is refused, whichever way the price moved
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Fab.WrongValue.selector, previous, cost));
            fab.tapeoutChip{value: previous}(nl, TEMPLATE);

            Ledger memory before = _ledger(alice);
            vm.prank(alice);
            uint256 chipId = fab.tapeoutChip{value: cost}(nl, TEMPLATE);
            Ledger memory now_ = _ledger(alice);
            assertEq(now_.payer, before.payer - cost, "exactly the new cost was paid");
            assertEq(now_.treasury, before.treasury + steps[i][2], "the new tape-out fee");
            assertEq(now_.owedCreator, before.owedCreator + steps[i][0] * 300, "the new mint price");
            assertEq(now_.owedProtocol, before.owedProtocol + 2 * steps[i][1], "the new protocol fee");
            assertEq(circuits.ownerOf(chipId), alice);
            _assertFabHoldsNothing();
            previous = cost;
        }
    }

    /// A chip without NAND makes one mint call and pays one protocol fee, at whatever the fee is now.
    function test_prices_oneMintCallForAChipWithoutNand() public {
        bytes memory nl = NetlistBuilder.randomV1(5, 112, 0);
        _setProtocolFee(protocolFee * 4);
        (,, uint256 cost) = fab.quote(nl);
        assertEq(cost, MINT_PRICE * 112 + protocolFee * 4 + tapeoutFee, "one fee, not two");
        uint256 owedProtocol = transistors.owed(protocolWallet);
        _tape(alice, nl);
        assertEq(transistors.owed(protocolWallet), owedProtocol + protocolFee * 4);
        _assertFabHoldsNothing();
    }

    // ------------------------------------------------------------------ nothing is left behind

    /// With prices read on every call, the check at the end of a tape-out is what stops an overpayment from
    /// being stranded. If the processor's price views say more than `mint` charges, `mint` keeps the
    /// difference as a refund owed to the Fab, which the Fab has no way to collect: the tape-out reverts and
    /// the caller keeps the money.
    function test_revert_leftOver_whenTapeOutWouldOweTheFabARefund() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        (,, uint256 cost) = fab.quote(nl);
        bytes[2] memory views =
            [abi.encodeCall(ITapeOutTransistors.mintPrice, ()), abi.encodeCall(ITapeOutTransistors.protocolFee, ())];
        uint256[2] memory real = [MINT_PRICE, protocolFee];
        for (uint256 i = 0; i < 2; i++) {
            // the view overstates the price by one wei; what `mint` charges is unchanged
            vm.mockCall(address(transistors), views[i], abi.encode(real[i] + 1));
            (,, uint256 inflated) = fab.quote(nl);
            assertGt(inflated, cost);
            uint256 before = alice.balance;
            vm.prank(alice);
            vm.expectRevert(Fab.LeftOver.selector);
            fab.tapeoutChip{value: inflated}(nl, TEMPLATE);
            assertEq(alice.balance, before, "nothing was taken");
            vm.clearMockedCalls();
        }
        assertEq(transistors.owed(address(fab)), 0, "and nothing is owed");
        _assertFabHoldsNothing();
        _tape(alice, nl); // with honest views it works
    }

    /// The same check, condition by condition: a NAND balance, a LATCH balance, a refund owed.
    function test_revert_leftOver_eachCondition() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        (,, uint256 cost) = fab.quote(nl);
        bytes[3] memory reads = [
            abi.encodeCall(ITapeOutTransistors.balanceOf, (address(fab), NAND)),
            abi.encodeCall(ITapeOutTransistors.balanceOf, (address(fab), LATCH)),
            abi.encodeCall(ITapeOutTransistors.owed, (address(fab)))
        ];
        for (uint256 i = 0; i < 3; i++) {
            vm.mockCall(address(transistors), reads[i], abi.encode(uint256(1)));
            vm.prank(alice);
            vm.expectRevert(Fab.LeftOver.selector);
            fab.tapeoutChip{value: cost}(nl, TEMPLATE);
            vm.prank(alice);
            vm.expectRevert(Fab.LeftOver.selector);
            fab.tapeoutChipTo{value: cost}(nl, TEMPLATE, bob);
            vm.clearMockedCalls();
        }
        assertFalse(fab.isChip(circuits.nextId() + 1), "nothing was recorded");
        _tape(alice, nl);
    }

    /// Circuit logic that stops burning LATCH transistors (as an upgrade could) would leave them in the Fab
    /// for good. The tape-out reverts instead.
    function test_revert_leftOver_whenTheProcessorDoesNotBurn() public {
        bytes memory nl = NetlistBuilder.minimalV1(8);
        (,, uint256 cost) = fab.quote(nl);
        _upgradeCircuits(tapeoutFee, false, false); // same fee, plain mint, LATCH transistors not burned
        uint256 nextId = circuits.nextId();
        uint256 before = alice.balance;
        vm.prank(alice);
        vm.expectRevert(Fab.LeftOver.selector);
        fab.tapeoutChip{value: cost}(nl, TEMPLATE);
        assertEq(alice.balance, before);
        assertEq(circuits.nextId(), nextId, "nothing was taped out");
        _assertFabHoldsNothing();

        _upgradeCircuits(tapeoutFee, false, true); // burning again
        _tape(alice, nl);
        _assertFabHoldsNothing();
    }

    // ------------------------------------------------------------------ the ERC-721 receiver hook

    /// If TapeOut ever mints the circuit NFT with _safeMint, the mint calls the Fab's ERC-721 hook. The Fab
    /// answers it during its own tape-out, so it keeps working.
    function test_safeMint_theFabKeepsWorking() public {
        _upgradeCircuits(tapeoutFee, true, true); // same fee, _safeMint
        bytes memory nl = NetlistBuilder.randomV1(41, 8, 192);
        uint256 id = circuits.nextId() + 1;
        vm.expectCall(address(fab), abi.encodeWithSelector(IERC721Receiver.onERC721Received.selector));
        uint256 chipId = _tape(alice, nl);
        assertEq(chipId, id);
        assertEq(circuits.ownerOf(chipId), alice, "the NFT went on to the caller");
        _assertRecorded(chipId, nl, 8, 200, alice, TEMPLATE);
        _assertFabHoldsNothing();
        _assertSameOnRandomVectors(chipId, 8, 6, 41);

        // and to another recipient, and for a caller that is a contract without any hook
        (,, uint256 cost) = fab.quote(nl);
        vm.prank(alice);
        chipId = fab.tapeoutChipTo{value: cost}(nl, TEMPLATE, bob);
        assertEq(circuits.ownerOf(chipId), bob);
        PlainCaller caller = new PlainCaller();
        chipId = caller.tape{value: cost}(fab, nl, TEMPLATE);
        assertEq(circuits.ownerOf(chipId), address(caller));
        _assertFabHoldsNothing();
    }

    /// Outside a tape-out the hook refuses everything, the processor's own NFTs included: nobody can park a
    /// circuit in the Fab by a safe transfer.
    function test_erc721Hook_refusesEverythingOutsideATapeout() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        uint256 chipId = _tape(alice, nl);

        // a safe transfer of a circuit of this very processor
        vm.prank(alice);
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        IERC721Like(address(circuits)).safeTransferFrom(alice, address(fab), chipId);
        assertEq(circuits.ownerOf(chipId), alice);

        // the hook called directly: by a stranger, and by the processor's circuit contract itself
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        fab.onERC721Received(address(fab), address(0), chipId, "");
        vm.prank(address(circuits));
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        fab.onERC721Received(address(fab), address(0), chipId, "");
        vm.prank(address(transistors));
        vm.expectRevert(Fab.UnexpectedTokens.selector);
        fab.onERC721Received(address(fab), address(0), chipId, "");
        _assertFabHoldsNothing();

        // a plain (not safe) transfer calls no hook and cannot be refused by any contract; the NFT is then
        // simply lost to its owner. It changes nothing for the Fab or for anyone else.
        vm.prank(alice);
        IERC721Like(address(circuits)).transferFrom(alice, address(fab), chipId);
        assertEq(circuits.ownerOf(chipId), address(fab));
        _tape(bob, nl);
    }

    /// During a tape-out the hook still accepts only the processor's circuit contract as caller. TapeOut pays
    /// its treasury inside `tapeout`; code there that calls the hook is refused.
    function test_erc721Hook_duringATapeout_acceptsOnlyTheProcessor() public {
        HookCallingTreasury impl = new HookCallingTreasury();
        vm.etch(treasury, address(impl).code);
        HookCallingTreasury(payable(treasury)).arm(address(fab));

        uint256 chipId = _tape(alice, NetlistBuilder.minimalV1(2));
        assertTrue(HookCallingTreasury(payable(treasury)).called(), "the treasury ran inside the Fab's tape-out");
        assertFalse(HookCallingTreasury(payable(treasury)).accepted(), "its call of the hook was refused");
        assertEq(HookCallingTreasury(payable(treasury)).seen(), Fab.UnexpectedTokens.selector);
        assertEq(circuits.ownerOf(chipId), alice);
        _assertFabHoldsNothing();
    }

    function test_revert_tapeoutMismatch() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        (,, uint256 cost) = fab.quote(nl);
        uint256 id = circuits.nextId() + 1;

        // the processor reports a different shape
        uint32[4][4] memory wrong = [
            [uint32(95), 112, 2, 114], [uint32(96), 111, 2, 114], [uint32(96), 112, 3, 114], [uint32(96), 112, 2, 115]
        ];
        for (uint256 i = 0; i < 4; i++) {
            vm.mockCall(
                address(circuits),
                abi.encodeCall(ICircuitsView.circuitInfo, (id)),
                abi.encode(wrong[i][0], wrong[i][1], wrong[i][2], wrong[i][3])
            );
            vm.prank(alice);
            vm.expectRevert(Fab.TapeoutMismatch.selector);
            fab.tapeoutChip{value: cost}(nl, TEMPLATE);
            vm.clearMockedCalls();
        }

        // the processor stored other bytes
        bytes memory other = NetlistBuilder.minimalV1(2);
        other[3] = 0x03;
        vm.mockCall(address(circuits), abi.encodeCall(ICircuitsView.netlist, (id)), abi.encode(other));
        vm.prank(alice);
        vm.expectRevert(Fab.TapeoutMismatch.selector);
        fab.tapeoutChip{value: cost}(nl, TEMPLATE);
        vm.clearMockedCalls();

        assertFalse(fab.isChip(id));
        _assertFabHoldsNothing();
    }

    function test_revert_chipExists_recordsAreWriteOnce() public {
        bytes memory nl = NetlistBuilder.minimalV1(2);
        (,, uint256 cost) = fab.quote(nl);
        uint256 chipId = _tape(alice, nl);
        (address pointer,,,,,) = fab.chipInfo(chipId);

        // A processor that hands out the same id twice (only an upgraded TapeOut could) cannot make the
        // Fab overwrite a record.
        vm.mockCall(
            address(circuits), tapeoutFee, abi.encodeCall(ITapeOutCircuits.tapeout, (nl, 96, 112)), abi.encode(chipId)
        );
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Fab.ChipExists.selector, chipId));
        fab.tapeoutChip{value: cost}(nl, bytes32(uint256(1)));
        vm.clearMockedCalls();

        (address pointerAfter,,,, address author, bytes32 manifestHash) = fab.chipInfo(chipId);
        assertEq(pointerAfter, pointer);
        assertEq(author, alice);
        assertEq(manifestHash, TEMPLATE);
        _assertFabHoldsNothing();
    }
}
