// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TeamRegistry - append-only list of the Covenant team's wallets, rooted in the deployer.
///
/// @notice Entry 0 is the account that created the processor. A listed wallet may invite another wallet; an
///         invited wallet may then declare itself, only itself and only once. Nothing can ever be edited or
///         removed, an invitation included. There is no owner. The registry proves nothing about a wallet
///         that is NOT listed; it only makes a listing public, timestamped and impossible to withdraw.
contract TeamRegistry {
    /// @notice Longest role text accepted, in bytes.
    uint256 public constant MAX_ROLE_BYTES = 64;

    struct Declaration {
        address wallet;
        uint64 timestamp;
        string role;
    }

    Declaration[] private _declarations;

    /// @notice True once `wallet` is listed: the deployer from the start, any other wallet once it has declared.
    mapping(address wallet => bool declared) public isTeam;

    /// @notice True once a listed wallet has invited `wallet`. Only then may `wallet` declare itself.
    mapping(address wallet => bool invited) public isInvited;

    event Invited(address indexed wallet, address indexed by);
    event Declared(address indexed wallet, uint256 indexed index, string role);

    error NotListed();
    error NotInvited();
    error AlreadyDeclared();
    error RoleTooLong();

    /// @param founder Listed as entry 0 with the role "deployer". The Splitter passes the account that sends
    ///                the transaction creating the processor.
    constructor(address founder) {
        isTeam[founder] = true;
        // uint64 holds timestamps for the next 584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        _declarations.push(Declaration({wallet: founder, timestamp: uint64(block.timestamp), role: "deployer"}));

        emit Declared(founder, 0, "deployer");
    }

    /// @notice Allows `wallet` to declare itself. Only a listed wallet may invite. Cannot be undone.
    function invite(address wallet) external {
        if (!isTeam[msg.sender]) revert NotListed();

        // The Invited event on the next line reports this change.
        // forge-lint: disable-next-line(missing-events-access-control)
        isInvited[wallet] = true;
        emit Invited(wallet, msg.sender);
    }

    /// @notice Lists `msg.sender`, which must have been invited, with a free-text `role` of at most 64 bytes.
    function declare(string calldata role) external {
        if (isTeam[msg.sender]) revert AlreadyDeclared();
        if (!isInvited[msg.sender]) revert NotInvited();
        if (bytes(role).length > MAX_ROLE_BYTES) revert RoleTooLong();

        // The Declared event at the end of this function reports this change.
        // forge-lint: disable-next-line(missing-events-access-control)
        isTeam[msg.sender] = true;
        // uint64 holds timestamps for the next 584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        _declarations.push(Declaration({wallet: msg.sender, timestamp: uint64(block.timestamp), role: role}));

        emit Declared(msg.sender, _declarations.length - 1, role);
    }

    /// @notice Number of listed wallets.
    function count() external view returns (uint256) {
        return _declarations.length;
    }

    /// @notice The `i`-th listed wallet, in the order they were listed. Entry 0 is the deployer.
    function at(uint256 i) external view returns (address wallet, string memory role, uint256 timestamp) {
        Declaration storage d = _declarations[i];
        return (d.wallet, d.role, d.timestamp);
    }
}
