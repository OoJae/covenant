// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";
import {IgnixRead} from "../src/IgnixRead.sol";

/// @dev A Manager whose tokens() returns a different number of words, to exercise the reader.
contract FakeManager {
    uint256 public words;

    constructor(uint256 words_) {
        words = words_;
    }

    fallback() external {
        uint256 n = words;
        assembly {
            for { let i := 0 } lt(i, n) { i := add(i, 1) } { mstore(mul(i, 0x20), add(i, 1)) }
            return(0, mul(n, 0x20))
        }
    }
}

/// @notice Q5. The exact shape of `tokens(token)` and the other Manager views the kernel reads.
contract Q5_Decode is ProbeBase {
    uint256 internal constant SLOT_TOKENS = 8;
    uint256 internal constant SLOT_FOUNDER_ROUND = 10;
    uint256 internal constant SLOT_VAULT_OF = 12;
    uint256 internal constant SLOT_PAIR_OF = 15;
    uint256 internal constant SLOT_PAUSED_UNTIL = 21;

    function setUp() public {
        _fork();
    }

    function test_Q5_tokens_returns_exactly_16_words_512_bytes() public view {
        (bool ok, bytes memory ret) = address(M).staticcall(abi.encodeWithSelector(0xe4860339, OB_TOKEN));
        assertTrue(ok);
        assertEq(ret.length, 512, "tokens() returndata size");
        assertEq(bytes4(IIgnixManager.tokens.selector), bytes4(0xe4860339));

        uint256[16] memory w = abi.decode(ret, (uint256[16]));
        // live OB values at block 72369000
        assertEq(address(uint160(w[0])), OB_RECIPIENT, "0 creator");
        assertEq(w[1], 100, "1 buyFeeBps");
        assertEq(w[2], 100, "2 sellFeeBps");
        assertEq(w[3], 100, "3 taxBuyBps");
        assertEq(w[4], 100, "4 taxSellBps");
        assertEq(w[5], 0, "5 quote = native");
        assertEq(w[6], 5_000, "6 snipeStartBps");
        assertEq(w[7], 30, "7 snipeMins");
        assertEq(w[8], 1_790_119_556, "8 createdAt (2026-09-22 23:25:56 UTC)");
        assertEq(w[9], 28_333_333_333_333_333_333 + w[12], "9 vQuote = E + collected");
        assertEq(w[10], 1_066_666_666_666_666_666_666_666_666 - w[11], "10 vToken = T - sold");
        assertEq(w[11], 6_632_272_887_764_698_979_702_275, "11 sold");
        assertEq(w[12], 177_271_982_484_240_993, "12 collected");
        assertEq(w[13], 800_000_000 ether, "13 sellable");
        assertEq(w[14], 200_000_000 ether, "14 reserve");
        assertEq(w[15], 0, "15 poolId");
        // the Manager holds everything not yet sold
        assertEq(IIgnixToken(OB_TOKEN).balanceOf(address(M)), 1_000_000_000 ether - w[11]);
    }

    function test_Q5_typed_struct_and_reader_agree_with_raw_words() public view {
        (bool ok, bytes memory ret) = address(M).staticcall(abi.encodeCall(IIgnixManager.tokens, (OB_TOKEN)));
        assertTrue(ok);
        CurveToken memory viaStruct = M.tokens(OB_TOKEN);
        CurveToken memory viaDecode = abi.decode(ret, (CurveToken));
        (bool rok, CurveToken memory viaReader) = IgnixRead.tryTokens(address(M), OB_TOKEN);
        assertTrue(rok);
        assertEq(keccak256(abi.encode(viaStruct)), keccak256(ret), "struct interface");
        assertEq(keccak256(abi.encode(viaDecode)), keccak256(ret), "abi.decode into struct");
        assertEq(keccak256(abi.encode(viaReader)), keccak256(ret), "IgnixRead.tryTokens");
    }

    /// @dev Field order == storage packing: 6 slots at keccak256(abi.encode(token, 8)).
    function test_Q5_storage_layout_of_tokens_mapping() public view {
        CurveToken memory t = _tok(OB_TOKEN);
        uint256 base = uint256(keccak256(abi.encode(OB_TOKEN, SLOT_TOKENS)));
        uint256 s0 = uint256(vm.load(address(M), bytes32(base)));
        uint256 s1 = uint256(vm.load(address(M), bytes32(base + 1)));
        uint256 s2 = uint256(vm.load(address(M), bytes32(base + 2)));
        uint256 s3 = uint256(vm.load(address(M), bytes32(base + 3)));
        uint256 s4 = uint256(vm.load(address(M), bytes32(base + 4)));
        uint256 s5 = uint256(vm.load(address(M), bytes32(base + 5)));

        assertEq(address(uint160(s0)), t.creator);
        assertEq(uint16(s0 >> 160), t.buyFeeBps);
        assertEq(uint16(s0 >> 176), t.sellFeeBps);
        assertEq(uint16(s0 >> 192), t.taxBuyBps);
        assertEq(uint16(s0 >> 208), t.taxSellBps);
        assertEq(address(uint160(s1)), t.quote);
        assertEq(uint16(s1 >> 160), t.snipeStartBps);
        assertEq(uint16(s1 >> 176), t.snipeMins);
        assertEq(uint64(s1 >> 192), t.createdAt);
        assertEq(uint128(s2), t.vQuote);
        assertEq(uint128(s2 >> 128), t.vToken);
        assertEq(uint128(s3), t.sold);
        assertEq(uint128(s3 >> 128), t.collected);
        assertEq(uint128(s4), t.sellable);
        assertEq(uint128(s4 >> 128), t.reserve);
        assertEq(bytes32(s5), t.poolId);
    }

    function test_Q5_vaultOf_pairOf_snipeBpsNow_pausedUntil_founderRound_live() public view {
        assertEq(M.vaultOf(OB_TOKEN), OB_VAULT);
        assertEq(M.pairOf(OB_TOKEN), address(0), "not graduated");
        assertEq(M.creatorOf(OB_TOKEN), OB_RECIPIENT);
        assertEq(M.snipeBpsNow(OB_TOKEN), 0, "window (30 min from 2026-09-22) is over");
        for (uint256 k; k <= 8; ++k) {
            assertEq(M.pausedUntil(k), 0, "nothing is paused at the pinned block");
        }
        (bytes32 root, uint64 endsAt, uint128 capTotal, uint128 spentTotal) = M.founderRound(OB_TOKEN);
        assertEq(root, bytes32(0));
        assertEq(endsAt, 0, "no founder round");
        assertEq(capTotal, 0);
        assertEq(spentTotal, 0);

        // mapping slots
        assertEq(
            address(uint160(uint256(vm.load(address(M), keccak256(abi.encode(OB_TOKEN, SLOT_VAULT_OF)))))),
            OB_VAULT
        );
        assertEq(vm.load(address(M), keccak256(abi.encode(OB_TOKEN, SLOT_PAIR_OF))), bytes32(0));
        assertEq(address(uint160(uint256(vm.load(address(M), bytes32(SLOT_SIGNER))))), PLATFORM_SIGNER);

        // non-reverting reader
        (bool ok, address pair) = IgnixRead.tryPairOf(address(M), OB_TOKEN);
        assertTrue(ok);
        assertEq(pair, address(0));
        uint256 bps;
        (ok, bps) = IgnixRead.trySnipeBpsNow(address(M), OB_TOKEN);
        assertTrue(ok);
        assertEq(bps, 0);
        uint64 until;
        (ok, until) = IgnixRead.tryPausedUntil(address(M), IgnixPause.DIVIDEND);
        assertTrue(ok);
        assertEq(until, 0);
        (ok, endsAt) = IgnixRead.tryFounderEndsAt(address(M), OB_TOKEN);
        assertTrue(ok);
        assertEq(endsAt, 0);
    }

    function test_Q5_graduated_V2_token_reads() public view {
        address grad = 0x16Aa672ddA63F5ACd0De098c04c4A3e957d1EEEE; // live, graduated, ERC-20 quote
        CurveToken memory t = _tok(grad);
        address pair = M.pairOf(grad);
        assertTrue(pair != address(0), "pairOf is the graduated flag for V2");
        assertEq(t.poolId, bytes32(0), "poolId stays zero for a V2 graduation");
        assertEq(t.sold, t.sellable);
        assertEq(IIgnixToken(grad).pair(), pair);
        assertTrue(IIgnixToken(grad).unlocked());
        assertEq(
            address(uint160(uint256(vm.load(address(M), keccak256(abi.encode(grad, SLOT_PAIR_OF)))))), pair
        );
    }

    function test_Q5_unknown_token_reads_as_all_zero() public view {
        CurveToken memory t = _tok(address(0xBEEF));
        assertEq(t.creator, address(0), "creator == 0 means not an IGNIX token");
        assertEq(t.sellable, 0);
        assertEq(M.vaultOf(address(0xBEEF)), address(0));
        assertEq(M.snipeBpsNow(address(0xBEEF)), 0);
    }

    function _launchWithFounderRound(address recipient) internal returns (address t, bytes32 root) {
        uint256 pk = _overrideSigner();
        LaunchCfg memory cfg = _defaultCfg(recipient);
        cfg.snipeStartBps = 5_000;
        cfg.snipeMins = 30;
        CreateArgs memory a = _createArgs(cfg);
        a.p.founderBps = 1_000; // 10% of the 85 OKB graduation = 8.5 OKB cap
        a.p.founderSecs = 1 hours;
        a.p.founderRoot = keccak256("any non-zero root");
        _signArgs(pk, creator, a);
        t = _create(creator, a);
        root = a.p.founderRoot;
    }

    function test_Q5_founder_round_flag_and_FounderOnly() public {
        RecipientProbe probe = new RecipientProbe();
        vm.deal(address(probe), 1 ether);
        (address t, bytes32 expectedRoot) = _launchWithFounderRound(address(probe));

        (bytes32 root, uint64 endsAt, uint128 capTotal, uint128 spentTotal) = M.founderRound(t);
        assertEq(root, expectedRoot);
        assertEq(endsAt, block.timestamp + 1 hours);
        assertEq(capTotal, 8.5 ether);
        assertEq(spentTotal, 0);
        (bool ok, uint64 e2) = IgnixRead.tryFounderEndsAt(address(M), t);
        assertTrue(ok);
        assertEq(e2, endsAt);
        assertEq(
            uint64(
                uint256(
                    vm.load(address(M), bytes32(uint256(keccak256(abi.encode(t, SLOT_FOUNDER_ROUND))) + 1))
                )
            ),
            endsAt,
            "founderRound slot: root, then endsAt | capTotal"
        );
        _founderGate(probe, t, endsAt);
    }

    function _founderGate(RecipientProbe probe, address t, uint64 endsAt) internal {
        // public buys are closed while the round is open
        vm.prank(alice);
        vm.expectRevert(IIgnixManager.FounderOnly.selector);
        M.buy{value: 1 ether}(t, 1 ether, 0);
        (bool bok, bytes memory err,,) = probe.tryBuyTo(M, t, 0.5 ether, 0, address(probe));
        assertFalse(bok);
        assertEq(_sel(err), bytes4(0x2c353d89), "FounderOnly()");
        // the anti-snipe clock does not start until the round ends
        assertEq(M.snipeBpsNow(t), 5_000);
        vm.warp(endsAt - 1);
        assertEq(M.snipeBpsNow(t), 5_000);
        vm.warp(endsAt);
        assertEq(M.snipeBpsNow(t), 5_000);
        (bok,,,) = probe.tryBuyTo(M, t, 0.5 ether, 0, address(probe));
        assertTrue(bok, "public buys open at endsAt");
        vm.warp(endsAt + 15 minutes);
        assertEq(M.snipeBpsNow(t), 2_500);
        vm.warp(endsAt + 30 minutes);
        assertEq(M.snipeBpsNow(t), 0);
    }

    function test_Q5_selectors_of_everything_the_kernel_calls() public pure {
        // IgnixManager (verified source)
        assertEq(IIgnixManager.tokens.selector, bytes4(0xe4860339));
        assertEq(IIgnixManager.pairOf.selector, bytes4(0xa7465bdb));
        assertEq(IIgnixManager.vaultOf.selector, bytes4(0x0709df45));
        assertEq(IIgnixManager.creatorOf.selector, bytes4(0xdea5c2e0));
        assertEq(IIgnixManager.snipeBpsNow.selector, bytes4(0xf91a40b4));
        assertEq(IIgnixManager.pausedUntil.selector, bytes4(0x54bce65b));
        assertEq(IIgnixManager.founderRound.selector, bytes4(0x47965b55));
        assertEq(IIgnixManager.buy.selector, bytes4(0xa59ac6dd));
        assertEq(IIgnixManager.buyTo.selector, bytes4(0x9415aa2a));
        assertEq(IIgnixManager.sell.selector, bytes4(0x6a272462));
        assertEq(IIgnixManager.createToken.selector, bytes4(0xef44bdf2));
        // Directed vault (selectors present in the unverified bytecode)
        assertEq(IDirectedVault.RECIPIENT.selector, bytes4(0x0d9019e1));
        assertEq(IDirectedVault.MANAGER.selector, bytes4(0x1b2df850));
        assertEq(IDirectedVault.FACTORY.selector, bytes4(0x2dd31000));
        assertEq(IDirectedVault.TOKEN.selector, bytes4(0x82bfefc8));
        assertEq(IDirectedVault.QUOTE.selector, bytes4(0x9c579839));
        assertEq(IDirectedVault.DIVIDEND_BPS.selector, bytes4(0x8d7036de));
        assertEq(IDirectedVault.tracker.selector, bytes4(0xf52bccad));
        assertEq(IDirectedVault.sync.selector, bytes4(0xfff6cae9));
        assertEq(IDirectedVault.claim.selector, bytes4(0x1e83409a));
        assertEq(IDirectedVault.claimFor.selector, bytes4(0xb4ba9e11));
        assertEq(IDirectedVault.claimableNow.selector, bytes4(0x82ee9d56));
        // token
        assertEq(IIgnixToken.unlocked.selector, bytes4(0x6a5e2650));
        assertEq(IIgnixToken.pair.selector, bytes4(0xa8aa1b31));
        assertEq(IIgnixToken.taxSink.selector, bytes4(0x655e764a));
        assertEq(IIgnixToken.taxExempt.selector, bytes4(0xd1ecfc68));
        assertEq(IIgnixToken.pools.selector, bytes4(0xa4063dbc));
        assertEq(IIgnixToken.taxBuyBps.selector, bytes4(0x44e1ba46));
        assertEq(IIgnixToken.taxSellBps.selector, bytes4(0xca5b0bee));
        assertEq(IIgnixToken.protectionActive.selector, bytes4(0xc294e9a6));
        assertEq(IIgnixToken.protectionEndsAt.selector, bytes4(0xa929442c));
        assertEq(IIgnixToken.protectionDuration.selector, bytes4(0x33eb06c4));
        assertEq(IIgnixToken.protectionHook.selector, bytes4(0x30e466b3));
        assertEq(IIgnixToken.protectionQuote.selector, bytes4(0xbd4ee19f));
        // errors
        assertEq(IIgnixManager.Graduated_.selector, bytes4(0x735c0da7));
        assertEq(IIgnixManager.Paused.selector, bytes4(0x9e87fac8));
        assertEq(IIgnixManager.FounderOnly.selector, bytes4(0x2c353d89));
        assertEq(IIgnixManager.FreezeTooLong.selector, bytes4(0x6955d88b));
        assertEq(IDirectedVault.Paused.selector, bytes4(0x9e87fac8));
        assertEq(IIgnixToken.CurveOnly.selector, bytes4(0x9dabc49b));
        assertEq(IIgnixToken.ERC20InvalidReceiver.selector, bytes4(0xec442f05));
        // Uniswap V2 router
        assertEq(
            IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens.selector, bytes4(0xb6f9de95)
        );
    }

    /// @dev Every view of the token interface answers on the live OB token (names matched from bytecode).
    function test_Q5_token_views_answer_on_the_live_token() public view {
        IIgnixToken t = IIgnixToken(OB_TOKEN);
        assertEq(t.MANAGER(), address(M));
        assertEq(t.taxSink(), OB_VAULT);
        assertEq(t.taxBuyBps(), 100);
        assertEq(t.taxSellBps(), 100);
        assertEq(t.tracker(), address(0));
        assertEq(t.protectionDuration(), 8_640_000);
        assertEq(t.protectionEndsAt(), 0);
        assertFalse(t.protectionActive());
        assertFalse(t.unlocked());
        assertEq(t.pair(), address(0));
        assertEq(t.protectionQuote(), WOKB);
        assertEq(t.protectionHook(), 0xeb7e2bBA4579705B608c466317d47817C9e16080);
        assertEq(t.poolManager(), 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
        assertEq(t.lpLocker(), 0x560d9f6025c3537E7610695C760AdA761d0A0d6A);
        assertEq(t.protectionRouter(), 0xb47b2f991d4014D2c4A2bBac6Dd6fE3ed8884985);
        assertEq(t.name(), "OpenBook");
        assertEq(t.symbol(), "OB");
    }

    function typedRead(address manager) external view returns (uint256) {
        return IIgnixManager(manager).tokens(OB_TOKEN).vQuote;
    }

    function test_Q5_reader_tolerates_longer_returndata_and_rejects_shorter() public {
        FakeManager longer = new FakeManager(17);
        FakeManager shorter = new FakeManager(15);

        (bool ok, CurveToken memory t) = IgnixRead.tryTokens(address(longer), OB_TOKEN);
        assertTrue(ok, "17 words accepted");
        assertEq(t.vQuote, 10);
        assertEq(uint256(t.poolId), 16);
        // the typed interface accepts a longer answer too
        CurveToken memory t2 = IIgnixManager(address(longer)).tokens(OB_TOKEN);
        assertEq(t2.reserve, 15);

        (ok,) = IgnixRead.tryTokens(address(shorter), OB_TOKEN);
        assertFalse(ok, "15 words rejected without reverting");
        // ... while the typed interface reverts in the CALLER's ABI decoder
        vm.expectRevert();
        this.typedRead(address(shorter));

        // an address with no code
        (ok,) = IgnixRead.tryTokens(address(0xDEAD0001), OB_TOKEN);
        assertFalse(ok);
    }
}
