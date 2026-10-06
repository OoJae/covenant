// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import {Kernel} from "../../src/Kernel.sol";
import {KernelFactory} from "../../src/KernelFactory.sol";
import {Lens} from "../../src/Lens.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {TradeMath} from "../../src/lib/TradeMath.sol";
import {Record, Envelope, RecordFlags} from "../../src/interfaces/IKernelV1.sol";
import {Globals} from "../../src/interfaces/IKernelExt.sol";
import {ICircuits} from "../../src/interfaces/IEvaluators.sol";

import {Fab} from "evaluator/Fab.sol";
import {SealedVM} from "evaluator/SealedVM.sol";
import {Netlists} from "../integration/Netlists.sol";

// ---- the live contracts, as far as the fork tests drive them (never used by the kernel itself)

interface ITapeOutFactory {
    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 supply,
        uint256 price
    ) external payable returns (address transistors, address circuits);
    function deployFee() external view returns (uint256);
    function owner() external view returns (address);
    function circuitBeacon() external view returns (address);
    function upgradeCircuits(address newImpl) external;
}

interface IBeaconView {
    function implementation() external view returns (address);
}

interface ICircuitsNft {
    function transferFrom(address from, address to, uint256 id) external;
    function ownerOf(uint256 id) external view returns (address);
}

interface IManagerFork {
    struct CreateParams {
        string name;
        string symbol;
        string metadataURI;
        bytes32 salt;
        address quote;
        uint256 graduation;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint16 taxBuyBps;
        uint16 taxSellBps;
        uint16 snipeStartBps;
        uint16 snipeMins;
        uint256 listingFee;
        uint256 firstBuy;
        uint16 founderBps;
        uint32 founderSecs;
        bytes32 founderRoot;
    }

    function createToken(
        CreateParams calldata p,
        uint16 templateId,
        bytes calldata vaultData,
        uint64 deadline,
        address factory,
        uint8 venue,
        uint64 graduationProtectionSecs,
        bytes calldata sig
    ) external payable returns (address token);

    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable;
    function buyTo(address token, uint256 amountIn, uint256 minTokensOut, address recipient) external payable;
    function sell(address token, uint256 tokenIn, uint256 minQuoteOut) external;
    function vaultOf(address token) external view returns (address);
    function pairOf(address token) external view returns (address);
    function snipeBpsNow(address token) external view returns (uint256);
    function owner() external view returns (address);
    function signer() external view returns (address);
    function REGISTRY() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function LAUNCH_FACTORY() external view returns (address);
    function setPaused(uint256 kind, uint64 until) external;
    function pausedUntil(uint256 kind) external view returns (uint64);
}

interface IRegistryFork {
    function factoryOf(uint16 id) external view returns (address);
}

interface ITokenFork {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
    function transfer(address to, uint256 a) external returns (bool);
    function totalSupply() external view returns (uint256);
    function unlocked() external view returns (bool);
    function pair() external view returns (address);
    function protectionActive() external view returns (bool);
    function protectionEndsAt() external view returns (uint256);
}

interface IVaultFork {
    function RECIPIENT() external view returns (address);
    function claimFor(address recipient, address asset) external returns (uint256);
    function claimableNow(address recipient, address asset) external view returns (uint256);
}

