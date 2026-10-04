// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice `IgnixManager.tokens(token)`: 16 static words, 512 bytes. Mirrors `CurveToken` in the verified
///         CurveTrading.sol; the field order is the Manager's storage layout (6 packed slots).
struct CurveToken {
    address creator; //       word 0   slot 0, bytes 0..19
    uint16 buyFeeBps; //      word 1   slot 0, bytes 20..21
    uint16 sellFeeBps; //     word 2   slot 0, bytes 22..23
    uint16 taxBuyBps; //      word 3   slot 0, bytes 24..25
    uint16 taxSellBps; //     word 4   slot 0, bytes 26..27
    address quote; //         word 5   slot 1, bytes 0..19   (address(0) = native OKB)
    uint16 snipeStartBps; //  word 6   slot 1, bytes 20..21
    uint16 snipeMins; //      word 7   slot 1, bytes 22..23
    uint64 createdAt; //      word 8   slot 1, bytes 24..31
    uint128 vQuote; //        word 9   slot 2, low half
    uint128 vToken; //        word 10  slot 2, high half
    uint128 sold; //          word 11  slot 3, low half
    uint128 collected; //     word 12  slot 3, high half
    uint128 sellable; //      word 13  slot 4, low half
    uint128 reserve; //       word 14  slot 4, high half
    bytes32 poolId; //        word 15  slot 5
}

/// @title IGNIX launch manager, as seen by a contract that is a Directed-vault recipient ("kernel").
/// @notice Everything here is confirmed against the verified implementation
///         0x126f5088cf077944933f5741fb71a6cc40f2942a (vendored in contracts/vendor/ignix-xlayer) AND against
///         live state on X Layer (chain 196) by the fork tests in contracts/probes/test (Q3, Q4, Q5, Q8).
///
///         Proxy:  0x96b51c57e5346d0c0198899243cf851d1e23c309 (UUPS, owner = 1-of-2 Safe 0x9147...E76a)
///
/// @dev Storage slots of the proxy (the inherited OZ v5 upgradeable bases use ERC-7201 namespaces, so the
///      Manager's own variables start at slot 0). Read with `cast storage` at block 72369000:
///        slot 5  signer            slot 8  tokens (mapping)       slot 10 founderRound (mapping)
///        slot 12 vaultOf (mapping) slot 15 pairOf (mapping)       slot 21 pausedUntil (mapping)
///      `tokens[token]` occupies 6 consecutive slots starting at keccak256(abi.encode(token, 8)).
interface IIgnixManager {
    // ───────────────────────────── curve state ─────────────────────────────

    /// @notice Per-token curve state. The getter returns 16 static words = 512 bytes.
    /// @dev Field order is the Manager's storage layout and "remains append-only": a future upgrade may
    ///      return MORE than 512 bytes, never fewer. Decoding with this interface tolerates extra words
    ///      (the ABI decoder only requires returndatasize >= 512).
    ///
    ///      word  field          type     meaning
    ///      0     creator        address  msg.sender of createToken; zero means "not an IGNIX token"
    ///      1     buyFeeBps      uint16   platform curve fee on buys (LaunchLogic forces 100)
    ///      2     sellFeeBps     uint16   platform curve fee on sells (LaunchLogic forces 100)
    ///      3     taxBuyBps      uint16   project tax on buys, 0..1000; paid to vaultOf(token) in QUOTE
    ///      4     taxSellBps     uint16   project tax on sells, 0..1000
    ///      5     quote          address  address(0) = native OKB
    ///      6     snipeStartBps  uint16   0 = anti-snipe disabled, else 2000..9000
    ///      7     snipeMins      uint16   linear decay window, minutes
    ///      8     createdAt      uint64   anti-snipe clock origin (block.timestamp of createToken)
    ///      9     vQuote         uint128  virtual quote reserve
    ///      10    vToken         uint128  virtual token reserve
    ///      11    sold           uint128  tokens sold on the curve
    ///      12    collected      uint128  net quote raised (injected into the LP in full at graduation)
    ///      13    sellable       uint128  curve allocation C = 800,000,000e18
    ///      14    reserve        uint128  DEX allocation D = 200,000,000e18
    ///      15    poolId         bytes32  non-zero = graduated to Uniswap V4 (never for a taxed token)
    ///
    ///      There is NO graduation-target field and NO graduated flag. Graduated means
    ///      `pairOf(token) != address(0)` (V2, every taxed token) or `poolId != 0` (V4, untaxed tokens).
    ///      For a V2 token `sold == sellable` holds from the graduating buy onwards.
    ///
    ///      Declared here as a struct return ON PURPOSE. The ABI encoding of 16 static return values and of
    ///      one static 16-field struct is identical, but solc 0.8.28 without via_ir cannot compile a CALL to
    ///      the flat 16-value form ("Stack too deep ... Variable headStart is 2 slot(s) too deep" in the ABI
    ///      decoder). The struct form compiles with the legacy pipeline.
    function tokens(address token) external view returns (CurveToken memory); // 0xe4860339

