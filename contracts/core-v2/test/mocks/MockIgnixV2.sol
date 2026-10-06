// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Test doubles of the IGNIX contracts a v2 kernel talks to when the quote is an ERC-20 (USD₮0). They follow
// kernel v1's doubles (contracts/core/test/mocks/MockIgnix.sol), which mirror IGNIX's verified MIT sources
// (contracts/vendor/ignix-xlayer), with the quote paths of those sources for an ERC-20 quote: the Manager pulls
// the quote with transferFrom and measures what arrived (QuoteLib.pullExact), pays tax, refunds and sellers by
// ERC-20 transfer, and graduates into a token/quote V2 pair. The fork probes Q11 and Q12
// (contracts/probes/test) measured the same behaviour on the live contracts.
//
// The project token (MockToken), the V2 pair (MockPair) and the gas burner are kernel v1's doubles, unchanged.
//
// chips/golden/world_v2.py mirrors these contracts arithmetic for arithmetic; change both together.

import {GasBurner, MockToken, MockPair} from "core-test/mocks/MockIgnix.sol";

/// @notice USD₮0 as far as a kernel uses it: 6 decimals, approve without the classic-USDT zero-first rule
///         (measured on X Layer, Q12 R1), and Tether's owner powers (block an address; a blocked address still
///         receives but cannot send or be pulled from; destroy its balance), with failure switches.
contract MockUSDT0 is GasBurner {
    string public constant name = "USDT0 (mock)";
    string public constant symbol = "USDT0";
    uint8 public constant decimals = 6;

    address public immutable owner;
    uint256 public totalSupply;
    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlocked;

    // failure switches (tests only)
    bool public balanceOfReverts;
    bool public transferReverts;
    bool public approveReverts;
    bool public approveReturnsFalse; // returns false and leaves the allowance unchanged
    uint256 public feeBps; // fee-on-transfer, taken from what the recipient gets (an upgrade could add one)

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function setFailure(bool balRev, bool xferRev, bool apprRev, bool apprFalse) external {
        balanceOfReverts = balRev;
        transferReverts = xferRev;
        approveReverts = apprRev;
        approveReturnsFalse = apprFalse;
    }

    function setFeeBps(uint256 f) external {
        feeBps = f;
    }

    function addToBlockedList(address a) external {
        require(msg.sender == owner, "owner");
        isBlocked[a] = true;
    }

    function removeFromBlockedList(address a) external {
        require(msg.sender == owner, "owner");
        isBlocked[a] = false;
    }

    function destroyBlockedFunds(address a) external {
        require(msg.sender == owner && isBlocked[a], "owner/blocked");
        totalSupply -= _bal[a];
        _bal[a] = 0;
    }

    function balanceOf(address a) external view returns (uint256) {
        require(!balanceOfReverts, "balanceOf");
        return _bal[a];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(!approveReverts, "approve");
        if (approveReturnsFalse) return false;
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: insufficient allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        _burn();
        require(!transferReverts, "transfer");
        require(!isBlocked[from], "TetherToken: from is blocked");
        require(_bal[from] >= amount, "ERC20: transfer amount exceeds balance");
        uint256 fee = (amount * feeBps) / 10_000;
        _bal[from] -= amount;
        _bal[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

interface IERC20Q {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @notice IGNIX Directed vault with an ERC-20 quote: no ledger, claimable is the balance, the whole balance goes
///         to RECIPIENT by plain ERC-20 transfer (no callback). claim(address(0)) is UnknownAsset (Q11 U1).
contract MockVaultV2 is GasBurner {
    address public immutable RECIPIENT;
    address public immutable MANAGER;
    address public immutable TOKEN;
    address public immutable QUOTE;

    // failure switches (tests only): 0 normal, 1 revert, 2 burn all gas, 3 Paused() (IGNIX's DIVIDEND pause)
    uint8 public mode;

    error Unauthorized();
    error UnknownAsset();
    error Paused();
    error NothingToClaim();

    event Claimed(address indexed recipient, address indexed asset, uint256 amount);

    constructor(address token_, address recipient_, address manager_, address quote_) {
        TOKEN = token_;
        RECIPIENT = recipient_;
        MANAGER = manager_;
        QUOTE = quote_;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function sync() external {}

    function claimableNow(address recipient, address asset) external view returns (uint256) {
        if (recipient != RECIPIENT) return 0;
        if (asset == QUOTE) return IERC20Q(QUOTE).balanceOf(address(this));
        if (asset == TOKEN) {
            return MockToken(TOKEN).pair() == address(0) ? 0 : MockToken(TOKEN).balanceOf(address(this));
        }
        revert UnknownAsset();
    }

    function claim(address asset) external returns (uint256) {
        if (msg.sender != RECIPIENT) revert Unauthorized();
        return _claim(asset);
    }

    function claimFor(address recipient, address asset) external returns (uint256) {
        if (recipient != RECIPIENT) revert Unauthorized();
        return _claim(asset);
    }

    function _claim(address asset) internal returns (uint256 amount) {
        _burn();
        if (mode == 1) revert("vault broken");
        if (mode == 2) {
            while (true) {}
        }
        if (mode == 3) revert Paused();
        if (asset == QUOTE && asset != address(0)) {
            amount = IERC20Q(QUOTE).balanceOf(address(this));
            if (amount == 0) revert NothingToClaim();
            require(IERC20Q(QUOTE).transfer(RECIPIENT, amount), "SafeERC20FailedOperation");
        } else if (asset == TOKEN) {
            amount = MockToken(TOKEN).pair() == address(0) ? 0 : MockToken(TOKEN).balanceOf(address(this));
            if (amount == 0) revert NothingToClaim();
            MockToken(TOKEN).transfer(RECIPIENT, amount);
        } else {
            revert UnknownAsset();
        }
        emit Claimed(RECIPIENT, asset, amount);
    }
}

/// @notice IgnixManager with an ERC-20 quote, reduced to what a kernel and traders use, with the real curve
///         arithmetic (CurveTrading.buy / sell, CurveMath, V2Graduation without the donation handling).
contract MockManagerV2 is GasBurner {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    struct Token {
        address creator;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint16 taxBuyBps;
        uint16 taxSellBps;
        address quote;
        uint16 snipeStartBps;
        uint16 snipeMins;
        uint64 createdAt;
        uint128 vQuote;
        uint128 vToken;
        uint128 sold;
        uint128 collected;
        uint128 sellable;
        uint128 reserve;
        bytes32 poolId;
    }

    address public immutable QUOTE;
    mapping(address => Token) internal _t;
    mapping(address => address) internal _vaultOf;
    mapping(address => address) internal _pairOf;
    mapping(uint256 => uint64) public pausedUntil;
    mapping(address => uint64) public founderEndsAt;
    uint256 public platformAccrued;

    // failure switches (tests only)
    uint8 public tokensMode; // 0 normal, 1 revert, 2 short (480 bytes), 3 long (544 bytes), 4 absurd, 5 burn gas
    bool public snipeReverts;
    // 0 normal, 1 revert, 2 burn all gas, 3 deliver one token less than quoted (Slippage), 4 revert with data
    uint8 public buyMode;
    bytes public buyRevertData;
    address public reenterTarget;
    bytes public reenterData;
    uint256 public refundQuote; // quote sent back to the buy recipient after a buy ("part came back")
    bool public pullMore; // transferFrom one unit more than asked (models a Manager that over-pulls)

    error Slippage();
    error SoldOut();
    error BadValue();
    error FounderOnly();
    error Paused();
    error Graduated_();
    error NotFound();
    error ReentrancyGuardReentrantCall();

    bool internal _entered;

    modifier nonReentrant() {
        if (_entered) revert ReentrancyGuardReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    event Trade(address indexed token, address indexed trader, bool isBuy, uint256 gross, uint256 out, uint256 tax);
    event GraduatedV2(address indexed token, address indexed pair, uint128 quoteInjected, uint128 tokenInjected);

    constructor(address quote_) {
        QUOTE = quote_;
    }

    // ------------------------------------------------------------------ test controls

    function setTokensMode(uint8 m) external {
        tokensMode = m;
    }

    function setSnipeReverts(bool v) external {
        snipeReverts = v;
    }

    function setBuyMode(uint8 m) external {
        buyMode = m;
    }

    function setBuyRevertData(bytes calldata d) external {
        buyRevertData = d;
        buyMode = 4;
    }

    function setPaused(uint256 kind, uint64 until) external {
        pausedUntil[kind] = until;
    }

    function setFounderRound(address token, uint64 endsAt) external {
        founderEndsAt[token] = endsAt;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function setRefundQuote(uint256 q) external {
        refundQuote = q;
    }

    function setPullMore(bool v) external {
        pullMore = v;
    }

    function setCreator(address token, address creator) external {
        _t[token].creator = creator;
    }

    function setQuoteOf(address token, address q) external {
        _t[token].quote = q;
    }

    function setFees(address token, uint16 buyFeeBps, uint16 sellFeeBps) external {
        _t[token].buyFeeBps = buyFeeBps;
        _t[token].sellFeeBps = sellFeeBps;
    }

    function setVault(address token, address vault) external {
        _vaultOf[token] = vault;
    }

    /// @dev Runs `target.call(data)` while the Manager's reentrancy lock is held. The real Manager is shared by
    ///      every IGNIX token: the sell of any token quoted in native OKB pays the seller by a native call made
    ///      under this lock, which is how a contract can call a kernel while the lock is held.
    function withLock(address target, bytes calldata data) external nonReentrant returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    // ------------------------------------------------------------------ launch

    /// @dev IGNIX's CurveMath.params for an 80/20 split: C = 800M, D = 200M, T = C^2 / (C - D), E = G (T - C) / C.
    function createToken(
        address creator,
        address recipient,
        uint16 taxBuyBps,
        uint16 taxSellBps,
        uint16 snipeStartBps,
        uint16 snipeMins,
        uint256 graduation
    ) external returns (address token, address vault) {
        MockToken tk = new MockToken();
        token = address(tk);
        vault = address(new MockVaultV2(token, recipient, address(this), QUOTE));
        _vaultOf[token] = vault;
        tk.initTaxConfig(vault, taxBuyBps, taxSellBps);

        uint256 c = (TOTAL_SUPPLY * 8000) / BPS;
        uint256 d = TOTAL_SUPPLY - c;
        uint256 tt = (c * c) / (c - d);
        uint256 e = (graduation * (tt - c)) / c;
        Token storage t = _t[token];
        t.creator = creator;
        t.buyFeeBps = 100;
        t.sellFeeBps = 100;
        t.taxBuyBps = taxBuyBps;
        t.taxSellBps = taxSellBps;
        t.quote = QUOTE;
        t.snipeStartBps = snipeStartBps;
        t.snipeMins = snipeMins;
        t.createdAt = uint64(block.timestamp);
        t.vQuote = uint128(e);
        t.vToken = uint128(tt);
        t.sellable = uint128(c);
        t.reserve = uint128(d);
    }

    // ------------------------------------------------------------------ views

    function vaultOf(address token) external view returns (address) {
        return _vaultOf[token];
    }

    function pairOf(address token) external view returns (address) {
        return _pairOf[token];
    }

    function raw(address token) external view returns (Token memory) {
        return _t[token];
    }

    /// @dev The real getter returns 16 static words. The failure modes return fewer, more or absurd words.
    function tokens(address token) external view returns (bytes memory) {
        Token memory t = _t[token];
        if (tokensMode == 1) revert("tokens");
        if (tokensMode == 5) {
            while (true) {}
        }
        uint256 vq = t.vQuote;
        if (tokensMode == 4) vq = type(uint256).max;
        bytes memory out = abi.encode(
            t.creator,
            t.buyFeeBps,
            t.sellFeeBps,
            t.taxBuyBps,
            t.taxSellBps,
            t.quote,
            t.snipeStartBps,
            t.snipeMins,
            t.createdAt,
            vq,
            t.vToken,
            t.sold
        );
        out = bytes.concat(out, abi.encode(t.collected, t.sellable, t.reserve, t.poolId));
        if (tokensMode == 3) out = bytes.concat(out, abi.encode(uint256(0xdead)));
        uint256 n = tokensMode == 2 ? 480 : out.length;
        assembly {
            return(add(out, 0x20), n)
        }
    }

    function snipeBpsNow(address token) public view returns (uint256) {
        require(!snipeReverts, "snipe");
        Token storage t = _t[token];
        if (t.snipeStartBps == 0) return 0;
        uint256 win = uint256(t.snipeMins) * 60;
        uint256 startsAt = t.createdAt;
        if (founderEndsAt[token] > startsAt) startsAt = founderEndsAt[token];
        if (block.timestamp <= startsAt) return t.snipeStartBps;
        uint256 el = block.timestamp - startsAt;
        if (el >= win) return 0;
        return (uint256(t.snipeStartBps) * (win - el)) / win;
    }

    function founderRound(address token) external view returns (bytes32, uint64, uint128, uint128) {
        return (bytes32(0), founderEndsAt[token], 0, 0);
    }

    // ------------------------------------------------------------------ trading

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable nonReentrant {
        _publicBuy(token, amountIn, minTokensOut, msg.sender);
    }

    function buyTo(address token, uint256 amountIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
    {
        if (recipient == address(0) || recipient == address(this)) revert BadValue();
        _publicBuy(token, amountIn, minTokensOut, recipient);
    }

    function _publicBuy(address token, uint256 amountIn, uint256 minOut, address recipient) internal {
        _burn();
        if (buyMode == 1) revert("buy broken");
        if (buyMode == 2) {
            while (true) {}
        }
        if (buyMode == 4) {
            bytes memory d = buyRevertData;
            assembly {
                revert(add(d, 0x20), mload(d))
            }
        }
        if (reenterTarget != address(0)) {
            (bool okR,) = reenterTarget.call(reenterData);
            require(okR, "reentry rejected");
        }
        if (block.timestamp < founderEndsAt[token]) revert FounderOnly();
        if (block.timestamp < pausedUntil[1]) revert Paused();
        if (msg.value != 0) revert BadValue(); // an ERC-20 quote: msg.value must be 0 (Q11 U3)

        Token storage t = _t[token];
        if (t.creator == address(0)) revert NotFound();
        if (_pairOf[token] != address(0)) revert Graduated_();
        amountIn = _pullExact(msg.sender, pullMore ? amountIn + 1 : amountIn);

        uint256 feeBps = uint256(t.buyFeeBps) + t.taxBuyBps + snipeBpsNow(token);
        uint256 net = amountIn - (amountIn * feeBps) / BPS;
        uint256 left = t.sellable - t.sold;
        uint256 out = t.vToken - _ceilDiv(uint256(t.vQuote) * t.vToken, t.vQuote + net);
        uint256 refund;
        if (out >= left) {
            out = left;
            net = _ceilDiv(uint256(t.vQuote) * left, t.vToken - left);
            uint256 grossNeeded = _ceilDiv(net * BPS, BPS - feeBps);
            if (grossNeeded < amountIn) {
                refund = amountIn - grossNeeded;
                amountIn = grossNeeded;
            }
        }
        if (buyMode == 3) out -= 1;
        if (out < minOut) revert Slippage();
        if (out == 0) revert SoldOut();

        uint256 tax = (amountIn * t.taxBuyBps) / BPS;
        uint256 pFee = amountIn - net - tax;
        t.vQuote += uint128(net);
        t.vToken -= uint128(out);
        t.sold += uint128(out);
        t.collected += uint128(net);
        platformAccrued += pFee;

        require(MockToken(token).transfer(recipient, out), "SafeERC20FailedOperation");
        if (tax > 0) _pay(_vaultOf[token], tax);
        emit Trade(token, recipient, true, amountIn, out, tax);

        if (t.sold == t.sellable) _graduate(token);
        if (refund > 0) _pay(recipient, refund);
        if (refundQuote > 0) _pay(recipient, refundQuote);
    }

    function sell(address token, uint256 tokenIn, uint256 minQuoteOut) external nonReentrant {
        if (block.timestamp < pausedUntil[4]) revert Paused();
        Token storage t = _t[token];
        if (t.creator == address(0)) revert NotFound();
        if (_pairOf[token] != address(0)) revert Graduated_();
        require(MockToken(token).transferFrom(msg.sender, address(this), tokenIn), "SafeERC20FailedOperation");

        uint256 gross = t.vQuote - _ceilDiv(uint256(t.vQuote) * t.vToken, t.vToken + tokenIn);
        uint256 pFee = (gross * t.sellFeeBps) / BPS;
        uint256 jFee = (gross * t.taxSellBps) / BPS;
        uint256 net = gross - pFee - jFee;
        if (net < minQuoteOut) revert Slippage();

        t.vQuote -= uint128(gross);
        t.vToken += uint128(tokenIn);
        t.sold -= uint128(tokenIn);
        t.collected -= uint128(gross);
        platformAccrued += pFee;
        _pay(msg.sender, net);
        if (jFee > 0) _pay(_vaultOf[token], jFee);
        emit Trade(token, msg.sender, false, gross, tokenIn, jFee);
    }

    /// @dev QuoteLib.pullExact: what arrived, not what was asked for.
    function _pullExact(address from, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20Q(QUOTE).balanceOf(address(this));
        require(IERC20Q(QUOTE).transferFrom(from, address(this), amount), "SafeERC20FailedOperation");
        return IERC20Q(QUOTE).balanceOf(address(this)) - before;
    }

    function _pay(address to, uint256 amount) internal {
        require(IERC20Q(QUOTE).transfer(to, amount), "SafeERC20FailedOperation");
    }

    /// @dev V2Graduation.inject: a token/quote pair funded with the curve's reserve tokens and `collected`.
    function _graduate(address token) internal {
        Token storage t = _t[token];
        MockPair p = new MockPair(token, QUOTE);
        _pairOf[token] = address(p);
        MockToken(token).unlock();
        require(MockToken(token).transfer(address(p), t.reserve), "SafeERC20FailedOperation");
        _pay(address(p), t.collected);
        p.sync();
        MockToken(token).setPair(address(p));
        emit GraduatedV2(token, address(p), t.collected, t.reserve);
    }

    /// @dev Gross quote that buys the whole remaining curve (test helper).
    function costToGraduate(address token) external view returns (uint256) {
        Token storage t = _t[token];
        uint256 left = t.sellable - t.sold;
        if (left == 0) return 0;
        uint256 feeBps = uint256(t.buyFeeBps) + t.taxBuyBps + snipeBpsNow(token);
        uint256 net = _ceilDiv(uint256(t.vQuote) * left, t.vToken - left);
        return _ceilDiv(net * BPS, BPS - feeBps);
    }
}

/// @notice Uniswap V2 Router02, reduced to the ERC-20 to ERC-20 fee-on-transfer variant, in both directions.
contract MockRouterV2 is GasBurner {
    address public immutable manager;
    address public immutable QUOTE;

    // failure switches (tests only): 0 normal, 1 revert, 2 burn all gas, 3 revert with `revertData`
    uint8 public mode;
    bytes public revertData;
    uint256 public pullLess; // pulls this much less than amountIn (a router that does not spend all it may)

    constructor(address manager_, address quote_) {
        manager = manager_;
        QUOTE = quote_;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function setRevertData(bytes calldata d) external {
        revertData = d;
        mode = 3;
    }

    function setPullLess(uint256 x) external {
        pullLess = x;
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 f = amountIn * 997;
        return (f * rOut) / (rIn * 1000 + f);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        _burn();
        if (mode == 1) revert("router broken");
        if (mode == 2) {
            while (true) {}
        }
        if (mode == 3) {
            bytes memory d = revertData;
            assembly {
                revert(add(d, 0x20), mload(d))
            }
        }
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(path.length == 2, "UniswapV2Router: INVALID_PATH");
        uint256 before = IERC20Q(path[1]).balanceOf(to);
        _swap(amountIn, path[0], path[1], to);
        require(
            IERC20Q(path[1]).balanceOf(to) - before >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function _swap(uint256 amountIn, address tIn, address tOut, address to) internal {
        MockPair p = MockPair(MockManagerV2(manager).pairOf(tIn == QUOTE ? tOut : tIn));
        require(address(p) != address(0), "no pair");
        uint256 pulled = pullLess != 0 && pullLess < amountIn ? amountIn - pullLess : amountIn;
        require(IERC20Q(tIn).transferFrom(msg.sender, address(p), pulled), "TransferHelper: TRANSFER_FROM_FAILED");
        (uint112 a, uint112 b,) = p.getReserves();
        bool inIs0 = p.token0() == tIn;
        (uint256 rIn, uint256 rOut) = inIs0 ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 out = _out(IERC20Q(tIn).balanceOf(address(p)) - rIn, rIn, rOut);
        if (inIs0) p.swap(0, out, to, "");
        else p.swap(out, 0, to, "");
    }
}
