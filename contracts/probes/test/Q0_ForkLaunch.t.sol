// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

interface IManagerExtra {
    function creatorAccrued(address creator, address quote) external view returns (uint256);
}

/// @notice How every other probe gets a Directed token whose recipient is a contract: a FULL launch through
///         the live IgnixManager on the fork. The platform signer is replaced in fork storage (slot 5, found
///         with stdstore) by a throwaway key; createToken then runs unmodified mainnet code.
contract Q0_ForkLaunch is ProbeBase {
    using stdStorage for StdStorage;

    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        (token, vault) = _launch(_defaultCfg(address(probe)));
    }

    function test_Q0_signer_lives_in_slot_5_and_the_override_is_fork_only() public {
        // a second, untouched fork shows the real value
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", DEFAULT_RPC), PINNED_BLOCK);
        assertEq(M.signer(), PLATFORM_SIGNER);
        assertEq(address(uint160(uint256(vm.load(address(M), bytes32(SLOT_SIGNER))))), PLATFORM_SIGNER);
        assertEq(stdstore.target(address(M)).sig("signer()").find(), SLOT_SIGNER);
        // the proxy really is the verified implementation the vendored source belongs to
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(address(M), implSlot)))), MANAGER_IMPL);
        assertEq(M.owner(), 0x9147C109F903eeA66DD0b512531ae9cE0377E76a);
        assertTrue(M.configured() && M.configured2());
    }

    function test_Q0_fork_launch_wires_a_directed_vault_to_the_contract_recipient() public view {
        assertEq(M.vaultOf(address(token)), address(vault));
        assertEq(vault.RECIPIENT(), address(probe), "RECIPIENT = the contract we named in vaultData");
        assertEq(vault.TOKEN(), address(token));
        assertEq(vault.MANAGER(), address(M));
        assertEq(vault.QUOTE(), address(0), "native OKB");
        assertEq(vault.FACTORY(), IVaultRegistry(M.REGISTRY()).factoryOf(TEMPLATE_DIRECTED));
        assertEq(vault.FACTORY(), IgnixAddresses.DIRECTED_FACTORY);
        assertEq(vault.DIVIDEND_BPS(), 0);
        assertEq(vault.tracker(), address(0));
        assertEq(token.tracker(), address(0));
        assertEq(token.taxSink(), address(vault));
        assertEq(token.MANAGER(), address(M));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.decimals(), 18);
        assertEq(token.balanceOf(address(M)), 1_000_000_000 ether);
        assertFalse(token.unlocked());
        assertEq(token.pair(), address(0));
        assertEq(token.protectionDuration(), 8_640_000);
        assertEq(token.protectionEndsAt(), 0, "the window starts at graduation");
        assertFalse(token.protectionActive());

        CurveToken memory t = _tok(address(token));
        assertEq(t.creator, creator, "creator = msg.sender of createToken");
        assertEq(t.buyFeeBps, 100);
        assertEq(t.sellFeeBps, 100);
        assertEq(t.taxBuyBps, 300);
        assertEq(t.taxSellBps, 300);
        assertEq(t.quote, address(0));
        assertEq(t.createdAt, block.timestamp);
        assertEq(t.sold, 0);
        assertEq(t.sellable, 800_000_000 ether);
        assertEq(t.reserve, 200_000_000 ether);
    }

    /// @dev The token and vault the fork launch produces are byte-for-byte what live launches got.
    function test_Q0_fork_launched_token_and_vault_have_the_same_code_as_live_ones() public view {
        assertEq(address(token).codehash, OB_TOKEN.codehash, "token runtime code == live OB token");
        assertEq(address(token).code.length, 9_419);

        // the vault differs only by its immutables: TOKEN and RECIPIENT
        bytes memory live = OB_VAULT.code;
        assertEq(live.length, address(vault).code.length);
        assertEq(live.length, 3_019);
        uint256 nTok = _replace(live, OB_TOKEN, address(token));
        uint256 nRcp = _replace(live, OB_RECIPIENT, address(probe));
        assertEq(
            keccak256(live), address(vault).codehash, "vault runtime code == live OB vault modulo immutables"
        );
        assertGt(nTok, 0);
        assertGt(nRcp, 0);
    }

    function test_Q0_no_creator_rebate_accrues_on_curve_trades() public {
        _buy(alice, address(token), 5 ether);
        uint256 bal = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(M), bal);
        M.sell(address(token), bal / 2, 0);
        vm.stopPrank();
        assertEq(
            IManagerExtra(address(M)).creatorAccrued(creator, address(0)),
            0,
            "creator earns nothing on the curve"
        );
        assertEq(IManagerExtra(address(M)).creatorAccrued(address(probe), address(0)), 0);
    }

    /// @dev In-place replacement of every 20-byte occurrence of `from` by `to`.
    function _replace(bytes memory code, address from, address to) internal pure returns (uint256 n) {
        bytes20 f = bytes20(from);
        bytes20 t = bytes20(to);
        if (code.length < 20) return 0;
        for (uint256 i; i + 20 <= code.length; ++i) {
            bool hit = true;
            for (uint256 j; j < 20; ++j) {
                if (code[i + j] != f[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                for (uint256 j; j < 20; ++j) {
                    code[i + j] = t[j];
                }
                ++n;
                i += 19;
            }
        }
    }
}
