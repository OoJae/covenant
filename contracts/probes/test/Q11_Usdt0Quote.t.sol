// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProbeBase} from "./ProbeBase.sol";
import {IIgnixManager, CurveToken, IVaultRegistry, IgnixAddresses} from "../src/interfaces/IIgnix.sol";
import {IDirectedVault} from "../src/interfaces/IDirectedVault.sol";
import {IIgnixToken} from "../src/interfaces/IIgnixToken.sol";
import {IUniswapV2Pair, IUniswapV2Factory} from "../src/interfaces/IUniswapV2.sol";
import {CurveQuote, V2TaxQuote} from "../src/CurveQuote.sol";

/// USD₮0 on X Layer, as far as these probes use it.
interface IUSDT0 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function owner() external view returns (address);
    function isBlocked(address) external view returns (bool);
    function addToBlockedList(address) external;
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address, bytes32) external view returns (bool);
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

interface IRouterTT {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @notice A contract recipient of an ERC-20-quoted Directed vault, doing what a kernel v2 would do.
///         Its receive() always reverts: nothing in the ERC-20-quote paths may depend on a native callback.
///         No fallback (the token probes contracts for token0()/token1()/fee() during protection).
contract Erc20Recipient {
    receive() external payable {
        revert("no native");
    }

    function claim(IDirectedVault v, address asset, address measure) external returns (uint256 ret, uint256 delta, uint256 gasUsed) {
        uint256 b0 = IUSDT0(measure).balanceOf(address(this));
        uint256 g = gasleft();
        ret = v.claim(asset);
        gasUsed = g - gasleft();
        delta = IUSDT0(measure).balanceOf(address(this)) - b0;
    }

    function tryClaim(IDirectedVault v, address asset) external returns (bool ok, bytes memory err) {
        try v.claim(asset) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    /// approve exactly `amt`, then buyTo; returns gas of the buyTo call alone
    function buyTo(IIgnixManager m, address quote, address token, uint256 amt, uint256 minOut, address to)
        external
        returns (uint256 gasUsed)
    {
        IUSDT0(quote).approve(address(m), amt);
        uint256 g = gasleft();
        m.buyTo(token, amt, minOut, to);
        gasUsed = g - gasleft();
    }

    function tryBuyTo(IIgnixManager m, address quote, address token, uint256 amt, uint256 approveAmt, uint256 value)
        external
        payable
        returns (bool ok, bytes memory err)
    {
        IUSDT0(quote).approve(address(m), approveAmt);
        try m.buyTo{value: value}(token, amt, 0, address(this)) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        IUSDT0(quote).approve(address(m), 0);
    }

    function routerBuy(address router, address quote, address token, uint256 amt, uint256 minOut, address to)
        external
        returns (uint256 gasUsed)
    {
        IUSDT0(quote).approve(router, amt);
        address[] memory p = new address[](2);
        p[0] = quote;
        p[1] = token;
        uint256 g = gasleft();
        IRouterTT(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(amt, minOut, p, to, block.timestamp);
        gasUsed = g - gasleft();
    }

    function tryRouterBuy(address router, address quote, address token, uint256 amt, uint256 minOut, address to)
        external
        returns (bool ok, bytes memory err)
    {
        IUSDT0(quote).approve(router, amt);
        address[] memory p = new address[](2);
        p[0] = quote;
        p[1] = token;
        try IRouterTT(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(amt, minOut, p, to, block.timestamp) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        IUSDT0(quote).approve(router, 0);
    }
}

/// @notice Stand-in for an immutable RevenueInbox: a contract with code and no function the payer calls.
contract InboxStub {
    address public immutable KERNEL;

    constructor(address k) {
        KERNEL = k;
    }

    /// The only exit: everything to the kernel, called by the kernel.
    function pull(address usdt0) external returns (uint256 amt) {
        require(msg.sender == KERNEL, "only kernel");
        amt = IUSDT0(usdt0).balanceOf(address(this));
        if (amt != 0) IUSDT0(usdt0).transfer(KERNEL, amt);
    }
}

/// @notice Kernel v2 questions: an IGNIX Directed token quoted in USD₮0 with a contract recipient, end to end,
///         and an EIP-3009 payment (what the x402 "exact" scheme settles) to a contract payTo.
///         Fork only; the platform signer is replaced in fork storage exactly as in the native probes.
contract Q11_Usdt0Quote is ProbeBase {
    IUSDT0 internal constant USDT0 = IUSDT0(0x779Ded0c9e1022225f8E0630b35a9b54bE713736);
    uint256 internal constant GRAD_USDT0 = 8_000e6; // GET /v1/ignix/params: USDT0 graduation 8000000000
    bytes32 internal constant TWA_TYPEHASH = 0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    bytes4 internal constant UNKNOWN_ASSET = 0xc97d95cf;
    bytes4 internal constant BAD_VALUE = 0x0bba69fb;
    bytes4 internal constant NOTHING_TO_CLAIM = 0x969bf728;

    Erc20Recipient internal R;
    IIgnixToken internal token;
    IDirectedVault internal vault;

    function setUp() public {
        _fork();
        vm.label(address(USDT0), "USDT0");
        R = new Erc20Recipient();
        vm.label(address(R), "kernel-like recipient");
        (token, vault) = _launchUsdt0(address(R));
    }

    function _launchUsdt0(address recipient) internal returns (IIgnixToken t, IDirectedVault v) {
        uint256 pk = _overrideSigner();
        CreateArgs memory a = _createArgs(_defaultCfg(recipient));
        a.p.quote = address(USDT0);
        a.p.graduation = GRAD_USDT0;
        _signArgs(pk, creator, a);
        address tok = _create(creator, a); // msg.value = 0: firstBuy = listingFee = 0
        t = IIgnixToken(tok);
        v = IDirectedVault(M.vaultOf(tok));
        vm.label(tok, "usdt0-quoted token");
        vm.label(address(v), "usdt0-quoted vault");
    }

    function _fund(address who, uint256 amt) internal {
        deal(address(USDT0), who, USDT0.balanceOf(who) + amt);
    }

    function _publicBuy(address who, uint256 amt) internal {
        _fund(who, amt);
        vm.startPrank(who);
        USDT0.approve(address(M), amt);
        M.buy(address(token), amt, 0);
        vm.stopPrank();
    }

    function _graduateUsdt0() internal returns (address pair) {
        uint256 cost = CurveQuote.costToGraduate(_curve(address(token)), M.snipeBpsNow(address(token)));
        _publicBuy(whale, cost);
        pair = M.pairOf(address(token));
        assertTrue(pair != address(0), "did not graduate");
    }

    function _usdt0Reserves(address pair) internal view returns (uint256 rToken, uint256 rQuote) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (rToken, rQuote) = IUniswapV2Pair(pair).token0() == address(token)
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
    }

    // ───────────────────────────── launch ─────────────────────────────

    function test_U0_directed_launch_with_usdt0_quote_and_contract_recipient() public {
        assertEq(vault.QUOTE(), address(USDT0), "vault QUOTE");
        assertEq(vault.RECIPIENT(), address(R), "vault RECIPIENT");
        assertEq(vault.TOKEN(), address(token));
        CurveToken memory c = _tok(address(token));
        assertEq(c.quote, address(USDT0), "curve quote");
        assertEq(c.taxBuyBps, 300);
        assertEq(c.sellable, 800_000_000 ether);
        assertEq(c.reserve, 200_000_000 ether);
        assertEq(c.sold, 0);
        assertEq(USDT0.balanceOf(address(vault)), 0);
        // Same token runtime as every live IGNIX token
        assertEq(address(token).codehash, 0xe4a9dfa056a271c2bab97dd1b2968f0f7364b654f79ebc4d11b50f96ebe75dec);
        emit log_named_uint("vQuote (USDT0 base units)", c.vQuote);
        emit log_named_uint("vToken", c.vToken);
        emit log_named_uint("costToGraduate (USDT0 base units)", CurveQuote.costToGraduate(_curve(address(token)), 0));
    }

    // ───────────────────────────── tax and claims on the curve ─────────────────────────────

    function test_U1_curve_tax_accrues_in_usdt0_and_claim_pays_a_contract_by_transfer() public {
        _publicBuy(alice, 100e6);
        assertEq(USDT0.balanceOf(address(vault)), 3e6, "3% of 100 USDT0");
        assertEq(vault.claimableNow(address(R), address(USDT0)), 3e6);
        // the native slot of this vault is not an asset
        vm.expectRevert(UNKNOWN_ASSET);
        vault.claimableNow(address(R), address(0));
        (bool ok, bytes memory err) = R.tryClaim(vault, address(0));
        assertFalse(ok);
        assertEq(_sel(err), UNKNOWN_ASSET, "claim(native) on a USDT0 vault");

        // claim(USDT0) works although R's receive() reverts: it is a plain ERC-20 transfer
        (uint256 ret, uint256 delta, uint256 g) = R.claim(vault, address(USDT0), address(USDT0));
        assertEq(ret, 3e6);
        assertEq(delta, 3e6);
        emit log_named_uint("gas claim(USDT0) seen by caller", g);
        (ok, err) = R.tryClaim(vault, address(USDT0));
        assertEq(_sel(err), NOTHING_TO_CLAIM);
        // the project token is not claimable before graduation
        (ok, err) = R.tryClaim(vault, address(token));
        assertEq(_sel(err), NOTHING_TO_CLAIM);
    }

    function test_U2_third_party_claimFor_pushes_usdt0_without_any_callback() public {
        _publicBuy(alice, 50e6);
        uint256 b0 = USDT0.balanceOf(address(R));
        vm.prank(bob);
        uint256 amt = vault.claimFor(address(R), address(USDT0));
        assertEq(amt, 1_500_000);
        assertEq(USDT0.balanceOf(address(R)) - b0, 1_500_000, "arrived although R refuses native");
        // donations to the vault are claimable tax as well (no ledger)
        _fund(bob, 7);
        vm.prank(bob);
        USDT0.transfer(address(vault), 7);
        assertEq(vault.claimableNow(address(R), address(USDT0)), 7);
    }

    // ───────────────────────────── buyTo with an ERC-20 quote ─────────────────────────────

    function test_U3_buyTo_from_a_contract_pulls_usdt0_by_allowance_and_is_exact() public {
        _publicBuy(alice, 10e6); // curve already traded
        _fund(address(R), 50e6);
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(_curve(address(token)), 0, 50e6);
        uint256 v0 = USDT0.balanceOf(address(vault));
        uint256 g = R.buyTo(M, address(USDT0), address(token), 50e6, q.tokensOut, address(R));
        assertEq(token.balanceOf(address(R)), q.tokensOut, "exact quote");
        assertEq(USDT0.balanceOf(address(R)), 0, "all 50 USDT0 pulled");
        assertEq(USDT0.allowance(address(R), address(M)), 0, "allowance fully consumed");
        assertEq(USDT0.balanceOf(address(vault)) - v0, q.tax, "own buy pays tax to own vault, in USDT0");
        assertEq(q.tax, 1_500_000);
        emit log_named_uint("gas buyTo(USDT0) seen by caller", g);

        // msg.value must be 0 for an ERC-20 quote
        _fund(address(R), 1e6);
        vm.deal(address(R), 1 ether);
        (bool ok, bytes memory err) = R.tryBuyTo(M, address(USDT0), address(token), 1e6, 1e6, 1);
        assertFalse(ok);
        assertEq(_sel(err), BAD_VALUE, "value with an ERC-20 quote");
        // without allowance the pull fails
        (ok, err) = R.tryBuyTo(M, address(USDT0), address(token), 1e6, 0, 0);
        assertFalse(ok, "no allowance");
        emit log_named_bytes("revert without allowance", err);
        // tokens still cannot move before graduation
        vm.prank(address(R));
        vm.expectRevert(bytes4(0x9dabc49b)); // CurveOnly
        token.transfer(DEAD, 1);
    }

    /// The exact quote holds for a 6-decimal quote, including buys that cross the end of the curve.
    function testFuzz_U4_curve_quote_is_exact_for_usdt0(uint256 seed, uint256 pre) public {
        pre = bound(pre, 0, 4_000e6);
        if (pre != 0) _publicBuy(alice, pre);
        uint256 e = bound(seed, 0, 40); // 1 base unit .. ~1e10 base units on a log scale
        uint256 amt = (uint256(1) << (e > 33 ? 33 : e)) + (seed >> 200) % (uint256(1) << (e > 33 ? 33 : e));
        CurveQuote.Curve memory c = _curve(address(token));
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(c, 0, amt);
        if (q.tokensOut == 0) return; // Manager reverts SoldOut
        _fund(address(R), amt);
        uint256 v0 = USDT0.balanceOf(address(vault));
        R.buyTo(M, address(USDT0), address(token), amt, q.tokensOut, address(R));
        assertEq(token.balanceOf(address(R)), q.tokensOut, "tokens");
        assertEq(USDT0.balanceOf(address(vault)) - v0, q.tax, "tax");
        assertEq(USDT0.balanceOf(address(R)), q.refund, "refund to the recipient, by transfer");
        assertEq(M.pairOf(address(token)) != address(0), q.soldOut, "graduated iff sold out");
    }

    function test_U5_maxNonGraduatingBuy_is_exact_for_usdt0() public {
        _publicBuy(alice, 123_456_789);
        CurveQuote.Curve memory c = _curve(address(token));
        uint256 max = CurveQuote.maxNonGraduatingBuy(c, 0);
        uint256 cost = CurveQuote.costToGraduate(c, 0);
        emit log_named_uint("maxNonGraduatingBuy (USDT0 base units)", max);
        emit log_named_uint("costToGraduate     (USDT0 base units)", cost);
        _fund(address(R), max);
        R.buyTo(M, address(USDT0), address(token), max, CurveQuote.tokensOut(c, 0, max), address(R));
        assertEq(M.pairOf(address(token)), address(0), "max did not graduate");
        CurveToken memory t = _tok(address(token));
        assertGt(t.sellable - t.sold, 0, "at least one unit left");
        // one more base unit of USDT0 graduates
        c = _curve(address(token));
        assertEq(CurveQuote.maxNonGraduatingBuy(c, 0), 0);
        _fund(address(R), 1);
        R.buyTo(M, address(USDT0), address(token), 1, CurveQuote.tokensOut(c, 0, 1), address(R));
        assertTrue(M.pairOf(address(token)) != address(0), "1 base unit graduated");
    }

    function test_U6_crossing_buyTo_refunds_usdt0_by_transfer_and_graduates_to_a_token_usdt0_v2_pair() public {
        _publicBuy(alice, 200e6);
        CurveQuote.Curve memory c = _curve(address(token));
        uint256 cost = CurveQuote.costToGraduate(c, 0);
        _fund(address(R), cost + 10e6);
        uint256 v0 = USDT0.balanceOf(address(vault));
        uint256 g = R.buyTo(M, address(USDT0), address(token), cost + 10e6, 0, address(R));
        assertEq(USDT0.balanceOf(address(R)), 10e6, "refund of exactly the excess, to a contract that refuses native");
        address pair = M.pairOf(address(token));
        assertTrue(pair != address(0));
        assertEq(pair, IUniswapV2Factory(M.V2_FACTORY()).getPair(address(token), address(USDT0)), "pair is token/USDT0");
        assertEq(token.pair(), pair);
        (uint256 rT, uint256 rQ) = _usdt0Reserves(pair);
        assertEq(rT, 200_000_000 ether, "token side");
        assertEq(rQ, _tok(address(token)).collected, "quote side = collected");
        assertApproxEqAbs(rQ, GRAD_USDT0, 1, "collected is the 8,000 USDT0 target (rounded down by at most 1 unit)");
        emit log_named_uint("opening USDT0 reserve", rQ);
        assertEq(USDT0.balanceOf(address(vault)) - v0, (cost * 300) / 10_000, "tax of the graduating buy, in USDT0");
        emit log_named_uint("gas graduating buyTo(USDT0)", g);
        // curve closed
        (bool ok, bytes memory err) = R.tryBuyTo(M, address(USDT0), address(token), 1e6, 1e6, 0);
        assertFalse(ok);
        assertEq(_sel(err), bytes4(0x735c0da7), "Graduated_");
    }

    // ───────────────────────────── after graduation ─────────────────────────────

    function test_U7_router_buy_usdt0_to_dead_is_exact_and_taxed_like_the_native_pair() public {
        address pair = _graduateUsdt0();
        address router = M.V2_ROUTER02();
        uint256 amt = 25e6;
        _fund(address(R), 2 * amt + 1);
        (uint256 rT, uint256 rQ) = _usdt0Reserves(pair);
        (, uint256 tax, uint256 net) = V2TaxQuote.buyOut(amt, rQ, rT, 300);
        // one unit above the formula fails
        (bool ok, bytes memory err) = R.tryRouterBuy(router, address(USDT0), address(token), amt, net + 1, DEAD);
        assertFalse(ok);
        assertEq(_revertString(err), "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        uint256 d0 = token.balanceOf(DEAD);
        uint256 v0 = token.balanceOf(address(vault));
        uint256 g = R.routerBuy(router, address(USDT0), address(token), amt, net, DEAD);
        assertEq(token.balanceOf(DEAD) - d0, net, "exact net to 0xdEaD");
        assertEq(token.balanceOf(address(vault)) - v0, tax, "tax to the vault, in the token");
        emit log_named_uint("gas router buy USDT0->token to 0xdEaD (first swap)", g);
        // and to itself
        (rT, rQ) = _usdt0Reserves(pair);
        (,, net) = V2TaxQuote.buyOut(amt, rQ, rT, 300);
        uint256 b0 = token.balanceOf(address(R));
        R.routerBuy(router, address(USDT0), address(token), amt, net, address(R));
        assertEq(token.balanceOf(address(R)) - b0, net);
    }

    function test_U8_after_graduation_token_tax_claims_and_residual_usdt0_stays_claimable() public {
        _publicBuy(alice, 100e6);
        address pair = _graduateUsdt0();
        uint256 residual = USDT0.balanceOf(address(vault));
        assertGt(residual, 3e6, "curve tax plus the graduating buy's tax");
        // a V2 buy adds token tax only
        _fund(bob, 10e6);
        (uint256 rT, uint256 rQ) = _usdt0Reserves(pair);
        (, uint256 tax,) = V2TaxQuote.buyOut(10e6, rQ, rT, 300);
        vm.startPrank(bob);
        USDT0.approve(M.V2_ROUTER02(), 10e6);
        address[] memory p = _path(address(USDT0), address(token));
        IRouterTT(M.V2_ROUTER02()).swapExactTokensForTokensSupportingFeeOnTransferTokens(10e6, 0, p, bob, block.timestamp);
        vm.stopPrank();
        assertEq(USDT0.balanceOf(address(vault)), residual, "no new USDT0 after graduation");
        assertEq(token.balanceOf(address(vault)), tax);
        (uint256 ret, uint256 delta, uint256 g) = R.claim(vault, address(token), address(token));
        assertEq(ret, tax);
        assertEq(delta, tax);
        emit log_named_uint("gas claim(token) after graduation", g);
        (ret, delta,) = R.claim(vault, address(USDT0), address(USDT0));
        assertEq(ret, residual);
        assertEq(delta, residual);
    }

    // ───────────────────────────── x402 exact scheme: EIP-3009 to a contract payTo ─────────────────────────────

    function _authorize(uint256 pk, address from, address to, uint256 value, bytes32 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s, uint256 validAfter, uint256 validBefore)
    {
        validAfter = block.timestamp - 1;
        validBefore = block.timestamp + 300;
        bytes32 structHash = keccak256(abi.encode(TWA_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", USDT0.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_U9_eip3009_transferWithAuthorization_pays_a_contract_payTo() public {
        (address payer, uint256 pk) = makeAddrAndKey("x402 buyer");
        InboxStub inbox = new InboxStub(address(R));
        assertGt(address(inbox).code.length, 0);
        _fund(payer, 500_000);
        bytes32 nonce = keccak256("x402 nonce 1");
        (uint8 v, bytes32 r, bytes32 s, uint256 va, uint256 vb) = _authorize(pk, payer, address(inbox), 500_000, nonce);
        // the facilitator (any relayer) submits it
        uint256 g = gasleft();
        vm.prank(bob);
        USDT0.transferWithAuthorization(payer, address(inbox), 500_000, va, vb, nonce, v, r, s);
        g -= gasleft();
        assertEq(USDT0.balanceOf(address(inbox)), 500_000, "contract payTo received USDT0");
        assertTrue(USDT0.authorizationState(payer, nonce));
        emit log_named_uint("gas transferWithAuthorization to a contract (incl. prank overhead)", g);
        // replay refused
        vm.prank(bob);
        vm.expectRevert();
        USDT0.transferWithAuthorization(payer, address(inbox), 500_000, va, vb, nonce, v, r, s);
        // the inbox moves it on only to its kernel
        vm.prank(bob);
        vm.expectRevert(bytes("only kernel"));
        inbox.pull(address(USDT0));
        vm.prank(address(R));
        assertEq(inbox.pull(address(USDT0)), 500_000);
        assertEq(USDT0.balanceOf(address(R)), 500_000);
    }

    /// The same authorization pays the kernel-like contract directly, and also the Directed vault itself
    /// (where it would become claimable "tax").
    function test_U9b_eip3009_can_pay_the_kernel_or_the_vault_directly() public {
        (address payer, uint256 pk) = makeAddrAndKey("x402 buyer 2");
        _fund(payer, 2e6);
        (uint8 v, bytes32 r, bytes32 s, uint256 va, uint256 vb) = _authorize(pk, payer, address(R), 1e6, bytes32(uint256(1)));
        vm.prank(bob);
        USDT0.transferWithAuthorization(payer, address(R), 1e6, va, vb, bytes32(uint256(1)), v, r, s);
        assertEq(USDT0.balanceOf(address(R)), 1e6);
        (v, r, s, va, vb) = _authorize(pk, payer, address(vault), 1e6, bytes32(uint256(2)));
        vm.prank(bob);
        USDT0.transferWithAuthorization(payer, address(vault), 1e6, va, vb, bytes32(uint256(2)), v, r, s);
        assertEq(vault.claimableNow(address(R), address(USDT0)), 1e6, "revenue paid to the vault looks like tax");
    }

    /// Tether's owner can block any holder of USD₮0, a kernel or an inbox included. Measured: a blocked
    /// address still RECEIVES (the vault's claim succeeds), but cannot send, cannot be pulled from, and the
    /// owner can destroy its balance.
    function test_U10_usdt0_owner_can_freeze_and_destroy_a_contract_holders_balance() public {
        InboxStub inbox = new InboxStub(address(R));
        _fund(address(inbox), 1e6);
        address own = USDT0.owner();
        emit log_named_address("USDT0 owner", own);
        assertFalse(USDT0.isBlocked(address(inbox)));
        vm.prank(own);
        USDT0.addToBlockedList(address(inbox));
        assertTrue(USDT0.isBlocked(address(inbox)));
        vm.prank(address(R));
        vm.expectRevert();
        inbox.pull(address(USDT0)); // a blocked inbox cannot send

        _publicBuy(alice, 10e6);
        vm.prank(own);
        USDT0.addToBlockedList(address(R));
        (uint256 ret, uint256 delta,) = R.claim(vault, address(USDT0), address(USDT0));
        assertEq(ret, 300_000, "a blocked recipient still receives its claim");
        assertEq(delta, 300_000);
        _fund(address(R), 1e6);
        (bool ok, bytes memory err) = R.tryBuyTo(M, address(USDT0), address(token), 1e6, 1e6, 0);
        assertFalse(ok, "a blocked kernel cannot buy: the Manager cannot pull from it");
        emit log_named_bytes("buyTo from blocked kernel revert", err);
        uint256 before = USDT0.balanceOf(address(R));
        vm.prank(own);
        (bool okD,) = address(USDT0).call(abi.encodeWithSignature("destroyBlockedFunds(address)", address(R)));
        assertTrue(okD, "destroyBlockedFunds");
        emit log_named_uint("blocked kernel balance before destroy", before);
        assertEq(USDT0.balanceOf(address(R)), 0, "owner destroyed the kernel's USDT0");
    }
}
