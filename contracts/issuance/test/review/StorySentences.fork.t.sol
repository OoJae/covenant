// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {XLayerFork} from "../fork/XLayerFork.sol";
import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {IKernelMin} from "../../src/interfaces/IKernelMin.sol";
import {ICircuits, ITransistors} from "../../src/interfaces/ITapeOut.sol";
import {MockKernel} from "../mocks/MockKernel.sol";

// Review tests (story lens). Each test takes one sentence of the on-chain story and runs it against the real
// TapeOut factory (and, for what a kernel does inside settle(), the real IgnixManager) at the pinned block.
//
// They were written against the first story. What they found is why the story now reads as it does:
//   - "(refunds settlement gas per chip, never more than the gas spent)" was not true of the gas a caller is
//     billed for. The three refund tests below still show a caller ending ahead; the story now says "refunds
//     the gas of a chip's settlements, up to that chip's prepaid allowance", which they do not contradict.
//   - a tip of half the base fee was refunded in full; MAX_TIP is now 0.001 gwei and the tip test shows 5%.
//   - anyone could list itself in the registry; the registry test now shows that it cannot.
// The tests of the launchpad socket's sentence went with the socket (NOTES.md, section 9).

interface IManagerMin {
    function buyTo(address token, uint256 amountIn, uint256 minTokensOut, address recipient) external payable;
    function pairOf(address token) external view returns (address);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @dev An honest-looking kernel: settle() is protected by OpenZeppelin's classic (storage) ReentrancyGuard
///      and does one unit of bookkeeping. Nothing here is hostile.
contract GuardedKernel is IKernelMin, ReentrancyGuard {
    uint256 internal immutable CHIP;
    uint256 public settles;

    constructor(uint256 chip) {
        CHIP = chip;
        settles = 1; // so that steady-state writes are nonzero -> nonzero
    }

    function chipId() external view returns (uint256) {
        return CHIP;
    }

    function settle() external nonReentrant returns (uint32) {
        return uint32(++settles);
    }
}

/// @dev What the real kernel's curve leg does: one IgnixManager.buyTo to itself, with OKB it already holds.
contract BuyingKernel is IKernelMin {
    uint256 internal immutable CHIP;
    address internal immutable MANAGER;
    address internal immutable TOKEN;
    uint256 public settles;

    constructor(uint256 chip, address manager, address token) payable {
        CHIP = chip;
        MANAGER = manager;
        TOKEN = token;
        settles = 1;
    }

    function chipId() external view returns (uint256) {
        return CHIP;
    }

    function settle() external returns (uint32) {
        IManagerMin(MANAGER).buyTo{value: 0.001 ether}(TOKEN, 0.001 ether, 0, address(this));
        return uint32(++settles);
    }

    receive() external payable {}
}

/// @dev Hostile: odd settlements write N slots (the tank pays for the writes), even ones clear them.
contract FlipFlopKernel is IKernelMin {
    uint256 internal immutable CHIP;
    uint256 internal immutable N;
    uint256 public settles;
    mapping(uint256 => uint256) internal junk;

    constructor(uint256 chip, uint256 n) {
        CHIP = chip;
        N = n;
    }

    function chipId() external view returns (uint256) {
        return CHIP;
    }

    function settle() external returns (uint32) {
        uint256 v = settles % 2 == 0 ? 1 : 0;
        for (uint256 i = 0; i < N; i++) {
            junk[i] = v;
        }
        return uint32(++settles);
    }
}

contract StorySentencesForkTest is XLayerFork {
    /// @dev IgnixManager, the IGNIX launchpad: what the real kernel's curve leg calls inside settle().
    address internal constant IGNIX_MANAGER = 0x96B51c57e5346D0C0198899243cf851D1E23C309;
    // live pre-graduation IGNIX token quoted in native OKB (contracts/probes/test/ProbeBase.sol: OB_TOKEN)
    address internal constant OB_TOKEN = 0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe;

    function setUp() public {
        _forkAndIgnite();
    }

    function _chipTo(address kernel, uint256 chipId) internal {
        vm.prank(user);
        circuits.transferFrom(user, kernel, chipId);
    }

    function _log(string memory tag, Settled memory r) internal view {
        console2.log(tag);
        console2.log("   tx gas consumed            ", r.txGas);
        console2.log("   tx gas billed (after 3529) ", r.txGasBilled);
        console2.log("   gas counted by the tank    ", r.gasCounted);
        console2.log("   caller paid for gas (wei)  ", r.txGasBilled * gasPrice);
        console2.log("   tank paid the caller (wei) ", r.paid);
        if (r.paid >= r.txGasBilled * gasPrice) {
            console2.log("   CALLER AHEAD BY (wei)      ", r.paid - r.txGasBilled * gasPrice);
            console2.log("   CALLER AHEAD BY (gas)      ", (r.paid - r.txGasBilled * gasPrice) / gasPrice);
        } else {
            console2.log("   caller short by (wei)      ", r.txGasBilled * gasPrice - r.paid);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // "SUPPLY 67,108,864 (2^26), fixed; NAND and LATCH share the cap; burned transistors are never
    //  re-minted." + "No per-wallet cap"
    // ---------------------------------------------------------------------------------------------
    function test_review_supplyIsShared_andBurnedIsNeverReminted_onTheLiveLogic() public {
        uint256 cap = transistors.supplyCap();
        assertEq(cap, 67_108_864);
        assertEq(cap, 2 ** 26);

        // one wallet buys the whole supply: 67,108,859 NAND and 5 LATCH (no per-wallet cap)
        _mint(user, 0, cap - 5);
        _mint(user, 1, 5);
        assertEq(transistors.minted(), cap);
        assertEq(transistors.balanceOf(user, 0), cap - 5);

        // the cap is shared: neither type can be minted any more
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(bytes("supply cap"));
        transistors.mint{value: PRICE + PROTOCOL_FEE}(0, 1);
        vm.prank(user);
        vm.expectRevert(bytes("supply cap"));
        transistors.mint{value: PRICE + PROTOCOL_FEE}(1, 1);

        // burn three by taping out
        vm.prank(user);
        uint256 chipId = circuits.tapeout{value: TAPEOUT_FEE}(NAND3, 2, 1);
        assertEq(transistors.balanceOf(user, 0), cap - 8, "three NAND burned");
        assertEq(tank.burnedOf(chipId), 3);

        // the burn frees nothing
        assertEq(transistors.minted(), cap, "minted does not go down on burn");
        vm.prank(user);
        vm.expectRevert(bytes("supply cap"));
        transistors.mint{value: PRICE + PROTOCOL_FEE}(0, 1);
        vm.prank(user);
        vm.expectRevert(bytes("supply cap"));
        transistors.mint{value: PRICE + PROTOCOL_FEE}(1, 1);

        // and the whole supply pays out 85 / 15 with no dust at all
        splitter.pull();
        uint256 proceeds = cap * PRICE;
        assertEq(address(tank).balance, proceeds * 85 / 100);
        assertEq(maintainer.balance, proceeds * 15 / 100);
        assertEq(proceeds * 85 % 100, 0);
        console2.log("whole supply proceeds (wei)", proceeds);
    }

    // ---------------------------------------------------------------------------------------------
    // First story: "(refunds settlement gas per chip, never more than the gas spent)".
    // Now: "refunds the gas of a chip's settlements, up to that chip's prepaid allowance".
    // ---------------------------------------------------------------------------------------------

    /// One classic reentrancy guard inside settle() is enough: the caller receives more than the
    /// transaction cost it.
    function test_review_refund_oneClassicReentrancyGuard_callerReceivesMoreThanItPaid() public {
        uint256 chipId = _tapeoutNand3(user);
        GuardedKernel kernel = new GuardedKernel(chipId);
        _chipTo(address(kernel), chipId);
        splitter.pull();

        Settled memory first = _settleAs(keeper, address(kernel));
        _log("guarded kernel, first settlement of the chip", first);
        Settled memory second = _settleAs(keeper, address(kernel));
        _log("guarded kernel, steady state", second);

        assertEq(second.paid, second.gasCounted * gasPrice, "allowance and balance are not the binding limit");
        assertGt(second.paid, second.txGasBilled * gasPrice, "the caller is paid more than the gas cost it");
        // by the 2,800 gas the EVM gives back for the guard, less the 602 gas and the calldata the tank
        // never counts
        assertEq(second.txGas - second.txGasBilled, 2_800, "one storage reentrancy guard: 2,800 gas given back");
        assertLe(first.paid + second.paid, tank.allowanceOf(chipId), "the bound that holds: the allowance");
    }

    /// The real kernel's curve leg is one IgnixManager.buyTo. IgnixManager guards it with OpenZeppelin's
    /// storage ReentrancyGuardUpgradeable, which earns an EIP-3529 refund inside the measured window.
    function test_review_refund_realIgnixBuyInsideSettle_callerReceivesMoreThanItPaid() public {
        assertEq(IManagerMin(IGNIX_MANAGER).pairOf(OB_TOKEN), address(0), "OB is still on the curve");
        uint256 chipId = _tapeoutNand3(user);
        BuyingKernel kernel = new BuyingKernel(chipId, IGNIX_MANAGER, OB_TOKEN);
        vm.deal(address(kernel), 1 ether);
        _chipTo(address(kernel), chipId);
        splitter.pull();

        Settled memory first = _settleAs(keeper, address(kernel));
        _log("buying kernel, first settlement of the chip", first);
        assertGt(IERC20Min(OB_TOKEN).balanceOf(address(kernel)), 0, "the buy really happened");
        Settled memory second = _settleAs(keeper, address(kernel));
        _log("buying kernel, steady state", second);

        assertEq(second.paid, second.gasCounted * gasPrice, "allowance and balance are not the binding limit");
        assertGt(second.paid, second.txGasBilled * gasPrice, "the caller is paid more than the gas cost it");
    }

    /// A kernel that writes storage in one settlement (paid for by the tank) and clears it in the next.
    function test_review_refund_flipFlopKernel_callerProfitsAQuarterOnEveryOtherSettlement() public {
        uint256 chipId = _tapeoutNand3(user);
        FlipFlopKernel kernel = new FlipFlopKernel(chipId, 100);
        _chipTo(address(kernel), chipId);
        splitter.pull();
        vm.prank(user);
        tank.topUp{value: 0.01 ether}(chipId);

        uint256 paid;
        uint256 cost;
        for (uint256 i = 0; i < 6; i++) {
            Settled memory r = _settleAs(keeper, address(kernel));
            _log(i % 2 == 0 ? "flip-flop kernel: WRITE settlement" : "flip-flop kernel: CLEAR settlement", r);
            paid += r.paid;
            cost += r.txGasBilled * gasPrice;
            if (i % 2 == 1) {
                assertGt(r.paid * 100, r.txGasBilled * gasPrice * 120, "more than 20% above what it cost");
            }
        }
        console2.log("six settlements: caller paid for gas (wei)", cost);
        console2.log("six settlements: tank paid caller (wei)   ", paid);
        console2.log("six settlements: caller net profit (wei)  ", paid - cost);
        assertGt(paid, cost, "over the whole sequence the caller receives more than it paid");
        assertEq(keeper.balance, paid);
    }

    /// The tip. When it was reviewed, MAX_TIP was 0.01 gwei, half of X Layer's base fee: a caller who paid
    /// that tip got it back, and the chip's allowance drained 1.5 times as fast as with the usual 1 wei tip,
    /// at no cost to that caller. MAX_TIP is now 0.001 gwei: the same caller is refunded 5% above the base
    /// fee and pays the rest of its tip itself.
    function test_review_refund_maxTip_noLongerDrainsTheAllowanceHalfAgainFaster() public {
        uint256 chipId = _tapeoutNand3(user);
        MockKernel kernel = new MockKernel(chipId);
        _chipTo(address(kernel), chipId);
        splitter.pull();
        _settleAs(keeper, address(kernel)); // first settlement out of the way
        assertEq(tank.MAX_TIP(), 0.001 gwei);

        Settled memory usual = _settleAs(keeper, address(kernel));
        vm.txGasPrice(block.basefee + 0.01 gwei);
        Settled memory tipped = _settleAs(keeper, address(kernel));
        vm.txGasPrice(gasPrice);

        console2.log("refund with a 1 wei tip (wei)    ", usual.paid);
        console2.log("refund with a 0.01 gwei tip (wei)", tipped.paid);
        console2.log("gas counted, 1 wei tip / 0.01 gwei tip", usual.gasCounted, tipped.gasCounted);
        console2.log("tx gas billed, 1 wei tip / 0.01 gwei tip", usual.txGasBilled, tipped.txGasBilled);
        assertEq(tipped.paid, tipped.gasCounted * (block.basefee + 0.001 gwei), "refunded at the cap");
        assertLt(tipped.paid * 100, usual.paid * 106, "about 5% more than with a 1 wei tip, not 50%");
        assertGt(tipped.paid * 100, usual.paid * 104);
        // and the tip is no longer free: the caller is out of pocket by at least 0.009 gwei per unit of gas
        assertLe(
            tipped.paid + tipped.txGasBilled * 0.009 gwei,
            tipped.txGasBilled * (block.basefee + 0.01 gwei),
            "the tipping caller pays for its own tip"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // First story: "Team wallets self-declare in registry ...".
    // Now: "Team wallets are listed in registry ...: the deployer, then wallets that a listed wallet invited
    //       and that declared themselves."
    // ---------------------------------------------------------------------------------------------

    function test_review_registry_aWalletCanNoLongerListItselfAsTeam() public {
        address impostor = makeAddr("impostor");

        // when it was reviewed the impostor got there first, with the role the real team would use
        vm.prank(impostor);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare("maintainer");
        assertFalse(registry.isTeam(impostor));

        // the maintainer of this test is not the deployer, so it is not listed either until it is invited
        vm.prank(maintainer);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare("maintainer");

        // the deployer (this test contract sent the creation) is entry 0 and is what links the list to the team
        (address w0, string memory r0,) = registry.at(0);
        assertEq(w0, address(this));
        assertEq(r0, "deployer");
        registry.invite(maintainer);
        vm.prank(maintainer);
        registry.declare("maintainer");

        assertTrue(registry.isTeam(maintainer));
        (address w1, string memory r1,) = registry.at(1);
        assertEq(w1, maintainer);
        assertEq(r1, "maintainer");
        assertEq(registry.count(), 2);
        assertEq(splitter.MAINTAINER(), maintainer);
    }
}
