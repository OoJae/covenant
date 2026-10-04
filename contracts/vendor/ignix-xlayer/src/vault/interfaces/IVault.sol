// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Vault interface as seen by the platform
/// @notice Deliberately just two functions — that is everything the platform needs.
///         How tax arrives is the vault's own business (it is pushed in; `sync`
///         recognises it from the balance), and what a template does with it is even
///         less the platform's business. See docs/26 §3.
///
///         Note the absence of any LP entry point: permanent LP lock-up is a
///         platform-wide promise and lives in the `IgnixLpLocker` singleton, so no
///         template has to carry a concept unrelated to it.
interface IVault {
    /// @notice Recognise newly arrived tax and hand it to the template's `_onRevenue`.
    ///         **Permissionless** — anyone may call it; the platform's cron job merely
    ///         pays the gas on everyone's behalf and holds no privilege.
    function sync() external;

    /// @notice Address of the share/dividend ledger, or zero for a template that pays
    ///         no dividends. The Manager reads it at launch and wires it into the
    ///         token, so **every template must implement it**.
    function tracker() external view returns (address);
}
