// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import {KernelV2} from "../../src/KernelV2.sol";
import {KernelFactoryV2} from "../../src/KernelFactoryV2.sol";
import {LensV2} from "../../src/LensV2.sol";
import {KernelMathV2} from "../../src/KernelMathV2.sol";
import {RecordV2, GlobalsV2} from "../../src/interfaces/IKernelV2.sol";
import {KernelMath} from "core/KernelMath.sol";
import {TradeMath} from "core/lib/TradeMath.sol";
import {Envelope, RecordFlags, IKernelMin} from "core/interfaces/IKernelV1.sol";
import {ICircuits} from "core/interfaces/IEvaluators.sol";

import {DeployCoreV2} from "../../script/DeployCoreV2.s.sol";
import {LaunchChipV2} from "../../script/LaunchChipV2.s.sol";

// ---- the live contracts, as far as the fork tests drive them (never used by the kernel itself)

interface IManagerV2Fork {
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
    function sell(address token, uint256 tokenIn, uint256 minQuoteOut) external;
    function vaultOf(address token) external view returns (address);
    function pairOf(address token) external view returns (address);
    function owner() external view returns (address);
    function signer() external view returns (address);
    function REGISTRY() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function LAUNCH_FACTORY() external view returns (address);
    function setPaused(uint256 kind, uint64 until) external;
}

interface IRegistryV2Fork {
    function factoryOf(uint16 id) external view returns (address);
}

interface IERC20Fork {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
    function totalSupply() external view returns (uint256);
    function pair() external view returns (address);
}

interface IUSDT0Fork is IERC20Fork {
    function owner() external view returns (address);
    function addToBlockedList(address) external;
    function removeFromBlockedList(address) external;
    function isBlocked(address) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IVaultV2Fork {
    function RECIPIENT() external view returns (address);
    function TOKEN() external view returns (address);
    function QUOTE() external view returns (address);
    function claimFor(address recipient, address asset) external returns (uint256);
}

interface IRouterV2Fork {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPairV2Fork {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface ITapeOutFactoryFork {
    function owner() external view returns (address);
    function upgradeCircuits(address newImpl) external;
}

interface IBeaconFork {
    function implementation() external view returns (address);
}

interface ICircuitsFork {
    function ownerOf(uint256 id) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface IFabFork {
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
    function tapeoutChip(bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256 chipId);
    function CIRCUITS() external view returns (address);
}

interface IKeeperTankFork {
    function settleAndRefund(address kernel) external;
    function topUp(uint256 chipId) external payable;
    function remainingOf(uint256 chipId) external view returns (uint256);
}

/// @notice Everything live on an X Layer fork at one pinned block: the Covenant processor, Fab and SealedVM of
///         deployments/xlayer.json; IGNIX's Manager, vault factory, router and pairs; USD₮0; TapeOut. On top of
///         them, deployed in the fork only: KernelFactoryV2 and LensV2 (by the DeployCoreV2 script), the Flow
///         Governor (chips/out/fg.hex) taped out through the live Fab, a v2 kernel, and a Directed token quoted in
///         USD₮0 launched through the live Manager with that kernel as its recipient.
///
///         Nothing here sends a transaction or uses a real key. The one fork-only change to live state is
///         IGNIX's platform signer (storage slot 5), replaced by a throwaway key so that `createToken` can be
///         called. Every trader and every payer is an address unrelated to the team.
///
///         Run:  XLAYER_FORK=1 forge test --match-path 'test/fork/*'   (XLAYER_RPC_URL overrides the RPC)
abstract contract ForkBaseV2 is Test {
    using stdStorage for StdStorage;

    uint256 internal constant PINNED_BLOCK = 72_530_000; // 2026-10-06 15:03:56 UTC
    string internal constant DEFAULT_RPC = "https://rpc.xlayer.tech";
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Covenant (deployments/xlayer.json)
    address internal constant CIRCUITS = 0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b;
    address internal constant FAB = 0xdCAc8c47aF534dC0cDE30f60056bCe7D63a79aFE;
    address internal constant SEALED_VM = 0x19C248cF463c1E167121e52b77abA7EC68CBE47B;
    address internal constant KEEPER_TANK = 0xb89BCe53822a99503A937C22974F1224D9Ab6352;
    // TapeOut
    address internal constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant CIRCUIT_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address internal constant CIRCUIT_IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    // IGNIX and USD₮0
    IManagerV2Fork internal constant M = IManagerV2Fork(0x96B51c57e5346D0C0198899243cf851D1E23C309);
    IRouterV2Fork internal constant ROUTER = IRouterV2Fork(0x182a927119D56008d921126764bF884221b10f59);
    IUSDT0Fork internal constant USDT0 = IUSDT0Fork(0x779Ded0c9e1022225f8E0630b35a9b54bE713736);
    uint16 internal constant TEMPLATE_DIRECTED = 3;
    bytes32 internal constant TWA_TYPEHASH = 0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;
    bytes32 internal constant FG_MANIFEST_HASH = 0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209;

    uint32 internal constant EPOCH = 900;

    address internal launcher = makeAddr("launcher (creator wallet)");
    address internal payee = makeAddr("allowance payee (agent wallet)");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice (unrelated trader)");
    address internal bob = makeAddr("bob (unrelated trader)");
    address internal whale = makeAddr("whale (unrelated trader)");
    address internal x402Payer;
    uint256 internal x402PayerKey;

    DeployCoreV2 internal deployScript;
    KernelFactoryV2 internal factory;
    LensV2 internal lens;
    KernelV2 internal kernel;
    IERC20Fork internal token;
    IVaultV2Fork internal vault;
    uint256 internal chipId;
    bytes internal fg;

    uint256 private _saltNonce;
    uint256 private _nonce3009;

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
        (x402Payer, x402PayerKey) = makeAddrAndKey("x402 buyer (unrelated to the team)");
        vm.deal(launcher, 10 ether);
        vm.deal(keeper, 10 ether);
        vm.label(address(M), "IgnixManager");
        vm.label(address(ROUTER), "V2Router02");
        vm.label(address(USDT0), "USDT0");
        vm.label(CIRCUITS, "Circuits (Covenant processor)");
        vm.label(FAB, "Fab");
        vm.label(SEALED_VM, "SealedVM");
        return true;
    }

