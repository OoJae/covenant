// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {Vm} from "forge-std/Vm.sol";
import {XLayer, IFactory, ICircuits, IOpener, ISiteRegistry, IDomainBinding} from "./DeWeb.sol";

/// @title SitePublisher - turns a directory of static files into the ordered list of calls that publishes
///        it into the DeWEB container of one TapeOut circuit, and checks the result by reading it back.
///
/// @notice Shared by `script/Publish.s.sol` (which broadcasts the calls) and the fork tests (which execute
///         them one by one and measure gas). `tools/deweb/plan.ts` builds the same list without Foundry;
///         `tools/deweb/test/plan-vs-fork.test.ts` checks the two are byte-identical.
///
///         The rules (file order, content types, what is skipped) are written down in tools/deweb/NOTES.md.
abstract contract SitePublisher is CommonBase {
    // ------------------------------------------------------------------ types

    struct SiteFile {
        string path; // relative to the site directory, "/" separators, no leading slash
        string contentType;
        bytes32 sha256Hash;
        bytes data;
    }

    /// @dev What to do beyond writing the files.
    struct Options {
        /// Months of name activation to pay for when the container is not activated. 0 = never call `bind`.
        uint256 months;
        /// Pay for `months` more even though the container is already activated.
        bool renew;
        /// When not empty: make this path the site's fallback (`setFallback`). Empty = leave it as it is.
        string fallbackPath;
        /// Remove on-chain paths that are not in the directory (`removeFile`).
        bool prune;
        /// The processor's index in `factory.cpuAt`. `UNKNOWN` = find it by scanning from the newest.
        uint256 processorNumber;
    }

    /// @dev Everything read from the chain before planning.
    struct Target {
        address processor;
        uint256 circuitId;
        uint256 processorNumber;
        address holder;
        address container;
        string name; // on-chain name, "<id>.2.<processor number>.tape"
        string host; // gateway host label, "<id>-2-<processor number>"
        bool opened;
        bool live;
        uint256 paidUntil;
        uint256 openFee;
        uint256 monthlyFee;
        bool implementationsAccepted;
    }

    struct Step {
        uint8 kind; // one of the K_ constants
        address target;
        uint256 value;
        bytes data;
        string label;
    }

    uint8 internal constant K_OPEN = 1;
    uint8 internal constant K_PUT = 2;
    uint8 internal constant K_APPEND = 3;
    uint8 internal constant K_FALLBACK = 4;
    uint8 internal constant K_REMOVE = 5;
    uint8 internal constant K_BIND = 6;

    uint256 internal constant UNKNOWN = type(uint256).max;
    uint64 private constant MAX_DEPTH = 32;

    IFactory internal constant FACTORY = IFactory(XLayer.FACTORY);
    IOpener internal constant OPENER = IOpener(XLayer.OPENER);
    ISiteRegistry internal constant REGISTRY = ISiteRegistry(XLayer.SITE_REGISTRY);
    IDomainBinding internal constant BINDING = IDomainBinding(XLayer.DOMAIN_BINDING);

    // ------------------------------------------------------------------ the directory

    /// @notice Reads every file under `dir` (absolute, or relative to the Foundry project root).
    ///         Order: files that are not HTML first, then HTML files; each group sorted by path bytes. The page
    ///         that references the other files is therefore written last.
    function loadSite(string memory dir) internal view returns (SiteFile[] memory files) {
        string memory root = bytes(dir).length != 0 && bytes(dir)[0] == "/" ? dir : string.concat(vm.projectRoot(), "/", dir);
        require(vm.isDir(root), string.concat("SitePublisher: not a directory: ", root));

        Vm.DirEntry[] memory entries = vm.readDir(root, MAX_DEPTH);
        files = new SiteFile[](entries.length);
        uint256 n;
        for (uint256 i; i < entries.length; i++) {
            Vm.DirEntry memory e = entries[i];
            require(bytes(e.errorMessage).length == 0, string.concat("SitePublisher: cannot read ", e.path));
            require(!e.isSymlink, string.concat("SitePublisher: symbolic link in the site: ", e.path));
            if (e.isDir) {
                require(e.depth < MAX_DEPTH, "SitePublisher: directory nesting deeper than 32");
                continue;
            }
            // forge reports absolute, normalised paths; the last `depth` segments are the path inside the site
            string memory path = _tail(e.path, e.depth);
            if (_skipped(path)) continue;
            checkPath(path);
            bytes memory data = vm.readFileBinary(e.path);
            require(
                data.length <= XLayer.CHUNK_MAX * XLayer.CHUNKS_MAX,
                string.concat("SitePublisher: file larger than 8,400,000 bytes: ", path)
            );
            files[n++] = SiteFile(path, contentTypeOf(path), sha256(data), data);
        }
        assembly {
            mstore(files, n)
        }
        require(n != 0, string.concat("SitePublisher: no files in ", root));

        // insertion sort: a site has few files
        for (uint256 i = 1; i < n; i++) {
            SiteFile memory f = files[i];
            uint256 j = i;
            while (j > 0 && _before(f, files[j - 1])) {
                files[j] = files[j - 1];
                j--;
            }
            files[j] = f;
        }
        require(_indexOf(files, "index.html") != UNKNOWN, "SitePublisher: the site has no index.html at its root");
    }

    /// @notice A path the registry can store and the gateway can serve: printable ASCII, no backslash, and
    ///         not one of the gateway's own paths (`/sw.js`, `/.tape/...`), which are never read from the chain.
    function checkPath(string memory path) internal pure {
        bytes memory p = bytes(path);
        require(p.length != 0 && p.length <= 512, string.concat("SitePublisher: bad path length: ", path));
        for (uint256 i; i < p.length; i++) {
            uint8 c = uint8(p[i]);
            require(c >= 0x20 && c <= 0x7e && c != 0x5c, string.concat("SitePublisher: path is not plain ASCII: ", path));
        }
        require(
            !_eq(path, "sw.js") && !_startsWith(p, ".tape/"),
            string.concat("SitePublisher: path is reserved by the gateway: ", path)
        );
    }

    /// @notice The content type declared for a path, by file extension (case-insensitive).
    ///         Keep in step with CONTENT_TYPES in tools/deweb/src/site.ts.
    function contentTypeOf(string memory path) internal pure returns (string memory) {
        bytes32 x = keccak256(bytes(_extension(path)));
        if (x == keccak256("html") || x == keccak256("htm")) return "text/html; charset=utf-8";
        if (x == keccak256("js") || x == keccak256("mjs")) return "text/javascript; charset=utf-8";
        if (x == keccak256("css")) return "text/css; charset=utf-8";
        if (x == keccak256("json") || x == keccak256("map")) return "application/json; charset=utf-8";
        if (x == keccak256("webmanifest")) return "application/manifest+json; charset=utf-8";
        if (x == keccak256("txt")) return "text/plain; charset=utf-8";
        if (x == keccak256("xml")) return "application/xml; charset=utf-8";
        if (x == keccak256("svg")) return "image/svg+xml";
        if (x == keccak256("png")) return "image/png";
        if (x == keccak256("jpg") || x == keccak256("jpeg")) return "image/jpeg";
        if (x == keccak256("gif")) return "image/gif";
        if (x == keccak256("webp")) return "image/webp";
        if (x == keccak256("avif")) return "image/avif";
        if (x == keccak256("ico")) return "image/x-icon";
        if (x == keccak256("woff2")) return "font/woff2";
        if (x == keccak256("woff")) return "font/woff";
        if (x == keccak256("ttf")) return "font/ttf";
        if (x == keccak256("otf")) return "font/otf";
        if (x == keccak256("wasm")) return "application/wasm";
        if (x == keccak256("pdf")) return "application/pdf";
        if (x == keccak256("mp4")) return "video/mp4";
        if (x == keccak256("webm")) return "video/webm";
        if (x == keccak256("mp3")) return "audio/mpeg";
        return "application/octet-stream";
    }

    /// @notice Number of chunks a file of `length` bytes occupies (an empty file still has one chunk).
    function chunkCountOf(uint256 length) internal pure returns (uint256) {
        return length == 0 ? 1 : (length + XLayer.CHUNK_MAX - 1) / XLayer.CHUNK_MAX;
    }

    // ------------------------------------------------------------------ the chain

    /// @notice Reads what the plan depends on and refuses early, in plain words, when `sender` cannot publish.
    function inspect(address processor, uint256 circuitId, address sender, uint256 processorNumber)
        internal
        view
        returns (Target memory t)
    {
        require(block.chainid == XLayer.CHAIN_ID, "SitePublisher: not X Layer (chain id 196)");
        require(circuitId != 0, "SitePublisher: circuit ids start at 1");
        require(FACTORY.isCPU(processor), "SitePublisher: PROCESSOR is not a processor of the TapeOut factory");

        t.processor = processor;
        t.circuitId = circuitId;
        try ICircuits(processor).ownerOf(circuitId) returns (address holder) {
            t.holder = holder;
        } catch {
            revert("SitePublisher: the processor has no circuit with this id");
        }
        t.container = OPENER.accountOf(processor, circuitId);
        t.opened = OPENER.isOpened(processor, circuitId);
        t.openFee = OPENER.FEE();
        t.monthlyFee = BINDING.monthlyFee();

        t.processorNumber = _processorNumber(processor, processorNumber);
        string memory id = vm.toString(circuitId);
        string memory area = vm.toString(XLayer.AREA_CODE);
        string memory number = vm.toString(t.processorNumber);
        t.name = string.concat(id, ".", area, ".", number, ".tape");
        t.host = string.concat(id, "-", area, "-", number);

        t.paidUntil = BINDING.containerPaidUntil(t.container);
        t.live = BINDING.isLive(t.name, t.container) || BINDING.isContainerLive(t.container);
        t.implementationsAccepted = _implementation(XLayer.SITE_REGISTRY) == XLayer.SITE_REGISTRY_IMPL
            && _implementation(XLayer.DOMAIN_BINDING) == XLayer.DOMAIN_BINDING_IMPL;

        // Writes are allowed for the circuit's current holder (or an operator the holder set) and only while the
        // circuit is not listed on TapeOut's market. Before the container is opened only the holder can be
        // checked; afterwards the registry answers for itself.
        if (t.opened) {
            require(
                REGISTRY.canEdit(t.container, sender),
                string.concat(
                    "SitePublisher: the sending account may not write to this container. Circuit holder: ",
                    vm.toString(t.holder),
                    ", sender: ",
                    vm.toString(sender),
                    " (a circuit listed on the market is frozen too)"
                )
            );
        } else {
            require(
                t.holder == sender,
                string.concat(
                    "SitePublisher: the sending account does not hold the circuit. Circuit holder: ",
                    vm.toString(t.holder),
                    ", sender: ",
                    vm.toString(sender)
                )
            );
            require(t.holder != t.container, "SitePublisher: the circuit is held by its own container");
        }
    }

    // ------------------------------------------------------------------ the plan

    /// @notice The ordered calls. A file whose on-chain copy already equals the local one (size, declared hash,
    ///         content type, chunk count and the bytes themselves) is skipped; anything else is written from its
    ///         first chunk, because `putFile` replaces the whole file.
    function plan(Target memory t, SiteFile[] memory files, Options memory o)
        internal
        view
        returns (Step[] memory steps)
    {
        string[] memory onChain = t.opened ? REGISTRY.paths(t.container) : new string[](0);

        uint256 capacity = 3 + onChain.length;
        for (uint256 i; i < files.length; i++) capacity += chunkCountOf(files[i].data.length);
        steps = new Step[](capacity);
        uint256 n;

        if (!t.opened) {
            steps[n++] = Step(
                K_OPEN,
                XLayer.OPENER,
                t.openFee,
                abi.encodeCall(IOpener.open, (t.processor, t.circuitId)),
                string.concat("open the container of circuit ", vm.toString(t.circuitId))
            );
        }

        for (uint256 i; i < files.length; i++) {
            SiteFile memory f = files[i];
            if (t.opened && _published(t.container, f)) continue;
            uint256 count = chunkCountOf(f.data.length);
            for (uint256 c; c < count; c++) {
                bytes memory chunk = _chunk(f.data, c);
                string memory label = string.concat(
                    f.path, " chunk ", vm.toString(c + 1), "/", vm.toString(count), " (", vm.toString(chunk.length), " bytes)"
                );
                steps[n++] = c == 0
                    ? Step(
                        K_PUT,
                        XLayer.SITE_REGISTRY,
                        0,
                        abi.encodeCall(ISiteRegistry.putFile, (t.container, f.path, f.contentType, f.sha256Hash, chunk)),
                        string.concat("putFile ", label)
                    )
                    : Step(
                        K_APPEND,
                        XLayer.SITE_REGISTRY,
                        0,
                        abi.encodeCall(ISiteRegistry.appendChunk, (t.container, f.path, c, chunk)),
                        string.concat("appendChunk ", label)
                    );
            }
        }

        if (bytes(o.fallbackPath).length != 0) {
            require(
                _indexOf(files, o.fallbackPath) != UNKNOWN,
                string.concat("SitePublisher: the fallback path is not a file of the site: ", o.fallbackPath)
            );
            if (!t.opened || !_eq(REGISTRY.fallbackPath(t.container), o.fallbackPath)) {
                steps[n++] = Step(
                    K_FALLBACK,
                    XLayer.SITE_REGISTRY,
                    0,
                    abi.encodeCall(ISiteRegistry.setFallback, (t.container, o.fallbackPath)),
                    string.concat("setFallback ", o.fallbackPath)
                );
            }
        }

        if (o.prune) {
            for (uint256 i; i < onChain.length; i++) {
                if (_indexOf(files, onChain[i]) != UNKNOWN) continue;
                steps[n++] = Step(
                    K_REMOVE,
                    XLayer.SITE_REGISTRY,
                    0,
                    abi.encodeCall(ISiteRegistry.removeFile, (t.container, onChain[i])),
                    string.concat("removeFile ", onChain[i])
                );
            }
        }

        if (o.months != 0 && (!t.live || o.renew)) {
            require(o.months <= 120, "SitePublisher: MONTHS must be at most 120");
            steps[n++] = Step(
                K_BIND,
                XLayer.DOMAIN_BINDING,
                o.months * t.monthlyFee,
                abi.encodeCall(IDomainBinding.bind, (t.name, t.container, o.months)),
                string.concat("bind ", t.name, " for ", vm.toString(o.months), " x 30 days")
            );
        }

        assembly {
            mstore(steps, n)
        }
    }

    /// @notice OKB the sender pays to the protocol (opening fee plus name fee), gas excluded.
    function valueOf(Step[] memory steps) internal pure returns (uint256 total) {
        for (uint256 i; i < steps.length; i++) total += steps[i].value;
    }

    // ------------------------------------------------------------------ reading back

    /// @notice Reads every file back through the registry's read path and compares it with the local file:
    ///         size, content type, declared SHA-256, chunk count, the bytes from `read` and the bytes from
    ///         `readRange` in the 98,304-byte segments the gateway uses. Reverts on the first difference.
    function requirePublished(Target memory t, SiteFile[] memory files, Options memory o) internal view {
        require(OPENER.isOpened(t.processor, t.circuitId), "SitePublisher: read-back: the container is not opened");
        for (uint256 i; i < files.length; i++) {
            SiteFile memory f = files[i];
            (uint32 size, string memory contentType, bytes32 hash,, uint256 chunkCount) =
                REGISTRY.fileInfo(t.container, f.path);
            require(chunkCount != 0, string.concat("SitePublisher: read-back: missing on chain: ", f.path));
            require(size == f.data.length, string.concat("SitePublisher: read-back: size differs: ", f.path));
            require(_eq(contentType, f.contentType), string.concat("SitePublisher: read-back: content type differs: ", f.path));
            require(hash == f.sha256Hash, string.concat("SitePublisher: read-back: declared SHA-256 differs: ", f.path));
            require(
                chunkCount == chunkCountOf(f.data.length),
                string.concat("SitePublisher: read-back: chunk count differs: ", f.path)
            );
            bytes memory whole = REGISTRY.read(t.container, f.path);
            require(
                whole.length == f.data.length && keccak256(whole) == keccak256(f.data),
                string.concat("SitePublisher: read-back: bytes differ: ", f.path)
            );
            require(sha256(whole) == f.sha256Hash, string.concat("SitePublisher: read-back: SHA-256 of the bytes differs: ", f.path));
            require(
                keccak256(_readInSegments(t.container, f.path, size)) == keccak256(f.data),
                string.concat("SitePublisher: read-back: readRange bytes differ: ", f.path)
            );
        }
        if (bytes(o.fallbackPath).length != 0) {
            require(
                _eq(REGISTRY.fallbackPath(t.container), o.fallbackPath), "SitePublisher: read-back: fallback path differs"
            );
        }
        if (o.prune) {
            require(
                REGISTRY.pathCount(t.container) == files.length, "SitePublisher: read-back: the container holds other paths"
            );
        }
        if (o.months != 0) {
            require(
                BINDING.isLive(t.name, t.container) || BINDING.isContainerLive(t.container),
                "SitePublisher: read-back: the name is not activated"
            );
        }
    }

    /// @dev The gateway reads a file above 96 KiB with `readRange(container, path, offset, 98304)`.
    function _readInSegments(address container, string memory path, uint256 size) private view returns (bytes memory out) {
        uint256 segment = 98_304;
        for (uint256 offset; offset < size; offset += segment) {
            out = bytes.concat(out, REGISTRY.readRange(container, path, offset, segment));
        }
    }

    // ------------------------------------------------------------------ internals

    /// @dev True when the on-chain file at `f.path` already equals the local file.
    function _published(address container, SiteFile memory f) private view returns (bool) {
        (uint32 size, string memory contentType, bytes32 hash,, uint256 chunkCount) = REGISTRY.fileInfo(container, f.path);
        if (chunkCount != chunkCountOf(f.data.length) || size != f.data.length) return false;
        if (hash != f.sha256Hash || !_eq(contentType, f.contentType)) return false;
        return keccak256(REGISTRY.read(container, f.path)) == keccak256(f.data);
    }

    function _processorNumber(address processor, uint256 claimed) private view returns (uint256) {
        uint256 count = FACTORY.cpuCount();
        if (claimed != UNKNOWN) {
            require(
                claimed < count && FACTORY.cpuAt(claimed) == processor,
                "SitePublisher: PROCESSOR_NUMBER is not this processor's index in the factory"
            );
            return claimed;
        }
        for (uint256 i = count; i > 0; i--) {
            if (FACTORY.cpuAt(i - 1) == processor) return i - 1;
        }
        revert("SitePublisher: processor not found in the factory");
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, XLayer.IMPL_SLOT))));
    }

    /// @dev Chunk `index` of `data`: 24,000 bytes, or what is left.
    function _chunk(bytes memory data, uint256 index) private pure returns (bytes memory out) {
        uint256 start = index * XLayer.CHUNK_MAX;
        uint256 length = data.length - start;
        if (length > XLayer.CHUNK_MAX) length = XLayer.CHUNK_MAX;
        out = new bytes(length);
        assembly {
            mcopy(add(out, 32), add(add(data, 32), start), length)
        }
    }

    /// @dev Non-HTML before HTML, then by path bytes.
    function _before(SiteFile memory a, SiteFile memory b) private pure returns (bool) {
        bool ah = _startsWith(bytes(a.contentType), "text/html");
        bool bh = _startsWith(bytes(b.contentType), "text/html");
        if (ah != bh) return bh;
        bytes memory x = bytes(a.path);
        bytes memory y = bytes(b.path);
        uint256 m = x.length < y.length ? x.length : y.length;
        for (uint256 i; i < m; i++) {
            if (x[i] != y[i]) return x[i] < y[i];
        }
        return x.length < y.length;
    }

    function _indexOf(SiteFile[] memory files, string memory path) private pure returns (uint256) {
        for (uint256 i; i < files.length; i++) {
            if (_eq(files[i].path, path)) return i;
        }
        return UNKNOWN;
    }

    /// @dev Finder metadata is never part of a site.
    function _skipped(string memory path) private pure returns (bool) {
        return _eq(_tail(path, 1), ".DS_Store");
    }

    /// @dev The last `segments` "/"-separated segments of `path`.
    function _tail(string memory path, uint256 segments) private pure returns (string memory) {
        bytes memory p = bytes(path);
        uint256 start = p.length;
        uint256 seen;
        while (start > 0) {
            if (p[start - 1] == "/") {
                if (++seen == segments) break;
            }
            start--;
        }
        bytes memory out = new bytes(p.length - start);
        for (uint256 i; i < out.length; i++) out[i] = p[start + i];
        return string(out);
    }

    /// @dev Lower-cased text after the last "." of the file name; empty when there is none.
    function _extension(string memory path) private pure returns (string memory) {
        bytes memory name = bytes(_tail(path, 1));
        uint256 dot = name.length;
        for (uint256 i = name.length; i > 0; i--) {
            if (name[i - 1] == ".") {
                dot = i - 1;
                break;
            }
        }
        if (dot == name.length) return "";
        bytes memory out = new bytes(name.length - dot - 1);
        for (uint256 i; i < out.length; i++) {
            uint8 c = uint8(name[dot + 1 + i]);
            out[i] = bytes1(c >= 0x41 && c <= 0x5a ? c + 32 : c);
        }
        return string(out);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(bytes memory text, bytes memory prefix) private pure returns (bool) {
        if (text.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; i++) {
            if (text[i] != prefix[i]) return false;
        }
        return true;
    }
}
