// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Q6 on LIVE state: the real OB token (launched 2026-09-22, 295 trades, tax 1% / 1%), with the probe
///         etched over its real recipient address. Same lifecycle as Q6_Graduation, end to end in one test,
///         to show the fork-launched token behaves like a token the real platform signer launched.
contract Q6_LiveOB is ProbeBase {
    IIgnixToken internal constant TOKEN = IIgnixToken(OB_TOKEN);
    IDirectedVault internal constant VAULT = IDirectedVault(OB_VAULT);
    address internal constant NATIVE = address(0);

    RecipientProbe internal probe;
    address internal pair;
    uint256 internal locked;

    function setUp() public {
        _fork();
        probe = _etchProbe(OB_RECIPIENT);
        vm.label(OB_RECIPIENT, "probe etched at OB recipient");
        vm.deal(OB_RECIPIENT, 100 ether);
    }

    function test_Q6_live_OB_full_lifecycle_with_contract_recipient() public {
        _curvePhase();
        _graduation();
        _v2Phase();
        _burnPhase();
    }

    /// @dev The only graduated Directed vaults on mainnet (ERC-20 quote, recipient 0x...dEaD), untouched.
    ///      Corrects the design note that claimableNow can exceed the balance: at one block they are equal.
    function test_Q6_live_graduated_directed_vault_claimableNow_equals_balance_and_claimFor_delivers()
        public
    {
        IIgnixToken t = IIgnixToken(0x16Aa672ddA63F5ACd0De098c04c4A3e957d1EEEE);
        IDirectedVault v = IDirectedVault(0xa6A54EE383A75DA9A2f6e6a060A4c023C8DE8d64);
        address quote = v.QUOTE();
        assertEq(v.RECIPIENT(), DEAD);
        assertEq(address(t).codehash, OB_TOKEN.codehash, "same token code as native-quote launches");
        assertFalse(t.protectionActive(), "this token's 1-day window is over: a live after-protection case");

        uint256 claimableToken = v.claimableNow(DEAD, address(t));
        uint256 claimableQuote = v.claimableNow(DEAD, quote);
        assertEq(claimableToken, t.balanceOf(address(v)), "token: claimableNow == vault balance");
        assertEq(
            claimableQuote, IIgnixToken(quote).balanceOf(address(v)), "quote: claimableNow == vault balance"
        );
        assertEq(claimableToken, 58_985_399_581_383_102_476_555);
        assertEq(claimableQuote, 408_163_265_306_122_444);

        uint256 d0 = t.balanceOf(DEAD);
        vm.prank(bob);
        uint256 ret = v.claimFor(DEAD, address(t));
        assertEq(ret, claimableToken);
        assertEq(t.balanceOf(DEAD) - d0, claimableToken, "delta == claimableNow == return value");

        d0 = IIgnixToken(quote).balanceOf(DEAD);
        vm.prank(bob);
        ret = v.claimFor(DEAD, quote);
        assertEq(IIgnixToken(quote).balanceOf(DEAD) - d0, claimableQuote);
        assertEq(ret, claimableQuote);
    }

    function _curvePhase() internal {
        // the recipient contract buys on the curve; the tokens are stuck in it
        uint256 expected = CurveQuote.tokensOut(_curve(OB_TOKEN), M.snipeBpsNow(OB_TOKEN), 1 ether);
        (locked,,) = probe.buyTo(M, OB_TOKEN, 1 ether, expected, OB_RECIPIENT);
        assertEq(locked, expected, "quote exact on live state");
        (bool ok, bytes memory err,) =
            probe.exec(OB_TOKEN, 0, abi.encodeCall(IIgnixToken.transfer, (DEAD, locked)));
        assertFalse(ok);
        assertEq(_sel(err), IIgnixToken.CurveOnly.selector);
        // native tax: what was already there on mainnet + 1% of this buy
        assertEq(OB_VAULT.balance, 4_006_687_747_548_187 + 0.01 ether);
    }

    function _graduation() internal {
        uint256 cost = CurveQuote.costToGraduate(_curve(OB_TOKEN), 0);
        console2.log("live OB: gross cost for a whale to finish the curve (wei)", cost);
        pair = _graduate(OB_TOKEN);
        (uint256 rToken, uint256 rWokb) = _reserves(pair, OB_TOKEN);
        assertEq(rToken, 200_000_000 ether);
        assertEq(rWokb, _tok(OB_TOKEN).collected);
        console2.log("live OB: WOKB injected at graduation (wei)", rWokb);
        assertTrue(TOKEN.unlocked());
        assertEq(TOKEN.pair(), pair);
        assertEq(TOKEN.protectionEndsAt(), block.timestamp + 8_640_000);

        (bool ok, bytes memory err,,) = probe.tryBuyTo(M, OB_TOKEN, 0.1 ether, 0, OB_RECIPIENT);
        assertFalse(ok);
        assertEq(_sel(err), IIgnixManager.Graduated_.selector);
    }

    function _v2Phase() internal {
        (uint256 rToken, uint256 rWokb) = _reserves(pair, OB_TOKEN);
        (, uint256 tax, uint256 net) = V2TaxQuote.buyOut(1 ether, rWokb, rToken, 100);
        uint256 a0 = TOKEN.balanceOf(alice);
        vm.prank(alice);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(
            0, _path(WOKB, OB_TOKEN), alice, block.timestamp
        );
        assertEq(TOKEN.balanceOf(alice) - a0, net);
        assertEq(TOKEN.balanceOf(OB_VAULT), tax, "1% buy tax, in OB, in the vault");

        // token tax to the contract recipient: claim == claimableNow == balance delta
        uint256 claimable = VAULT.claimableNow(OB_RECIPIENT, OB_TOKEN);
        (uint256 ret, uint256 delta,) = probe.claim(VAULT, OB_TOKEN);
        assertEq(ret, claimable);
        assertEq(delta, claimable);
        assertEq(delta, tax);

        // residual native tax (pre-existing + probe buy + the whale's graduating buy) is still there
        uint256 residual = OB_VAULT.balance;
        assertGt(residual, 0.8 ether);
        vm.prank(bob);
        uint256 pushed = VAULT.claimFor(OB_RECIPIENT, NATIVE);
        assertEq(pushed, residual);
        console2.log("live OB: residual native tax pushed after graduation (wei)", pushed);
    }

    function _burnPhase() internal {
        uint256 bal = TOKEN.balanceOf(OB_RECIPIENT);
        uint256 v0 = TOKEN.balanceOf(OB_VAULT);
        probe.tokenTransfer(OB_TOKEN, DEAD, bal);
        assertEq(TOKEN.balanceOf(DEAD), bal, "untaxed");
        assertEq(TOKEN.balanceOf(OB_VAULT), v0);
        assertEq(TOKEN.totalSupply(), 1_000_000_000 ether);
    }
}
