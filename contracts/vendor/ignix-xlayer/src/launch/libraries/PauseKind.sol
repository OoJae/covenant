// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * Identifiers for the emergency switches. The switches themselves live in one mapping on
 * `IgnixManager`; every other contract reads them from there.
 *
 * Centralising the deadlines keeps pause duration policy and state writes in the upgradeable
 * Manager. What is *not* revisable is where the checks sit — those are compiled into singletons
 * and per-token contracts that can only be replaced by a new generation. Adding a new gate must
 * therefore add both an append-only identifier here and a check at the affected call site.
 *
 * `internal constant` costs nothing at deploy time (the compiler inlines the values), which
 * matters: the Manager sits within ~1.4 KB of the EIP-170 ceiling.
 *
 * ## Two classes, and the line between them
 *
 * Platform-operated actions may be held closed indefinitely.
 *
 * `SELL` / `DIVIDEND` gate paths that move **users' own money**, and the Manager
 * caps those at 72 hours. The cap does not restrain an attacker — the owner can always renew —
 * it exists so a lost key or an abandoned team cannot leave user funds locked forever. A brake
 * that never releases is indistinguishable from confiscation, and this product's whole claim is
 * that the platform holds no such power.
 *
 * Values become part of the on-chain interface at deployment: **append only, never renumber.**
 */
library PauseKind {
    /// Creating new tokens.
    uint256 internal constant LAUNCH = 0;
    /// Buying on the bonding curve. Covers `buy` and `buyFounder` alike — both funnel through
    /// `_pullAndBuy`, so one check gates both.
    uint256 internal constant BUY = 1;
    /// Platform and creator withdrawals of curve trading fees.
    uint256 internal constant CURVE_FEE = 2;
    /// Collecting and withdrawing LP fees, on both the V4 and V2 lockers.
    uint256 internal constant LP_FEE = 3;

    /// Selling back to the curve — a holder's only exit before graduation.
    uint256 internal constant SELL = 4;
    // 5 was AIRDROP — retired 2026-08-17 together with the airdrop feature. Values are part
    // of the on-chain interface (append only, never renumber), so 5 stays a permanent hole.
    /// Claiming accrued dividends, for holders and for the creator's share alike.
    uint256 internal constant DIVIDEND = 6;

    /// Adding or removing liquidity through the protocol's tax-exempt V2 helper.
    uint256 internal constant LIQUIDITY = 7;
    /// Swapping through the protocol's restricted V4 router.
    uint256 internal constant V4_SWAP = 8;

    uint256 internal constant LAST = V4_SWAP;

    /// @dev Pause identifiers are append-only, so numeric ranges cannot encode this class once
    ///      new platform-operated actions are appended after user-funds actions.
    function isUserFunds(uint256 kind) internal pure returns (bool) {
        return kind == SELL || kind == DIVIDEND;
    }
}
