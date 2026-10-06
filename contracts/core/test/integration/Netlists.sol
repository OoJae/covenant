// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev The harness contracts of TapeHarness.sol, as the tests see them.
interface ITapeCircuits {
    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external returns (uint256 id);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function netlist(uint256 id) external view returns (bytes memory);
    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32);
    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
}

interface ITapeFab {
    function CIRCUITS() external view returns (address);
    function tapeoutChip(bytes calldata nl) external returns (uint256 chipId);
    function isChip(uint256 chipId) external view returns (bool);
    function chipInfo(uint256 chipId) external view returns (address, bytes32, uint32, uint32, address, bytes32);
    function snapshot(uint256 chipId) external view returns (bytes memory);
}

/// @notice Builds TAP-20 netlists of the Covenant v1 shape (96 inputs, 112 outputs, LATCH records first).
library Netlists {
    uint256 internal constant N_IN = 96;

    function _nand(uint256 a, uint256 b) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), uint24(a), uint24(b));
    }

    function _latch(uint256 d) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), uint24(d));
    }

    /// @notice A chip of exactly `gates` records: `nLatch` latches, pseudo-random NAND logic that feeds them,
    ///         and 112 output gates that drive the constant word `word`.
    /// @dev    Signal numbering (TAP-20): 0 and 1 are the constants, 2..97 the inputs, then one signal per
    ///         record. Output bit 1 is NAND(0, 0); output bit 0 is NAND(1, 1).
    function synthetic(uint256 gates, uint256 nLatch, uint256 word, uint256 seed)
        internal
        pure
        returns (bytes memory nl)
    {
        require(gates >= nLatch + 112 + 1, "too few gates");
        uint256 nLogic = gates - nLatch - 112;
        uint256 firstLogic = 2 + N_IN + nLatch; // index of the first NAND's signal
        // latches: each takes its next value from one of the logic gates
        for (uint256 i = 0; i < nLatch; i++) {
            uint256 d = firstLogic + (uint256(keccak256(abi.encode(seed, "d", i))) % nLogic);
            nl = bytes.concat(nl, _latch(d));
        }
        // logic: every NAND reads two earlier signals (inputs, latch outputs or earlier gates)
        bytes memory logic;
        for (uint256 i = 0; i < nLogic; i++) {
            uint256 have = firstLogic + i;
            uint256 a = 2 + (uint256(keccak256(abi.encode(seed, "a", i))) % (have - 2));
            uint256 b = 2 + (uint256(keccak256(abi.encode(seed, "b", i))) % (have - 2));
            logic = bytes.concat(logic, _nand(a, b));
        }
        nl = bytes.concat(nl, logic);
        bytes memory outs;
        for (uint256 i = 0; i < 112; i++) {
            outs = bytes.concat(outs, (word >> i) & 1 == 1 ? _nand(0, 0) : _nand(1, 1));
        }
        nl = bytes.concat(nl, outs);
    }

    /// @notice A chip with no NAND at all: `n` latches, each holding its own bit. The outputs are the last
    ///         112 latch outputs. With the all-ones state every latch output and every next-state bit is 1,
    ///         which is the most work TapeOut's evaluator does per LATCH record.
    function latchOnly(uint256 n) internal pure returns (bytes memory nl) {
        require(n >= 112 && n <= 256, "112..256 latches");
        for (uint256 i = 0; i < n; i++) {
            nl = bytes.concat(nl, _latch(2 + N_IN + i));
        }
    }

    /// @notice The smallest state-dependent chip: one latch that toggles, and two output words selected by it.
    ///         Output bit i is 1 when (the latch is 0 and bit i of `wordA` is set) or (the latch is 1 and bit
    ///         i of `wordB` is set).
    function toggle(uint256 wordA, uint256 wordB) internal pure returns (bytes memory nl) {
        uint256 latch = 2 + N_IN; // signal 98: the latch's stored bit
        uint256 notLatch = latch + 1; // signal 99
        nl = bytes.concat(_latch(notLatch), _nand(latch, latch));
        for (uint256 i = 0; i < 112; i++) {
            bool a = (wordA >> i) & 1 == 1;
            bool b = (wordB >> i) & 1 == 1;
            if (a && b) nl = bytes.concat(nl, _nand(0, 0)); // 1
            else if (!a && !b) nl = bytes.concat(nl, _nand(1, 1)); // 0
            else if (a) nl = bytes.concat(nl, _nand(latch, latch)); // NOT latch: 1 while the latch is 0
            else nl = bytes.concat(nl, _nand(notLatch, notLatch)); // latch
        }
    }
}
