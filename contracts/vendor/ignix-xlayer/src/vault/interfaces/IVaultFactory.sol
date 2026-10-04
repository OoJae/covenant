// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Vault template factory — the platform/template boundary
/// @notice The platform knows only this interface and never any concrete template.
///         `vaultData` is forwarded verbatim and is **never interpreted** by the
///         platform (docs/26 §3.3). Adding a template means writing one Factory plus
///         one Vault and registering it — no platform code changes.
///
///         Only functions that affect **funds or admission** live here. Anything purely
///         presentational is kept off-chain on purpose:
///
///         - a `schema()` for rendering the launch form was removed: four generic
///           fields cannot express a stock picker with live quotes or a draggable
///           split ring, so it would have been bytecode nobody reads;
///         - a `meta()` returning name/description/risk-tier was removed for a stronger
///           reason: a `pure` value is unchangeable, so an audited template could never
///           stop advertising itself as unaudited without redeploying the factory — and
///           more fundamentally, a self-assigned risk score is not a verifiable fact,
///           yet putting it on-chain lends it the authority of one. Audit status is
///           honestly expressed by linking to the actual report.
interface IVaultFactory {
    /// @notice Deploy one vault of this template. Called by the Manager at launch.
    /// @param manager   Manager the vault must trust: it pushes tax in, and the LP-fee
    ///                  recipient is read live from its `owner()`.
    /// @param vaultData Template-specific parameters chosen by the creator, encoded by
    ///                  the template itself. The platform does not interpret them.
    function newVault(
        address token,
        address quote,
        address creator,
        address manager,
        bytes calldata vaultData
    ) external returns (address vault);

    /// @notice Last admission gate before a launch. Returns a plain bool: the Manager
    ///         only branches on it, and the signing service carries its own
    ///         human-readable errors, so a `reason` string would be dead bytecode in
    ///         every template.
    /// @dev It must cover the rules `newVault` cannot enforce by itself — the asset
    ///      whitelist above all. Skipping it makes the whitelist decorative.
    function validate(address quote, uint256 graduation, bytes calldata vaultData)
        external
        view
        returns (bool ok);
}