interface IRouterFork {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPairFork {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IWOKBFork {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @notice Everything real, on an X Layer fork at one pinned block: a processor created through TapeOut's
///         factory, the real Fab and SealedVM from contracts/evaluator, a chip taped out through the Fab, a
///         kernel from the KernelFactory, and a token launched through the live IgnixManager with its
///         Directed vault pointing at that kernel.
///
///         Nothing here sends a transaction or uses a real key. The only fork-only change to live state is
///         IGNIX's platform signer (storage slot found with stdstore), replaced by a throwaway key so that
///         `createToken` can be called; every other line of mainnet code runs unmodified.
///
///         Run:  forge test --match-path 'test/fork/*' --fork-url https://rpc.xlayer.tech --fork-block-number 72369000
///         (or set XLAYER_FORK=1 and let the tests create the fork themselves). Without either they skip.
abstract contract ForkBase is Test {
    using stdStorage for StdStorage;

    uint256 internal constant PINNED_BLOCK = 72_369_000; // 2026-10-04 18:20:36 UTC
    string internal constant DEFAULT_RPC = "https://rpc.xlayer.tech";

    address internal constant NATIVE = address(0);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // TapeOut
    address internal constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant CIRCUIT_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address internal constant CIRCUIT_IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    bytes32 internal constant CIRCUIT_IMPL_HASH = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    // IGNIX
    IManagerFork internal constant M = IManagerFork(0x96B51c57e5346D0C0198899243cf851D1E23C309);
    IRouterFork internal constant ROUTER = IRouterFork(0x182a927119D56008d921126764bF884221b10f59);
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    uint16 internal constant TEMPLATE_DIRECTED = 3;

    uint32 internal constant EPOCH = 900;

    address internal launcher = makeAddr("launcher (creator wallet)");
    address internal payee = makeAddr("allowance payee");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal whale = makeAddr("whale");

    address internal transistors;
    address internal circuits;
    Fab internal fab;
    SealedVM internal sealedVM;
    KernelFactory internal factory;
    Lens internal lens;

    Kernel internal kernel;
    ITokenFork internal token;
    IVaultFork internal vault;
    uint256 internal chipId;
    bool internal isFlowGovernor;

    uint256 private _saltNonce;

    /// @return false when no fork is available; the caller then skips
    function _fork() internal returns (bool) {
        if (block.chainid == 196) {
            if (block.number != PINNED_BLOCK) vm.rollFork(PINNED_BLOCK);
        } else if (vm.envOr("XLAYER_FORK", false)) {
            vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", DEFAULT_RPC), PINNED_BLOCK);
        } else {
            return false;
        }
        assertEq(block.chainid, 196, "not X Layer");
        assertEq(block.number, PINNED_BLOCK, "not the pinned block");
        vm.deal(launcher, 10 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(whale, 10_000 ether);
        vm.deal(keeper, 10 ether);
        vm.label(address(M), "IgnixManager");
        vm.label(address(ROUTER), "V2Router02");
        vm.label(WOKB, "WOKB");
        vm.label(TAPEOUT_FACTORY, "TapeOutFactory");
        return true;
    }

    // ------------------------------------------------------------------ TapeOut side

    function _deployCovenant() internal {
        uint256 fee = ITapeOutFactory(TAPEOUT_FACTORY).deployFee();
        vm.prank(launcher);
        (transistors, circuits) = ITapeOutFactory(TAPEOUT_FACTORY).createCPU{value: fee}(
            "Covenant (fork)", "CVNT", "fork test processor", 67_108_864, 0.00002 ether
        );
        vm.label(circuits, "Circuits (processor)");
        fab = new Fab(circuits, transistors);
        sealedVM = new SealedVM();
        factory = new KernelFactory(
            address(M),
            address(ROUTER),
            WOKB,
            circuits,
            address(fab),
            address(sealedVM),
            CIRCUIT_BEACON,
            CIRCUIT_IMPL,
            CIRCUIT_IMPL_HASH
        );
        lens = new Lens();
    }

    /// @dev The Flow Governor: the fixed copy test/fixtures/fg.hex, the chip as the chip tools built it on
    ///      2026-10-04 (1,889 NAND + 64 LATCH, 13,479 bytes). chips/out/fg.hex itself is rebuilt by the chip
    ///      tools; every number these fork tests print or assert is for this copy.
    function _netlist() internal returns (bytes memory nl) {
        nl = vm.parseBytes(vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/fg.hex"))));
        assertEq(nl.length, 13_479, "the fixture is the 2026-10-04 build");
        assertEq(keccak256(nl), 0x2fd0e007398296a5845c8a7e3b99d5149d6c02ae670afe373abd191fb2591a89);
        isFlowGovernor = true;
    }

    /// 50% buy, 25% hold, 18.75% allowance, 6.25% reserve, release a quarter, no ceiling
    function _syntheticWord() internal pure returns (uint256) {
        KernelMath.OutputFields memory o;
        o.tBuy = 128;
        o.tHold = 64;
        o.tAllow = 48;
        o.tRes = 16;
        o.rel = 64;
        o.ceil = 1023;
        return KernelMath.packOutput(o);
    }

    function _tapeout(bytes memory nl) internal returns (uint256 id) {
        (,, uint256 cost) = fab.quote(nl);
        vm.deal(launcher, launcher.balance + cost);
        vm.prank(launcher);
        id = fab.tapeoutChip{value: cost}(nl, bytes32("fork"));
    }

    /// The reference token's envelope (chips/rtl/fg_params.json).
    function _env() internal view returns (Envelope memory e) {
        e.launcher = launcher;
        e.epochLen = EPOCH;
        e.allowancePayee = payee;
        e.capT = 48;
        e.capV = 0;
        e.allowCumBps = 1875;
        e.ceilMax = 440;
        e.relMax = 128;
        e.floorRel = 2;
        e.floorMin = 1;
        e.fallbackEpochs = 16;
        e.fbAllow = 8;
        e.buyEnabled = true;
    }

    // ------------------------------------------------------------------ IGNIX side

    struct CreateArgs {
        IManagerFork.CreateParams p;
        bytes vaultData;
        uint64 deadline;
        address factory;
        uint64 protectionSecs;
        bytes sig;
    }

    /// @dev Replaces the platform signer in the FORK's storage with a throwaway key.
    function _overrideSigner() internal returns (uint256 pk) {
        address s;
        (s, pk) = makeAddrAndKey("covenant-core fork-only signer");
        uint256 slot = stdstore.target(address(M)).sig("signer()").find();
        vm.store(address(M), bytes32(slot), bytes32(uint256(uint160(s))));
        assertEq(M.signer(), s);
    }

    /// @notice A full Directed launch on the fork: quote native OKB, first buy 0, tax `taxBps` each side.
    function _launch(address recipient, uint16 taxBps, uint16 snipeStartBps, uint16 snipeMins)
        internal
        returns (ITokenFork t, IVaultFork v)
    {
        uint256 pk = _overrideSigner();
        CreateArgs memory a;
        a.p = IManagerFork.CreateParams({
            name: "Covenant Fork Token",
            symbol: "CVFORK",
            metadataURI: "ipfs://fork",
            salt: bytes32(++_saltNonce),
            quote: address(0),
            graduation: 85 ether,
            buyFeeBps: 100,
            sellFeeBps: 100,
            taxBuyBps: taxBps,
            taxSellBps: taxBps,
            snipeStartBps: snipeStartBps,
            snipeMins: snipeMins,
            listingFee: 0,
            firstBuy: 0,
            founderBps: 0,
            founderSecs: 0,
            founderRoot: bytes32(0)
        });
        a.vaultData = abi.encode(recipient);
        a.deadline = uint64(block.timestamp + 1 hours);
        a.factory = IRegistryFork(M.REGISTRY()).factoryOf(TEMPLATE_DIRECTED);
        a.protectionSecs = 8_640_000;
        bytes32 inner = keccak256(
            abi.encode(
                block.chainid,
                address(M),
                launcher,
                a.p,
                TEMPLATE_DIRECTED,
                a.vaultData,
                a.deadline,
                a.factory,
                uint8(1),
                a.protectionSecs,
                M.POOL_FEE(),
                M.LAUNCH_FACTORY()
            )
        );
        (uint8 vv, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner)));
        a.sig = abi.encodePacked(r, s, vv);
        vm.prank(launcher);
        address tk =
            M.createToken(a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig);
        t = ITokenFork(tk);
        v = IVaultFork(M.vaultOf(tk));
        vm.label(tk, "token");
        vm.label(address(v), "vault");
    }

    /// @dev The order real life uses: tape out, create the kernel, launch against its address, move the
    ///      chip NFT, bind.
    function _fixture(bytes memory nl, Envelope memory e, uint16 taxBps) internal {
        chipId = _tapeout(nl);
        kernel = Kernel(payable(factory.create(e, chipId, bytes32("fork"))));
        vm.label(address(kernel), "kernel");
        (token, vault) = _launch(address(kernel), taxBps, 0, 0);
        vm.prank(launcher);
        ICircuitsNft(circuits).transferFrom(launcher, address(kernel), chipId);
        vm.prank(bob); // anyone
        kernel.bind(address(token));
    }

    // ------------------------------------------------------------------ actions

    function _buy(address who, uint256 amount) internal {
        vm.prank(who);
        M.buy{value: amount}(address(token), amount, 0);
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }

    function _settle() internal returns (uint32 n, uint256 gasUsed) {
        vm.prank(keeper);
        uint256 g0 = gasleft();
        n = kernel.settle();
        gasUsed = g0 - gasleft();
    }

    function _curve() internal view returns (TradeMath.Curve memory c) {
        (bool ok, bytes memory t) = address(M).staticcall(abi.encodeWithSignature("tokens(address)", address(token)));
        require(ok && t.length >= 512, "tokens()");
        uint256[16] memory w = abi.decode(t, (uint256[16]));
        c.buyFeeBps = w[1];
        c.sellFeeBps = w[2];
        c.taxBuyBps = w[3];
        c.taxSellBps = w[4];
        c.vQuote = w[9];
        c.vToken = w[10];
        c.sold = w[11];
        c.sellable = w[13];
    }

    /// @dev A whale buys the whole remaining curve; graduation runs inside this call.
    function _graduate() internal returns (address pair) {
        TradeMath.Curve memory c = _curve();
        uint256 left = c.sellable - c.sold;
        uint256 net = TradeMath.ceilDiv(c.vQuote * left, c.vToken - left);
        uint256 cost =
            TradeMath.ceilDiv(net * 10_000, 10_000 - (c.buyFeeBps + c.taxBuyBps + M.snipeBpsNow(address(token))));
        vm.deal(whale, cost + 100 ether);
        vm.prank(whale);
        M.buy{value: cost + 10 ether}(address(token), cost + 10 ether, 0);
        pair = M.pairOf(address(token));
        assertTrue(pair != address(0), "did not graduate");
        vm.label(pair, "V2 pair");
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _v2Buy(address who, uint256 amount) internal {
        vm.prank(who);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0, _path(WOKB, address(token)), who, block.timestamp
        );
    }

    function _has(uint8 flags, uint8 bit) internal pure returns (bool) {
        return flags & bit != 0;
    }
}
