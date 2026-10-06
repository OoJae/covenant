// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {KernelV2} from "../../src/KernelV2.sol";
import {LensV2} from "../../src/LensV2.sol";
import {RecordV2} from "../../src/interfaces/IKernelV2.sol";
import {Envelope, RecordFlags, IKernelMin} from "core/interfaces/IKernelV1.sol";
import {MockToken, MockPair} from "core-test/mocks/MockIgnix.sol";
import {MockBeacon, MockCircuits, MockSealedVM} from "core-test/mocks/MockTapeOut.sol";
import {MockUSDT0, MockVaultV2, MockManagerV2, MockRouterV2} from "../mocks/MockIgnixV2.sol";

interface IBal {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Settles a kernel from inside the Manager's lock or a flash swap on the token/USD₮0 pair.
contract LockProbeV2 {
    address internal kernel;
    address internal q;
    uint256 internal gasLimit;
    bool public attempted;
    bool public ok;
    bytes public ret;

    function insideManager(MockManagerV2 m, address kernel_, uint256 gasLimit_) external {
        (kernel, gasLimit, attempted) = (kernel_, gasLimit_, false);
        m.withLock(address(this), abi.encodeCall(this.settleNow, ()));
    }

    function insidePair(MockPair pair, address quote_, uint256 quoteOut, address kernel_, uint256 gasLimit_) external {
        (kernel, gasLimit, attempted, q) = (kernel_, gasLimit_, false, quote_);
        bool quoteIs0 = pair.token0() == quote_;
        pair.swap(quoteIs0 ? quoteOut : 0, quoteIs0 ? 0 : quoteOut, address(this), hex"01");
    }

    function settleNow() public {
        attempted = true;
        (ok, ret) = kernel.call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        settleNow();
        uint256 borrowed = amount0 + amount1;
        MockUSDT0(q).transfer(msg.sender, borrowed + (borrowed * 3) / 997 + 1);
    }
}

/// @notice Drives several v2 kernels through random trades, revenue from an unrelated payer, time, settles with
///         random gas limits, settles under a held lock, third-party claims, donations, forced OKB, graduation and
///         every failure switch of the doubles (USD₮0's included). Checks that need a before/after comparison are
///         made around each action; a failed check is recorded (never reverted) and surfaces as `violations()`.
contract HandlerV2 is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant CALL_GAS = 8_000_000;

    struct Ctx {
        KernelV2 kernel;
        MockToken token;
        MockVaultV2 vault;
        Envelope env;
        uint256 chipId;
        bytes netlist;
        bool tampered;
        uint256 forcedOkb; // native OKB forced into the kernel, which it can never move
    }

    Ctx[] internal ctxs;
    MockUSDT0 internal usdt;
    MockManagerV2 internal manager;
    MockRouterV2 internal router;
    MockCircuits internal circuits;
    MockSealedVM internal sealedVM;
    MockBeacon internal beacon;
    address internal impl;
    address internal implV2;
    LensV2 internal lens;

    address[] internal actors;
    address internal whale;
    address internal payer;
    LockProbeV2 internal probe;
    bool public quoteFaulty; // a USD₮0 fault is on: balance-based route checks are skipped

    uint256 public violations;
    string public lastViolation;
    uint256 public settlesOk;
    uint256 public settlesGraduated;
    uint256 public settlesFallback;
    uint256 public settlesSealed;
    uint256 public settlesStepFailed;
    uint256 public settlesGasReverted;
    uint256 public buysExecuted;
    uint256 public swapsExecuted;
    uint256 public revenuePaid;
    uint256 public replays;
    uint256 public lockedSettlesSame;
    uint256 public lockedSettlesReverted;
    uint256 public settlesBlind; // settles with a balance unreadable
    uint256 public settlesBlindRegime; // ... the regime asset's balance
    mapping(address => uint32) public lastRecordEpoch;

    address internal immutable owner = msg.sender;

    constructor(
        MockUSDT0 usdt_,
        MockManagerV2 manager_,
        MockRouterV2 router_,
        MockCircuits circuits_,
        MockSealedVM sealedVM_,
        MockBeacon beacon_,
        address impl_,
        address implV2_,
        LensV2 lens_
    ) {
        usdt = usdt_;
        manager = manager_;
        router = router_;
        circuits = circuits_;
        sealedVM = sealedVM_;
        beacon = beacon_;
        impl = impl_;
        implV2 = implV2_;
        lens = lens_;
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        whale = makeAddr("whale");
        payer = makeAddr("x402 buyer (unrelated to the team)");
        probe = new LockProbeV2();
    }

    function add(KernelV2 k, MockToken t, MockVaultV2 v, Envelope memory e, uint256 chipId, bytes memory nl) external {
        require(msg.sender == owner, "setup only");
        ctxs.push(Ctx(k, t, v, e, chipId, nl, false, 0));
    }

