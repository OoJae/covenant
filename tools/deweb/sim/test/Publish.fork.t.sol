// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {XLayerFork} from "./XLayerFork.sol";
import {Publish} from "../script/Publish.s.sol";
import {XLayer, IContainer} from "../src/DeWeb.sol";

/// @notice The whole publication on a fork of X Layer, for a circuit held by a test address:
///         open the container, write every file, activate the name, then read every file back through the
///         registry's read path and compare it with the file on disk.
contract PublishForkTest is XLayerFork {
    address internal holder = makeAddr("holder");
    uint256 internal circuitId;

    function setUp() public {
        _fork();
        _createProcessor(holder);
        circuitId = _tapeout(holder);
        assertEq(circuitId, 1, "first circuit of the new processor");
    }

    // ------------------------------------------------------------------ the real site

    /// @notice web/dist (or the fixture when the build output is missing), into a container that was never
    ///         opened: open, write, activate. Gas is measured per transaction.
    function test_fork_publish_wholeSite_readsBackByteForByte() public {
        (string memory dir, bool isBuild) = _siteDir();
        SiteFile[] memory files = loadSite(dir);
        Options memory o = Options({months: 1, renew: false, fallbackPath: "", prune: false, processorNumber: UNKNOWN});

        Target memory t = inspect(address(circuits), circuitId, holder, o.processorNumber);
        assertEq(t.processorNumber, 275);
        assertEq(t.name, "1.2.275.tape");
        assertEq(t.host, "1-2-275");
        assertFalse(t.opened, "a new circuit's container is not opened");
        assertFalse(t.live);
        assertEq(t.openFee, 0.08 ether, "opening fee");
        assertEq(t.monthlyFee, 0.026 ether, "name fee per 30 days");
        assertTrue(t.implementationsAccepted, "the gateway accepts both implementations at the pinned block");
        assertEq(t.container.code.length, 0, "no container code before opening");

        Step[] memory steps = plan(t, files, o);
        uint256 chunks;
        for (uint256 i; i < files.length; i++) chunks += chunkCountOf(files[i].data.length);
        assertEq(steps.length, 1 + chunks + 1, "open, one transaction per chunk, bind");
        assertEq(steps[0].kind, K_OPEN);
        assertEq(steps[steps.length - 1].kind, K_BIND);
        assertEq(valueOf(steps), 0.08 ether + 0.026 ether, "fees paid to the protocol");

        uint256 holderBefore = holder.balance;
        Measured memory m = _execute(steps, holder);
        assertEq(m.totalValue, 0.106 ether);
        assertEq(holder.balance, holderBefore, "the test funds exactly the protocol fees");

        // every file, through the registry's read path
        requirePublished(t, files, o);
        _assertSiteOnChain(t, files);
        assertEq(REGISTRY.pathCount(t.container), files.length, "no other path in the container");
        assertEq(REGISTRY.fallbackPath(t.container), "", "no fallback was set");

        // what the gateway checks before it shows a site (TAP-10 sections 4.2, 6.2, 6.3)
        assertEq(FACTORY.cpuAt(t.processorNumber), t.processor);
        assertEq(OPENER.accountOf(t.processor, t.circuitId), t.container);
        assertTrue(OPENER.isOpened(t.processor, t.circuitId), "opened");
        assertTrue(BINDING.isLive(t.name, t.container), "name activated");
        assertTrue(BINDING.isContainerLive(t.container), "container activated");
        assertEq(BINDING.containerPaidUntil(t.container), block.timestamp + 30 days, "paid for 30 days");

        _logMeasured(isBuild ? "Publication of web/dist, fresh container" : "Publication of the FIXTURE, fresh container", steps, m);
        _writeMeasured(isBuild ? "web-dist" : "web-dist-missing-fixture-used", dir, t, o, steps, m);

        if (isBuild) {
            // the number of files follows the site (eleven on 2026-10-06); the order rule does not
            assertGt(files.length, 1, "web/dist has the page and its scripts");
            assertEq(files[files.length - 1].path, "index.html", "the page is written last");
            assertEq(files[files.length - 1].contentType, "text/html; charset=utf-8");
        }
    }

    // ------------------------------------------------------------------ the fixture: chunking, fallback, updates

    /// @notice Four small files and one 60,000-byte file (three chunks), with a fallback path.
    function test_fork_publish_fixture_threeChunkFile_andFallback() public {
        SiteFile[] memory files = loadSite(FIXTURE);
        assertEq(files.length, 5);
        // non-HTML files sorted by path, then the HTML file
        assertEq(files[0].path, "app.js");
        assertEq(files[1].path, "big.bin");
        assertEq(files[2].path, "data.json");
        assertEq(files[3].path, "style.css");
        assertEq(files[4].path, "index.html");
        assertEq(files[0].contentType, "text/javascript; charset=utf-8");
        assertEq(files[1].contentType, "application/octet-stream");
        assertEq(files[2].contentType, "application/json; charset=utf-8");
        assertEq(files[3].contentType, "text/css; charset=utf-8");
        assertEq(files[1].data.length, 60_000);

        Options memory o =
            Options({months: 1, renew: false, fallbackPath: "index.html", prune: false, processorNumber: 275});
        Target memory t = inspect(address(circuits), circuitId, holder, o.processorNumber);
        Step[] memory steps = plan(t, files, o);

        // open, app.js, big.bin x3, data.json, style.css, index.html, setFallback, bind
        assertEq(steps.length, 10);
        assertEq(steps[2].kind, K_PUT);
        assertEq(steps[3].kind, K_APPEND);
        assertEq(steps[4].kind, K_APPEND);
        assertEq(steps[8].kind, K_FALLBACK);
        assertEq(steps[9].kind, K_BIND);

        Measured memory m = _execute(steps, holder);
        requirePublished(t, files, o);
        _assertSiteOnChain(t, files);

        (uint32 size,,,, uint256 chunkCount) = REGISTRY.fileInfo(t.container, "big.bin");
        assertEq(size, 60_000);
        assertEq(chunkCount, 3, "24,000 + 24,000 + 12,000");
        address[] memory chunkContracts = REGISTRY.chunksOf(t.container, "big.bin");
        assertEq(chunkContracts[0].code.length, 24_001, "a chunk is a contract: one zero byte, then the data");
        assertEq(chunkContracts[2].code.length, 12_001);
        assertEq(REGISTRY.fallbackPath(t.container), "index.html");

        // a range that crosses both chunk boundaries
        bytes memory range = REGISTRY.readRange(t.container, "big.bin", 23_990, 24_020);
        assertEq(range.length, 24_020);
        for (uint256 i; i < range.length; i += 7) assertEq(range[i], files[1].data[23_990 + i]);
        assertEq(REGISTRY.readRange(t.container, "big.bin", 60_000, 10).length, 0, "empty at the end of the file");
        assertEq(REGISTRY.readRange(t.container, "big.bin", 59_990, 500).length, 10, "clipped to the end of the file");

        _logMeasured("Publication of the fixture site (5 files, 60,438 bytes), fresh container, with fallback", steps, m);
        _writeMeasured("fixture", FIXTURE, t, o, steps, m);
    }

    /// @notice Running the plan again sends nothing. A changed site sends only what changed; PRUNE removes
    ///         what is gone.
    function test_fork_publish_secondRunSendsNothing_updateSendsOnlyTheDifference() public {
        SiteFile[] memory v1 = loadSite(FIXTURE);
        Options memory o = Options({months: 1, renew: false, fallbackPath: "", prune: true, processorNumber: 275});
        Target memory t = inspect(address(circuits), circuitId, holder, o.processorNumber);
        _execute(plan(t, v1, o), holder);
        requirePublished(t, v1, o);

        // same site again
        t = inspect(address(circuits), circuitId, holder, o.processorNumber);
        assertTrue(t.opened);
        assertTrue(t.live);
        assertEq(plan(t, v1, o).length, 0, "an identical site needs no transaction");

        // second version: index.html changed, two new files, style.css and big.bin gone
        SiteFile[] memory v2 = loadSite(FIXTURE_V2);
        Step[] memory steps = plan(t, v2, o);
        assertEq(steps.length, 5);
        assertEq(steps[0].label, "putFile notes/a-path-longer-than-thirty-two-bytes/site.webmanifest chunk 1/1 (45 bytes)");
        assertEq(steps[1].label, "putFile notes/read-me.txt chunk 1/1 (56 bytes)");
        assertEq(steps[2].label, "putFile index.html chunk 1/1 (311 bytes)");
        assertEq(steps[3].label, "removeFile big.bin");
        assertEq(steps[4].label, "removeFile style.css");

        Measured memory m = _execute(steps, holder);
        requirePublished(t, v2, o);
        _assertSiteOnChain(t, v2);
        assertEq(REGISTRY.pathCount(t.container), 5);
        (, string memory manifestType,,,) =
            REGISTRY.fileInfo(t.container, "notes/a-path-longer-than-thirty-two-bytes/site.webmanifest");
        assertEq(manifestType, "application/manifest+json; charset=utf-8");
        (,,,, uint256 chunkCount) = REGISTRY.fileInfo(t.container, "big.bin");
        assertEq(chunkCount, 0, "a removed file has no chunks");
        vm.expectRevert(bytes4(0x2a9df442)); // NoSuchFile()
        REGISTRY.read(t.container, "big.bin");

        _logMeasured("Update of the fixture site to its second version, with PRUNE", steps, m);
        _writeMeasured("fixture-update", FIXTURE_V2, t, o, steps, m);

        // without PRUNE the stale files would stay, and the plan says nothing about them
        o.prune = false;
        t = inspect(address(circuits), circuitId, holder, o.processorNumber);
        assertEq(plan(t, v2, o).length, 0);
    }

    // ------------------------------------------------------------------ the script, as forge runs it

    /// @notice `forge script script/Publish.s.sol` end to end, inputs from the environment. In a test the
    ///         broadcasting account is forge's default sender, so that address holds the circuit here.
    function test_fork_script_run_fromEnvironment() public {
        address broadcaster = DEFAULT_SENDER;
        uint256 id = _tapeout(broadcaster);
        assertEq(id, 2);
        vm.deal(broadcaster, 1 ether);

        (string memory dir,) = _siteDir();
        vm.setEnv("PROCESSOR", vm.toString(address(circuits)));
        vm.setEnv("CIRCUIT_ID", "2");
        vm.setEnv("SITE_DIR", dir);
        vm.setEnv("PROCESSOR_NUMBER", "275");

        uint256 before = broadcaster.balance;
        new Publish().run();
        assertEq(before - broadcaster.balance, 0.106 ether, "the sender pays the opening fee and one name fee");

        SiteFile[] memory files = loadSite(dir);
        Options memory o = Options(1, false, "", false, 275);
        Target memory t = inspect(address(circuits), 2, broadcaster, 275);
        assertEq(t.name, "2.2.275.tape");
        assertTrue(t.opened);
        assertTrue(t.live);
        requirePublished(t, files, o);
        _assertSiteOnChain(t, files);
        assertEq(plan(t, files, o).length, 0, "a second run would send nothing");
    }

    function test_fork_script_refusesASenderThatDoesNotHoldTheCircuit() public {
        Publish script = new Publish();
        // the default sender does not hold circuit 1
        vm.expectRevert();
        script.publish(address(circuits), circuitId, FIXTURE, Options(1, false, "", false, 275));

        vm.expectRevert(bytes("SitePublisher: PROCESSOR is not a processor of the TapeOut factory"));
        script.publish(address(transistors), circuitId, FIXTURE, Options(1, false, "", false, UNKNOWN));

        vm.expectRevert(bytes("SitePublisher: the processor has no circuit with this id"));
        script.publish(address(circuits), 99, FIXTURE, Options(1, false, "", false, 275));

        vm.expectRevert(bytes("SitePublisher: PROCESSOR_NUMBER is not this processor's index in the factory"));
        script.publish(address(circuits), circuitId, FIXTURE, Options(1, false, "", false, 274));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Explicit comparison of every file with the chain (requirePublished does the same with reverts).
    function _assertSiteOnChain(Target memory t, SiteFile[] memory files) internal view {
        string[] memory onChain = REGISTRY.paths(t.container);
        for (uint256 i; i < files.length; i++) {
            SiteFile memory f = files[i];
            (uint32 size, string memory contentType, bytes32 hash, uint40 updatedAt, uint256 chunkCount) =
                REGISTRY.fileInfo(t.container, f.path);
            assertEq(size, f.data.length, f.path);
            assertEq(contentType, f.contentType, f.path);
            assertEq(hash, sha256(f.data), f.path);
            assertEq(chunkCount, chunkCountOf(f.data.length), f.path);
            assertGt(updatedAt, 0, f.path);
            assertEq(REGISTRY.read(t.container, f.path), f.data, f.path);

            bool listed;
            for (uint256 j; j < onChain.length; j++) listed = listed || _eq(onChain[j], f.path);
            assertTrue(listed, string.concat("in the path list: ", f.path));
        }
    }
}

/// @notice The facts NOTES.md states about the DeWEB contracts, each checked against the real contracts.
contract DeWebFactsForkTest is XLayerFork {
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");
    address internal buyer = makeAddr("buyer");
    uint256 internal id;
    address internal container;

    bytes4 internal constant NOT_OWNER = 0x30cd7471;
    bytes4 internal constant TOO_LARGE = 0x218e0a07;
    bytes4 internal constant NO_SUCH_FILE = 0x2a9df442;
    bytes4 internal constant BAD_INDEX = 0xef3ff4ae;
    bytes4 internal constant ALREADY_OPENED = 0x1da42b26;
    bytes4 internal constant FEE_TOO_LOW = 0xf04f3db2;
    bytes4 internal constant BAD_PAYMENT = 0xbdbbb533;

    function setUp() public {
        _fork();
        _createProcessor(holder);
        id = _tapeout(holder);
        container = OPENER.accountOf(address(circuits), id);
        vm.deal(holder, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    function _open(address payer) internal {
        vm.prank(payer);
        OPENER.open{value: 0.08 ether}(address(circuits), id);
    }

    function _put(address who, string memory path, bytes memory data) internal {
        bytes32 hash = sha256(data);
        vm.prank(who);
        REGISTRY.putFile(container, path, "text/plain; charset=utf-8", hash, data);
    }

    /// @dev The hash is computed first: `expectRevert` applies to the very next call, and `sha256` is one.
    function _putReverts(bytes4 err, address who, string memory path, bytes memory data) internal {
        bytes32 hash = sha256(data);
        vm.expectRevert(err);
        vm.prank(who);
        REGISTRY.putFile(container, path, "text/plain; charset=utf-8", hash, data);
    }

    /// @notice The container address is the ERC-6551 CREATE2 address: registry 0x0000…5758, salt 0, the
    ///         implementation the opener names, chain id, processor, circuit id. plan.ts computes it the same way.
    function test_fork_fact_containerAddressIsTheErc6551Address() public view {
        address registry = 0x000000006551c19487814612e58FE06813775758;
        address implementation = 0xAC4F791353eE9F06e2C50Ae4C34680D28Ea52a57;
        bytes memory creationCode = abi.encodePacked(
            hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3",
            abi.encode(bytes32(0), block.chainid, address(circuits), id)
        );
        address expected = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), registry, bytes32(0), keccak256(creationCode)))))
        );
        assertEq(container, expected);
    }

    /// @notice What opening does: it costs FEE() = 0.08 OKB paid to the opener's treasury, deploys the
    ///         173-byte ERC-6551 account and marks it paid. Anyone may pay; paying grants nothing.
    function test_fork_fact_open_anyoneMayPay_itGrantsNoWriteAccess() public {
        address treasury = OPENER.treasury();
        uint256 treasuryBefore = treasury.balance;
        assertFalse(OPENER.isOpened(address(circuits), id));
        assertFalse(OPENER.isDeployed(address(circuits), id));

        _open(stranger);

        assertEq(treasury.balance - treasuryBefore, 0.08 ether, "the whole fee goes to the treasury");
        assertTrue(OPENER.isOpened(address(circuits), id));
        assertEq(container.code.length, 173, "ERC-6551 account proxy");
        (uint256 chainId, address tokenContract, uint256 tokenId) = IContainer(container).token();
        assertEq(chainId, 196);
        assertEq(tokenContract, address(circuits));
        assertEq(tokenId, id);
        assertEq(IContainer(container).owner(), holder, "the container's owner is the circuit's holder");
        assertTrue(REGISTRY.isOpenedContainer(container));

        // the payer gained nothing; the holder can write
        assertFalse(REGISTRY.canEdit(container, stranger));
        assertTrue(REGISTRY.canEdit(container, holder));
        _putReverts(NOT_OWNER, stranger, "a.txt", "x");
        _put(holder, "a.txt", "x");

        vm.expectRevert(ALREADY_OPENED);
        _open(holder);
    }

    function test_fork_fact_open_excessIsReturned_shortfallReverts() public {
        vm.expectRevert(abi.encodeWithSelector(FEE_TOO_LOW, 0.08 ether - 1, 0.08 ether));
        vm.prank(holder);
        OPENER.open{value: 0.08 ether - 1}(address(circuits), id);

        uint256 before = holder.balance;
        vm.prank(holder);
        OPENER.open{value: 1 ether}(address(circuits), id);
        assertEq(before - holder.balance, 0.08 ether, "only the fee is kept");
    }

    /// @notice No write before the container is opened, not even by the holder.
    function test_fork_fact_writesNeedAnOpenedContainer() public {
        assertFalse(REGISTRY.canEdit(container, holder));
        _putReverts(NOT_OWNER, holder, "a.txt", "x");
        vm.expectRevert(); // NotContainer()
        vm.prank(holder);
        BINDING.bind{value: 0.026 ether}("1.2.275.tape", container, 1);
    }

    /// @notice Permission is read from the circuit's current holder on every write: after a transfer the old
    ///         holder is refused and the new holder writes to the same container. An approved address is refused.
    function test_fork_fact_ownershipIsCheckedOnEveryWrite() public {
        _open(holder);
        _put(holder, "a.txt", "first");

        vm.prank(holder);
        (bool ok,) = address(circuits).call(abi.encodeWithSignature("approve(address,uint256)", stranger, id));
        assertTrue(ok);
        _putReverts(NOT_OWNER, stranger, "a.txt", "by an approved address");

        vm.prank(holder);
        circuits.transferFrom(holder, buyer, id);
        assertEq(OPENER.accountOf(address(circuits), id), container, "the container does not move");

        _putReverts(NOT_OWNER, holder, "a.txt", "by the previous holder");
        vm.expectRevert(NOT_OWNER);
        vm.prank(holder);
        REGISTRY.appendChunk(container, "a.txt", 1, "more");
        vm.expectRevert(NOT_OWNER);
        vm.prank(holder);
        REGISTRY.removeFile(container, "a.txt");
        vm.expectRevert(NOT_OWNER);
        vm.prank(holder);
        REGISTRY.setFallback(container, "a.txt");

        _put(buyer, "a.txt", "by the new holder");
        assertEq(REGISTRY.read(container, "a.txt"), bytes("by the new holder"));
    }

    /// @notice An operator set by the holder can write files for at most 30 days, cannot pay for the name and
    ///         cannot name another operator; it stops working when the circuit changes hands.
    function test_fork_fact_operator_writesFiles_cannotBind_endsWithATransfer() public {
        _open(holder);
        vm.expectRevert(TOO_LARGE);
        vm.prank(holder);
        REGISTRY.setOperator(container, stranger, 30 days + 1);
        vm.prank(holder);
        REGISTRY.setOperator(container, stranger, 1 days);
        assertEq(REGISTRY.operatorOf(container), stranger);

        _put(stranger, "a.txt", "by the operator");
        vm.prank(stranger);
        REGISTRY.setFallback(container, "a.txt");
        vm.expectRevert(NOT_OWNER);
        vm.prank(stranger);
        REGISTRY.setOperator(container, stranger, 30 days);
        vm.expectRevert(NOT_OWNER);
        vm.prank(stranger);
        BINDING.bind{value: 0.026 ether}("1.2.275.tape", container, 1);

        vm.prank(holder);
        circuits.transferFrom(holder, buyer, id);
        assertEq(REGISTRY.operatorOf(container), address(0));
        _putReverts(NOT_OWNER, stranger, "a.txt", "after the transfer");

        // and it expires
        vm.prank(buyer);
        REGISTRY.setOperator(container, stranger, 1 days);
        _put(stranger, "a.txt", "operator of the new holder");
        vm.warp(block.timestamp + 1 days);
        _putReverts(NOT_OWNER, stranger, "a.txt", "after expiry");
    }

    /// @notice putFile replaces a whole file; appendChunk needs the right index; removeFile takes the path
    ///         out of the list; a chunk is at most 24,000 bytes.
    function test_fork_fact_replace_append_remove_limits() public {
        _open(holder);
        bytes memory full = new bytes(24_000);
        bytes memory tooLong = new bytes(24_001);

        _put(holder, "a.bin", full);
        vm.prank(holder);
        REGISTRY.appendChunk(container, "a.bin", 1, "tail");
        (uint32 size,,,, uint256 chunkCount) = REGISTRY.fileInfo(container, "a.bin");
        assertEq(size, 24_004);
        assertEq(chunkCount, 2);

        vm.expectRevert(BAD_INDEX);
        vm.prank(holder);
        REGISTRY.appendChunk(container, "a.bin", 1, "again"); // the same transaction sent twice
        vm.expectRevert(NO_SUCH_FILE);
        vm.prank(holder);
        REGISTRY.appendChunk(container, "missing.bin", 0, "x");
        _putReverts(TOO_LARGE, holder, "b.bin", tooLong);
        vm.expectRevert(TOO_LARGE);
        vm.prank(holder);
        REGISTRY.appendChunk(container, "a.bin", 2, tooLong);

        // replacing starts the file again from one chunk and keeps one entry in the path list
        _put(holder, "a.bin", "short");
        (size,,,, chunkCount) = REGISTRY.fileInfo(container, "a.bin");
        assertEq(size, 5);
        assertEq(chunkCount, 1);
        assertEq(REGISTRY.read(container, "a.bin"), bytes("short"));
        assertEq(REGISTRY.pathCount(container), 1);

        // an empty file is one chunk of no bytes
        _put(holder, "empty.txt", "");
        (size,,,, chunkCount) = REGISTRY.fileInfo(container, "empty.txt");
        assertEq(size, 0);
        assertEq(chunkCount, 1);
        assertEq(REGISTRY.read(container, "empty.txt").length, 0);

        vm.prank(holder);
        REGISTRY.removeFile(container, "a.bin");
        assertEq(REGISTRY.pathCount(container), 1);
        assertEq(REGISTRY.paths(container)[0], "empty.txt");
        vm.expectRevert(NO_SUCH_FILE);
        REGISTRY.read(container, "a.bin");
        vm.expectRevert(NO_SUCH_FILE);
        vm.prank(holder);
        REGISTRY.removeFile(container, "a.bin");
    }

    /// @notice The contract stores the declared SHA-256 without checking it. (The gateway recomputes it and
    ///         refuses a file whose bytes do not match.)
    function test_fork_fact_declaredHashIsNotCheckedOnChain() public {
        _open(holder);
        vm.prank(holder);
        REGISTRY.putFile(container, "a.txt", "text/plain", bytes32(uint256(1)), "anything");
        (,, bytes32 hash,,) = REGISTRY.fileInfo(container, "a.txt");
        assertEq(hash, bytes32(uint256(1)));
        assertTrue(hash != sha256("anything"));
    }

    /// @notice bind: exact fee, holder only, 30 days per month paid; any name activates the whole container.
    function test_fork_fact_bind_exactFee_holderOnly_activatesTheContainer() public {
        _open(holder);
        assertFalse(BINDING.isContainerLive(container));

        vm.expectRevert(BAD_PAYMENT);
        vm.prank(holder);
        BINDING.bind{value: 0.026 ether + 1}("1.2.275.tape", container, 1);
        vm.expectRevert(NOT_OWNER);
        vm.prank(stranger);
        BINDING.bind{value: 0.026 ether}("1.2.275.tape", container, 1);
        vm.expectRevert(); // BadDomain(): upper case, or no dot
        vm.prank(holder);
        BINDING.bind{value: 0.026 ether}("1.2.275.TAPE", container, 1);

        vm.prank(holder);
        BINDING.bind{value: 0.052 ether}("covenant.example", container, 2);
        assertTrue(BINDING.isContainerLive(container), "paying for any name activates the container");
        assertFalse(BINDING.isLive("1.2.275.tape", container), "the on-chain name itself was not paid for");
        assertEq(BINDING.containerPaidUntil(container), block.timestamp + 60 days);

        vm.warp(block.timestamp + 60 days);
        assertFalse(BINDING.isContainerLive(container), "it expires");
    }
}
