// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";

/// @notice Limits of kernel v2 that the documentation states (NOTES.md sections 1, 5, 7 and 9; INTERFACE-V2 9.3, 9.4
///         and 13), pinned as tests so that the wording and the code cannot drift apart. None of them is a bug the
///         kernel could fix without new trust: each is what an immutable contract holding an ERC-20 does.
///
///         As everywhere in this tree, every USD₮0 payment comes from `payer`, an address unrelated to the team.
contract StatedLimitsV2Test is BaseV2 {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    /// Review A-F2. After graduation the chip never sees revenue: the input word carries only token flows, and
    /// the USD₮0 pot (revenue included) is spent by a fixed rule, buying the token to 0xdEaD, whatever the chip
    /// outputs. Here a chip that puts everything in the reserve and releases nothing.
    function test_after_graduation_revenue_is_not_seen_by_the_chip_and_a_fixed_rule_buys_and_burns_it() public {
        _fixture(_word(0, 0, 0, 256, 0, 1023));
        _buy(alice, 300e6);
        _nextEpoch();
        _settle();
        _graduate();
        // spend the pot the curve left
        for (uint256 i = 0; i < 40; i++) {
            _nextEpoch();
            _settle();
            if (_qbal(address(kernel)) == 0) break;
        }
        assertEq(_qbal(address(kernel)), 0, "the pot left by the curve is spent");
        _nextEpoch();
        _settle(); // claims the token tax of the last pot buy

        _revenue(50e6); // x402 revenue after graduation
        uint256 dead0 = token.balanceOf(DEAD);
        _nextEpoch();
        uint32 n = _settle();
        RecordV2 memory r = _rec(n);
        KernelMath.InputFields memory f = _in(n);
        assertEq(f.tax, 0, "the chip saw no flow");
        assertEq(r.inflow, 0, "the revenue is not inflow of the token regime");
        assertEq(r.quoteIn, 50e6, "yet all of it was spent on the pair by the fixed rule");
        assertEq(r.allow, 0, "and none of it became allowance");
        assertEq(token.balanceOf(DEAD) - dead0, r.tokensOut, "the tokens bought went to 0xdEaD");
        assertGt(r.tokensOut, 0);
    }

    /// Review A-F3 and B-F6. USD₮0 sent to a kernel that is never bound has no exit (settle reverts NotBound, no
    /// credit exists), and no ERC-20 other than USD₮0 and the bound token has an exit from any kernel. Hence the
    /// rule in NOTES.md section 9: never point PAY_TO at a kernel before bind() has succeeded.
    function test_usdt0_sent_before_bind_and_foreign_tokens_have_no_exit() public {
        vm.prank(launcher);
        uint256 id = fab.tapeoutChip(ChipModel.fixedChip(64, W), 2200);
        KernelV2 k = KernelV2(factory.create(_env(), id, bytes32("unbound")));
        _fund(payer, 25e6);
        vm.prank(payer);
        usdt.transfer(address(k), 25e6); // revenue paid before bind
        vm.expectRevert(KernelV2.NotBound.selector);
        k.settle();
        vm.expectRevert(KernelV2.NotGraduated.selector);
        k.burnLocked();
        assertEq(k.withdrawCredit(payee, address(usdt)), 0);
        assertEq(k.withdrawCredit(launcher, address(usdt)), 0);
        assertEq(usdt.balanceOf(address(k)), 25e6, "stays until a bind that may never come");

        _fixture(W);
        MockUSDT0 other = new MockUSDT0(); // stands for USDC, WOKB, an xStock or any other ERC-20
        other.mint(address(kernel), 7e6);
        _nextEpoch();
        _settle();
        assertEq(kernel.withdrawCredit(payee, address(other)), 0);
        assertEq(kernel.withdrawCredit(sinkAddr, address(other)), 0);
        assertEq(other.balanceOf(address(kernel)), 7e6, "a foreign ERC-20 has no exit");
    }

    /// The same USD₮0 sent before bind is routed by the first settle once bind succeeds.
    function test_usdt0_sent_before_bind_is_routed_once_bound() public {
        vm.prank(launcher);
        uint256 id = fab.tapeoutChip(ChipModel.fixedChip(64, W), 2200);
        Envelope memory e = _env();
        KernelV2 k = KernelV2(factory.create(e, id, bytes32("late")));
        _fund(payer, 25e6);
        vm.prank(payer);
        usdt.transfer(address(k), 25e6);
        (address t,) = manager.createToken(launcher, address(k), 300, 300, 0, 0, GRADUATION);
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(k), id);
        k.bind(t);
        kernel = k;
        token = MockToken(t);
        _nextEpoch();
        uint32 n = _settle();
        assertEq(_rec(n).inflow, 25e6);
    }

    /// Review A-F4 and B-F7. Tether blocks the kernel and destroys its USD₮0 while an allowance credit is owed,
    /// then unblocks it. Credits come first: USD₮0 that arrives later refills the credits the destroyed balance
    /// covered before the chip sees any of it. The lifetime bound (allowCumBps of all that arrived) still holds.
    function test_after_tether_destroys_the_balance_later_inflow_refills_the_credits_first() public {
        _fixture(W);
        _buy(alice, 100e6); // 3 USD0 tax to the vault
        _nextEpoch();
        _settle();
        uint256 credit = kernel.creditOf(payee, address(usdt));
        assertGt(credit, 0, "a credit is owed");

        vm.prank(usdt.owner());
        usdt.addToBlockedList(address(kernel));
        vm.prank(usdt.owner());
        usdt.destroyBlockedFunds(address(kernel));
        _nextEpoch();
        _settle(); // blocked and empty: the reserve book is cut to what is there, nothing reverts
        vm.prank(usdt.owner());
        usdt.removeFromBlockedList(address(kernel));
        // the blocked kernel still received the echo tax of its own curve buy; the rest of the credit is unbacked
        uint256 shortfall = credit - _qbal(address(kernel));
        assertGt(shortfall, 0, "the credit is no longer backed");

        _revenue(shortfall - 1); // an unrelated payer, one unit short of the shortfall
        _nextEpoch();
        uint32 n = _settle();
        RecordV2 memory r = _rec(n);
        assertEq(r.inflow, 0, "the new revenue is not inflow");
        assertEq(_in(n).tax, 0, "the chip sees TAX = 0");
        assertEq(r.allow, 0);
        assertEq(r.buyExecuted, 0);

        _revenue(1);
        uint256 before = _qbal(payee);
        kernel.withdrawCredit(payee, address(usdt));
        assertEq(_qbal(payee) - before, credit, "the payee is paid in full, out of the new revenue");
        assertEq(_qbal(address(kernel)), 0);

        _revenue(2e6); // from here on revenue is inflow again
        _nextEpoch();
        n = _settle();
        assertEq(_rec(n).inflow, 2e6);
        // the destroyed USD0 counts as having arrived, so the lifetime bound still holds against all arrivals
        assertLe(uint256(kernel.allowPaidCum()) * 10_000, uint256(kernel.cumInflow()) * 2500, "allowCumBps");
    }
}
