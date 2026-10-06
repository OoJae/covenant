// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Test doubles of the IGNIX contracts a kernel talks to. The curve arithmetic mirrors IGNIX's verified MIT
// sources (contracts/vendor/ignix-xlayer: CurveMath, CurveTrading, IgnixManager._buy, V2Graduation), the token
// and vault rules mirror what our fork probes measured (contracts/probes/src/interfaces). Each double has
// failure switches so tests can make every external dependency revert, lie or burn gas.

/// @dev Burns about `target` gas and then lets the caller continue: models a dependency that is expensive
///      but works, so tests can run every external call close to the gas the kernel gives it.
abstract contract GasBurner {
    uint256 public burnGas;

    function setBurnGas(uint256 g) external {
        burnGas = g;
    }

    function _burn() internal view {
        uint256 target = burnGas;
        if (target == 0) return;
        uint256 start = gasleft();
        uint256 x;
        while (start - gasleft() < target) {
            x = uint256(keccak256(abi.encode(x)));
        }
    }
}

interface IMockWOKB {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function withdraw(uint256) external;
}

/// @notice IGNIX launch token: fixed supply, CurveOnly before graduation, fee-on-transfer on the pair after it.
contract MockToken is GasBurner {
    string public constant name = "Mock IGNIX Token";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000e18;

    address public immutable MANAGER;
    bool public unlocked;
    /// The graduated pair, for tests and other mocks: this getter never fails. `pair()` below is the read
    /// the kernel and the vault make.
    address public pairAddr;
    address public taxSink;
    uint256 public taxBuyBps;
    uint256 public taxSellBps;
    mapping(address => bool) public taxExempt;
    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    // failure switches (tests only)
    bool public balanceOfReverts;
    bool public transferReverts;
    bool public transferReturnsFalse;
    address public blockedRecipient; // transfers to this address revert
    // pair(): 0 normal, 1 revert with 32 bytes of ones, 2 answer with 31 bytes of ones, 3 burn all gas
    uint8 public pairMode;

    error CurveOnly();

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor() {
        MANAGER = msg.sender;
        _bal[msg.sender] = totalSupply;
        taxExempt[msg.sender] = true;
    }

    modifier onlyManager() {
        require(msg.sender == MANAGER, "manager");
        _;
    }

    function initTaxConfig(address sink, uint256 buyBps, uint256 sellBps) external onlyManager {
        taxSink = sink;
        taxBuyBps = buyBps;
        taxSellBps = sellBps;
        taxExempt[sink] = true;
    }

    function unlock() external onlyManager {
        unlocked = true;
    }

    function setPair(address p) external onlyManager {
        pairAddr = p;
    }

    function setPairMode(uint8 m) external {
        pairMode = m;
    }

    /// @dev IgnixToken.pair(). The failing modes leave non-zero bytes where a careless reader would look for
    ///      an address, so a kernel that ignored the failure would latch on garbage.
    function pair() external view returns (address) {
        uint8 m = pairMode;
        if (m == 1) {
            assembly {
                mstore(0x00, not(0))
                revert(0x00, 0x20)
            }
        }
        if (m == 2) {
            assembly {
                mstore(0x00, not(0))
                return(0x00, 0x1f)
            }
        }
        if (m == 3) {
            while (true) {}
        }
        return pairAddr;
    }

    function setFailure(bool balRev, bool xferRev, bool xferFalse, address blocked) external {
        balanceOfReverts = balRev;
        transferReverts = xferRev;
        transferReturnsFalse = xferFalse;
        blockedRecipient = blocked;
    }

    function balanceOf(address a) external view returns (uint256) {
        require(!balanceOfReverts, "balanceOf");
        return _bal[a];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (transferReturnsFalse) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        _burn();
        require(!transferReverts, "transfer");
        require(to != blockedRecipient || to == address(0), "blocked");
        if (!unlocked && from != MANAGER && to != MANAGER) revert CurveOnly();
        _bal[from] -= amount;
        uint256 tax;
        if (unlocked && pairAddr != address(0) && !taxExempt[from] && !taxExempt[to]) {
            if (from == pairAddr) tax = (amount * taxBuyBps) / 10_000; // a buy
            else if (to == pairAddr) tax = (amount * taxSellBps) / 10_000; // a sell
        }
        if (tax != 0) {
            _bal[taxSink] += tax;
            emit Transfer(from, taxSink, tax);
        }
        _bal[to] += amount - tax;
        emit Transfer(from, to, amount - tax);
    }
}

