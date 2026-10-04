// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CurveToken, IIgnixManager} from "./interfaces/IIgnix.sol";
import {CurveQuote} from "./CurveQuote.sol";

/// @title IgnixRead: non-reverting reads of IgnixManager state for a contract that must never revert on them
/// @notice A typed interface call reverts if the Manager (an upgradeable proxy) ever returns fewer than 512
///         bytes or reverts. These helpers return `ok = false` instead. Extra trailing words (the struct is
///         documented as append-only) are tolerated.
library IgnixRead {
    bytes4 private constant TOKENS = IIgnixManager.tokens.selector; // 0xe4860339
    bytes4 private constant PAIR_OF = IIgnixManager.pairOf.selector; // 0xa7465bdb
    bytes4 private constant SNIPE_BPS_NOW = IIgnixManager.snipeBpsNow.selector; // 0xf91a40b4
    bytes4 private constant FOUNDER_ROUND = IIgnixManager.founderRound.selector; // 0x47965b55
    bytes4 private constant PAUSED_UNTIL = IIgnixManager.pausedUntil.selector; // 0x54bce65b

    /// @notice tokens(token), or ok = false if the call fails or returns fewer than 16 words.
    function tryTokens(address manager, address token) internal view returns (bool ok, CurveToken memory t) {
        (bool success, bytes memory ret) = manager.staticcall(abi.encodeWithSelector(TOKENS, token));
        if (!success || ret.length < 512) return (false, t);
        // Decode word by word and mask, so a dirty high bit can never make abi.decode revert.
        uint256[16] memory w;
        assembly {
            for { let i := 0 } lt(i, 16) { i := add(i, 1) } {
                mstore(add(w, mul(i, 0x20)), mload(add(add(ret, 0x20), mul(i, 0x20))))
            }
        }
        t.creator = address(uint160(w[0]));
        t.buyFeeBps = uint16(w[1]);
        t.sellFeeBps = uint16(w[2]);
        t.taxBuyBps = uint16(w[3]);
        t.taxSellBps = uint16(w[4]);
        t.quote = address(uint160(w[5]));
        t.snipeStartBps = uint16(w[6]);
        t.snipeMins = uint16(w[7]);
        t.createdAt = uint64(w[8]);
        t.vQuote = uint128(w[9]);
        t.vToken = uint128(w[10]);
        t.sold = uint128(w[11]);
        t.collected = uint128(w[12]);
        t.sellable = uint128(w[13]);
        t.reserve = uint128(w[14]);
        t.poolId = bytes32(w[15]);
        ok = true;
    }

    function curveOf(CurveToken memory t) internal pure returns (CurveQuote.Curve memory c) {
        c = CurveQuote.Curve(t.buyFeeBps, t.taxBuyBps, t.vQuote, t.vToken, t.sold, t.sellable);
    }

    /// @notice One word from a single-argument view, or ok = false.
    function tryWord(address manager, bytes4 selector, uint256 arg)
        internal
        view
        returns (bool ok, uint256 word)
    {
        (bool success, bytes memory ret) = manager.staticcall(abi.encodeWithSelector(selector, arg));
        if (!success || ret.length < 32) return (false, 0);
        assembly {
            word := mload(add(ret, 0x20))
        }
        ok = true;
    }

    function tryPairOf(address manager, address token) internal view returns (bool ok, address pair) {
        uint256 w;
        (ok, w) = tryWord(manager, PAIR_OF, uint256(uint160(token)));
        pair = address(uint160(w));
    }

    function trySnipeBpsNow(address manager, address token) internal view returns (bool ok, uint256 bps) {
        (ok, bps) = tryWord(manager, SNIPE_BPS_NOW, uint256(uint160(token)));
    }

    function tryPausedUntil(address manager, uint256 kind) internal view returns (bool ok, uint64 until) {
        uint256 w;
        (ok, w) = tryWord(manager, PAUSED_UNTIL, kind);
        until = uint64(w);
    }

    /// @notice founderRound(token).endsAt (word 1 of 4), or ok = false. Zero means no founder round.
    function tryFounderEndsAt(address manager, address token) internal view returns (bool ok, uint64 endsAt) {
        (bool success, bytes memory ret) = manager.staticcall(abi.encodeWithSelector(FOUNDER_ROUND, token));
        if (!success || ret.length < 128) return (false, 0);
        uint256 w;
        assembly {
            w := mload(add(ret, 0x40))
        }
        endsAt = uint64(w);
        ok = true;
    }
}
