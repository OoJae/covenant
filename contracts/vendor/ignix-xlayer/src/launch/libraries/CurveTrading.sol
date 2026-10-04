// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { CurveMath } from "./CurveMath.sol";
import { QuoteLib } from "./QuoteLib.sol";

/// @dev Field order and widths are the Manager's persistent storage layout. Do not reorder,
///      insert, or widen fields: packed changes shift every field after them.
struct CurveToken {
    // Slot 0: creator + four rates (20 + 2 + 2 + 2 + 2 bytes)
    address creator;
    uint16 buyFeeBps; // curve buy fee, paid to the platform
    uint16 sellFeeBps; // curve sell fee, paid to the platform
    // Non-zero tax implies the V2 venue; createToken binds that invariant.
    uint16 taxBuyBps;
    uint16 taxSellBps;
    // Slot 1: quote + anti-snipe config (20 + 2 + 2 + 8 bytes)
    address quote; // zero means native OKB
    uint16 snipeStartBps; // zero disables anti-snipe
    uint16 snipeMins; // linear decay window in minutes
    uint64 createdAt; // anti-snipe clock origin
    // Slot 2: virtual constant-product reserves
    uint128 vQuote; // initialized to E from the graduation threshold
    uint128 vToken; // initialized to T
    // Slot 3: running curve totals
    uint128 sold;
    uint128 collected; // net quote raised, injected into the LP in full
    // Slot 4: supply split fixed at creation
    uint128 sellable; // curve allocation C
    uint128 reserve; // DEX allocation D
    // Slot 5: non-zero means V4-graduated and is the V4 Swap join key
    bytes32 poolId;
}

/// @dev Manager inherits this interface so its ABI and the linked library share one source for
///      the curve event and errors. The library emits/reverts these exact declarations through
///      DELEGATECALL, while the Manager artifact remains the public integration ABI.
interface ICurveTradingAbi {
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 grossQuoteAmount,
        uint256 netQuoteAmount,
        uint256 curveQuoteAmount,
        uint256 tokenAmount,
        uint256 platformFee,
        uint256 taxFee,
        uint128 collected
    );

    error Slippage();
    error SoldOut();
}

/// @title IGNIX bonding-curve trade execution and adapter authorization
/// @dev External solely for Manager bytecode headroom. Forge links this library into the
///      Manager implementation and invokes it with DELEGATECALL, so balances, storage,
///      `address(this)`, `msg.sender`, and emitted log addresses all remain those of Manager.
library CurveTrading {
    using SafeERC20 for IERC20;
    using QuoteLib for address;

    uint256 private constant BPS = 10_000;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant SELL_FROM_TYPEHASH = keccak256(
        "SellFrom(address adapter,address token,address payer,address recipient,uint256 tokenIn,uint256 minQuoteOut,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant EIP712_NAME_HASH = keccak256("IgnixManager");
    bytes32 private constant EIP712_VERSION_HASH = keccak256("1");

    struct SellFromCall {
        address token;
        address payer;
        address recipient;
        uint256 tokenIn;
        uint256 minQuoteOut;
        uint256 deadline;
        bytes authorization;
    }

    function buy(
        CurveToken storage t,
        mapping(address => uint256) storage platformAccrued,
        mapping(address => address) storage vaultOf,
        address token,
        uint256 quoteIn,
        uint256 minOut,
        uint256 snipeBps,
        address recipient
    ) external returns (uint256 refund, bool soldOut) {
        uint256 feeBps = uint256(t.buyFeeBps) + t.taxBuyBps + snipeBps;
        uint256 net = quoteIn - (quoteIn * feeBps) / BPS;

        uint256 left = t.sellable - t.sold;
        uint256 out = CurveMath.tokensOut(t.vQuote, t.vToken, net);
        if (out >= left) {
            out = left;
            net = CurveMath.quoteInFor(t.vQuote, t.vToken, left);
            uint256 grossNeeded = Math.mulDiv(net, BPS, BPS - feeBps, Math.Rounding.Ceil);
            if (grossNeeded < quoteIn) {
                refund = quoteIn - grossNeeded;
                quoteIn = grossNeeded;
            }
        }
        if (out < minOut) revert ICurveTradingAbi.Slippage();
        if (out == 0) revert ICurveTradingAbi.SoldOut();

        uint256 tax = (quoteIn * t.taxBuyBps) / BPS;
        // Platform receives the curve fee and all anti-snipe fees, including rounding dust.
        uint256 pFee = quoteIn - net - tax;

        t.vQuote += SafeCast.toUint128(net);
        t.vToken -= SafeCast.toUint128(out);
        t.sold += SafeCast.toUint128(out);
        t.collected += SafeCast.toUint128(net);
        platformAccrued[t.quote] += pFee;

        IERC20(token).safeTransfer(recipient, out);
        if (tax > 0) t.quote.pay(vaultOf[token], tax);
        emit ICurveTradingAbi.Trade(
            token, recipient, true, quoteIn, net, net, out, pFee, tax, t.collected
        );
        soldOut = t.sold == t.sellable;
    }

    function sell(
        CurveToken storage t,
        mapping(address => uint256) storage platformAccrued,
        mapping(address => address) storage vaultOf,
        address token,
        address payer,
        address recipient,
        uint256 tokenIn,
        uint256 minQuoteOut
    ) external {
        IERC20(token).safeTransferFrom(payer, address(this), tokenIn);

        uint256 gross = CurveMath.quoteOut(t.vQuote, t.vToken, tokenIn);
        uint256 pFee = (gross * t.sellFeeBps) / BPS;
        uint256 jFee = (gross * t.taxSellBps) / BPS;
        uint256 net = gross - pFee - jFee;
        if (net < minQuoteOut) revert ICurveTradingAbi.Slippage();

        t.vQuote -= SafeCast.toUint128(gross);
        t.vToken += SafeCast.toUint128(tokenIn);
        t.sold -= SafeCast.toUint128(tokenIn);
        t.collected -= SafeCast.toUint128(gross);
        platformAccrued[t.quote] += pFee;

        t.quote.pay(recipient, net);
        if (jFee > 0) t.quote.pay(vaultOf[token], jFee);
        emit ICurveTradingAbi.Trade(
            token, payer, false, gross, net, gross, tokenIn, pFee, jFee, t.collected
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    function sellFromTypehash() external pure returns (bytes32) {
        return SELL_FROM_TYPEHASH;
    }

    /// @dev Passing the original Manager calldata as one slice keeps the Manager-side
    ///      DELEGATECALL encoder small. Decoding and hashing live entirely in this library.
    function verifySell(bytes calldata sellFromCalldata, uint256 nonce)
        external
        view
        returns (bool)
    {
        SellFromCall memory order;
        (
            order.token,
            order.payer,
            order.recipient,
            order.tokenIn,
            order.minQuoteOut,
            order.deadline,
            order.authorization
        ) =
            abi.decode(
                sellFromCalldata[4:], (address, address, address, uint256, uint256, uint256, bytes)
            );
        bytes32 structHash = keccak256(
            abi.encode(
                SELL_FROM_TYPEHASH,
                msg.sender,
                order.token,
                order.payer,
                order.recipient,
                order.tokenIn,
                order.minQuoteOut,
                nonce,
                order.deadline
            )
        );
        return SignatureChecker.isValidSignatureNow(
            order.payer,
            MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash),
            order.authorization
        );
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                EIP712_NAME_HASH,
                EIP712_VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }
}
