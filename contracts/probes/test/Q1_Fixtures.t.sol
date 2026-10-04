// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Q1. Live pre-graduation Directed (templateId 3) tokens quoted in native OKB, found through the
///         IGNIX API (cached under vendor-cache/) and re-proven here from chain state at the pinned block.
contract Q1_Fixtures is ProbeBase {
    // A second live fixture whose recipient is a third-party CONTRACT (verified on OKLink as
    // "BurstBurnEngine", an unrelated project). Used unmodified, never etched.
    address internal constant TEST_TOKEN = 0xa0aBa560a1c48545e8EB5E9B938af097b007EEee;
    address internal constant TEST_VAULT = 0x27558D2205B3553cAc5875Cef63624E3bE6672e4;
    address internal constant TEST_RECIPIENT = 0xb27fAEaB17A97bAAda0C571F3E679aABD952992f;

    // The one graduated Directed token known from the brief (ERC-20 quote, recipient 0x...dEaD).
    address internal constant GRAD_TOKEN = 0x16Aa672ddA63F5ACd0De098c04c4A3e957d1EEEE;
    address internal constant GRAD_VAULT = 0xa6A54EE383A75DA9A2f6e6a060A4c023C8DE8d64;

    function setUp() public {
        _fork();
    }

    function test_Q1_OB_is_live_pregraduation_directed_native_with_trades() public view {
        CurveToken memory t = _tok(OB_TOKEN);
        IDirectedVault v = IDirectedVault(M.vaultOf(OB_TOKEN));

        assertEq(address(v), OB_VAULT, "vaultOf");
        // templateId 3: the vault was built by the factory the registry lists for template 3
        assertEq(
            v.FACTORY(), IVaultRegistry(M.REGISTRY()).factoryOf(TEMPLATE_DIRECTED), "not a Directed vault"
        );
        assertEq(v.FACTORY(), IgnixAddresses.DIRECTED_FACTORY);
        assertEq(v.TOKEN(), OB_TOKEN);
        assertEq(v.MANAGER(), address(M));
        // native OKB quote
        assertEq(t.quote, address(0), "quote not native");
        assertEq(v.QUOTE(), address(0));
        // pre-graduation
        assertEq(M.pairOf(OB_TOKEN), address(0), "graduated (V2)");
        assertEq(t.poolId, bytes32(0), "graduated (V4)");
        assertFalse(IIgnixToken(OB_TOKEN).unlocked());
        // has trades
        assertGt(t.sold, 0);
        assertGt(t.collected, 0);
        // recipient is a real address, not a burn address
        assertEq(v.RECIPIENT(), OB_RECIPIENT);
        assertTrue(OB_RECIPIENT != DEAD && OB_RECIPIENT != address(0));
        assertEq(OB_RECIPIENT.code.length, 0, "OB recipient is an EOA at the pinned block");
        assertEq(t.creator, OB_RECIPIENT, "the creator directed the tax to itself");

        console2.log("OB sold (tokens, 1e18)", uint256(t.sold) / 1e18);
        console2.log("OB collected (wei)", uint256(t.collected));
        console2.log("OB taxBuyBps / taxSellBps", t.taxBuyBps, t.taxSellBps);
        console2.log("OB vault native balance (wei)", OB_VAULT.balance);
    }

    function test_Q1_second_fixture_recipient_is_a_live_contract() public view {
        CurveToken memory t = _tok(TEST_TOKEN);
        IDirectedVault v = IDirectedVault(M.vaultOf(TEST_TOKEN));
        assertEq(address(v), TEST_VAULT);
        assertEq(v.FACTORY(), IgnixAddresses.DIRECTED_FACTORY);
        assertEq(t.quote, address(0));
        assertEq(M.pairOf(TEST_TOKEN), address(0));
        assertEq(v.RECIPIENT(), TEST_RECIPIENT);
        assertGt(TEST_RECIPIENT.code.length, 1_000, "recipient is a contract");
        assertGt(TEST_VAULT.balance, 0, "unclaimed native tax sits in the vault");
        console2.log("TEST recipient code size", TEST_RECIPIENT.code.length);
        console2.log("TEST vault native balance (wei)", TEST_VAULT.balance);
    }

    function test_Q1_no_native_directed_token_has_graduated_reference_is_erc20_quote() public view {
        CurveToken memory t = _tok(GRAD_TOKEN);
        assertTrue(t.quote != address(0), "the only graduated Directed tokens use an ERC-20 quote");
        assertTrue(M.pairOf(GRAD_TOKEN) != address(0));
        assertEq(t.sold, t.sellable, "sold == sellable after graduation");
        assertEq(IDirectedVault(GRAD_VAULT).RECIPIENT(), DEAD);
    }
}
