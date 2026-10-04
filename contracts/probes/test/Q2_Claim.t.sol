// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Q2. Claiming the Directed vault's native-OKB tax to a CONTRACT recipient.
///         Fixture A: a full launch on the fork whose recipient is a freshly deployed RecipientProbe.
///         Fixture B: the live OB token with the probe etched over its (EOA) recipient.
///         Fixture C: a live token whose recipient already is a third-party contract (not modified).
contract Q2_Claim is ProbeBase {
    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;

    address internal constant NATIVE = address(0);

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        vm.label(address(probe), "probe (recipient)");
        (token, vault) = _launch(_defaultCfg(address(probe)));
    }

    // ───────────────────────── accrual ─────────────────────────

    function test_Q2_tax_accrues_in_vault_as_native_on_curve_buy() public {
        assertEq(vault.RECIPIENT(), address(probe));
        assertEq(vault.QUOTE(), NATIVE);
        assertEq(address(vault).balance, 0);

        uint256 amt = 1 ether;
        _buy(alice, address(token), amt);

        // tax = floor(gross * taxBuyBps / 10000), pushed to the vault inside the buy
        assertEq(address(vault).balance, (amt * 300) / 10_000, "tax in vault");
        assertEq(address(vault).balance, 0.03 ether);
        // claimable is the balance, for the recipient only
        assertEq(vault.claimableNow(address(probe), NATIVE), 0.03 ether);
        assertEq(vault.claimableNow(alice, NATIVE), 0, "nobody else has a claim");
        // the project token is not claimable before graduation
        assertEq(vault.claimableNow(address(probe), address(token)), 0);
        // a sell is taxed too
        uint256 bal = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(M), bal);
        uint256 v0 = address(vault).balance;
        uint256 a0 = alice.balance;
        M.sell(address(token), bal, 0);
        vm.stopPrank();
        uint256 sellTax = address(vault).balance - v0;
        uint256 netToAlice = alice.balance - a0;
        // gross = net + 1% fee + 3% tax ; tax = floor(gross * 300 / 10000)
        console2.log("sell tax to vault (wei)", sellTax);
        console2.log("sell net to seller (wei)", netToAlice);
        assertGt(sellTax, 0);
        assertApproxEqRel(sellTax, (netToAlice * 300) / 9_600, 1e12);
    }

    // ───────────────────────── claim by the recipient contract ─────────────────────────

    function test_Q2_sync_then_claim_delivers_native_to_contract() public {
        _buy(alice, address(token), 1 ether);
        vm.prank(bob);
        vault.sync(); // permissionless; a no-op for this template (see Q8)

        uint256 claimable = vault.claimableNow(address(probe), NATIVE);
        (uint256 ret, uint256 delta, uint256 gasUsed) = probe.claim(vault, NATIVE);

        assertEq(ret, 0.03 ether, "return value");
        assertEq(delta, 0.03 ether, "balance delta");
        assertEq(delta, claimable, "claimableNow == real delta");
        assertEq(address(vault).balance, 0, "vault emptied");
        assertEq(address(probe).balance, 0.03 ether);
        console2.log("claim(native) gas, near-empty receive", gasUsed);
    }

    function test_Q2_claim_without_sync_works() public {
        _buy(alice, address(token), 1 ether);
        (uint256 ret, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(ret, 0.03 ether);
        assertEq(delta, 0.03 ether);
    }

    function test_Q2_nontrivial_receive_works() public {
        probe.setMode(RecipientProbe.Mode.Record); // 4 SSTOREs + 1 event in receive()
        _buy(alice, address(token), 1 ether);
        (uint256 ret, uint256 delta, uint256 gasUsed) = probe.claim(vault, NATIVE);
        assertEq(ret, 0.03 ether);
        assertEq(delta, 0.03 ether);
        assertEq(probe.receiveCount(), 1);
        assertEq(probe.receivedTotal(), 0.03 ether);
        assertEq(probe.lastSender(), address(vault), "msg.sender in receive() is the vault");
        console2.log("claim(native) gas, heavy receive", gasUsed);
        console2.log("gas available at receive() entry", probe.lastGasAtReceive());
        assertGt(probe.lastGasAtReceive(), 2_300, "more than the 2300 stipend");
    }

    /// @dev The vault does `RECIPIENT.call{value: amount}("")` with no gas argument: 63/64 of what is left.
    function test_Q2_gas_forwarded_to_recipient_is_63_64ths() public {
        probe.setMode(RecipientProbe.Mode.Record);
        _buy(alice, address(token), 1 ether);

        uint256[5] memory limits = [uint256(150_000), 300_000, 1_000_000, 5_000_000, 30_000_000];
        for (uint256 i; i < limits.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(bob);
            vault.claimFor{gas: limits[i]}(address(probe), NATIVE);
            uint256 atEntry = probe.lastGasAtReceive();
            console2.log("claimFor gas limit", limits[i], "-> gas at receive() entry", atEntry);
            // overhead before the CALL is about 20k (cold) and the CALL itself costs 9,000 for the value
            // transfer (2,300 of it handed on as stipend); the rest is forwarded 63/64.
            assertGt(atEntry, ((limits[i] - 40_000) * 63) / 64, "less than 63/64 forwarded");
            assertLt(atEntry, limits[i]);
            vm.revertToState(snap);
        }
    }

    function test_Q2_out_of_gas_in_receive_reverts_the_whole_claim() public {
        probe.setMode(RecipientProbe.Mode.Record); // needs roughly 95k gas
        _buy(alice, address(token), 1 ether);
        vm.prank(bob);
        (bool ok, bytes memory err) = address(vault).call{gas: 80_000}(
            abi.encodeCall(IDirectedVault.claimFor, (address(probe), NATIVE))
        );
        assertFalse(ok, "starved claimFor must fail");
        console2.logBytes(err);
        // nothing moved; the next properly funded claim gets everything
        assertEq(address(vault).balance, 0.03 ether);
        assertEq(probe.receiveCount(), 0);
        (, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(delta, 0.03 ether);
    }

    // ───────────────────────── a recipient that refuses ─────────────────────────

    function test_Q2_reverting_receive_makes_claim_revert_TransferFailed() public {
        _buy(alice, address(token), 1 ether);
        probe.setMode(RecipientProbe.Mode.Refuse);

        vm.expectRevert(IDirectedVault.TransferFailed.selector);
        probe.claim(vault, NATIVE);

        vm.prank(bob);
        vm.expectRevert(IDirectedVault.TransferFailed.selector);
        vault.claimFor(address(probe), NATIVE);

        assertEq(bytes4(IDirectedVault.TransferFailed.selector), bytes4(0x90b8ec18));
        // funds are not lost: they stay in the vault until the recipient accepts
        assertEq(address(vault).balance, 0.03 ether);
        probe.setMode(RecipientProbe.Mode.Accept);
        (, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(delta, 0.03 ether);
    }

    function test_Q2_receive_that_only_accepts_vault_and_manager_works() public {
        probe.setMode(RecipientProbe.Mode.OnlyKnown);
        probe.setKnown(address(vault), true);
        probe.setKnown(address(M), true);
        _buy(alice, address(token), 1 ether);
        (, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(delta, 0.03 ether);
        // a stranger's transfer is refused
        vm.prank(bob);
        (bool ok,) = address(probe).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_Q2_reentrant_claim_from_receive_is_blocked() public {
        probe.setMode(RecipientProbe.Mode.Reenter);
        probe.setReenterVault(address(vault));
        _buy(alice, address(token), 1 ether);
        (, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(delta, 0.03 ether, "outer claim still pays once");
        assertEq(_sel(probe.lastReenterRevert()), IDirectedVault.ReentrancyGuardReentrantCall.selector);
        assertEq(bytes4(IDirectedVault.ReentrancyGuardReentrantCall.selector), bytes4(0x3ee5aeb5));
    }

    // ───────────────────────── third party push ─────────────────────────

    function test_Q2_claimFor_by_third_party_pushes_to_recipient() public {
        probe.setMode(RecipientProbe.Mode.Record);
        _buy(alice, address(token), 1 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        uint256 ret = vault.claimFor(address(probe), NATIVE);

        assertEq(ret, 0.03 ether);
        assertEq(address(probe).balance, 0.03 ether, "pushed to RECIPIENT");
        assertEq(bob.balance, bobBefore, "the caller gets nothing");
        assertEq(probe.lastSender(), address(vault));
        assertEq(address(vault).balance, 0);
    }

    function test_Q2_claimFor_cannot_redirect_and_claim_is_recipient_only() public {
        _buy(alice, address(token), 1 ether);

        vm.prank(bob);
        vm.expectRevert(IDirectedVault.Unauthorized.selector);
        vault.claimFor(bob, NATIVE);

        vm.prank(bob);
        vm.expectRevert(IDirectedVault.Unauthorized.selector);
        vault.claim(NATIVE);

        assertEq(bytes4(IDirectedVault.Unauthorized.selector), bytes4(0x82b42900));
    }

    // ───────────────────────── edge cases the kernel must survive ─────────────────────────

    function test_Q2_claim_reverts_NothingToClaim_when_vault_is_empty() public {
        assertEq(address(vault).balance, 0);
        vm.expectRevert(IDirectedVault.NothingToClaim.selector);
        probe.claim(vault, NATIVE);

        vm.prank(bob);
        vm.expectRevert(IDirectedVault.NothingToClaim.selector);
        vault.claimFor(address(probe), NATIVE);
        assertEq(bytes4(IDirectedVault.NothingToClaim.selector), bytes4(0x969bf728));

        // the kernel's try/catch shape: no revert, zero delta
        (bool ok, bytes memory err, uint256 delta, uint256 gasUsed) = probe.tryClaim(vault, NATIVE);
        assertFalse(ok);
        assertEq(_sel(err), IDirectedVault.NothingToClaim.selector);
        assertEq(delta, 0);
        console2.log("failed claim (NothingToClaim) gas", gasUsed);
    }

    function test_Q2_claim_of_project_token_before_graduation_reverts_NothingToClaim() public {
        _buy(alice, address(token), 1 ether);
        vm.expectRevert(IDirectedVault.NothingToClaim.selector);
        probe.claim(vault, address(token));
    }

    function test_Q2_unknown_asset_reverts() public {
        vm.expectRevert(IDirectedVault.UnknownAsset.selector);
        probe.claim(vault, WOKB);
        vm.expectRevert(IDirectedVault.UnknownAsset.selector);
        vault.claimableNow(address(probe), WOKB);
        assertEq(bytes4(IDirectedVault.UnknownAsset.selector), bytes4(0xc97d95cf));
    }

    function test_Q2_vault_has_no_ledger_donations_are_claimable() public {
        _buy(alice, address(token), 1 ether);
        vm.prank(bob);
        (bool ok,) = address(vault).call{value: 0.5 ether}("");
        assertTrue(ok, "the vault accepts plain native transfers");
        assertEq(vault.claimableNow(address(probe), NATIVE), 0.53 ether);
        (uint256 ret, uint256 delta,) = probe.claim(vault, NATIVE);
        assertEq(ret, 0.53 ether);
        assertEq(delta, 0.53 ether);
    }

    function test_Q2_claim_emits_Claimed_event() public {
        _buy(alice, address(token), 1 ether);
        vm.recordLogs();
        probe.claim(vault, NATIVE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) {
                found = true;
                assertEq(logs[i].topics[0], keccak256("Claimed(address,address,uint256)"));
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(probe)))), "topic1 = recipient");
                assertEq(logs[i].topics[2], bytes32(0), "topic2 = asset (native)");
                assertEq(abi.decode(logs[i].data, (uint256)), 0.03 ether);
            }
        }
        assertTrue(found, "vault emitted nothing");
    }

    // ───────────────────────── live fixtures ─────────────────────────

    function test_Q2_live_OB_vault_claim_to_etched_contract_recipient() public {
        IDirectedVault obVault = IDirectedVault(OB_VAULT);
        uint256 preexisting = OB_VAULT.balance;
        assertEq(preexisting, 4_006_687_747_548_187, "live unclaimed tax at the pinned block");
        assertEq(obVault.claimableNow(OB_RECIPIENT, NATIVE), preexisting);

        RecipientProbe p = _etchProbe(OB_RECIPIENT);
        p.setMode(RecipientProbe.Mode.Record);
        uint256 r0 = OB_RECIPIENT.balance;

        _buy(alice, OB_TOKEN, 1 ether); // OB taxes 1% / 1%
        assertEq(OB_VAULT.balance, preexisting + 0.01 ether);

        (uint256 ret, uint256 delta, uint256 gasUsed) = p.claim(obVault, NATIVE);
        assertEq(ret, preexisting + 0.01 ether);
        assertEq(delta, ret);
        assertEq(OB_RECIPIENT.balance - r0, ret);
        assertEq(p.lastSender(), OB_VAULT);
        console2.log("OB claim(native) gas, heavy receive", gasUsed);
    }

    function test_Q2_live_third_party_contract_recipient_receives_claimFor() public {
        // TEST token: vault 0x2755..., recipient 0xb27f... is a deployed contract (BurstBurnEngine) whose
        // receive() emits an event. Nothing is etched or overridden here.
        IDirectedVault v = IDirectedVault(0x27558D2205B3553cAc5875Cef63624E3bE6672e4);
        address rcp = 0xb27fAEaB17A97bAAda0C571F3E679aABD952992f;
        assertEq(v.RECIPIENT(), rcp);
        uint256 claimable = v.claimableNow(rcp, NATIVE);
        assertEq(claimable, 16_933_658_097_562_826, "live unclaimed tax at the pinned block");
        uint256 r0 = rcp.balance;
        vm.prank(bob);
        uint256 ret = v.claimFor(rcp, NATIVE);
        assertEq(ret, claimable);
        assertEq(rcp.balance - r0, claimable);
    }
}
