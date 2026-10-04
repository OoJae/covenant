// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { CurveToken as Token, CurveTrading, ICurveTradingAbi } from "./libraries/CurveTrading.sol";
import { LaunchLogic } from "./libraries/LaunchLogic.sol";
import { QuoteLib } from "./libraries/QuoteLib.sol";
import { PauseKind } from "./libraries/PauseKind.sol";
import { ILaunchFactory, IIgnixToken } from "./interfaces/IExternal.sol";
// The vault interfaces come from the authoritative definitions under `src/vault/` and are
// deliberately not re-declared in IExternal: an interface costs no bytecode, while a
// signature that drifts between two copies is a runtime failure the compiler cannot catch
// (see the note in IExternal).
import { IVaultRegistry } from "../vault/interfaces/IVaultRegistry.sol";
import { IVaultFactory } from "../vault/interfaces/IVaultFactory.sol";
import { IVault } from "../vault/interfaces/IVault.sol";
import { IPositionManager, IPermit2, IPoolGuard } from "./interfaces/IExternal.sol";
import { V2Graduation } from "./libraries/V2Graduation.sol";

/// @title IGNIX launch manager
/// @notice Three jobs: create a token, run its bonding-curve market, and graduate it to
///         Uniswap V4 automatically once the curve sells out.
///
/// Design trade-offs (docs/21 §2):
///   - Curve parameters are fixed by construction (80% sold on the curve, 20% DEX
///     reserve). Neither the platform nor the creator can set them by hand, so anyone
///     can recompute them.
///   - Graduation rides inside the buy that sells the curve out, which costs that buyer
///     under a cent and removes any window between "sold out" and "listed".
///   - Platform income is always accrued for later pull, never pushed: an owner that
///     rejects an incoming transfer would otherwise block every launch.
///
/// **Upgradeable (UUPS).** A contract that holds raised funds and performs the LP
/// injection needs a repair path; without one, a defect could only be answered by
/// abandoning the deployment and orphaning every token already launched.
/// `_authorizeUpgrade` is `onlyOwner`.
///
/// WARNING: **the storage layout is part of the upgrade contract.** The variables below
/// may not be reordered, inserted into, or widened. New fields may only be appended after
/// all existing ones, and the slot packing inside `Token` must be respected (see its
/// comment).
contract IgnixManager is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    ICurveTradingAbi
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using QuoteLib for address;

    // ── Platform invariants ──────────────────────────────────────
    uint256 private constant BPS = 10_000;
    /// A static V4 LP fee is denominated in millionths. Exactly 1_000_000 would consume the
    /// entire input and is rejected by the buyback path, so every configured value must be lower.
    uint24 private constant POOL_FEE_DENOMINATOR = 1_000_000;
    /// Ceiling on how long the paths that move users' own money may be frozen in one go.
    /// Long enough to write, review and ship a fix behind a multisig; short enough that funds
    /// come back on their own if nobody is left to unfreeze them. Renewable by the owner, so it
    /// bounds neglect rather than malice — see `PauseKind`.
    uint64 private constant MAX_USER_FREEZE = 72 hours;

    /// Graduation venue, signed by the platform and fixed for the life of the token.
    /// **The two are mutually exclusive with the tax**, enforced in `createToken`: V4 means a
    /// clean ERC20 with no tax at all, V2 means a fee-on-transfer token that must charge one.
    /// The reason is structural rather than a policy choice — a V2 pair calls nothing back, so
    /// the only place a tax can be charged is inside the token's own transfer (docs/34 §1.2).
    uint8 private constant VENUE_V2 = 1;

    // ── External dependencies (Uniswap V4 on X Layer) ────────────
    // Stored rather than immutable: `immutable` bakes the values into the **implementation**
    // bytecode, so every upgrade must re-supply the exact same constructor arguments. Miss
    // one and a dependency address is silently swapped out — a divergence between deployed
    // bytecode and source that is very hard to notice. These are only read at graduation,
    // so a few extra SLOADs buy out a whole class of upgrade accident.
    IPoolManager public POOL_MANAGER;
    IPositionManager public POSITION_MANAGER;
    IPermit2 public PERMIT2;
    /// Whitelisted shelf of vault templates. At launch, the factory registered for the
    /// requested templateId is looked up here and asked to build the vault
    IVaultRegistry public REGISTRY;
    /// Default V4 LP fee for newly created tokens, in hundredths of a bip (10000 = 1%).
    /// `setPoolFee` changes this default, while each token snapshots the current value at
    /// creation so an existing launch cannot have its promised pool fee rewritten later.
    /// Collected LP fees are split 50/50 by `IgnixLpLocker`.
    uint24 public POOL_FEE;
    int24 public TICK_SPACING;

    /// V4 pool guard. **Takes this contract's address as a constructor argument**, so it
    /// can only be created after this contract exists and must be filled in afterwards —
    /// see configure().
    /// ⚠ 2026-08-17: the `VESTING` slot that used to sit right after POOL_HOOK was removed
    /// together with the airdrop feature. This implementation is therefore **fresh-deploy
    /// only** — upgrading an older proxy onto it would shift every later slot (§9.1).
    address public POOL_HOOK;
    /// Whether configure() has run. No token may be created before it has
    bool public configured;

    /// Platform signer — the admission gate for creating a token
    address public signer;
    /// Platform receivable (listing fee, curve trading fee and anti-snipe tax), **kept per
    /// quote currency**: launches may use different quote tokens, and summing OKB with
    /// USDT0 into one number would cross the books. Post-graduation LP fees do not pass
    /// through here; LP fees are booked inside `IgnixLpLocker` and claimed from there
    mapping(address quote => uint256) public platformAccrued;
    /// Historical creator receivable, kept for storage compatibility and outstanding claims.
    /// New anti-snipe fees accrue entirely to the platform; creator share is zero.
    mapping(address creator => mapping(address quote => uint256)) public creatorAccrued;

    // ── Per-token state ──────────────────────────────────────────
    /// @dev `CurveToken` is declared in CurveTrading so the linked library can receive this
    ///      storage pointer without copying it. Its field order is this proxy's layout and the
    ///      public getter ABI; it remains append-only.
    mapping(address => Token) public tokens;
    /// The V4 position NFT minted at graduation. It is minted straight to `LP_LOCKER`,
    /// which has no entry point that transfers an NFT out — that is the permanent lock.
    /// Nothing on-chain reads this mapping; it exists for the frontend, indexers, and
    /// whoever calls `IgnixLpLocker.collect`
    mapping(address => uint256) public lpTokenId;

    // ── Founder round ────────────────────────────────────────────
    /// @notice A window in which only whitelisted addresses may buy.
    ///
    /// **This contract knows nothing about where the list comes from, and should not.**
    /// It sees only a Merkle root; who qualifies and how each cap was derived is entirely
    /// the platform's policy at signing time. Switching to another source (creator-supplied
    /// lists, say) needs no change here.
    ///
    /// Kept in its own mapping instead of as fields on `Token`: that struct carries a hard
    /// "field order is the storage layout" constraint, and touching it would also change the
    /// return signature of `tokens()`, breaking the ABI and every frontend decoder.
    struct FounderRound {
        bytes32 root; // leaf = keccak256(bytes.concat(keccak256(abi.encode(token, account, cap))))
        uint64 endsAt; // zero means no founder round
        uint128 capTotal; // cap for the whole round, in gross quote
        uint128 spentTotal; // spent so far this round (gross)
    }
    mapping(address token => FounderRound) public founderRound;
    /// Gross spent per whitelist entry. Keyed by the leaf, which already carries both token
    /// and cap, so entries are naturally isolated across tokens and allowances
    mapping(bytes32 leaf => uint128) public founderSpent;

    /**
     * Where a token's tax goes. Created **unconditionally** at launch, so on this Manager
     * it is non-zero for every token that exists; zero only means the token does not.
     * Tokens whose template pays no dividends go through it too (the tax is then credited
     * entirely to the creator), which keeps the tax ledger the same shape for every token
     * so indexers and frontends handle exactly one path.
     *
     * Only this mapping is stored. The tracker address is kept by the vault itself and
     * announced in an event for indexers, so the Manager has no reason to hold it: one
     * fewer mapping and one fewer getter, and bytecode is a binding constraint here.
     */
    mapping(address token => address) public vaultOf;
    /**
     * Deployer of the launch token. (Vaults and their trackers are deployed by the
     * template's own factory, not by this one.)
     *
     * **No `new` may appear in the Manager.** Every `new` embeds the full creation code of
     * the deployed contract into the Manager's own bytecode — the token alone accounts for
     * several kilobytes of it — and the Manager has little headroom left under EIP-170.
     */
    ILaunchFactory public LAUNCH_FACTORY;

    /**
     * Permanent lock-up address for LP positions (a singleton). At graduation the position
     * is minted straight to it and **it is not notified**, because it holds no per-token
     * state. It shares the hook's circular dependency: its constructor
     * needs this contract's address (the LP-fee recipient is read live from the Manager's
     * `owner()`), so it can only be filled in by configure() once this contract exists.
     *
     * WARNING: **append only.** Every new state variable belongs below this line. One
     * inserted above shifts the slot of every variable after it, and existing launches
     * become unreadable.
     */
    address public LP_LOCKER;

    // ── V2 venue (docs/34). Appended after LP_LOCKER, per §9.1 ───
    /**
     * The Uniswap V2 pool a token graduated into. **Non-zero means graduated**, exactly as
     * `poolId` does on the V4 side, and the two are never both set.
     *
     * Deliberately a second mapping rather than a pair address stuffed into `poolId`:
     * everything downstream reads a non-zero `poolId` as "this is a V4 pool" and immediately
     * builds a PoolKey out of it (`apps/web/src/app/launch/page.tsx`), so disguising one as
     * the other would fail in the frontend rather than here.
     */
    mapping(address token => address) public pairOf;
    /// Official Uniswap V2 factory on X Layer. **Read on-chain, not copied from another
    /// chain** — the canonical mainnet addresses are empty bytecode here (docs/34 §1.1).
    address public V2_FACTORY;
    /// Permanent lock-up singleton for V2 LP tokens; the pair mints straight to it.
    address public V2_LOCKER;
    /// WOKB. A V2 pair needs an ERC20 on both sides, so a natively quoted launch wraps its
    /// raise in the graduating transaction.
    address public WRAPPED_NATIVE;
    /// Whether configure2() has run. A V2 launch is refused until it has — otherwise the
    /// token would create fine and only explode at graduation, by which time the curve is
    /// sold out and the token is stuck for good.
    bool public configured2;

    /// Official Router02 used by tax conversion and the liquidity-only exemption channel.
    /// Appended after every pre-existing V2 field to preserve the proxy layout.
    address public V2_ROUTER02;
    /// Singleton whose code surface is limited to proportional V2 liquidity add/remove.
    address public LIQUIDITY_HELPER;

    /**
     * Emergency switches, keyed by `PauseKind`. A path is closed while
     * `block.timestamp < pausedUntil[kind]`; zero means open.
     *
     * One mapping rather than a set of booleans, and a deadline rather than a flag, so that the
     * indefinite switches and the capped ones share a single representation: an indefinite
     * pause is simply `type(uint64).max`. Peripheral contracts (both lockers, the
     * dividend trackers, the liquidity helper and the restricted V4 router) read
     * `pausedUntil()` directly — see `PauseKind` for why the state is centralised here rather
     * than duplicated in each of them.
     *
     * Appended after LIQUIDITY_HELPER, per §9.1.
     */
    mapping(uint256 kind => uint64 until) public pausedUntil;

    /// Encoded as fee + 1 so a genuine zero-fee pool remains distinguishable from an unset slot.
    /// The legacy value covers tokens created before this mapping existed. On an upgraded proxy,
    /// the first `setPoolFee` snapshots the old global value before replacing it.
    uint24 private _legacyPoolFeePlusOne;
    mapping(address token => uint24 feePlusOne) private _poolFeePlusOne;

    /// One-time authorizations for adapter-triggered curve sells. Appended after every
    /// pre-existing field to preserve the proxy storage layout.
    mapping(address payer => uint256 nonce) public sellNonces;

    /// Aggregator contracts allowed to trigger signature-free curve sells: `sellFromOrigin`
    /// for EOA payers, `sellFromAdapter` for smart-account ones. **One list, one kill switch**
    /// — `setSellAdapter(x, false)` closes both entry points for that adapter at once.
    /// Appended after every pre-existing field to preserve the proxy storage layout.
    mapping(address adapter => bool) public sellAdapters;

    // ── Events (the indexer's input contract; field design in docs/21 §3.1) ──
    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed quote,
        uint256 graduation,
        string metadataURI,
        // Vault = tax sink + dividend split. One per token; indexers key vault-side events
        // off this address
        address vault,
        // Share/dividend ledger (zero for a template that pays no dividends). Indexers watch
        // Distributed / Claimed on it
        address tracker,
        // Template id (0 = system vault, 1 = stock, ...). vaultData is not emitted; it is
        // stored off-chain from the signing request
        uint16 templateId
    );
    event Graduated(
        address indexed token,
        bytes32 indexed poolId,
        uint256 lpTokenId,
        address vault,
        uint128 quoteInjected,
        uint128 tokenInjected
    );
    /// @notice The V2 counterpart of `Graduated`. **A separate event, not a widened one**:
    ///         indexers join V4 swaps on `poolId`, and a V2 pool has none — reusing the same
    ///         event with a zero poolId would make every existing consumer treat a V2 launch
    ///         as an un-graduated one. There is no `lpTokenId` either: V2 liquidity is a
    ///         fungible ERC20 held by `V2_LOCKER`, not a position NFT.
    event GraduatedV2(
        address indexed token,
        address indexed pair,
        address vault,
        uint128 quoteInjected,
        uint128 tokenInjected
    );
    event PlatformFeesClaimed(address indexed quote, uint256 amount);
    event CreatorFeesClaimed(address indexed creator, address indexed quote, uint256 amount);
    event FounderRoundOpened(address indexed token, bytes32 root, uint64 endsAt, uint128 capTotal);
    event FounderBuy(
        address indexed token, address indexed buyer, uint128 amountIn, uint128 spentTotal
    );
    /// @notice Restricted curve-phase settlement for project-token dividends.
    event CurveDividendTransferred(
        address indexed token, address indexed from, address indexed recipient, uint256 amount
    );
    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event PoolFeeChanged(uint24 oldFee, uint24 newFee);
    event LaunchFactoryChanged(address indexed oldFactory, address indexed newFactory);
    /// Emitted on every change, including a release (`until` = 0) and a renewal. Indexed by
    /// kind so a monitor can watch one path; the absolute deadline is emitted rather than a
    /// duration so an observer never has to know when the transaction landed.
    event PauseSet(uint256 indexed kind, uint64 until);
    event SellAuthorizationsCancelled(address indexed payer, uint256 newNonce);
    event SellAdapterSet(address indexed adapter, bool allowed);
    /// @notice A whitelisted adapter settled a curve sell on `payer`'s behalf.
    /// @dev The curve's own `Trade` event cannot stand in for this: all four sell entry points
    ///      emit an identical one carrying only `(token, payer)`, so nothing on chain says which
    ///      path a sale took or which adapter drove it. This path's payer authorisation lives
    ///      off chain, which makes observability its only compensating control — see docs/64 §8.
    event AdapterSell(
        address indexed adapter, address indexed payer, address indexed token, uint256 tokenIn
    );

    error BadSignature();
    /// The signature carried an expiry and it has passed
    error SignatureExpired();
    /// `sellFromOrigin` caller is not on the `sellAdapters` whitelist
    error NotSellAdapter();
    /// `sellFromOrigin` payer must equal the transaction originator
    error PayerNotOrigin();
    /// The template factory moved after the platform signed. See the note in `createToken`
    error FactoryChanged();
    error NotFound();
    error Graduated_();
    error FeeTooHigh();
    error NothingToClaim();
    error BadValue();
    error NotConfigured();
    error AlreadyConfigured();
    error FounderOnly();
    error FounderEnded();
    error NotWhitelisted();
    error OverPersonalCap();
    error OverRoundCap();
    error OnlyDividendSettlement();
    error RenounceDisabled();
    error ZeroAddress();
    error Paused();
    error BadPauseKind();
    error FreezeTooLong();
    /// @dev Kept in the Manager ABI although the reverting implementations now live in linked
    ///      logic libraries.
    error InvalidPrice();
    error BadGraduation();
    error ECDSAInvalidSignature();
    error ECDSAInvalidSignatureLength(uint256 length);
    error ECDSAInvalidSignatureS(bytes32 s);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address poolManager,
        address positionManager,
        address permit2,
        address registry,
        address launchFactory,
        uint24 poolFee,
        int24 tickSpacing,
        address signer_
    ) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        POOL_MANAGER = IPoolManager(poolManager);
        POSITION_MANAGER = IPositionManager(positionManager);
        PERMIT2 = IPermit2(permit2);
        REGISTRY = IVaultRegistry(registry);
        LAUNCH_FACTORY = ILaunchFactory(launchFactory);
        if (poolFee >= POOL_FEE_DENOMINATOR) revert FeeTooHigh();
        POOL_FEE = poolFee;
        TICK_SPACING = tickSpacing;
        signer = signer_;
    }

    /// @notice Fill in the hook and LP locker. **Callable once.**
    /// @dev Each of these takes this contract's address as a constructor argument, so none
    ///      of them can exist before this contract (the proxy) does — while this contract in
    ///      turn has to know both. Filling them in once, afterwards, breaks the cycle
    ///      and means the deployment script never has to predict an address.
    /// @param hook V4 pool guard; the low 14 bits of its address must match its permission flags.
    /// @param lpLocker permanent lock-up singleton for LP positions — graduation mints the
    ///        position to it
    function configure(address hook, address lpLocker) external onlyOwner {
        if (configured) revert AlreadyConfigured();
        LaunchLogic.validateV4Configuration(hook, lpLocker);
        configured = true;
        POOL_HOOK = hook;
        LP_LOCKER = lpLocker;
    }

    /// @notice Fill in the Uniswap V2 dependencies. **Callable once**, and required before any
    ///         taxed (V2) token may be created.
    /// @dev A second `configure` rather than an extension of the first: `configured` has
    ///      already latched on both live deployments, so reusing it is not an option, and the
    ///      three addresses here are needed by a path that did not exist when they launched.
    ///
    ///      The latch is set only after every dependency proves its semantics. In particular,
    ///      the locker must point back to this proxy, and the production chain pins its canonical
    ///      factory and wrapped-native addresses.
    function configure2(
        address v2Factory,
        address v2Router02,
        address v2Locker,
        address wrappedNative,
        address liquidityHelper
    ) external onlyOwner {
        if (configured2) revert AlreadyConfigured();
        V2Graduation.validateConfiguration(
            v2Factory, v2Router02, v2Locker, wrappedNative, liquidityHelper
        );
        V2_FACTORY = v2Factory;
        V2_ROUTER02 = v2Router02;
        V2_LOCKER = v2Locker;
        WRAPPED_NATIVE = wrappedNative;
        LIQUIDITY_HELPER = liquidityHelper;
        configured2 = true;
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    /// @notice Ownership is the repair and signer-rotation boundary. It may be transferred
    ///         through Ownable2Step, but never discarded permanently.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Relays confirmed pools to one token's append-only dividend exclusion set.
    /// @dev During protection the pool also enters tax/blocking. Afterwards registration only
    ///      removes dividend shares and cannot extend tax. `tokens[token].creator` ensures the
    ///      owner cannot use this Manager as a generic caller for unrelated contracts.
    function addDetectedPools(address token, address[] calldata detectedPools) external onlyOwner {
        _requirePlatformToken(token);
        IIgnixToken(token).addDetectedPools(detectedPools);
    }

    /// @notice Adds or removes a tax exemption for one approved contract integration.
    /// @dev The token rejects pools, EOAs, system endpoints and clean V4 tokens. Keeping those
    ///      checks in the token makes the invariant hold even if this relay changes later.
    function setTaxExempt(address token, address account, bool exempt) external onlyOwner {
        _requirePlatformToken(token);
        IIgnixToken(token).setTaxExempt(account, exempt);
    }

    /// @notice Atomically applies one tax-exemption decision to multiple platform tokens.
    /// @dev Any invalid token or token-level rejection reverts the entire batch.
    function batchSetTaxExempt(address[] calldata tokenList, address account, bool exempt)
        external
        onlyOwner
    {
        uint256 length = tokenList.length;
        if (length == 0) revert BadValue();
        for (uint256 i; i < length; ++i) {
            address token = tokenList[i];
            _requirePlatformToken(token);
            IIgnixToken(token).setTaxExempt(account, exempt);
        }
    }

    function _requirePlatformToken(address token) private view {
        if (tokens[token].creator == address(0)) revert NotFound();
    }

    // ── Creation ─────────────────────────────────────────────────

    struct CreateParams {
        string name;
        string symbol;
        string metadataURI; // event only, never stored
        bytes32 salt; // determines the token address (vanity prefixes are mined on it)
        address quote; // quote token; zero means native OKB
        uint256 graduation; // graduation threshold, in the quote's smallest unit
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint16 taxBuyBps;
        uint16 taxSellBps;
        uint16 snipeStartBps; // zero disables anti-snipe
        uint16 snipeMins;
        uint256 listingFee;
        uint256 firstBuy; // first buy, executed in the creating transaction
        // ── Founder round (optional: all three fields zero, or all three given) ──
        uint16 founderBps; // share of the graduation threshold; 0 disables. Cap
        // MAX_FOUNDER_BPS
        uint32 founderSecs; // window length, in seconds. **uint32, not uint16** —
        // 16 bits tops out at 18 hours while the default is a day, so it would truncate
        bytes32 founderRoot; // Merkle root of the whitelist; how it was built is not this
        // contract's concern
    }

    /// @notice Create a token. The first buy must happen in the same transaction, or anyone
    ///         can take the first segment of the curve in between — the cheapest supply
    ///         that will ever exist.
    /**
     * @param templateId Vault template id (0 = system vault, 1 = stock, ...). Admitted only
     *                   if the Registry knows a factory for it.
     * @param vaultData  Parameters encoded by that template (the system vault's
     *                   dividendBps, the stock vault's stocks[], and so on).
     *                   **The Manager does not interpret them**; they are forwarded
     *                   verbatim to the template's factory (docs/26 §3.3).
     *
     * **Vault parameters are top-level arguments rather than fields on `CreateParams`.**
     * The platform signs both, so admission is exactly as strong as for every other
     * parameter, and the template factory re-checks them on-chain with `validate`.
     */
    /**
     * @param deadline unix seconds after which this signature is dead.
     *        **The platform cannot revoke a signature it has already handed out** — nothing on
     *        chain tracks issued approvals, and adding a revocation list would mean a storage
     *        write per launch. An expiry gives the same protection for free: a request signed
     *        under one set of platform rules cannot be executed under the next one.
     * @param factory the template factory the platform saw when it signed. `factoryOf` is owner
     *        replaceable, so without pinning it here an old signature would execute against
     *        **new factory semantics** — same templateId, different validation and different
     *        vault code. The signer approved one specific implementation, not a slot.
     *
     * `deadline` and `factory` are top-level parameters rather than `CreateParams` fields on
     * purpose: that struct carries dynamic arrays, and every field added to it inflates the ABI
     * coder by roughly 500 bytes of bytecode (CLAUDE.md §9.2). As arguments they cost almost
     * nothing and bind into the digest just as tightly.
     */
    /**
     * @param venue 0 = Uniswap V4, 1 = Uniswap V2. **Signed, and binding for the life of the
     *        token** — there is no migration path between the two.
     *
     *        A top-level argument for the same reason as `deadline` and `factory`: adding a
     *        field to `CreateParams` inflates the ABI coder by roughly 500 bytes, and that
     *        struct carries dynamic arrays (CLAUDE.md §9.2).
     *
     *        The venue and the tax rates are checked against each other here rather than left
     *        to the signing service. On V4 the tax would have nowhere to be charged (the pool
     *        would simply never collect one) and on V2 an untaxed token would carry every
     *        fee-on-transfer downside for no benefit — both are silent misconfigurations
     *        rather than reverts, which is exactly the kind of thing that belongs on-chain.
     */
    function createToken(
        CreateParams calldata p,
        uint16 templateId,
        bytes calldata vaultData,
        uint64 deadline,
        address factory,
        uint8 venue,
        uint64 graduationProtectionSecs,
        bytes calldata sig
    ) external payable nonReentrant returns (address token) {
        _gate(PauseKind.LAUNCH);
        if (!configured || !configured2) revert NotConfigured();
        if (block.timestamp > deadline) revert SignatureExpired();
        LaunchLogic.validate(
            LaunchLogic.Validation({
                graduation: p.graduation,
                firstBuy: p.firstBuy,
                buyFeeBps: p.buyFeeBps,
                sellFeeBps: p.sellFeeBps,
                taxBuyBps: p.taxBuyBps,
                taxSellBps: p.taxSellBps,
                snipeStartBps: p.snipeStartBps,
                snipeMins: p.snipeMins,
                founderBps: p.founderBps,
                founderSecs: p.founderSecs,
                founderRoot: p.founderRoot,
                venue: venue,
                protectionSecs: graduationProtectionSecs
            })
        );

        // Read the fee **before** any external call and use this local everywhere below.
        // Re-reading the global after the factory and token deployments would let the value
        // move underneath a launch that already passed admission (audit M-01).
        uint24 selectedPoolFee = POOL_FEE;
        // Same snapshot discipline for the launch factory (docs/56 §5.3): the digest, the
        // deployment and the off-chain CREATE2 prediction must all see one value. A rotation
        // landing between signature issuance and confirmation would otherwise deploy the
        // token at an address other than the predicted one — the founder-round Merkle leaves
        // carry that prediction, so the launch would succeed with its founder round
        // permanently unusable. Binding the snapshot makes the race fail closed instead.
        ILaunchFactory selectedLaunchFactory = LAUNCH_FACTORY;

        // Admission: the platform signs every parameter, so flipping any bit fails recovery.
        //
        // `selectedPoolFee` is in the digest even though it is not calldata: it is a mutable
        // global that `setPoolFee` can change at any moment, and it is snapshotted per token
        // for the life of the launch with no migration path. Without it, an owner fee change
        // landing between signature issuance and confirmation would silently give the launch a
        // permanent LP fee other than the one that was approved, and the create would not
        // revert. Binding it makes that race fail closed: the on-chain digest stops matching
        // and the stale signature is rejected. It costs no calldata — the signing service
        // reads the same value from the chain.
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    msg.sender,
                    p,
                    templateId,
                    vaultData,
                    deadline,
                    factory,
                    venue,
                    graduationProtectionSecs,
                    selectedPoolFee,
                    address(selectedLaunchFactory)
                )
            )
        );
        if (LaunchLogic.recoverSigner(digest, sig) != signer) revert BadSignature();

        // Collect the quote: native through msg.value, ERC20 through transferFrom
        uint256 need = p.listingFee + p.firstBuy;
        uint256 listingFee = p.listingFee;
        if (p.quote == address(0)) {
            if (msg.value != need) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            if (need > 0) need = p.quote.pullExact(msg.sender, need);
            // **Cap the listing fee at what actually arrived.** `pullExact` returns the
            // amount truly received (less than requested if the quote token charges on
            // transfer). Booking the requested amount instead would push `platformAccrued`
            // above the balance actually held, and the shortfall would be covered by **other
            // tokens' `collected` in the same quote** — once the platform withdraws, those
            // tokens revert on their graduation LP injection for insufficient balance, with
            // their curve already sold out and the token stuck forever (audit M-3, docs/31).
            //
            // Unreachable today (the signing service restricts quote to OKB / USD₮0), but
            // `QuoteLib.pullExact` exists precisely because USD₮0 is a LayerZero OFT and could
            // in principle be upgraded to charge a fee — having written it and then ignoring
            // its return value would leave the defence half-built.
            if (listingFee > need) listingFee = need;
        }

        token = selectedLaunchFactory.deployToken(p.name, p.symbol, address(this), p.salt);
        address protectionRouter = IPoolGuard(POOL_HOOK).PROTECTION_ROUTER();
        IIgnixToken(token)
            .initProtection(
                graduationProtectionSecs,
                address(POOL_MANAGER),
                POOL_HOOK,
                protectionRouter,
                LP_LOCKER,
                p.quote == address(0) ? WRAPPED_NATIVE : p.quote
            );

        // The vault is created in the same transaction as the token — **it cannot wait for
        // graduation**. It owns the dividend share ledger, and holders exist from the very
        // first curve buy; a vault built at graduation would have missed every balance
        // change on the curve, leaving all shares at zero, and there is no cheap on-chain
        // way to reconstruct that history. So vaultOf is always non-zero, including for
        // templates that pay no dividends.
        //
        // The platform has already signed (templateId, vaultData); the template factory
        // re-checks them on-chain (whitelist, caps) — two independent gates (docs/26 §11).
        // The factory seeds the vault's own tracker with the exclusions known at launch
        // (Manager / PoolManager / dead / both lockers / liquidity helper). Because tax is
        // pushed, graduation introduces no new address, so nothing has to be sealed or
        // backfilled later.
        // The signed factory has to still be the registered one. Rejecting rather than silently
        // using whichever is current: the vault is immutable once built, so "close enough" here
        // means the launch is permanently wired to code the platform never approved
        if (REGISTRY.factoryOf(templateId) != factory) revert FactoryChanged();
        if (factory == address(0)) revert BadValue();
        if (!IVaultFactory(factory).validate(p.quote, p.graduation, vaultData)) revert BadValue();
        address vault =
            IVaultFactory(factory).newVault(token, p.quote, msg.sender, address(this), vaultData);
        vaultOf[token] = vault;
        // Wire the token's share ledger. A template that pays no dividends returns zero, and
        // the token's _update skips the sync while it is unset
        address tracker = IVault(vault).tracker();
        if (tracker != address(0)) IIgnixToken(token).initTracker(tracker);
        // Turn the token into a fee-on-transfer token, in the same transaction and with the
        // same one-shot discipline as initTracker. **It cannot be a constructor argument**:
        // the vault that receives the tax is deployed from this token's address, three lines
        // above, so it does not exist yet while the token's constructor runs — and putting the
        // rates in the constructor would fork `tokenCreationCode` by rate, which silently
        // moves every CREATE2-predicted address (docs/34 §3.3)
        if (venue == VENUE_V2) {
            IIgnixToken(token)
                .initTaxConfig(vault, p.taxBuyBps, p.taxSellBps, V2_LOCKER, LIQUIDITY_HELPER);
        }
        // No duplicate check is needed: redeploying with the same salt and creation code
        // reverts inside CREATE2 itself, so a non-empty tokens[token] implies the token
        // already exists and deployToken could never have reached this line

        LaunchLogic.InitialCurve memory curve = LaunchLogic.initialCurve(p.graduation);
        Token storage t = tokens[token];
        t.creator = msg.sender;
        t.buyFeeBps = p.buyFeeBps;
        t.sellFeeBps = p.sellFeeBps;
        t.taxBuyBps = p.taxBuyBps;
        t.taxSellBps = p.taxSellBps;
        t.quote = p.quote;
        t.snipeStartBps = p.snipeStartBps;
        t.snipeMins = p.snipeMins;
        t.createdAt = uint64(block.timestamp);
        t.vQuote = curve.vQuote;
        t.vToken = curve.vToken;
        t.sellable = curve.sellable;
        t.reserve = curve.reserve;
        unchecked {
            _poolFeePlusOne[token] = selectedPoolFee + 1;
        }

        if (p.founderBps > 0) {
            uint128 founderCap = SafeCast.toUint128((p.graduation * p.founderBps) / BPS);
            founderRound[token] = FounderRound({
                root: p.founderRoot,
                endsAt: uint64(block.timestamp + p.founderSecs),
                capTotal: founderCap,
                spentTotal: 0
            });
            emit FounderRoundOpened(
                token, p.founderRoot, uint64(block.timestamp + p.founderSecs), founderCap
            );
        }

        platformAccrued[p.quote] += listingFee;
        emit TokenCreated(
            token, msg.sender, p.quote, p.graduation, p.metadataURI, vault, tracker, templateId
        );

        // The first buy is exempt from anti-snipe: it is atomic with creation, so by
        // definition nobody could have got in ahead of it and it cannot be front-running
        if (need > listingFee) _buy(token, need - listingFee, 0, false, msg.sender);
    }

    // ── Curve trading ────────────────────────────────────────────

    /// @param amountIn quote amount to spend. Must equal msg.value when the quote is native
    function buy(address token, uint256 amountIn, uint256 minTokensOut)
        external
        payable
        nonReentrant
    {
        _publicBuy(token, amountIn, minTokensOut, msg.sender);
    }

    /// @notice Buy through an adapter while the Manager sends project tokens directly to the
    ///         final recipient. Quote still comes from the caller, while any overbuy refund
    ///         also goes directly to the recipient so the adapter retains neither asset.
    function buyTo(address token, uint256 amountIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
    {
        if (recipient == address(0) || recipient == address(this)) revert BadValue();
        // Reject the launch's future V2 pair. Curve tokens are transfer-locked, so this is the
        // only path that could seed a token balance there; once permissionlessly `sync`-ed it
        // becomes a reserve that inject()'s ActivePair guard reverts on — stranding graduation.
        // The pair is a CREATE2 address, so this holds before createPair too.
        if (
            recipient
                == V2Graduation.pairFor(V2_FACTORY, token, tokens[token].quote, WRAPPED_NATIVE)
        ) {
            revert BadValue();
        }
        _publicBuy(token, amountIn, minTokensOut, recipient);
    }

    function _publicBuy(address token, uint256 amountIn, uint256 minTokensOut, address recipient)
        private
    {
        // Closed while the founder window is open. **The gate has to live in the contract**:
        // buy has no access modifier, so blocking it in the frontend blocks nothing — anyone
        // can call this directly
        if (block.timestamp < founderRound[token].endsAt) revert FounderOnly();
        _pullAndBuy(token, amountIn, minTokensOut, true, recipient);
    }

    /// @notice Buy during the founder round. Addresses outside the whitelist cannot buy, and
    ///         those inside are bound by two caps.
    /// @param cap   this address's allowance (gross). It is part of the Merkle leaf, so
    ///              altering it by one wei fails the proof
    /// @param proof whitelist proof. Only the root lives on-chain; proofs are computed and
    ///              held by the platform at signing time
    function buyFounder(
        address token,
        uint256 amountIn,
        uint256 minTokensOut,
        uint256 cap,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        FounderRound storage f = founderRound[token];
        if (f.endsAt == 0 || block.timestamp >= f.endsAt) revert FounderEnded();

        bytes32 leaf = founderLeaf(token, msg.sender, cap);
        if (!MerkleProof.verifyCalldata(proof, f.root, leaf)) revert NotWhitelisted();

        // Both caps are enforced on the **gross** amount. Gross is the conservative choice:
        // once fees are taken, the amount actually raised is necessarily below the face
        // share, and "the most I can spend" is what a buyer has in mind anyway
        uint256 spent = founderSpent[leaf];
        if (spent + amountIn > cap) revert OverPersonalCap();
        if (uint256(f.spentTotal) + amountIn > f.capTotal) revert OverRoundCap();

        founderSpent[leaf] = SafeCast.toUint128(spent + amountIn);
        f.spentTotal = SafeCast.toUint128(uint256(f.spentTotal) + amountIn);

        // **The founder round is exempt from the anti-snipe tax** (audit L-1, docs/31).
        // Anti-snipe exists to stop front-running, but `buy` is closed to everyone during this
        // window: the allowlist is the only party that can buy at all, so by definition there
        // is nothing to front-run and the charge protects against nothing. Measured before the
        // exemption: paying 1 OKB put 0.905 into the creator's claimable balance and only 0.09
        // into the raise — the buyer's reward for early access was paying roughly ten times.
        _pullAndBuy(token, amountIn, minTokensOut, false, msg.sender);
        emit FounderBuy(token, msg.sender, SafeCast.toUint128(amountIn), f.spentTotal);
    }

    /// @dev The leaf carries both token and cap, so one address is a distinct entry per token
    ///      and per allowance and a proof cannot be reused elsewhere. The double hash gives
    ///      second-preimage resistance (a leaf can never be mistaken for an inner node)
    function founderLeaf(address token, address account, uint256 cap)
        public
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(token, account, cap))));
    }

    /// @param applySnipe true when called from `buy`; **false from `buyFounder`** — see the
    ///        comment there for why the founder round is exempt
    function _pullAndBuy(
        address token,
        uint256 amountIn,
        uint256 minTokensOut,
        bool applySnipe,
        address recipient
    ) private {
        // Gating the shared path rather than the two entry points: `buy` and `buyFounder` both
        // land here, so neither can be left open by accident.
        _gate(PauseKind.BUY);
        address q = tokens[token].quote;
        if (q == address(0)) {
            if (msg.value != amountIn) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            amountIn = q.pullExact(msg.sender, amountIn);
        }
        _buy(token, amountIn, minTokensOut, applySnipe, recipient);
    }

    /// @notice The anti-snipe tax right now, in bps. Decays linearly from the starting rate
    ///         to zero, and is zero outside the window.
    /// @dev The frontend renders the current surcharge from this; being a view, anyone can
    ///      recompute it
    function snipeBpsNow(address token) public view returns (uint256) {
        Token storage t = tokens[token];
        if (t.snipeStartBps == 0) return 0;
        uint256 win = uint256(t.snipeMins) * 60;
        // During a founder round public `buy` is closed, so consuming the anti-snipe window
        // there would silently remove the protection before the public market even opens.
        uint256 startsAt = t.createdAt;
        uint256 founderEndsAt = founderRound[token].endsAt;
        if (founderEndsAt > startsAt) startsAt = founderEndsAt;
        if (block.timestamp <= startsAt) return t.snipeStartBps;
        uint256 el = block.timestamp - startsAt;
        if (el >= win) return 0;
        return (uint256(t.snipeStartBps) * (win - el)) / win;
    }

    /// @notice Move already-accounted project-token rewards while ordinary transfers remain
    ///         disabled on the bonding curve.
    /// @dev This is not a general transfer bypass. Only the token's immutable vault may fund
    ///      its immutable tracker, and only that tracker may pay a recipient from its own
    ///      inventory. The Manager is the mandatory intermediate endpoint on both transfers.
    function transferCurveDividend(address token, address recipient, uint256 amount)
        external
        nonReentrant
    {
        _live(token);
        if (recipient == address(0) || amount == 0) revert BadValue();

        address vault = vaultOf[token];
        address dividendTracker = IVault(vault).tracker();
        if (msg.sender == vault) {
            if (dividendTracker == address(0) || recipient != dividendTracker) {
                revert OnlyDividendSettlement();
            }
        } else if (msg.sender != dividendTracker || dividendTracker == address(0)) {
            revert OnlyDividendSettlement();
        }

        IERC20 project = IERC20(token);
        project.safeTransferFrom(msg.sender, address(this), amount);
        project.safeTransfer(recipient, amount);
        emit CurveDividendTransferred(token, msg.sender, recipient, amount);
    }

    /// @dev A token that exists and is still on the curve. **Graduation is two flags, not
    ///      one**: `poolId` for V4 and `pairOf` for V2, never both. Checking only the first
    ///      would leave a graduated V2 token tradeable on its own curve forever — with the
    ///      curve's reserve already injected into the pool, so the sells would be paid out of
    ///      other tokens' raises.
    function _live(address token) private view returns (Token storage t) {
        t = tokens[token];
        if (t.creator == address(0)) revert NotFound();
        if (t.poolId != bytes32(0) || pairOf[token] != address(0)) revert Graduated_();
    }

    function _buy(
        address token,
        uint256 quoteIn,
        uint256 minOut,
        bool applySnipe,
        address recipient
    ) private {
        Token storage t = _live(token);
        (uint256 refund, bool soldOut) = CurveTrading.buy(
            t,
            platformAccrued,
            vaultOf,
            token,
            quoteIn,
            minOut,
            applySnipe ? snipeBpsNow(token) : 0,
            recipient
        );

        // Selling out graduates. Riding inside the buy means sold-out and listed happen in
        // one transaction, so there is no interval in which the curve is empty but unlisted
        if (soldOut) _graduate(token);

        if (refund > 0) t.quote.pay(recipient, refund);
    }

    function sell(address token, uint256 tokenIn, uint256 minQuoteOut) external nonReentrant {
        _sell(token, msg.sender, msg.sender, tokenIn, minQuoteOut);
    }

    /// @notice Current EIP-712 domain separator for adapter-authorized sells. Exposed so wallets
    ///         and adapters can verify the exact chain and Manager proxy they are signing for.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return CurveTrading.domainSeparator();
    }

    /// @notice Authoritative type hash for `SellFrom` EIP-712 authorizations.
    function SELL_FROM_TYPEHASH() external pure returns (bytes32) {
        return CurveTrading.sellFromTypehash();
    }

    /// @notice Invalidate every unexecuted sell authorization at the caller's current nonce.
    function cancelSellAuthorizations() external {
        uint256 newNonce = ++sellNonces[msg.sender];
        emit SellAuthorizationsCancelled(msg.sender, newNonce);
    }

    /// @notice Execute one payer-authorized curve sell through an adapter. The project tokens
    ///         move directly from `payer` to the Manager and quote moves directly to
    ///         `recipient`, so the adapter never needs custody of either asset.
    /// @dev The EIP-712 authorization binds the adapter (`msg.sender`), every order field, this
    ///      Manager, the current chain, and the payer's current nonce.
    function sellFrom(
        address token,
        address payer,
        address recipient,
        uint256 tokenIn,
        uint256 minQuoteOut,
        uint256 deadline,
        bytes calldata authorization
    ) external nonReentrant {
        if (
            payer == address(0) || payer == address(this) || recipient == address(0)
                || recipient == address(this)
        ) revert BadValue();
        if (block.timestamp > deadline) revert SignatureExpired();

        uint256 nonce = sellNonces[payer]++;
        if (authorization.length == 0 || !CurveTrading.verifySell(msg.data, nonce)) {
            revert BadSignature();
        }

        _sell(token, payer, recipient, tokenIn, minQuoteOut);
    }

    /// @notice Signature-free counterpart of `sellFrom` for whitelisted aggregator adapters
    ///         (the FourMeme-style integration OKX asked for). The payer is bound to the
    ///         transaction originator, so an adapter can only ever sell the position of the
    ///         EOA that initiated the transaction — never an arbitrary approved payer.
    /// @dev Accepted boundary, decided 2026-08-20 and recorded in contracts/README.md: binding
    ///      to `tx.origin` means any contract the originator transacts with can reach this path
    ///      through a whitelisted adapter and force-sell the originator's approved position, and
    ///      the recipient is adapter-chosen (OKX's integration spec, adopted verbatim by product
    ///      decision) — so such a route can also redirect the proceeds. The remaining controls
    ///      are the caller whitelist itself, the payer binding, and the shared SELL pause;
    ///      de-whitelisting the adapter is the kill switch. Smart-account payers (whose
    ///      tx.origin is the bundler) cannot use this path; `sellFrom` with an ERC-1271
    ///      signature remains theirs.
    function sellFromOrigin(
        address token,
        address payer,
        address recipient,
        uint256 tokenIn,
        uint256 minQuoteOut
    ) external nonReentrant {
        if (!sellAdapters[msg.sender]) revert NotSellAdapter();
        if (payer != tx.origin) revert PayerNotOrigin();
        if (recipient == address(0) || recipient == address(this)) revert BadValue();
        _sell(token, payer, recipient, tokenIn, minQuoteOut);
    }

    /// @notice Signature-free curve sell for a whitelisted adapter, usable by smart accounts.
    ///         `tx.origin` is never read, so an ERC-4337 payer — whose originator is the bundler
    ///         — reaches the curve through the same whitelisted-adapter path as an EOA.
    ///
    /// @dev **The payer is not proven on chain here.** The adapter is trusted to have bound it
    ///      to the real `msg.sender` that entered OKX's DexRouter, which that router enforces
    ///      and its off-chain signature covers (caller, payer, recipient, params, chainId,
    ///      nonce, deadline). Boundary accepted 2026-08-25, recorded in docs/64 §5.2: a
    ///      compromised adapter signing key can sell any payer that has approved this Manager,
    ///      and `setSellAdapter(x, false)` is the response.
    ///
    ///      Enforced here regardless of anything the adapter does:
    ///        1. the caller is on `sellAdapters`, re-checked on every call;
    ///        2. proceeds reach that same caller and nowhere else — there is deliberately **no
    ///           `recipient` parameter**, so no calldata can name a third party. Omitting it
    ///           beats validating a passed-in value: redirection is not rejected, it is
    ///           unrepresentable;
    ///        3. `_sell` applies the shared SELL pause and the live-token check.
    function sellFromAdapter(address token, address payer, uint256 tokenIn, uint256 minQuoteOut)
        external
        nonReentrant
    {
        if (!sellAdapters[msg.sender]) revert NotSellAdapter();
        if (payer == address(0) || payer == address(this)) revert BadValue();
        // Emitted before `_sell` moves any funds: it is an effect, and `_sell` reaches external
        // contracts. A revert downstream rolls this back with everything else.
        emit AdapterSell(msg.sender, payer, token, tokenIn);
        _sell(token, payer, msg.sender, tokenIn, minQuoteOut);
    }

    function _sell(
        address token,
        address payer,
        address recipient,
        uint256 tokenIn,
        uint256 minQuoteOut
    ) private {
        _gate(PauseKind.SELL);
        Token storage t = _live(token);
        CurveTrading.sell(
            t, platformAccrued, vaultOf, token, payer, recipient, tokenIn, minQuoteOut
        );
    }

    // ── Graduation: create the pool and inject, in one transaction ──

    /// @dev **Inject the entire raise**, on either venue. Not a wei goes to the platform or
    ///      the creator: by constraint (4) in docs/20 the LP's opening price is the injected
    ///      amount over D, so whatever is held back is an immediate loss for the last buyers
    ///      on the curve. Platform and creator earn from the listing fee, the curve trading
    ///      fee and post-graduation LP fees — never from the principal raised.
    ///
    ///      The venue is **derived from the tax rates**, which `createToken` has already bound
    ///      to the signed `venue` one-to-one (taxed ⇔ V2). Deriving it costs nothing and adds
    ///      no per-token storage; the binding is what makes it safe, so if that rule is ever
    ///      relaxed this must become a stored field in the same change.
    ///
    ///      **That binding only covers tokens this version created**, which is why this
    ///      implementation may only be deployed fresh, never upgraded onto a Manager still
    ///      holding a taxed V4 token on its curve: such a token would come down the V2 branch
    ///      and call `setPair` on an `IgnixToken` that has no such function, reverting its
    ///      graduation for good with the curve already sold out. docs/25 §V-4 carries the
    ///      pre-upgrade probe.
    function _graduate(address token) private {
        Token storage t = tokens[token];
        if (t.taxBuyBps == 0 && t.taxSellBps == 0) {
            _graduateV4(token);
            return;
        }
        uint128 lpQuote = t.collected;
        uint128 lpToken = t.reserve;
        // A **linked, external** library: this sequence costs 2,687 bytes and the Manager has
        // less headroom than that under EIP-170. `DELEGATECALL` keeps the raise, the storage
        // and `msg.sender` all in this contract, so nothing about the trust model moves with
        // it — see the header of V2Graduation for the full argument and the deployment cost.
        address pair = V2Graduation.inject(
            pairOf,
            token,
            t.quote,
            lpQuote,
            lpToken,
            V2Graduation.Venue(V2_FACTORY, V2_LOCKER, WRAPPED_NATIVE)
        );
        emit GraduatedV2(token, pair, vaultOf[token], lpQuote, lpToken);
    }

    /// @dev Boundaries in docs/21 §2.5.2. All approvals and identifier reads happen before
    ///      initialize. Once an unfunded pool exists, the very next external action is mint;
    ///      otherwise a callback/revert window could leave a pool that can be pushed to any
    ///      price for almost nothing before the principal is injected.
    function _graduateV4(address token) private {
        Token storage t = tokens[token];
        address q = t.quote;

        // V4 requires currency0 < currency1, and which side each lands on is decided by the
        // raw addresses, not by us. **The token address is deliberately left unconstrained**
        // — constraining it would put vanity prefixes at war with "must sort above the
        // quote", so a token starting 0x0000... could never be mined against a USDT0 quote.
        // Record which side the quote is on; every direction below follows it
        PoolKey memory key =
            LaunchLogic.poolKey(token, q, poolFeeOf(token), TICK_SPACING, POOL_HOOK);
        // Write poolId first: it doubles as the graduated flag, so it also guards reentrancy
        t.poolId = PoolId.unwrap(key.toId());

        // **Inject the entire raise.** Not a wei goes to the platform or the creator: by
        // constraint (4) in docs/20 the LP's opening price is the injected amount over D, so
        // whatever is held back is an immediate loss for the last buyers on the curve.
        // Platform and creator earn from the listing fee, the curve trading fee and
        // post-graduation LP fees — never from the principal raised
        uint128 lpQuote = t.collected;
        uint128 lpToken = t.reserve;

        // Graduation-side wiring. The vault was built alongside the token (vaultOf is always
        // non-zero) and its share ledger has been recording since the first trade; because
        // tax is pushed, **graduation introduces no new address**, so there is no exclusion
        // list to backfill. Only two steps remain:
        //   1. The LP position is **minted directly to the singleton locker**, which is the
        //      permanent lock-up: it has no entry point that transfers an NFT out. It needs
        //      no notification, because it holds no per-token state and reads everything it
        //      needs at `collect(tokenId)` time.
        //   2. Register the pool on the hook, so it knows which token's settlement gate to
        //      open during the protection window. **No tax is registered** — V4 tokens are
        //      zero-tax by construction (see `createToken`'s venue/tax binding).
        address vault = vaultOf[token];

        // The bytecode-heavy V4 sequence lives in a linked external library. Solidity uses
        // DELEGATECALL here, so token permissions, the native balance and address(this) remain
        // those of the Manager proxy. The graduated flag above is written before this boundary.
        uint256 tokenId = LaunchLogic.injectV4(
            key,
            token,
            q,
            lpQuote,
            lpToken,
            LaunchLogic.V4Venue(POOL_MANAGER, POSITION_MANAGER, PERMIT2, LP_LOCKER)
        );

        lpTokenId[token] = tokenId;
        emit Graduated(token, t.poolId, tokenId, vault, lpQuote, lpToken);
    }

    // ── Claiming ─────────────────────────────────────────────────

    /// @notice Push the platform's accrued balance in one quote to the owner.
    ///         **Permissionless** — anyone may call it. The destination is the on-chain
    ///         owner, so the caller gains nothing and there is no reason to restrict it.
    ///         It also means a temporarily unreachable owner cannot lock the funds up.
    function claimPlatformFees(address quote) external nonReentrant {
        _gate(PauseKind.CURVE_FEE);
        uint256 amt = platformAccrued[quote];
        if (amt == 0) revert NothingToClaim();
        platformAccrued[quote] = 0;
        quote.pay(owner(), amt);
        emit PlatformFeesClaimed(quote, amt);
    }

    /// @notice The creator behind a token, or the zero address if this contract never
    ///         launched it.
    /// @dev Exists for `IgnixLpLocker`, which has to split LP fees between the platform and
    ///      the creator but holds **no per-token state** — it resolves the creator from the
    ///      position's pool key through here. A dedicated getter rather than the public
    ///      `tokens` mapping: that one returns a sixteen-field struct, and the caller would
    ///      decode fifteen fields it has no use for. Also doubles as "is this one of ours",
    ///      the same guard `IgnixBuybackVault` applies at construction.
    function creatorOf(address token) external view returns (address) {
        return tokens[token].creator;
    }

    function claimCreatorFees(address quote) external nonReentrant {
        _gate(PauseKind.CURVE_FEE);
        uint256 amt = creatorAccrued[msg.sender][quote];
        if (amt == 0) revert NothingToClaim();
        creatorAccrued[msg.sender][quote] = 0;
        quote.pay(msg.sender, amt);
        emit CreatorFeesClaimed(msg.sender, quote, amt);
    }

    /// @notice Rotate the admission signer. A zero signer is not exploitable (ECDSA.recover
    ///         reverts on invalid signatures and never yields address(0)) but would silently
    ///         reject every createToken until reset — hence the guard, and the event so
    ///         rotations of the admission gate leave an on-chain trail.
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerChanged(signer, newSigner);
        signer = newSigner;
    }

    /// @notice Whitelist or remove an aggregator contract for signature-free curve sells.
    /// @dev Platform-level trading infrastructure, not a per-token promise, so it is owner-set
    ///      like the pause switches. Only register stable, dedicated integration addresses —
    ///      rotating-venue adapters turn every rotation into a hard revert here.
    function setSellAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        sellAdapters[adapter] = allowed;
        emit SellAdapterSet(adapter, allowed);
    }

    /// @notice Rotates the deployer of future launch tokens. Only new creations are
    ///         affected: every existing token, its address and its Manager-side state are
    ///         facts about the factory that deployed it, not about this pointer.
    /// @dev The factory address is part of the `createToken` digest, so **rotating outside a
    ///      signing pause invalidates every in-flight create signature** — they revert with
    ///      `BadSignature` instead of silently deploying at an unpredicted address. That
    ///      fail-closed property is deliberate (docs/56 §5.3) and is what the no-downtime
    ///      cutover relies on. Expect re-signing after calling this.
    function setLaunchFactory(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        address current = address(LAUNCH_FACTORY);
        if (next == current || next.code.length == 0) revert BadValue();
        emit LaunchFactoryChanged(current, next);
        LAUNCH_FACTORY = ILaunchFactory(next);
    }

    /// @notice Changes the V4 LP fee default for tokens created from this point onward.
    /// @dev Existing launches retain the value snapshotted by `poolFeeOf`. The legacy snapshot
    ///      is populated lazily so upgrading a Manager with pre-existing tokens remains safe.
    ///
    ///      **Invalidates every create signature issued against the previous fee.** The value
    ///      is part of the `createToken` digest, so in-flight launches signed under the old fee
    ///      revert with `BadSignature` rather than silently launching at the new one. Expect
    ///      re-signing after calling this, and prefer changing it during a signing pause.
    function setPoolFee(uint24 newPoolFee) external onlyOwner {
        if (newPoolFee >= POOL_FEE_DENOMINATOR) revert FeeTooHigh();
        if (_legacyPoolFeePlusOne == 0) {
            unchecked {
                _legacyPoolFeePlusOne = POOL_FEE + 1;
            }
        }
        emit PoolFeeChanged(POOL_FEE, newPoolFee);
        POOL_FEE = newPoolFee;
    }

    /// @notice The immutable V4 LP fee selected for one launch.
    function poolFeeOf(address token) public view returns (uint24) {
        uint24 encoded = _poolFeePlusOne[token];
        if (encoded != 0) {
            unchecked {
                return encoded - 1;
            }
        }

        // Pre-feature launches all shared one immutable Manager value. If this implementation
        // was installed by upgrade, the first setter call preserved that value here.
        uint24 legacy = _legacyPoolFeePlusOne;
        if (legacy == 0) return POOL_FEE;
        unchecked {
            return legacy - 1;
        }
    }

    /**
     * @notice Open or close an emergency switch. `until` is an absolute timestamp; a value in
     *         the past (zero is the idiom) reopens the path immediately.
     * @dev Deliberately **not** delegated to a separate hot "pauser" key. A second long-lived
     *      privileged key is itself an attack surface, and the response time it buys is only
     *      worth that on paths this contract cannot otherwise stop — there are none: the
     *      admission signer can be rotated off-chain in seconds, and the keeper role covers
     *      the buyback side.
     *
     *      Paths that move users' own money are capped at MAX_USER_FREEZE. Renewal is allowed,
     *      so this constrains an absent owner rather than a hostile one; see `PauseKind`.
     */
    function setPaused(uint256 kind, uint64 until) external onlyOwner {
        _setPaused(kind, until);
    }

    /// @notice Stops every operation owned by this contract family in one transaction.
    /// @dev Platform-operated paths remain closed until explicitly reopened. User-funds paths
    ///      keep the same 72-hour automatic expiry enforced by `setPaused`.
    function pauseAll() external onlyOwner {
        uint64 userFundsUntil = uint64(block.timestamp + MAX_USER_FREEZE);
        uint64 indefinitely = type(uint64).max;

        for (uint256 kind = PauseKind.LAUNCH; kind <= PauseKind.LAST; kind++) {
            // Identifier 5 is the retired airdrop switch and must remain untouched.
            if (kind == 5) continue;
            _writePause(kind, PauseKind.isUserFunds(kind) ? userFundsUntil : indefinitely);
        }
    }

    function _setPaused(uint256 kind, uint64 until) private {
        if (kind > PauseKind.LAST) revert BadPauseKind();
        // unchecked: both operands are bounded (timestamp by the chain, the other by a
        // compile-time constant), so the overflow check is dead weight on a contract this
        // close to the EIP-170 ceiling
        unchecked {
            if (PauseKind.isUserFunds(kind) && until > block.timestamp + MAX_USER_FREEZE) {
                revert FreezeTooLong();
            }
        }
        _writePause(kind, until);
    }

    function _writePause(uint256 kind, uint64 until) private {
        pausedUntil[kind] = until;
        emit PauseSet(kind, until);
    }

    /// @dev Call sites stay one line; the revert lives here once.
    function _gate(uint256 kind) private view {
        if (block.timestamp < pausedUntil[kind]) revert Paused();
    }

    /// @dev Both the sell path and PositionManager's sweep send funds to this contract
    receive() external payable { }
}
