// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @notice Selects an X Layer mainnet fork at a pinned block. Read-only: nothing is ever broadcast.
/// @dev The endpoint is XLAYER_RPC_URL if set, https://rpc.xlayer.tech otherwise; if it cannot serve the
///      block, the OKX endpoint (`xlayer_fallback` in foundry.toml) is tried. Both served state a million
///      blocks back when this was written, so the pinned block stays available.
abstract contract XLayerFork is Test {
    /// @dev 2026-10-04 18:37:16 UTC, hash 0x9f56e356e41890ea82616b0c62fad1816ce67a47402d0ce25038bc655cd48e5b.
    uint256 internal constant FORK_BLOCK = 72_370_000;

    /// @dev TapeOut's processor factory on X Layer (chain 196) and what stood behind it at FORK_BLOCK.
    address internal constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant CIRCUIT_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address internal constant CIRCUIT_IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    bytes32 internal constant CIRCUIT_IMPL_CODEHASH =
        0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    function _selectFork() internal {
        try vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK) returns (
            uint256
        ) {}
        catch {
            vm.createSelectFork("xlayer_fallback", FORK_BLOCK);
        }
        assertEq(block.chainid, 196, "not X Layer");
        assertEq(block.number, FORK_BLOCK);
    }
}
