// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2, stdStorage, StdStorage, Vm} from "forge-std/Test.sol";

import {
    IIgnixManager,
    CurveToken,
    IVaultRegistry,
    IgnixPause,
    IgnixAddresses
} from "../src/interfaces/IIgnix.sol";
import {IDirectedVault} from "../src/interfaces/IDirectedVault.sol";
import {IIgnixToken} from "../src/interfaces/IIgnixToken.sol";
import {IUniswapV2Router02, IUniswapV2Pair, IUniswapV2Factory, IWOKB} from "../src/interfaces/IUniswapV2.sol";
import {CurveQuote, V2TaxQuote} from "../src/CurveQuote.sol";
import {RecipientProbe} from "../src/probes/RecipientProbe.sol";

/// @notice Shared fixture for every probe. All tests run on an X Layer fork at ONE pinned block.
///         Nothing here sends a transaction to a real network or uses a real key.
abstract contract ProbeBase is Test {
    using stdStorage for StdStorage;

    // ── pinned fork ──
    uint256 internal constant PINNED_BLOCK = 72_369_000; // 2026-10-04 18:20:36 UTC
    uint256 internal constant PINNED_TIME = 1_791_138_036;
    string internal constant DEFAULT_RPC = "https://rpc.xlayer.tech";

    // ── IGNIX (chain 196) ──
    IIgnixManager internal constant M = IIgnixManager(IgnixAddresses.MANAGER);
    address internal constant MANAGER_IMPL = 0x126F5088cf077944933F5741fb71A6CC40F2942a;
    address internal constant PLATFORM_SIGNER = 0x6EFa1Fad18900B929Fe6782fd3eaBeac2563416A;
    IUniswapV2Router02 internal constant ROUTER = IUniswapV2Router02(IgnixAddresses.V2_ROUTER02);
    address internal constant WOKB = IgnixAddresses.WOKB;
    address internal constant DEAD = IgnixAddresses.DEAD;
    uint16 internal constant TEMPLATE_DIRECTED = 3;
    uint256 internal constant SLOT_SIGNER = 5;

    // ── live fixture: "OB" (OpenBook), a pre-graduation Directed token quoted in native OKB ──
    address internal constant OB_TOKEN = 0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe;
    address internal constant OB_VAULT = 0xeC7732C9dCF978C8a97E6c44499331757D240365;
    address internal constant OB_RECIPIENT = 0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404; // EOA, also the creator

    // ── actors ──
    address internal alice = makeAddr("alice (random funded user)");
    address internal bob = makeAddr("bob (third party / keeper)");
    address internal whale = makeAddr("whale (buys out the curve)");
    address internal creator = makeAddr("creator (launch wallet)");

    uint256 private _saltNonce;

    function _fork() internal {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", DEFAULT_RPC), PINNED_BLOCK);
        assertEq(block.chainid, 196, "not X Layer");
        assertEq(block.number, PINNED_BLOCK, "not the pinned block");
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(whale, 10_000 ether);
        vm.label(address(M), "IgnixManager");
        vm.label(address(ROUTER), "V2Router02");
        vm.label(WOKB, "WOKB");
        vm.label(OB_TOKEN, "OB token");
        vm.label(OB_VAULT, "OB vault");
        vm.label(OB_RECIPIENT, "OB recipient");
    }

    // ───────────────────────────── launch on the fork ─────────────────────────────

    struct LaunchCfg {
        address recipient;
        uint16 taxBuyBps;
        uint16 taxSellBps;
        uint16 snipeStartBps;
        uint16 snipeMins;
        uint256 firstBuy;
        uint64 protectionSecs;
    }

    function _defaultCfg(address recipient) internal pure returns (LaunchCfg memory c) {
        c.recipient = recipient;
        c.taxBuyBps = 300; // the plan's CVREF: tax 3% / 3%
        c.taxSellBps = 300;
        c.protectionSecs = 8_640_000; // what every observed live launch signs
    }

    /// @dev Replaces the platform signer in the FORK's storage with a throwaway key derived from a label
    ///      (forge-std makeAddrAndKey). The slot is located with stdstore and asserted to be slot 5.
    function _overrideSigner() internal returns (uint256 pk) {
        address s;
        (s, pk) = makeAddrAndKey("covenant-probes fork-only signer");
        uint256 slot = stdstore.target(address(M)).sig("signer()").find();
        assertEq(slot, SLOT_SIGNER, "signer slot moved");
        vm.store(address(M), bytes32(slot), bytes32(uint256(uint160(s))));
        assertEq(M.signer(), s);
    }

    /// @dev Everything createToken takes, bundled so the call site stays under the stack limit.
    struct CreateArgs {
        IIgnixManager.CreateParams p;
        bytes vaultData;
        uint64 deadline;
        address factory;
        uint64 protectionSecs;
        bytes sig;
    }

    function _createArgs(LaunchCfg memory c) internal returns (CreateArgs memory a) {
        a.p = IIgnixManager.CreateParams({
            name: "Covenant Probe",
            symbol: "CVPROBE",
            metadataURI: "ipfs://probe",
            salt: bytes32(++_saltNonce),
            quote: address(0),
            graduation: 85 ether,
            buyFeeBps: 100,
            sellFeeBps: 100,
            taxBuyBps: c.taxBuyBps,
            taxSellBps: c.taxSellBps,
            snipeStartBps: c.snipeStartBps,
            snipeMins: c.snipeMins,
            listingFee: 0,
            firstBuy: c.firstBuy,
            founderBps: 0,
            founderSecs: 0,
            founderRoot: bytes32(0)
        });
        a.vaultData = abi.encode(c.recipient);
        a.deadline = uint64(block.timestamp + 1 hours);
        a.factory = IVaultRegistry(M.REGISTRY()).factoryOf(TEMPLATE_DIRECTED);
        a.protectionSecs = c.protectionSecs;
    }

    /// @dev The exact digest IgnixManager.createToken recovers the signer from.
    function _digest(address sender, CreateArgs memory a) internal view returns (bytes32) {
        bytes32 inner = keccak256(
            abi.encode(
                block.chainid,
                address(M),
                sender,
                a.p,
                TEMPLATE_DIRECTED,
                a.vaultData,
                a.deadline,
                a.factory,
                uint8(1), // venue: Uniswap V2 (mandatory for a taxed token)
                a.protectionSecs,
                M.POOL_FEE(),
                M.LAUNCH_FACTORY()
            )
        );
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    function _signArgs(uint256 pk, address sender, CreateArgs memory a) internal view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(sender, a));
        a.sig = abi.encodePacked(r, s, v);
    }

    function _create(address sender, CreateArgs memory a) internal returns (address t) {
        vm.deal(sender, sender.balance + a.p.firstBuy + a.p.listingFee);
        vm.prank(sender);
        t = M.createToken{value: a.p.firstBuy + a.p.listingFee}(
            a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, a.sig
        );
    }

    /// @notice Full Directed launch on the fork: recipient = c.recipient, quote = native OKB.
    function _launch(LaunchCfg memory c) internal returns (IIgnixToken token, IDirectedVault vault) {
        uint256 pk = _overrideSigner();
        CreateArgs memory a = _createArgs(c);
        _signArgs(pk, creator, a);
        address t = _create(creator, a);
        token = IIgnixToken(t);
        vault = IDirectedVault(M.vaultOf(t));
        vm.label(t, "probe token");
        vm.label(address(vault), "probe vault");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _tok(address token) internal view returns (CurveToken memory) {
        return M.tokens(token);
    }

    function _curve(address token) internal view returns (CurveQuote.Curve memory c) {
        CurveToken memory t = _tok(token);
        c = CurveQuote.Curve(t.buyFeeBps, t.taxBuyBps, t.vQuote, t.vToken, t.sold, t.sellable);
    }

    function _buy(address who, address token, uint256 amountIn) internal returns (uint256 out) {
        uint256 b0 = IIgnixToken(token).balanceOf(who);
        vm.prank(who);
        M.buy{value: amountIn}(token, amountIn, 0);
        out = IIgnixToken(token).balanceOf(who) - b0;
    }

    /// @dev A whale buys the whole remaining curve; graduation runs inside this call.
    function _graduate(address token) internal returns (address pair) {
        uint256 cost = CurveQuote.costToGraduate(_curve(token), M.snipeBpsNow(token));
        vm.deal(whale, cost + 100 ether);
        vm.prank(whale);
        M.buy{value: cost + 50 ether}(token, cost + 50 ether, 0);
        pair = M.pairOf(token);
        assertTrue(pair != address(0), "did not graduate");
        vm.label(pair, "V2 pair");
    }

    function _etchProbe(address at) internal returns (RecipientProbe p) {
        RecipientProbe impl = new RecipientProbe();
        vm.etch(at, address(impl).code);
        p = RecipientProbe(payable(at));
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) return bytes4(0);
        assembly {
            s := mload(add(err, 0x20))
        }
    }

    /// @dev Decodes Error(string). Old-solc contracts (Uniswap V2) leave dirty padding after the string, so
    ///      comparing the raw revert bytes with a freshly encoded Error(string) fails.
    function _revertString(bytes memory err) internal pure returns (string memory) {
        if (err.length < 68 || _sel(err) != bytes4(0x08c379a0)) return "";
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        return abi.decode(body, (string));
    }

    function _reserves(address pair, address token) internal view returns (uint256 rToken, uint256 rWokb) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (rToken, rWokb) =
            IUniswapV2Pair(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
}
