// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FabSuite} from "./utils/FabSuite.sol";
import {ILocalTapeOut, ITapeOutFactory} from "./utils/Oracles.sol";

/// @notice The Fab suite against TapeOut's vendored contracts, deployed locally. No network needed.
/// @dev Fees are the ones read from the X Layer factory on 2026-10-04: deploy 0.0066 OKB, protocol fee
///      0.00066 OKB per mint call. The tape-out fee (0.0013 OKB) is a constant of TapeOut's source.
contract FabLocalTest is FabSuite {
    function _factory() internal override returns (ITapeOutFactory) {
        address local = deployCode(
            "LocalTapeOut.sol:LocalTapeOut",
            abi.encode(makeAddr("tapeout-owner"), makeAddr("tapeout-protocol-wallet"), 0.0066 ether, 0.00066 ether)
        );
        return ITapeOutFactory(ILocalTapeOut(local).factory());
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_acceptsExactlyV1Chips(uint256 seed) public {
        _checkAcceptsExactlyV1Chips(seed);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_tapeout_invariants(uint256 seed, uint16 latchSeed, uint16 nandSeed, bool toBob) public {
        _checkTapeoutInvariants(seed, latchSeed, nandSeed, toBob);
    }
}