    /// @notice The Uniswap V2 pair a taxed token graduated into. Non-zero means graduated.
    function pairOf(address token) external view returns (address); // 0xa7465bdb

    /// @notice The token's tax vault. Non-zero for every token this Manager created.
    function vaultOf(address token) external view returns (address); // 0x0709df45

    /// @notice tokens[token].creator, or zero if this Manager never launched `token`.
    function creatorOf(address token) external view returns (address); // 0xdea5c2e0

    /// @notice Anti-snipe surcharge in bps right now. 0 when disabled or after the window.
    /// @dev    snipeStartBps while block.timestamp <= start, then linear decay to 0 over snipeMins*60 s.
    ///         `start` = max(createdAt, founderRound.endsAt). It only reads the launch config, so it keeps
    ///         answering after graduation. The surcharge goes to the platform, never to the vault.
    function snipeBpsNow(address token) external view returns (uint256); // 0xf91a40b4

    /// @notice Emergency switches: path `kind` is closed while block.timestamp < pausedUntil(kind).
    /// @dev    0 LAUNCH, 1 BUY (buy/buyTo/buyFounder), 2 CURVE_FEE, 3 LP_FEE, 4 SELL, 5 retired,
    ///         6 DIVIDEND (THIS is the one that gates vault.claim / claimFor), 7 LIQUIDITY, 8 V4_SWAP.
    ///         Kinds 4 and 6 are capped at 72 h per call (renewable); the others may be indefinite.
    function pausedUntil(uint256 kind) external view returns (uint64); // 0x54bce65b

    /// @notice Founder round (whitelist-only window). `endsAt == 0` means the token never had one.
    /// @dev    While block.timestamp < endsAt, buy/buyTo revert FounderOnly().
    function founderRound(address token) // 0x47965b55
        external
        view
        returns (bytes32 root, uint64 endsAt, uint128 capTotal, uint128 spentTotal);

    function platformAccrued(address quote) external view returns (uint256);
    function lpTokenId(address token) external view returns (uint256);
    function poolFeeOf(address token) external view returns (uint24);

    // ───────────────────────────── trading ─────────────────────────────

    /// @notice Curve buy; tokens and any overbuy refund go to msg.sender.
    /// @param amountIn must equal msg.value for a native-OKB-quoted token.
    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable;

    /// @notice Curve buy; tokens AND any overbuy refund go to `recipient` (not to msg.sender).
    /// @dev    selector 0x9415aa2a. Reverts BadValue() if recipient is zero, the Manager, or the token's
    ///         future V2 pair. Charges buyFeeBps + taxBuyBps + snipeBpsNow on the gross amount whoever buys:
    ///         the vault's own recipient is NOT exempt, so its buy sends taxBuyBps back to its own vault.
    ///         A buy that reaches the end of the curve is capped, the excess is refunded to `recipient` by a
    ///         native call from the Manager, and the token graduates inside the same transaction.
    function buyTo(address token, uint256 amountIn, uint256 minTokensOut, address recipient) external payable;

    /// @notice Curve sell. Needs an ERC-20 approval of the Manager by msg.sender.
    function sell(address token, uint256 tokenIn, uint256 minQuoteOut) external;

    // ───────────────────────────── configuration ─────────────────────────────

    function owner() external view returns (address);
    function signer() external view returns (address);
    function REGISTRY() external view returns (address);
    function LAUNCH_FACTORY() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function V2_FACTORY() external view returns (address);
    function V2_ROUTER02() external view returns (address);
    function V2_LOCKER() external view returns (address);
    function WRAPPED_NATIVE() external view returns (address);
    function LIQUIDITY_HELPER() external view returns (address);
    function configured() external view returns (bool);
    function configured2() external view returns (bool);

    /// @dev Owner only. Used by the fork tests through vm.prank(owner()).
    function setPaused(uint256 kind, uint64 until) external;

    // ───────────────────────────── launch ─────────────────────────────

    struct CreateParams {
        string name;
        string symbol;
        string metadataURI;
        bytes32 salt;
        address quote; // zero = native OKB
        uint256 graduation; // 85e18 for every native-OKB launch observed
        uint16 buyFeeBps; // must be 100
        uint16 sellFeeBps; // must be 100
        uint16 taxBuyBps; // <= 1000; a V2 (taxed) launch needs taxBuy + taxSell > 0
        uint16 taxSellBps; // <= 1000
        uint16 snipeStartBps; // 0 disables anti-snipe; else 2000..9000
        uint16 snipeMins; // must be > 0 when snipeStartBps != 0
        uint256 listingFee;
        uint256 firstBuy; // 0 allowed; executed inside createToken, exempt from anti-snipe
        uint16 founderBps; // 0 disables the founder round
        uint32 founderSecs;
        bytes32 founderRoot;
    }