    function count() external view returns (uint256) {
        return ctxs.length;
    }

    function ctx(uint256 i) external view returns (Ctx memory) {
        return ctxs[i];
    }

    function _fail(string memory why) internal {
        violations++;
        lastViolation = why;
    }

    function _ctx(uint256 seed) internal view returns (Ctx storage) {
        return ctxs[seed % ctxs.length];
    }

    function _readable(Ctx storage c) internal view returns (bool) {
        return !usdt.balanceOfReverts() && !c.token.balanceOfReverts();
    }

    // ================================================================== market

    function trade(uint256 k, uint256 actorSeed, uint256 amount, bool isBuy) public {
        Ctx storage c = _ctx(k);
        if (!_readable(c)) return;
        address a = actors[actorSeed % actors.length];
        uint256 q0 = usdt.balanceOf(address(c.kernel));
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        address pair = c.token.pairAddr();
        if (isBuy) {
            amount = bound(amount, 1e4, 400e6);
            usdt.mint(a, amount);
            vm.startPrank(a);
            if (pair == address(0)) {
                try usdt.approve(address(manager), amount) {} catch {}
                try manager.buy{gas: CALL_GAS}(address(c.token), amount, 0) {} catch {}
            } else {
                try usdt.approve(address(router), amount) {} catch {}
                try router.swapExactTokensForTokensSupportingFeeOnTransferTokens{gas: CALL_GAS}(
                    amount, 0, _path(address(usdt), address(c.token)), a, block.timestamp
                ) {} catch {}
            }
            vm.stopPrank();
        } else {
            uint256 bal = c.token.balanceOf(a);
            if (bal == 0) return;
            amount = bound(amount, 1, bal);
            vm.startPrank(a);
            if (pair == address(0)) {
                c.token.approve(address(manager), amount);
                try manager.sell{gas: CALL_GAS}(address(c.token), amount, 0) {} catch {}
            } else {
                c.token.approve(address(router), amount);
                try router.swapExactTokensForTokensSupportingFeeOnTransferTokens{gas: CALL_GAS}(
                    amount, 0, _path(address(c.token), address(usdt)), a, block.timestamp
                ) {} catch {}
            }
            vm.stopPrank();
        }
        _noOutflow(c, q0, t0, "trade");
    }

    function tradeBuy(uint256 k, uint256 actorSeed, uint256 amount) external {
        trade(k, actorSeed, amount, true);
    }

