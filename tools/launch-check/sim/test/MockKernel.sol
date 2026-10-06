// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIgnixManager, IDirectedVault, IERC721Min, CurveToken, Record} from "../src/Interfaces.sol";

/// @notice TEST ONLY. A stand-in for a processor's Circuits contract: who owns which chip.
contract MockCircuits is IERC721Min {
    mapping(uint256 id => address owner) public override ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/// @notice TEST ONLY. The smallest contract that implements `bind` and `settle` as chips/INTERFACE.md
///         section 10 states them. It exists so that the launch simulation can be proven before the real
///         kernel is deployed; it is never deployed anywhere.
///
///         bind(token) succeeds once, and only if
///           vaultOf(token).RECIPIENT() == address(this), vault.TOKEN() == token, vault.QUOTE() == address(0),
///           the token has a tax on at least one side, this contract holds the chip NFT, and either
///           tokens(token).creator == launcher or msg.sender == launcher (interface revision 2).
///         settle() runs at most once per epoch (epoch = (block.timestamp - bindTime) / epochLen), claims the
///         vault's native OKB in try/catch, measures inflow as a balance delta, and writes a record.
///
///         It steps no chip: every share goes to the reserve (the K1T default of section 8), so the record's
///         inputs, outputs and state are zero. The real kernel differs there and only there.
contract MockKernel {
    IIgnixManager public immutable manager;
    IERC721Min public immutable circuits;
    uint256 public immutable chipId;
    address public immutable launcher;
    uint32 public immutable epochLen;

    address public token;
    address public vault;
    uint40 public bindTime;
    uint32 public lastEpoch;
    uint32 public count;
    bytes32 public state;
    uint256 public reserve;
    mapping(uint32 n => Record) internal _records;

    error AlreadyBound();
    error NotBound();
    error BindCheck(uint8 which);
    error EpochNotElapsed();
    error NotAccepted();

    constructor(address manager_, address circuits_, uint256 chipId_, address launcher_, uint32 epochLen_) {
        manager = IIgnixManager(manager_);
        circuits = IERC721Min(circuits_);
        chipId = chipId_;
        launcher = launcher_;
        epochLen = epochLen_;
    }

    function bind(address token_) external {
        if (token != address(0)) revert AlreadyBound();
        address v = manager.vaultOf(token_);
        if (v == address(0)) revert BindCheck(1);
        if (IDirectedVault(v).RECIPIENT() != address(this)) revert BindCheck(2);
        if (IDirectedVault(v).TOKEN() != token_) revert BindCheck(3);
        if (IDirectedVault(v).QUOTE() != address(0)) revert BindCheck(4);
        CurveToken memory t = manager.tokens(token_);
        if (t.creator != launcher && msg.sender != launcher) revert BindCheck(5);
        if (t.taxBuyBps == 0 && t.taxSellBps == 0) revert BindCheck(6);
        if (circuits.ownerOf(chipId) != address(this)) revert BindCheck(7);
        token = token_;
        vault = v;
        bindTime = uint40(block.timestamp);
    }

    function epochNow() public view returns (uint32) {
        if (token == address(0)) return 0;
        return uint32((block.timestamp - bindTime) / epochLen);
    }

    function settle() external returns (uint32 n) {
        if (token == address(0)) revert NotBound();
        uint32 epoch = epochNow();
        if (epoch <= lastEpoch) revert EpochNotElapsed();

        uint8 flags;
        if (vault.balance != 0) {
            try IDirectedVault(vault).claim(address(0)) {}
            catch {
                flags |= 4; // vault claim failed
            }
        }
        uint256 inflow = address(this).balance - reserve;

        n = ++count;
        lastEpoch = epoch;
        Record storage r = _records[n];
        r.epoch = epoch;
        r.time = uint40(block.timestamp);
        r.flags = flags;
        r.inflow = uint128(inflow);
        r.reserveBefore = uint128(reserve);
        reserve += inflow;
    }

    function records(uint32 n) external view returns (Record memory) {
        return _records[n];
    }

    /// Native OKB only from the vault (claims) and the Manager (refunds), as section 9 requires.
    receive() external payable virtual {
        if (msg.sender != vault && msg.sender != address(manager)) revert NotAccepted();
    }
}

/// @notice TEST ONLY. A stand-in KernelFactory that knows the kernels it is told about.
contract MockKernelFactory {
    mapping(address => bool) public isKernel;
    mapping(address => address) public kernelOf;

    function add(address k) external {
        isKernel[k] = true;
    }
}
