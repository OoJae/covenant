// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IGNIX "Directed" vault (template 3), one per token, 100% of the trading tax to one RECIPIENT.
/// @notice The vault source is NOT verified on OKLink. This interface was recovered from the runtime
///         bytecode (3,019 bytes, disassembly cached in contracts/probes/vendor-cache/disasm-vault-OB.txt)
///         and every statement below is exercised by a fork test (test/Q2_Claim, Q6_Graduation, Q8_Timing).
///
///         Factory (template 3): 0x48509800895d5735fDC93367aE925579eeFF24aE
///
/// Behaviour, in one place:
///   - The vault keeps NO ledger. "Claimable" is simply the vault's current balance of the asset:
///       claimableNow(RECIPIENT, QUOTE) = balance of the quote (native: address(vault).balance)
///       claimableNow(RECIPIENT, TOKEN) = TOKEN.balanceOf(vault), but 0 while TOKEN.pair() == address(0)
///     Anything sent to the vault (tax, a donation) becomes claimable; plain native transfers are accepted.
///   - claim / claimFor pay the WHOLE balance of one asset to RECIPIENT and return that amount. The return
///     value, claimableNow and the recipient's real balance delta are equal (the vault is taxExempt on its
///     token). There is no on-chain minimum: 1 wei is claimable.
///   - Native OKB is paid with `RECIPIENT.call{value: amount}("")`, forwarding all remaining gas (63/64).
///     The recipient's receive() therefore runs INSIDE claim, with msg.sender == vault. If it reverts or
///     runs out of gas the whole claim reverts TransferFailed() and the money stays in the vault.
///   - The project token is paid with a plain ERC-20 transfer: no callback into the recipient.
///   - Both revert NothingToClaim() when the balance is zero (and claim(TOKEN) always does before
///     graduation). Wrap them in try/catch.
///   - Both revert Paused() while block.timestamp < IgnixManager.pausedUntil(6) (PauseKind.DIVIDEND, at
///     most 72 h per owner call, renewable). The BUY pause (kind 1) does not affect them.
///   - Both are nonReentrant (one shared guard in slot 0): a re-entrant claim from receive() reverts
///     ReentrancyGuardReentrantCall().
///   - sync() is a no-op for this template (reads the quote balance, writes nothing, emits nothing).
///   - After graduation tax arrives in TOKEN directly from the token's transfer hook (taxSink == vault);
///     nothing converts it. The quote side only keeps what accrued on the curve.
interface IDirectedVault {
    // ── immutables ──
    function RECIPIENT() external view returns (address); // 0x0d9019e1
    function MANAGER() external view returns (address); // 0x1b2df850
    function FACTORY() external view returns (address); // 0x2dd31000
    function TOKEN() external view returns (address); // 0x82bfefc8
    /// @notice address(0) = native OKB.
    function QUOTE() external view returns (address); // 0x9c579839
    /// @notice Always 0 for the Directed template.
    function DIVIDEND_BPS() external view returns (uint256); // 0x8d7036de
    /// @notice Always address(0) for the Directed template (no dividend tracker).
    function tracker() external view returns (address); // 0xf52bccad

    // ── actions ──

    /// @notice No-op for this template. Not needed before claim.
    function sync() external; // 0xfff6cae9

    /// @notice Only RECIPIENT may call. Pays the vault's whole balance of `asset` to RECIPIENT.
    /// @param asset QUOTE (address(0) for native OKB) or TOKEN. Anything else: UnknownAsset().
    /// @return amount the amount sent. For TOKEN this equals the recipient's balance delta because the
    ///         vault is taxExempt on its token. Measure the delta anyway.
    function claim(address asset) external returns (uint256 amount); // 0x1e83409a

    /// @notice Permissionless push. `recipient` must equal RECIPIENT, else Unauthorized().
    function claimFor(address recipient, address asset) external returns (uint256 amount); // 0xb4ba9e11

    /// @notice 0 when recipient != RECIPIENT; reverts UnknownAsset() for a foreign asset.
    function claimableNow(address recipient, address asset) external view returns (uint256); // 0x82ee9d56

    // 0x67318ec1 (uint256 minAmount): NOT part of this interface on purpose. Recovered from bytecode:
    // callable only by the address returned by FACTORY.0x2761dbab() (a platform operator); pushes the whole
    // TOKEN balance to RECIPIENT if it is >= minAmount, otherwise returns 0. It is the platform's batched
    // equivalent of claimFor(RECIPIENT, TOKEN): it cannot redirect funds and it does not convert them.

    // ── events (topics measured on the fork) ──
    /// @dev topic0 0xf7a40077ff7a04c7e61f6f26fb13774259ddf1b6bce9ecf26a8276cdd3992683
    event Claimed(address indexed recipient, address indexed asset, uint256 amount);

    // ── errors (selectors measured on the fork) ──
    error Unauthorized(); // 0x82b42900
    error UnknownAsset(); // 0xc97d95cf
    error Paused(); // 0x9e87fac8
    error NothingToClaim(); // 0x969bf728
    error TransferFailed(); // 0x90b8ec18
    error ReentrancyGuardReentrantCall(); // 0x3ee5aeb5
}