    // ------------------------------------------------------------------ Covenant side

    function _deployV2() internal {
        deployScript = new DeployCoreV2();
        (factory, lens) = deployScript.deploy(deployScript.defaults());
        vm.label(address(factory), "KernelFactoryV2");
        vm.label(address(lens), "LensV2");
    }

    function _fgNetlist() internal returns (bytes memory nl) {
        nl = vm.parseBytes(vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/../../chips/out/fg.hex"))));
        assertEq(keccak256(nl), 0xe548768a1adafa7331faacfd029e1a829b00af3f7d769657f3b234ccdd7143b4, "chip 2's netlist");
        assertEq(nl.length, 13_472);
    }

    function _tapeoutFG() internal returns (uint256 id) {
        fg = _fgNetlist();
        (,, uint256 cost) = IFabFork(FAB).quote(fg);
        vm.deal(launcher, launcher.balance + cost);
        vm.prank(launcher);
        id = IFabFork(FAB).tapeoutChip{value: cost}(fg, FG_MANIFEST_HASH);
    }

    LaunchChipV2 internal launchScript;

    /// The reference v2 envelope (LaunchChipV2.referenceEnvelope).
    function _env() internal returns (Envelope memory) {
        if (address(launchScript) == address(0)) launchScript = new LaunchChipV2();
        return launchScript.referenceEnvelope(launcher, payee);
    }

    // ------------------------------------------------------------------ IGNIX side

    function _overrideSigner() internal returns (uint256 pk) {
        address s;
        (s, pk) = makeAddrAndKey("covenant-core-v2 fork-only signer");
        uint256 slot = stdstore.target(address(M)).sig("signer()").find();
        assertEq(slot, 5, "the signer slot");
        vm.store(address(M), bytes32(slot), bytes32(uint256(uint160(s))));
        assertEq(M.signer(), s);
    }

    /// @notice A Directed launch on the fork quoted in USD₮0 (graduation 8,000 USD₮0), recipient `recipient`.
    function _launchUsdt0(address recipient, uint16 taxBps) internal returns (IERC20Fork t, IVaultV2Fork v) {
        uint256 pk = _overrideSigner();
        IManagerV2Fork.CreateParams memory p = IManagerV2Fork.CreateParams({
            name: "Covenant v2 Fork Token",
            symbol: "CV2FORK",
            metadataURI: "ipfs://fork",
            salt: bytes32(++_saltNonce),
            quote: address(USDT0),
            graduation: 8_000e6,
            buyFeeBps: 100,
            sellFeeBps: 100,
            taxBuyBps: taxBps,
            taxSellBps: taxBps,
            snipeStartBps: 0,
            snipeMins: 0,
            listingFee: 0,
            firstBuy: 0,
            founderBps: 0,
            founderSecs: 0,
            founderRoot: bytes32(0)
        });
        bytes memory vaultData = abi.encode(recipient);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        address vf = IRegistryV2Fork(M.REGISTRY()).factoryOf(TEMPLATE_DIRECTED);
        uint64 protection = 8_640_000;
        bytes32 inner = keccak256(
            abi.encode(
                block.chainid,
                address(M),
                launcher,
                p,
                TEMPLATE_DIRECTED,
                vaultData,
                deadline,
                vf,
                uint8(1),
                protection,
                M.POOL_FEE(),
                M.LAUNCH_FACTORY()
            )
        );
        (uint8 vv, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner)));
        vm.prank(launcher);
        address tk = M.createToken(p, TEMPLATE_DIRECTED, vaultData, deadline, vf, 1, protection, abi.encodePacked(r, s, vv));
        t = IERC20Fork(tk);
        v = IVaultV2Fork(M.vaultOf(tk));
        vm.label(tk, "token (USDT0 quote)");
        vm.label(address(v), "vault (USDT0 quote)");
    }