    /// @notice selector 0xef44bdf2. Directed launch: templateId = 3, vaultData = abi.encode(address recipient),
    ///         venue = 1 (Uniswap V2), graduationProtectionSecs >= 1 days (8,640,000 on every launch observed).
    /// @dev    msg.value must equal listingFee + firstBuy for a native quote.
    function createToken(
        CreateParams calldata p,
        uint16 templateId,
        bytes calldata vaultData,
        uint64 deadline,
        address factory,
        uint8 venue,
        uint64 graduationProtectionSecs,
        bytes calldata sig
    ) external payable returns (address token);

    // ───────────────────────────── events ─────────────────────────────

    /// @dev `trader` is the RECIPIENT of a buy (so the kernel for a kernel buy), the payer of a sell.
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
    event GraduatedV2(
        address indexed token,
        address indexed pair,
        address vault,
        uint128 quoteInjected,
        uint128 tokenInjected
    );
    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed quote,
        uint256 graduation,
        string metadataURI,
        address vault,
        address tracker,
        uint16 templateId
    );

    // ───────────────────────────── errors (selectors measured on the fork) ─────────────────────────────

    error Slippage(); // 0x7dd37f70  out < minTokensOut
    error SoldOut(); // 0x52df9fe5  out == 0 (in practice only amountIn == 0: 1 wei of OKB already buys tokens)
    error BadValue(); // 0x0bba69fb  msg.value != amountIn, bad buyTo recipient
    error FounderOnly(); // 0x2c353d89  buy/buyTo while a founder round is open
    error Paused(); // 0x9e87fac8  block.timestamp < pausedUntil(kind)
    error Graduated_(); // 0x735c0da7  buy/sell on the curve after graduation
    error NotFound(); // 0xc5723b51  token not launched by this Manager
    error BadSignature(); // 0x5cd5d233
    error SignatureExpired(); // 0x0819bdcd
    error FeeTooHigh(); // 0xcd4e6167  LaunchLogic.validate range checks
    error FreezeTooLong(); // 0x6955d88b  setPaused beyond 72 h on kinds 4 and 6
}

interface IVaultRegistry {
    /// @notice templateId => vault factory. 3 = Directed (0x48509800895d5735fDC93367aE925579eeFF24aE).
    function factoryOf(uint16 id) external view returns (address);
}

/// @dev Pause kinds, mirrored from IGNIX's PauseKind library.
library IgnixPause {
    uint256 internal constant LAUNCH = 0;
    uint256 internal constant BUY = 1;
    uint256 internal constant CURVE_FEE = 2;
    uint256 internal constant LP_FEE = 3;
    uint256 internal constant SELL = 4;
    uint256 internal constant DIVIDEND = 6;
    uint256 internal constant LIQUIDITY = 7;
    uint256 internal constant V4_SWAP = 8;
}

/// @dev Addresses on X Layer mainnet (chain 196), read on-chain at block 72369000.
///      MANAGER, V2_ROUTER02, V2_FACTORY and WOKB are fixed (the last three are pinned inside the verified
///      V2Graduation library). VAULT_REGISTRY, DIRECTED_FACTORY and LAUNCH_FACTORY are pointers the IGNIX
///      owner can rotate for FUTURE launches; read them from the Manager instead of hard-coding them.
library IgnixAddresses {
    address internal constant MANAGER = 0x96B51c57e5346D0C0198899243cf851D1E23C309;
    address internal constant V2_ROUTER02 = 0x182a927119D56008d921126764bF884221b10f59;
    address internal constant V2_FACTORY = 0xDf38F24fE153761634Be942F9d859f3DBA857E95;
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address internal constant V2_LOCKER = 0xeD707fc375C6A27e4330d3d38a939ba55bB2b99A;
    address internal constant LIQUIDITY_HELPER = 0x8916FDAB92f3F5B3e8FB0d22f99c88a28e751ba6;
    address internal constant VAULT_REGISTRY = 0xCE65471A6c6950e17f4B527b20b0aF8a8f905311;
    address internal constant DIRECTED_FACTORY = 0x48509800895d5735fDC93367aE925579eeFF24aE;
    address internal constant LAUNCH_FACTORY = 0x5Fe101CaED11883eE133eb3Ffd013F0CD27Bb9D3;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
}