/// @notice IGNIX Directed vault: no ledger, claimable is the balance, the whole balance goes to RECIPIENT.
contract MockVault is GasBurner {
    address public immutable RECIPIENT;
    address public immutable MANAGER;
    address public immutable TOKEN;
    address public immutable QUOTE; // address(0): native OKB

    // failure switches (tests only): 0 normal, 1 revert, 2 burn all gas, 3 Paused()
    uint8 public mode;
    // lies about immutables (bind tests)
    address public fakeRecipient;
    address public fakeToken;
    address public fakeQuote;
    bool public lie;

    error Unauthorized();
    error UnknownAsset();
    error Paused();
    error NothingToClaim();
    error TransferFailed();

    event Claimed(address indexed recipient, address indexed asset, uint256 amount);

    constructor(address token_, address recipient_, address manager_) {
        TOKEN = token_;
        RECIPIENT = recipient_;
        MANAGER = manager_;
        QUOTE = address(0);
    }

    receive() external payable {}

    function setMode(uint8 m) external {
        mode = m;
    }

    function sync() external {}

    function claimableNow(address recipient, address asset) external view returns (uint256) {
        if (recipient != RECIPIENT) return 0;
        if (asset == QUOTE) return address(this).balance;
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
        if (asset == QUOTE) {
            amount = address(this).balance;
            if (amount == 0) revert NothingToClaim();
            (bool ok,) = RECIPIENT.call{value: amount}("");
            if (!ok) revert TransferFailed();
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

/// @notice A vault that lies about its immutables (bind tests).
contract LyingVault {
    address public RECIPIENT;
    address public TOKEN;
    address public QUOTE;

    constructor(address r, address t, address q) {
        RECIPIENT = r;
        TOKEN = t;
        QUOTE = q;
    }
}

contract MockWOKB {
    mapping(address => uint256) public balanceOf;

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 a) external {
        balanceOf[msg.sender] -= a;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "withdraw");
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice Uniswap V2 pair, reduced to what the kernel and the tests use: reserves, swap with the K check, sync.
contract MockPair {
    address public immutable token0;
    address public immutable token1;
    uint112 internal r0;
    uint112 internal r1;

    bool public reservesRevert;
    // sync(), tests only: 0 as Uniswap V2, 1 RETURN (not revert) the bytes of Error("UniswapV2: LOCKED"),
    // 2 revert with another string, 3 burn all gas
    uint8 public syncMode;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReservesRevert(bool v) external {
        reservesRevert = v;
    }

    function setSyncMode(uint8 m) external {
        syncMode = m;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        require(!reservesRevert, "reserves");
        return (r0, r1, uint32(block.timestamp));
    }

    function _bal(address t) internal view returns (uint256) {
        (bool ok, bytes memory d) = t.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        require(ok, "bal");
        return abi.decode(d, (uint256));
    }

    uint256 private unlocked = 1;

    /// @dev Uniswap V2's lock: swap and sync cannot be entered while another call into the pair is running.
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function sync() public {
        uint8 m = syncMode;
        if (m == 1) {
            bytes memory d = abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKED");
            assembly {
                return(add(d, 0x20), mload(d))
            }
        }
        if (m == 2) revert("UniswapV2: K");
        if (m == 3) {
            while (true) {}
        }
        _sync();
    }

    function _sync() internal lock {
        r0 = uint112(_bal(token0));
        r1 = uint112(_bal(token1));
    }

    function swap(uint256 out0, uint256 out1, address to, bytes calldata data) external lock {
        require(out0 > 0 || out1 > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        require(out0 < r0 && out1 < r1, "UniswapV2: INSUFFICIENT_LIQUIDITY");
        if (out0 > 0) _send(token0, to, out0);
        if (out1 > 0) _send(token1, to, out1);
        // flash-swap callback, as in Uniswap V2: runs while the pair is locked
        if (data.length > 0) {
            (bool okCb,) = to.call(
                abi.encodeWithSignature("uniswapV2Call(address,uint256,uint256,bytes)", msg.sender, out0, out1, data)
            );
            require(okCb, "callback");
        }
        uint256 b0 = _bal(token0);
        uint256 b1 = _bal(token1);
        uint256 in0 = b0 > r0 - out0 ? b0 - (r0 - out0) : 0;
        uint256 in1 = b1 > r1 - out1 ? b1 - (r1 - out1) : 0;
        require(in0 > 0 || in1 > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        require((b0 * 1000 - in0 * 3) * (b1 * 1000 - in1 * 3) >= uint256(r0) * r1 * 1_000_000, "UniswapV2: K");
        r0 = uint112(b0);
        r1 = uint112(b1);
    }

    function _send(address t, address to, uint256 a) internal {
        (bool ok,) = t.call(abi.encodeWithSignature("transfer(address,uint256)", to, a));
        require(ok, "send");
    }
}

/// @dev Sends its whole balance to `to` without calling it (a contract cannot refuse this).
contract ForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @notice Uniswap V2 Router02, reduced to the two fee-on-transfer variants.
contract MockRouter is GasBurner {
    address public immutable WETH;
    address public immutable manager;

    // failure switches (tests only): 0 normal, 1 revert, 2 burn all gas, 3 revert with `revertData`
    uint8 public mode;
    bytes public revertData;
    // native value forced back into the caller during a swap (a router that does not spend all it was sent)
    uint256 public refundWei;

    constructor(address wokb, address manager_) {
        WETH = wokb;
        manager = manager_;
    }

    receive() external payable {}

    function setMode(uint8 m) external {
        mode = m;
    }

    /// @dev Makes every swap revert with exactly these bytes.
    function setRevertData(bytes calldata d) external {
        revertData = d;
        mode = 3;
    }

    function setRefundWei(uint256 w) external {
        refundWei = w;
    }

    function _pair(address token) internal view returns (MockPair) {
        return MockPair(MockManager(payable(manager)).pairOf(token));
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 f = amountIn * 997;
        return (f * rOut) / (rIn * 1000 + f);
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable {
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
        require(path.length == 2 && path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        MockPair p = _pair(path[1]);
        require(address(p) != address(0), "no pair");
        uint256 value = msg.value;
        if (refundWei != 0 && refundWei < value) {
            value -= refundWei;
            new ForceSend{value: refundWei}(payable(msg.sender));
        }
        IMockWOKB(WETH).deposit{value: value}();
        IMockWOKB(WETH).transfer(address(p), value);
        uint256 before = MockToken(path[1]).balanceOf(to);
        (uint112 a, uint112 b,) = p.getReserves();
        bool wokbIs0 = p.token0() == WETH;
        (uint256 rIn, uint256 rOut) = wokbIs0 ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 amountInput = IMockWOKB(WETH).balanceOf(address(p)) - rIn;
        uint256 out = _out(amountInput, rIn, rOut);
        if (wokbIs0) p.swap(0, out, to, "");
        else p.swap(out, 0, to, "");
        require(
            MockToken(path[1]).balanceOf(to) - before >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(path.length == 2 && path[1] == WETH, "UniswapV2Router: INVALID_PATH");
        MockPair p = _pair(path[0]);
        MockToken(path[0]).transferFrom(msg.sender, address(p), amountIn);
        (uint112 a, uint112 b,) = p.getReserves();
        bool wokbIs0 = p.token0() == WETH;
        (uint256 rIn, uint256 rOut) = wokbIs0 ? (uint256(b), uint256(a)) : (uint256(a), uint256(b));
        uint256 amountInput = MockToken(path[0]).balanceOf(address(p)) - rIn;
        uint256 out = _out(amountInput, rIn, rOut);
        if (wokbIs0) p.swap(out, 0, address(this), "");
        else p.swap(0, out, address(this), "");
        require(out >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        IMockWOKB(WETH).withdraw(out);
        (bool ok,) = to.call{value: out}("");
        require(ok, "UniswapV2Router: ETH_TRANSFER_FAILED");
    }
}

/// @notice IgnixManager, reduced to what a kernel and traders use, with the real curve arithmetic.
contract MockManager is GasBurner {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    address internal constant SAFE_SINK = 0x000000000000000000000000000000000000dEaD;

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

    mapping(address => Token) internal _t;
    mapping(address => address) internal _vaultOf;
    mapping(address => address) internal _pairOf;
    mapping(uint256 => uint64) public pausedUntil;
    mapping(address => uint64) public founderEndsAt;
    mapping(address => uint256) public platformAccrued;
    address public immutable WRAPPED_NATIVE;

    // failure switches (tests only)
    uint8 public tokensMode; // 0 normal, 1 revert, 2 short (480 bytes), 3 long (544 bytes), 4 absurd values, 5 burn gas
    bool public pairOfReverts;
    bool public snipeReverts;
    // 0 normal, 1 revert, 2 burn all gas, 3 deliver fewer tokens than quoted (Slippage), 4 revert with `buyRevertData`
    uint8 public buyMode;
    bytes public buyRevertData;
    address public reenterTarget; // if set, buyTo calls it back (reentrancy tests)
    bytes public reenterData;
    uint256 public refundWei; // native value sent back to the buy recipient after a buy (refund path tests)

    error Slippage();
    error SoldOut();
    error BadValue();
    error FounderOnly();
    error Paused();
    error Graduated_();
    error NotFound();
    error TransferFailed();
    error ReentrancyGuardReentrantCall();

    /// @dev The real Manager's buy, buyTo and sell share one reentrancy lock (OpenZeppelin's guard).
    bool internal _entered;

    modifier nonReentrant() {
        if (_entered) revert ReentrancyGuardReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    event Trade(address indexed token, address indexed trader, bool isBuy, uint256 gross, uint256 out, uint256 tax);
    event GraduatedV2(address indexed token, address indexed pair, uint128 quoteInjected, uint128 tokenInjected);

    constructor(address wokb) {
        WRAPPED_NATIVE = wokb;
    }

    receive() external payable {}

    // ------------------------------------------------------------------ test controls

    function setTokensMode(uint8 m) external {
        tokensMode = m;
    }

    function setPairOfReverts(bool v) external {
        pairOfReverts = v;
    }

    function setSnipeReverts(bool v) external {
        snipeReverts = v;
    }

    function setBuyMode(uint8 m) external {
        buyMode = m;
    }

    /// @dev Makes every buy revert with exactly these bytes.
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

    function setRefundWei(uint256 w) external {
        refundWei = w;
    }

    function setCreator(address token, address creator) external {
        _t[token].creator = creator;
    }

    /// @dev IGNIX fixes both at 100 bps today; the getter reports them per token and the kernel reads them.
    function setFees(address token, uint16 buyFeeBps, uint16 sellFeeBps) external {
        _t[token].buyFeeBps = buyFeeBps;
        _t[token].sellFeeBps = sellFeeBps;
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
        vault = address(new MockVault(token, recipient, address(this)));
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
        t.snipeStartBps = snipeStartBps;
        t.snipeMins = snipeMins;
        t.createdAt = uint64(block.timestamp);
        t.vQuote = uint128(e);
        t.vToken = uint128(tt);
        t.sellable = uint128(c);
        t.reserve = uint128(d);
    }

    /// @dev Registers a vault that was built elsewhere (bind tests with a lying vault).
    function setVault(address token, address vault) external {
        _vaultOf[token] = vault;
    }

    // ------------------------------------------------------------------ views

    function vaultOf(address token) external view returns (address) {
        return _vaultOf[token];
    }

    function pairOf(address token) external view returns (address) {
        require(!pairOfReverts, "pairOf");
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
        if (tokensMode == 4) vq = type(uint256).max; // an absurd read
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
        if (msg.value != amountIn) revert BadValue();

        Token storage t = _t[token];
        if (t.creator == address(0)) revert NotFound();
        if (_pairOf[token] != address(0)) revert Graduated_();

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
        if (buyMode == 3) out -= 1; // a Manager whose formula differs from the kernel's quote
        if (out < minOut) revert Slippage();
        if (out == 0) revert SoldOut();

        uint256 tax = (amountIn * t.taxBuyBps) / BPS;
        uint256 pFee = amountIn - net - tax;
        t.vQuote += uint128(net);
        t.vToken -= uint128(out);
        t.sold += uint128(out);
        t.collected += uint128(net);
        platformAccrued[address(0)] += pFee;

        _safeTransfer(token, recipient, out);
        if (tax > 0) _pay(_vaultOf[token], tax);
        emit Trade(token, recipient, true, amountIn, out, tax);

        if (t.sold == t.sellable) _graduate(token);
        if (refund > 0) _pay(recipient, refund);
        if (refundWei > 0) _pay(recipient, refundWei);
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
        platformAccrued[address(0)] += pFee;
        _pay(msg.sender, net);
        if (jFee > 0) _pay(_vaultOf[token], jFee);
        emit Trade(token, msg.sender, false, gross, tokenIn, jFee);
    }

    /// @dev SafeERC20.safeTransfer, as the real Manager uses: a `false` return reverts.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        require(MockToken(token).transfer(to, amount), "SafeERC20FailedOperation");
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev V2Graduation.inject without the donation handling: wrap the raise, fund the pair, unlock the token.
    function _graduate(address token) internal {
        Token storage t = _t[token];
        MockPair p = new MockPair(token, WRAPPED_NATIVE);
        _pairOf[token] = address(p);
        MockToken(token).unlock();
        IMockWOKB(WRAPPED_NATIVE).deposit{value: t.collected}();
        _safeTransfer(token, address(p), t.reserve);
        IMockWOKB(WRAPPED_NATIVE).transfer(address(p), t.collected);
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