    /// @dev The order real life uses: tape out, create the kernel, launch against its address, move the chip, bind.
    function _fixture() internal {
        chipId = _tapeoutFG();
        kernel = KernelV2(factory.create(_env(), chipId, bytes32("fork")));
        vm.label(address(kernel), "kernel v2");
        (token, vault) = _launchUsdt0(address(kernel), 300);
        vm.prank(launcher);
        ICircuitsFork(CIRCUITS).safeTransferFrom(launcher, address(kernel), chipId);
        vm.prank(bob); // anyone
        kernel.bind(address(token));
    }

    // ------------------------------------------------------------------ actions

    function _fund(address who, uint256 amount) internal {
        deal(address(USDT0), who, USDT0.balanceOf(who) + amount);
    }

    function _buy(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.startPrank(who);
        USDT0.approve(address(M), amount);
        M.buy(address(token), amount, 0);
        vm.stopPrank();
    }

    function _sell(address who, uint256 tokens) internal {
        vm.startPrank(who);
        token.approve(address(M), tokens);
        M.sell(address(token), tokens, 0);
        vm.stopPrank();
    }

    /// @dev x402 "exact" on chain: an EIP-3009 transferWithAuthorization from the buyer to payTo = the kernel,
    ///      submitted by anyone (the facilitator). The buyer is unrelated to the team.
    function _x402(uint256 value) internal {
        _fund(x402Payer, value);
        bytes32 nonce = keccak256(abi.encode("x402", ++_nonce3009));
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 300;
        bytes32 structHash =
            keccak256(abi.encode(TWA_TYPEHASH, x402Payer, address(kernel), value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", USDT0.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(x402PayerKey, digest);
        vm.prank(keeper); // the facilitator: any relayer
        USDT0.transferWithAuthorization(x402Payer, address(kernel), value, validAfter, validBefore, nonce, v, r, s);
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

    /// @dev A whale buys the whole remaining curve; graduation runs inside this call (the excess is refunded).
    function _graduate() internal returns (address pair) {
        TradeMath.Curve memory c = _curve();
        uint256 left = c.sellable - c.sold;
        uint256 net = TradeMath.ceilDiv(c.vQuote * left, c.vToken - left);
        uint256 cost = TradeMath.ceilDiv(net * 10_000, 10_000 - (c.buyFeeBps + c.taxBuyBps));
        _buy(whale, cost + 25e6);
        pair = M.pairOf(address(token));
        assertTrue(pair != address(0), "did not graduate");
        vm.label(pair, "token/USDT0 V2 pair");
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _v2Buy(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.startPrank(who);
        USDT0.approve(address(ROUTER), amount);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, _path(address(USDT0), address(token)), who, block.timestamp
        );
        vm.stopPrank();
    }

    function _pairReserves(address pair) internal view returns (uint256 rToken, uint256 rQuote) {
        (uint112 r0, uint112 r1,) = IPairV2Fork(pair).getReserves();
        (rToken, rQuote) =
            IPairV2Fork(pair).token0() == address(token) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _has(uint8 flags, uint8 bit) internal pure returns (bool) {
        return flags & bit != 0;
    }

    function _books() internal view {
        bool grad = kernel.graduated();
        assertGe(
            USDT0.balanceOf(address(kernel)), kernel.totalCredits(address(USDT0)) + (grad ? 0 : kernel.reserve()), "USD0"
        );
        assertGe(
            token.balanceOf(address(kernel)),
            kernel.totalCredits(address(token)) + kernel.lockedTokens() + (grad ? kernel.reserve() : 0),
            "tokens"
        );
        assertEq(USDT0.allowance(address(kernel), address(M)), 0, "no allowance to the live Manager");
        assertEq(USDT0.allowance(address(kernel), address(ROUTER)), 0, "no allowance to the live router");
    }
}
