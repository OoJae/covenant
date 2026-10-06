// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {Record, Envelope, RecordFlags, IKernelV1, IKernelMin} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel} from "../mocks/MockTapeOut.sol";

/// @dev A payee contract like the KeeperTank: its receive() needs a lot of gas and probes the sender.
contract HungryPayee {
    uint256 public received;
    uint256 public probedChip;

    receive() external payable {
        require(gasleft() >= 200_000, "needs 200k");
        probedChip = IKernelMin(msg.sender).chipId(); // a view call back into the kernel, as the tank does
        received += msg.value;
    }
}

contract RefusingPayee {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    receive() external payable {
        require(accept, "no");
    }
}

/// @dev A payee that tries to take its credit twice, or to settle, from inside the payment.
contract ReentrantPayee {
    Kernel public kernel;
    bool public triedWithdraw;
    bool public triedSettle;
    bool public withdrawWorked;
    bool public settleWorked;

    function arm(Kernel k) external {
        kernel = k;
    }

    receive() external payable {
        triedWithdraw = true;
        (withdrawWorked,) = address(kernel).call(abi.encodeCall(IKernelV1.withdrawCredit, (address(this), address(0))));
        triedSettle = true;
        (settleWorked,) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
    }
}

/// @notice Pull credits: who is credited, who can withdraw, what a refusing or hostile payee can do.
contract CreditsTest is Base {
    bytes14 internal W = _word(128, 64, 48, 16, 0, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    function _fund() internal returns (uint256 credit) {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        credit = kernel.creditOf(payee, NATIVE);
        assertEq(credit, (0.3 ether * 48) / 256);
    }

    function test_anyone_may_call_and_only_the_payee_is_paid() public {
        uint256 credit = _fund();
        uint256 bobBefore = bob.balance;
        vm.expectEmit(true, true, false, true, address(kernel));
        emit Kernel.CreditWithdrawn(payee, NATIVE, credit);
        vm.prank(bob);
        uint256 paid = kernel.withdrawCredit(payee, NATIVE);
        assertEq(paid, credit);
        assertEq(payee.balance, credit, "the payee got it");
        assertEq(bob.balance, bobBefore, "the caller got nothing");
        assertEq(kernel.creditOf(payee, NATIVE), 0);
        assertEq(kernel.totalCredits(NATIVE), 0);
        assertEq(address(kernel).balance, kernel.reserve(), "what is left is the reserve");
    }

    function test_withdraw_with_no_credit_returns_zero_and_calls_nothing() public {
        _fund();
        assertEq(kernel.withdrawCredit(bob, NATIVE), 0);
        // an arbitrary "asset" address is never called: there is no credit in it
        address trap = makeAddr("trap");
        vm.etch(trap, hex"fe"); // INVALID: any call to it would fail loudly
        assertEq(kernel.withdrawCredit(payee, trap), 0);
        assertEq(kernel.withdrawCredit(trap, trap), 0);
    }

    function test_withdraw_cannot_take_the_reserve_or_another_payees_credit() public {
        uint256 credit = _fund();
        uint256 reserve = kernel.reserve();
        assertGt(reserve, 0);
        kernel.withdrawCredit(payee, NATIVE);
        kernel.withdrawCredit(payee, NATIVE); // again: nothing
        assertEq(payee.balance, credit);
        assertEq(address(kernel).balance, reserve, "the reserve is untouched");
        // the launcher, the keeper and the sink have no claim at all
        assertEq(kernel.withdrawCredit(launcher, NATIVE), 0);
        assertEq(kernel.withdrawCredit(keeper, NATIVE), 0);
        assertEq(kernel.withdrawCredit(address(0), NATIVE), 0);
    }

    function test_refusing_payee_reverts_and_keeps_its_credit() public {
        RefusingPayee rp = new RefusingPayee();
        Envelope memory e = _env();
        e.allowancePayee = address(rp);
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("refuse"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle(); // crediting never calls the payee: a refusing payee cannot block a settle
        uint256 credit = kernel.creditOf(address(rp), NATIVE);
        assertGt(credit, 0);
        vm.expectRevert(Kernel.PayFailed.selector);
        kernel.withdrawCredit(address(rp), NATIVE);
        assertEq(kernel.creditOf(address(rp), NATIVE), credit, "still owed");
        rp.setAccept(true);
        assertEq(kernel.withdrawCredit(address(rp), NATIVE), credit);
        assertEq(address(rp).balance, credit);
    }

    function test_contract_payee_gets_enough_gas_and_can_read_the_kernel() public {
        HungryPayee hp = new HungryPayee();
        Envelope memory e = _env();
        e.allowancePayee = address(hp);
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("tank"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        uint256 credit = kernel.creditOf(address(hp), NATIVE);
        kernel.withdrawCredit(address(hp), NATIVE);
        assertEq(hp.received(), credit);
        assertEq(hp.probedChip(), b.chipId, "chipId() is readable from inside the payment");
    }

    function test_under_gassed_withdraw_reverts_as_a_whole() public {
        HungryPayee hp = new HungryPayee();
        Envelope memory e = _env();
        e.allowancePayee = address(hp);
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("tank2"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        uint256 credit = kernel.creditOf(address(hp), NATIVE);
        (bool ok,) = address(kernel).call{gas: 150_000}(abi.encodeCall(IKernelV1.withdrawCredit, (address(hp), NATIVE)));
        assertFalse(ok);
        assertEq(kernel.creditOf(address(hp), NATIVE), credit, "nothing was lost");
    }

    function test_payee_cannot_reenter() public {
        ReentrantPayee rp = new ReentrantPayee();
        Envelope memory e = _env();
        e.allowancePayee = address(rp);
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("reenter"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        rp.arm(kernel);
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        _buy(alice, 10 ether);
        _nextEpoch(); // a settle is due: the payee will try to run it from inside its payment
        uint256 credit = kernel.creditOf(address(rp), NATIVE);
        uint256 balBefore = address(kernel).balance;
        kernel.withdrawCredit(address(rp), NATIVE);
        assertTrue(rp.triedWithdraw() && rp.triedSettle());
        assertFalse(rp.withdrawWorked(), "no second withdrawal from inside the first");
        assertFalse(rp.settleWorked(), "no settle from inside a withdrawal");
        assertEq(address(rp).balance, credit, "paid exactly once");
        assertEq(address(kernel).balance, balBefore - credit);
        assertEq(kernel.count(), 1);
    }

    function test_credits_accumulate_across_settles() public {
        uint256 c1 = _fund();
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertEq(kernel.creditOf(payee, NATIVE), c1 + r.allow);
        assertEq(kernel.totalCredits(NATIVE), c1 + r.allow);
        assertGe(address(kernel).balance, kernel.totalCredits(NATIVE) + kernel.reserve());
    }

    function test_a_credit_survives_any_number_of_later_settles() public {
        uint256 credit = _fund();
        // the chip, the reserve and the buys can never touch money that is already credited
        for (uint256 i = 0; i < 10; i++) {
            _nextEpoch();
            _settle();
        }
        assertGe(kernel.creditOf(payee, NATIVE), credit);
        uint256 owed = kernel.creditOf(payee, NATIVE);
        assertGe(address(kernel).balance, owed);
        kernel.withdrawCredit(payee, NATIVE);
        assertEq(payee.balance, owed);
    }
}