    function graduate(uint256 k) external {
        Ctx storage c = _ctx(k);
        if (c.token.pairAddr() != address(0) || !_readable(c)) return;
        uint256 q0 = usdt.balanceOf(address(c.kernel));
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        uint256 cost = 20_000e6; // more than any curve can cost; the Manager refunds the excess
        usdt.mint(whale, cost);
        vm.startPrank(whale);
        try usdt.approve(address(manager), cost) {} catch {}
        try manager.buy{gas: CALL_GAS}(address(c.token), cost, 0) {} catch {}
        vm.stopPrank();
        _noOutflow(c, q0, t0, "graduate");
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 * 900));
    }

    // ================================================================== third parties

    /// Revenue: a USD₮0 payment to the kernel from an address unrelated to the team (an x402 settlement).
    function revenue(uint256 k, uint256 amount) external {
        Ctx storage c = _ctx(k);
        amount = bound(amount, 1, 50e6);
        usdt.mint(payer, amount);
        vm.prank(payer);
        try usdt.transfer{gas: CALL_GAS}(address(c.kernel), amount) {
            revenuePaid += amount;
        } catch {}
    }

    function claimFor(uint256 k, bool tokenAsset) external {
        Ctx storage c = _ctx(k);
        if (!_readable(c)) return;
        uint256 q0 = usdt.balanceOf(address(c.kernel));
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        vm.prank(actors[0]);
        try c.vault.claimFor{gas: CALL_GAS}(address(c.kernel), tokenAsset ? address(c.token) : address(usdt)) {}
            catch {}
        _noOutflow(c, q0, t0, "claimFor");
    }

    function donateVault(uint256 k, uint256 amount) external {
        Ctx storage c = _ctx(k);
        amount = bound(amount, 1, 20e6);
        usdt.mint(payer, amount);
        vm.prank(payer);
        try usdt.transfer{gas: CALL_GAS}(address(c.vault), amount) {} catch {}
    }

    /// A plain OKB transfer into a kernel must be refused, whoever sends it.
    function plainOkb(uint256 k, uint256 amount, uint256 senderSeed) external {
        Ctx storage c = _ctx(k);
        amount = bound(amount, 1, 5 ether);
        address[4] memory senders = [actors[0], c.env.launcher, c.env.allowancePayee, whale];
        address s = senders[senderSeed % 4];
        vm.deal(s, s.balance + amount);
        uint256 b0 = address(c.kernel).balance;
        vm.prank(s);
        (bool ok,) = address(c.kernel).call{value: amount}("");
        if (ok) _fail("a plain OKB transfer into the kernel was accepted");
        if (address(c.kernel).balance != b0) _fail("kernel OKB balance moved on a refused transfer");
    }

    /// OKB forced in (SELFDESTRUCT, a block reward) cannot be refused; it must never be counted or moved.
    function forceOkb(uint256 k, uint256 amount) external {
        Ctx storage c = _ctx(k);
        amount = bound(amount, 1, 2 ether);
        vm.deal(address(c.kernel), address(c.kernel).balance + amount);
        c.forcedOkb += amount;
    }

    function giftTokens(uint256 k, uint256 amount) external {
        Ctx storage c = _ctx(k);
        if (!_readable(c)) return;
        address a = actors[2];
        uint256 q0 = usdt.balanceOf(address(c.kernel));
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        if (c.token.pairAddr() == address(0)) {
            amount = bound(amount, 1e4, 20e6);
            usdt.mint(a, amount);
            vm.startPrank(a);
            try usdt.approve(address(manager), amount) {} catch {}
            try manager.buyTo{gas: CALL_GAS}(address(c.token), amount, 0, address(c.kernel)) {} catch {}
            vm.stopPrank();
        } else {
            uint256 bal = c.token.balanceOf(a);
            if (bal == 0) return;
            amount = bound(amount, 1, bal);
            vm.prank(a);
            try c.token.transfer{gas: CALL_GAS}(address(c.kernel), amount) {} catch {}
        }
        _noOutflow(c, q0, t0, "giftTokens");
    }

    // ================================================================== credits and locked tokens

    function withdraw(uint256 k, uint256 who, bool tokenAsset) external {
        Ctx storage c = _ctx(k);
        address[4] memory payees = [c.env.allowancePayee, c.env.sink, actors[3], c.env.launcher];
        address p = payees[who % 4];
        address asset = tokenAsset ? address(c.token) : address(usdt);
        uint256 credit = c.kernel.creditOf(p, asset);
        if ((p == actors[3] || p == c.env.launcher) && p != c.env.allowancePayee && p != c.env.sink && credit != 0) {
            _fail("somebody who is neither the allowance payee nor the sink holds a credit");
        }
        uint256 total = c.kernel.totalCredits(asset);
        // balance deltas around the payment (kernel v1's checks), when the asset's balances can be read
        bool readable = tokenAsset ? !c.token.balanceOfReverts() : !usdt.balanceOfReverts();
        uint256 kBefore = readable ? IBal(asset).balanceOf(address(c.kernel)) : 0;
        uint256 pBefore = readable ? IBal(asset).balanceOf(p) : 0;
        vm.prank(actors[0]);
        try c.kernel.withdrawCredit{gas: CALL_GAS}(p, asset) returns (uint256 paid) {
            if (paid != credit) _fail("withdraw paid something other than the credit");
            if (c.kernel.creditOf(p, asset) != 0) _fail("credit not cleared");
            if (c.kernel.totalCredits(asset) != total - paid) _fail("totalCredits not reduced by the payment");
            if (readable && paid != 0) {
                if (IBal(asset).balanceOf(address(c.kernel)) != kBefore - paid) {
                    _fail("kernel paid out more than the credit");
                }
                // a fee on transfer (USD₮0 upgraded to charge one) is taken from what the payee receives
                uint256 fee = tokenAsset ? 0 : (paid * usdt.feeBps()) / 10_000;
                if (IBal(asset).balanceOf(p) != pBefore + paid - fee) _fail("the payee did not receive the credit");
            }
        } catch {
            if (c.kernel.creditOf(p, asset) != credit) _fail("a failed withdrawal changed the credit");
        }
    }

    function burnLocked(uint256 k) external {
        Ctx storage c = _ctx(k);
        if (!_readable(c)) return;
        uint256 locked = c.kernel.lockedTokens();
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        uint256 d0 = c.token.balanceOf(DEAD);
        uint256 q0 = usdt.balanceOf(address(c.kernel));
        try c.kernel.burnLocked{gas: CALL_GAS}() returns (uint256 burned) {
            if (burned != locked) _fail("burnLocked burned something other than the locked tokens");
            if (c.token.balanceOf(address(c.kernel)) != t0 - burned) _fail("burnLocked moved other tokens");
            if (c.token.balanceOf(DEAD) != d0 + burned) _fail("locked tokens did not go to 0xdEaD");
        } catch {
            if (c.kernel.lockedTokens() != locked) _fail("a failed burnLocked changed the books");
        }
        if (usdt.balanceOf(address(c.kernel)) != q0) _fail("burnLocked moved USD0");
    }

    // ================================================================== failure switches

    function faultEvaluator(uint8 mode, bool sealedOne) external {
        mode = mode % 9;
        if (sealedOne) sealedVM.setStepMode(mode);
        else circuits.setStepMode(mode);
    }

    function upgradeBeacon(bool toV2) external {
        beacon.upgradeTo(toV2 ? implV2 : impl);
    }

    function tamperNetlist(uint256 k, bool on) external {
        Ctx storage c = _ctx(k);
        c.tampered = on;
        circuits.rewriteNetlist(c.chipId, on ? bytes.concat(c.netlist, hex"ff") : c.netlist);
    }

    function faultIgnix(uint256 k, uint8 which, uint8 mode) external {
        Ctx storage c = _ctx(k);
        which = which % 9;
        if (which == 0) c.vault.setMode(mode % 4);
        else if (which == 1) manager.setTokensMode(mode % 6);
        else if (which == 2) manager.setBuyMode(mode % 4);
        else if (which == 3) manager.setSnipeReverts(mode % 2 == 1);
        else if (which == 4) manager.setPaused(1, mode % 2 == 1 ? uint64(block.timestamp + 5 * 900) : 0);
        else if (which == 5) manager.setFounderRound(address(c.token), mode % 2 == 1 ? uint64(block.timestamp + 2700) : 0);
        else if (which == 6) router.setMode(mode % 3);
        else if (which == 7) c.token.setFailure(mode % 5 == 1, mode % 5 == 2, mode % 5 == 3, mode % 5 == 4 ? DEAD : address(0));
        else c.token.setPairMode(mode % 4);
    }

    /// USD₮0's own failures: balanceOf, transfer or approve reverting, approve returning false, a fee, a block.
    function faultQuote(uint256 k, uint8 mode) external {
        Ctx storage c = _ctx(k);
        mode = mode % 7;
        usdt.setFailure(mode == 1, mode == 2, mode == 3, mode == 4);
        usdt.setFeeBps(mode == 5 ? 20 : 0);
        if (mode == 6) {
            vm.prank(usdt.owner()); // Tether's owner
            usdt.addToBlockedList(address(c.kernel));
        }
        quoteFaulty = mode != 0;
    }

    function pairFault(uint256 k, bool on) external {
        Ctx storage c = _ctx(k);
        address pair = c.token.pairAddr();
        if (pair != address(0)) MockPair(pair).setReservesRevert(on);
    }

    function clearFaults() public {
        circuits.setStepMode(0);
        sealedVM.setStepMode(0);
        beacon.upgradeTo(impl);
        manager.setTokensMode(0);
        manager.setBuyMode(0);
        manager.setSnipeReverts(false);
        manager.setPaused(1, 0);
        router.setMode(0);
        usdt.setFailure(false, false, false, false);
        usdt.setFeeBps(0);
        quoteFaulty = false;
        for (uint256 i = 0; i < ctxs.length; i++) {
            Ctx storage c = ctxs[i];
            c.vault.setMode(0);
            c.token.setFailure(false, false, false, address(0));
            c.token.setPairMode(0);
            manager.setFounderRound(address(c.token), 0);
            if (usdt.isBlocked(address(c.kernel))) {
                vm.prank(usdt.owner());
                usdt.removeFromBlockedList(address(c.kernel));
            }
            if (c.tampered) {
                c.tampered = false;
                circuits.rewriteNetlist(c.chipId, c.netlist);
            }
            address pair = c.token.pairAddr();
            if (pair != address(0)) MockPair(pair).setReservesRevert(false);
        }
    }

    // ================================================================== settle

    struct Snap {
        uint256 kq; // kernel USD0
        uint256 kt; // kernel tokens
        uint256 vq; // vault USD0
        uint256 vt; // vault tokens
        uint256 mq; // Manager USD0
        uint256 pq; // pair USD0
        uint256 pt; // pair tokens
        uint256 dead;
        uint256 others; // USD0 of everybody else a settle could touch: payee, sink, actors, payer
        uint256 locked;
        uint256 burned;
        uint32 count;
        uint32 epoch;
        uint32 lastStepEpoch;
        bool graduated;
        bytes32 state;
        uint256 okb;
    }

    function _snap(Ctx storage c) internal view returns (Snap memory s) {
        s.kq = usdt.balanceOf(address(c.kernel));
        s.kt = c.token.balanceOf(address(c.kernel));
        s.vq = usdt.balanceOf(address(c.vault));
        s.vt = c.token.balanceOf(address(c.vault));
        s.mq = usdt.balanceOf(address(manager));
        address pair = c.token.pairAddr();
        if (pair != address(0)) {
            s.pq = usdt.balanceOf(pair);
            s.pt = c.token.balanceOf(pair);
        }
        s.dead = c.token.balanceOf(DEAD);
        s.others = usdt.balanceOf(c.env.allowancePayee) + usdt.balanceOf(payer) + usdt.balanceOf(actors[0])
            + (c.env.sink == address(0) ? 0 : usdt.balanceOf(c.env.sink));
        s.locked = c.kernel.lockedTokens();
        s.burned = c.kernel.burnedTokens();
        s.count = c.kernel.count();
        s.epoch = c.kernel.epochNow();
        s.lastStepEpoch = c.kernel.lastStepEpoch();
        s.graduated = c.kernel.graduated();
        s.state = c.kernel.state();
        s.okb = address(c.kernel).balance;
    }

    function _digest(Ctx storage c) internal view returns (bytes32) {
        uint32 n = c.kernel.count();
        (uint128 cum, uint128 paid) = c.kernel.cums(n);
        bytes32 a = keccak256(abi.encode(n, c.kernel.records(n), cum, paid, c.kernel.state(), c.kernel.reserve()));
        bytes32 b = keccak256(
            abi.encode(
                c.kernel.lockedTokens(),
                c.kernel.burnedTokens(),
                c.kernel.graduated(),
                usdt.balanceOf(address(c.kernel)),
                usdt.balanceOf(address(c.vault)),
                usdt.balanceOf(address(manager)),
                c.kernel.totalCredits(address(usdt)),
                c.kernel.totalCredits(address(c.token))
            )
        );
        return keccak256(abi.encode(a, b));
    }

    function settleNow(uint256 k, uint256 gasSeed, bool randomGas) external {
        _settle(k, gasSeed, randomGas);
    }

    function settleNextEpoch(uint256 k, uint256 gasSeed, bool randomGas) external {
        vm.warp(block.timestamp + 900);
        _settle(k, gasSeed, randomGas);
    }

    function settleLater(uint256 k, uint256 gasSeed, bool randomGas, uint256 epochs) external {
        vm.warp(block.timestamp + bound(epochs, 1, 20) * 900 + (gasSeed % 900));
        _settle(k, gasSeed, randomGas);
    }

    function settleAll(uint256 gasSeed) external {
        vm.warp(block.timestamp + 900);
        for (uint256 i = 0; i < ctxs.length; i++) {
            _settle(i, gasSeed, false);
        }
    }

    function settleInsideManager(uint256 k, bool warpFirst) external {
        if (warpFirst) vm.warp(block.timestamp + 900);
        Ctx storage c = _ctx(k);
        if (!_readable(c)) return;
        _settleUnderLock(c, true);
    }

    function settleInsidePair(uint256 k, bool warpFirst) external {
        if (warpFirst) vm.warp(block.timestamp + 900);
        Ctx storage c = _ctx(k);
        if (c.token.pairAddr() == address(0) || !_readable(c)) return;
        _settleUnderLock(c, false);
    }

    function _settleUnderLock(Ctx storage c, bool managerLock) internal {
        Snap memory s = _snap(c);
        uint256 snapId = vm.snapshotState();
        (bool refOk, bytes memory refRet) = _call(c, 60_000_000);
        bytes32 refDigest = refOk ? _digest(c) : bytes32(0);
        vm.revertToState(snapId);
        bool reached;
        if (managerLock) {
            try probe.insideManager{gas: 90_000_000}(manager, address(c.kernel), 60_000_000) {
                reached = true;
            } catch {}
        } else {
            MockPair pair = MockPair(c.token.pairAddr());
            uint256 out = usdt.balanceOf(address(pair)) / 4;
            if (out == 0 || usdt.balanceOfReverts() || usdt.transferReverts() || usdt.feeBps() != 0) return;
            usdt.mint(address(probe), out);
            try probe.insidePair{gas: 90_000_000}(pair, address(usdt), out, address(c.kernel), 60_000_000) {
                reached = true;
            } catch {}
        }
        if (!reached || !probe.attempted()) return;
        bytes memory ret = probe.ret();
        bytes4 err = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        if (probe.ok()) {
            if (!refOk) _fail("a settle under a held lock succeeded where a normal one reverts");
            else if (_digest(c) != refDigest) _fail("a held lock changed what a settle wrote");
            lockedSettlesSame++;
            if (managerLock) {
                _afterSettle(c, s);
            } else {
                // the flash swap moved USD0 through the pair around the settle: the balance route checks do not
                // apply; the record itself was compared with the reference above
                uint32 n = c.kernel.count();
                RecordV2 memory r = c.kernel.records(n);
                if (r.epoch <= lastRecordEpoch[address(c.kernel)]) _fail("two records in one epoch");
                lastRecordEpoch[address(c.kernel)] = r.epoch;
                settlesOk++;
                _replay(c, n);
            }
        } else if (err == KernelV2.LockHeld.selector) {
            if (!refOk) _fail("LockHeld although a normal settle would not have reached a buy");
            if (c.kernel.count() != s.count) _fail("a settle that reverted with LockHeld wrote a record");
            if (managerLock && c.token.pairAddr() != address(0)) _fail("the Manager's lock reverted a graduated settle");
            lockedSettlesReverted++;
        } else {
            bytes4 refErr = refRet.length >= 4 ? bytes4(refRet) : bytes4(0);
            if (refOk || refErr != err) _fail("a settle under a held lock reverted differently from a normal one");
        }
    }

    function _settle(uint256 k, uint256 gasSeed, bool randomGas) internal {
        Ctx storage c = _ctx(k);
        if (!_readable(c)) return _settleBlind(c);
        Snap memory s = _snap(c);

        uint256 snapId = vm.snapshotState();
        (bool refOk, bytes memory refRet) = _call(c, 60_000_000);
        bytes32 refDigest = refOk ? _digest(c) : bytes32(0);
        vm.revertToState(snapId);

        bytes4 refErr = refRet.length >= 4 ? bytes4(refRet) : bytes4(0);
        if (!refOk) {
            bool notDue = refErr == KernelV2.EpochNotElapsed.selector;
            bool inGrace =
                refErr == KernelV2.StepFailed.selector && uint256(s.epoch) - s.lastStepEpoch < c.env.fallbackEpochs;
            if (!notDue && !inGrace) _fail("a funded settle reverted for a reason other than epoch or grace period");
            if (notDue && s.epoch > c.kernel.lastEpoch()) _fail("EpochNotElapsed although a new epoch has begun");
        } else if (s.epoch <= c.kernel.lastEpoch()) {
            _fail("a second settle in one epoch succeeded");
        }

        uint256 gasLimit = randomGas ? bound(gasSeed, 30_000, 14_000_000) : 60_000_000;
        (bool ok, bytes memory ret) = _call(c, gasLimit);
        if (!ok) {
            bytes4 err = ret.length >= 4 ? bytes4(ret) : bytes4(0);
            if (refOk) {
                if (!randomGas) _fail("settle with ample gas diverged from its own reference");
                if (err != KernelV2.InsufficientGas.selector && err != bytes4(0)) {
                    _fail("under-funded settle reverted with something other than a lack of gas");
                }
                settlesGasReverted++;
            } else if (err == KernelV2.StepFailed.selector) {
                settlesStepFailed++;
            }
            if (c.kernel.count() != s.count || c.kernel.state() != s.state) _fail("a reverted settle wrote state");
            return;
        }
        if (!refOk) _fail("a settle succeeded where the amply funded one reverts");
        if (_digest(c) != refDigest) _fail("the gas limit changed the outcome of a settle");
        _afterSettle(c, s);
    }

    /// A settle while a balance cannot be read. When it is the regime asset's balance (USD₮0 on the curve, the
    /// token after graduation) the kernel takes "exactly what the books say": no inflow, the stored reserve kept
    /// whole, the totals unchanged; only an allowance it records (none, with no inflow) or a buy can move them
    /// (INTERFACE-V2 8.1, review B-F2).
    /// One epoch later, a settle while the regime asset's balance (USD₮0 on the curve, the token after graduation)
    /// cannot be read; the switch is then put back as it was. Reaches the "books, not balance" branch of
    /// INTERFACE-V2 8.1 far more often than random faults do (review B-F2).
    function settleUnreadable(uint256 k, bool alsoOther) external {
        Ctx storage c = _ctx(k);
        bool grad = c.kernel.graduated() || c.token.pairAddr() != address(0);
        bool q0 = usdt.balanceOfReverts();
        bool t0 = c.token.balanceOfReverts();
        if (!grad || alsoOther) {
            usdt.setFailure(true, usdt.transferReverts(), usdt.approveReverts(), usdt.approveReturnsFalse());
        }
        if (grad || alsoOther) {
            c.token.setFailure(true, c.token.transferReverts(), c.token.transferReturnsFalse(), c.token.blockedRecipient());
        }
        vm.warp(block.timestamp + c.env.epochLen);
        _settleBlind(c);
        usdt.setFailure(q0, usdt.transferReverts(), usdt.approveReverts(), usdt.approveReturnsFalse());
        c.token.setFailure(t0, c.token.transferReverts(), c.token.transferReturnsFalse(), c.token.blockedRecipient());
    }

    function _settleBlind(Ctx storage c) internal {
        KernelV2 kn = c.kernel;
        BlindSnap memory b = BlindSnap(
            kn.reserve(), kn.cumInflow(), kn.allowPaidCum(), kn.graduated(), kn.count(), kn.lastStepEpoch(), kn.state()
        );
        (bool ok, bytes memory ret) = _call(c, 60_000_000);
        if (!ok) {
            bytes4 err = ret.length >= 4 ? bytes4(ret) : bytes4(0);
            if (err != KernelV2.EpochNotElapsed.selector && err != KernelV2.StepFailed.selector) {
                _fail("a funded settle reverted while a balance was unreadable");
            }
            return;
        }
        settlesBlind++;
        RecordV2 memory r = kn.records(kn.count());
        bool grad = r.flags & RecordFlags.GRADUATED != 0;
        bool latched = grad && !b.graduated; // the latch resets the books of the new regime
        if (r.flags & RecordFlags.FALLBACK != 0) {
            if (r.flags & RecordFlags.SEALED != 0) _fail("flag 2 on a record no evaluator answered");
            if (kn.lastStepEpoch() != b.lastStepEpoch || kn.state() != b.state) {
                _fail("the fallback counted as a persisted step");
            }
        }
        bool regimeUnreadable = grad ? c.token.balanceOfReverts() : usdt.balanceOfReverts();
        if (!regimeUnreadable) return;
        settlesBlindRegime++;
        uint256 reserve0 = latched ? 0 : b.reserve;
        if (r.inflow != 0) _fail("an unreadable balance produced inflow");
        if (r.reserveBefore != reserve0) _fail("an unreadable balance lost reserve");
        if (r.allow != 0) _fail("an allowance without inflow");
        if (kn.cumInflow() != (latched ? 0 : b.cum)) _fail("an unreadable balance changed cumInflow");
        if (kn.allowPaidCum() != (latched ? 0 : b.paid)) _fail("an unreadable balance changed allowPaidCum");
        uint256 left = reserve0 > r.buyExecuted ? reserve0 - r.buyExecuted : 0;
        if (kn.reserve() != left) _fail("the reserve moved by something other than a buy while unreadable");
    }

    struct BlindSnap {
        uint256 reserve;
        uint128 cum;
        uint128 paid;
        bool graduated;
        uint32 count;
        uint32 lastStepEpoch;
        bytes32 state;
    }

    function _call(Ctx storage c, uint256 gasLimit) internal returns (bool ok, bytes memory ret) {
        vm.prank(actors[3]);
        (ok, ret) = address(c.kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
    }

    /// Value may leave a kernel in a settle only to the Manager (curve buy), to the pair (V2 buy) or to 0xdEaD;
    /// nothing approved may remain; nobody else's USD₮0 may move; forced OKB never moves.
    function _afterSettle(Ctx storage c, Snap memory s) internal {
        settlesOk++;
        KernelV2 kn = c.kernel;
        uint32 n = kn.count();
        RecordV2 memory r = kn.records(n);
        if (n != s.count + 1) _fail("count did not advance by one");
        if (r.epoch != s.epoch) _fail("record epoch is not the current epoch");
        if (r.epoch <= lastRecordEpoch[address(kn)]) _fail("two records in one epoch");
        lastRecordEpoch[address(kn)] = r.epoch;
        if (r.buyExecuted > r.buyDecided) _fail("executed more than decided");
        if (uint256(r.allow) * 256 > uint256(r.inflow) * c.env.capT) _fail("allowance above capT of the inflow");
        if (uint256(r.allow) * 2 > r.inflow) _fail("more than half of an inflow became allowance");
        if (usdt.allowance(address(kn), address(manager)) != 0) _fail("an allowance to the Manager was left");
        if (usdt.allowance(address(kn), address(router)) != 0) _fail("an allowance to the router was left");
        if (address(kn).balance != s.okb) _fail("native OKB moved");
        if (r.clampBits & 130 != 0) _fail("a revenue clamp (K1V, K2V) was recorded");

        bool grad = r.flags & RecordFlags.GRADUATED != 0;
        if (grad) settlesGraduated++;
        if (r.flags & RecordFlags.FALLBACK != 0) {
            settlesFallback++;
            if (kn.state() != s.state) _fail("the fallback changed the chip state");
            if (uint256(r.epoch) - s.lastStepEpoch < c.env.fallbackEpochs) _fail("fallback inside the grace period");
            if (r.flags & RecordFlags.SEALED != 0) _fail("flag 2 on a record no evaluator answered");
            if (kn.lastStepEpoch() != s.lastStepEpoch) _fail("the fallback counted as a persisted step");
        } else if (kn.lastStepEpoch() != r.epoch) {
            _fail("an answered beat was not persisted");
        }
        if (r.flags & RecordFlags.SEALED != 0) settlesSealed++;
        if (!quoteFaulty) {
            if (grad) _checkGraduatedRoutes(c, s, r);
            else _checkCurveRoutes(c, s, r);
        }
        _replay(c, n);
    }

    function _othersQ(Ctx storage c) internal view returns (uint256) {
        return usdt.balanceOf(c.env.allowancePayee) + usdt.balanceOf(payer) + usdt.balanceOf(actors[0])
            + (c.env.sink == address(0) ? 0 : usdt.balanceOf(c.env.sink));
    }

    function _checkCurveRoutes(Ctx storage c, Snap memory s, RecordV2 memory r) internal {
        KernelV2 kn = c.kernel;
        uint256 claimed = (s.vq > 0 && r.flags & RecordFlags.CLAIM_FAILED == 0) ? s.vq : 0;
        uint256 spent = c.env.buyEnabled ? r.buyExecuted : 0;
        if (usdt.balanceOf(address(kn)) + spent != s.kq + claimed) _fail("curve: USD0 left by a route other than the buy");
        // the buy's USD0 is in the Manager, except its tax, which went to the vault
        if (usdt.balanceOf(address(manager)) + usdt.balanceOf(address(c.vault)) + claimed != s.mq + s.vq + spent) {
            _fail("curve: the buy's USD0 is not in the Manager and the vault");
        }
        if (_othersQ(c) != s.others) _fail("curve: somebody else's USD0 moved in a settle");
        if (c.token.balanceOf(address(kn)) != s.kt + r.tokensOut) _fail("curve: tokens changed other than by the buy");
        if (kn.lockedTokens() != s.locked + r.tokensOut) _fail("curve: bought tokens are not all locked");
        if (c.token.balanceOf(DEAD) != s.dead) _fail("curve: tokens reached 0xdEaD");
        if (r.quoteIn != 0) _fail("curve: quoteIn is not zero");
        if (spent != 0) buysExecuted++;
    }

    function _checkGraduatedRoutes(Ctx storage c, Snap memory s, RecordV2 memory r) internal {
        KernelV2 kn = c.kernel;
        address pair = c.token.pairAddr();
        uint256 claimedQ = s.vq > usdt.balanceOf(address(c.vault)) ? s.vq - usdt.balanceOf(address(c.vault)) : 0;
        uint256 pq = usdt.balanceOf(pair);
        uint256 swept = pq > s.pq ? pq - s.pq : 0;
        if (pq < s.pq) _fail("pair USD0 fell during a settle");
        if (usdt.balanceOf(address(kn)) + swept != s.kq + claimedQ) _fail("graduated: USD0 left by a route other than the pair");
        if (c.env.buyEnabled && r.quoteIn != swept) _fail("graduated: quoteIn is not the USD0 that reached the pair");
        if (_othersQ(c) != s.others) _fail("graduated: somebody else's USD0 moved in a settle");
        if (r.allow != 0) _fail("graduated: an allowance was paid");
        if (r.clampBits & 28 != 0) _fail("graduated: an allowance clamp was recorded");
        uint256 deadNow = c.token.balanceOf(DEAD);
        if (deadNow - s.dead != r.tokensOut) _fail("graduated: tokensOut is not what reached 0xdEaD");
        // tokens move only among the kernel, the vault, the pair and 0xdEaD
        if (
            c.token.balanceOf(address(kn)) + c.token.balanceOf(address(c.vault)) + c.token.balanceOf(pair) + deadNow
                != s.kt + s.vt + s.pt + s.dead
        ) _fail("graduated: tokens left by a route other than 0xdEaD");
        if (kn.lockedTokens() != s.locked) _fail("graduated: locked tokens changed in a settle");
        if (kn.burnedTokens() != s.burned + r.tokensOut) _fail("graduated: burnedTokens is not what reached 0xdEaD");
        if (swept != 0) swapsExecuted++;
    }

    function _replay(Ctx storage c, uint32 n) internal {
        uint256 snapId = vm.snapshotState();
        clearFaults();
        bool okT;
        bool okS;
        try lens.replayOn(address(c.kernel), n, false) returns (LensV2.Replay memory p) {
            okT = p.ok;
        } catch {}
        try lens.replayOn(address(c.kernel), n, true) returns (LensV2.Replay memory p) {
            okS = p.ok;
        } catch {}
        vm.revertToState(snapId);
        if (!okT) _fail("LensV2.replay on TapeOut does not reproduce the record");
        if (!okS) _fail("LensV2.replay on the sealed evaluator does not reproduce the record");
        replays += 2;
    }

    // ================================================================== helpers

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _noOutflow(Ctx storage c, uint256 q0, uint256 t0, string memory what) internal {
        if (!_readable(c)) return;
        if (usdt.balanceOf(address(c.kernel)) < q0) _fail(string.concat("USD0 left the kernel during ", what));
        if (c.token.balanceOf(address(c.kernel)) < t0) _fail(string.concat("tokens left the kernel during ", what));
    }
}
