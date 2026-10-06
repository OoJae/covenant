// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";

/// @dev A quote token that reports success but moves only part of what it is asked to (or nothing).
contract LyingQuote {
    mapping(address => uint256) public balanceOf;
    uint8 public mode; // 0 honest, 1 returns true and moves nothing, 2 moves one unit less, 3 returns false

    function set(uint8 m) external {
        mode = m;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (mode == 3) return false;
        if (mode == 1) return true;
        uint256 moved = mode == 2 ? a - 1 : a;
        balanceOf[msg.sender] -= moved;
        balanceOf[to] += moved;
        return true;
    }
}

/// @notice Allowance credits in USD₮0: anyone may trigger a withdrawal, only the payee is paid, and a withdrawal
///         completes only if the kernel's balance fell by exactly the credit (never trusting a return value).
contract CreditsV2Test is BaseV2 {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
        _buy(alice, 200e6);
        _revenue(4e6);
        _nextEpoch();
        _settle();
    }

    function test_anyone_may_call_and_only_the_payee_is_paid() public {
        uint256 credit = kernel.creditOf(payee, address(usdt));
        assertGt(credit, 0);
        vm.prank(bob);
        assertEq(kernel.withdrawCredit(payee, address(usdt)), credit);
        assertEq(_qbal(payee), credit);
        assertEq(_qbal(bob), 0);
        assertEq(kernel.creditOf(payee, address(usdt)), 0);
        assertEq(kernel.totalCredits(address(usdt)), 0);
    }

    function test_withdraw_with_no_credit_returns_zero_and_calls_nothing() public {
        vm.prank(bob);
        assertEq(kernel.withdrawCredit(bob, address(usdt)), 0);
        assertEq(kernel.withdrawCredit(payee, address(0)), 0, "there are no native credits in kernel v2");
        assertEq(kernel.withdrawCredit(payee, address(token)), 0);
    }

    function test_withdraw_cannot_take_the_reserve() public {
        uint256 credit = kernel.creditOf(payee, address(usdt));
        uint256 reserve0 = kernel.reserve();
        kernel.withdrawCredit(payee, address(usdt));
        assertEq(_qbal(address(kernel)), reserve0, "the reserve stays");
        assertEq(kernel.withdrawCredit(payee, address(usdt)), 0, "nothing twice");
        assertEq(_qbal(payee), credit);
    }

    function test_credits_accumulate_and_survive_later_settles() public {
        uint256 c1 = kernel.creditOf(payee, address(usdt));
        _revenue(4e6);
        _nextEpoch();
        _settle();
        uint256 c2 = kernel.creditOf(payee, address(usdt));
        assertGt(c2, c1);
        for (uint256 i = 0; i < 5; i++) {
            _nextEpoch();
            _settle();
        }
        assertGe(kernel.creditOf(payee, address(usdt)), c2);
        assertEq(kernel.totalCredits(address(usdt)), kernel.creditOf(payee, address(usdt)));
    }

    function test_a_failing_transfer_reverts_and_keeps_the_credit() public {
        uint256 credit = kernel.creditOf(payee, address(usdt));
        usdt.setFailure(false, true, false, false);
        vm.expectRevert(KernelV2.PayFailed.selector);
        kernel.withdrawCredit(payee, address(usdt));
        assertEq(kernel.creditOf(payee, address(usdt)), credit);
        usdt.setFailure(false, false, false, false);
        assertEq(kernel.withdrawCredit(payee, address(usdt)), credit);
    }

    function test_unreadable_balance_reverts_and_keeps_the_credit() public {
        uint256 credit = kernel.creditOf(payee, address(usdt));
        usdt.setFailure(true, false, false, false);
        vm.expectRevert(KernelV2.PayFailed.selector);
        kernel.withdrawCredit(payee, address(usdt));
        assertEq(kernel.creditOf(payee, address(usdt)), credit);
    }

    function test_a_fee_on_transfer_still_pays_the_credit_exactly_from_the_kernels_side() public {
        uint256 credit = kernel.creditOf(payee, address(usdt));
        usdt.setFeeBps(10);
        assertEq(kernel.withdrawCredit(payee, address(usdt)), credit);
        assertEq(_qbal(payee), credit - (credit * 10) / 10_000, "the payee bears the fee; the books are exact");
        assertEq(_qbal(address(kernel)), kernel.reserve());
    }

    function test_under_gassed_withdraw_reverts_as_a_whole() public {
        uint256 credit = kernel.creditOf(payee, address(usdt));
        (bool ok,) = address(kernel).call{gas: 60_000}(
            abi.encodeCall(KernelV2.withdrawCredit, (payee, address(usdt)))
        );
        assertFalse(ok);
        assertEq(kernel.creditOf(payee, address(usdt)), credit);
    }

    /// A token whose transfer lies (returns true and moves nothing, or moves less) cannot clear a credit: the
    /// balance delta decides. Reached with a clone outside the factory whose quote pin is that token.
    function test_return_values_are_not_trusted() public {
        LyingQuote lq = new LyingQuote();
        // a kernel that holds a credit in `lq`: copy this kernel's storage layout by hand is not needed; instead
        // pay the payee's credit slot directly in a fresh kernel's storage
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, _env(), 300, bytes32("lying"));
        KernelV2 k = b.kernel;
        // credit `payee` 1,000 units of `lq` (mapping _credit at slot 8, totalCredits at slot 9)
        bytes32 inner = keccak256(abi.encode(payee, uint256(8)));
        vm.store(address(k), keccak256(abi.encode(address(lq), inner)), bytes32(uint256(1000)));
        vm.store(address(k), keccak256(abi.encode(address(lq), uint256(9))), bytes32(uint256(1000)));
        assertEq(k.creditOf(payee, address(lq)), 1000, "slot layout");
        assertEq(k.totalCredits(address(lq)), 1000);
        lq.mint(address(k), 1000);
        for (uint8 m = 1; m <= 3; m++) {
            lq.set(m);
            vm.expectRevert(KernelV2.PayFailed.selector);
            k.withdrawCredit(payee, address(lq));
            assertEq(k.creditOf(payee, address(lq)), 1000);
        }
        lq.set(0);
        assertEq(k.withdrawCredit(payee, address(lq)), 1000);
        assertEq(lq.balanceOf(payee), 1000);
    }
}
