// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title Exact Q64.96 price encoding from two token amounts
/// @notice Computes floor(sqrt(amount1 / amount0) * 2^96) without first materialising
///         amount1 * 2^192 / amount0 in a uint256.
library PriceMath {
    error InvalidPrice();

    /// @dev Both amounts are uint128 because the Manager stores `collected` and `reserve` as
    ///      uint128. The bounds make every limb operation in `_squareTimesAmount0LteTarget`
    ///      provably fit its uint256 container.
    function sqrtPriceX96(uint128 amount1, uint128 amount0) internal pure returns (uint160 price) {
        if (amount0 == 0 || amount1 == 0) revert InvalidPrice();

        // V4 accepts [MIN_SQRT_PRICE, MAX_SQRT_PRICE). Search that exact domain rather than
        // returning a saturated uint160 that PoolManager would reject later.
        uint256 low = TickMath.MIN_SQRT_PRICE;
        uint256 high = TickMath.MAX_SQRT_PRICE; // exclusive
        if (
            !_squareTimesAmount0LteTarget(low, amount1, amount0)
                || _squareTimesAmount0LteTarget(high, amount1, amount0)
        ) revert InvalidPrice();

        // Find the greatest p for which p² * amount0 <= amount1 * 2¹⁹². This is exactly
        // floor(sqrt(amount1 / amount0) * 2⁹⁶), including the final rounding direction.
        while (low + 1 < high) {
            uint256 mid = (low + high) >> 1;
            if (_squareTimesAmount0LteTarget(mid, amount1, amount0)) {
                low = mid;
            } else {
                high = mid;
            }
        }
        price = SafeCast.toUint160(low);
    }

    /// @dev Compares two 512-bit integers without truncation:
    ///        candidate² * amount0 <= amount1 * 2¹⁹².
    ///
    /// candidate is at most 160 bits. Its square is at most 320 bits; multiplying the high
    /// 64-bit limb by a uint128 amount is at most 192 bits, so adding it to the other high
    /// limb cannot overflow uint256.
    function _squareTimesAmount0LteTarget(uint256 candidate, uint128 amount1, uint128 amount0)
        private
        pure
        returns (bool)
    {
        (uint256 squareHigh, uint256 squareLow) = Math.mul512(candidate, candidate);
        (uint256 productHigh, uint256 productLow) = Math.mul512(squareLow, uint256(amount0));
        productHigh += squareHigh * uint256(amount0);

        // A uint128 shifted left by 192 occupies at most 320 bits. Split it at bit 256.
        uint256 targetHigh = uint256(amount1) >> 64;
        uint256 targetLow = uint256(amount1) << 192;

        return productHigh < targetHigh || (productHigh == targetHigh && productLow <= targetLow);
    }
}
