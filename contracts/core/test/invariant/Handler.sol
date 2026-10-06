// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Kernel} from "../../src/Kernel.sol";
import {Lens} from "../../src/Lens.sol";
import {Record, Envelope, RecordFlags, IKernelMin} from "../../src/interfaces/IKernelV1.sol";
import {MockToken, MockVault, MockWOKB, MockPair, MockRouter, MockManager} from "../mocks/MockIgnix.sol";
import {MockBeacon, MockCircuits, MockSealedVM} from "../mocks/MockTapeOut.sol";

/// @dev Settles a kernel from inside a call that holds a reentrancy lock: the IgnixManager's (a zero-token
///      sell of any live token; the Manager pays the seller by a native call) or a Uniswap V2 pair's (a flash
///      swap, repaid with its fee in the callback).
contract LockProbe {
    address internal kernel;
    address internal wokbToken;
    uint256 internal gasLimit;
    bool public attempted;
    bool public ok;
    bytes public ret;

    function insideManager(MockManager manager, address anyLiveToken, address kernel_, uint256 gasLimit_) external {
        (kernel, gasLimit, attempted) = (kernel_, gasLimit_, false);
        manager.sell(anyLiveToken, 0, 0);
    }

    function insidePair(MockPair pair, MockWOKB wokb, uint256 wokbOut, address kernel_, uint256 gasLimit_)
        external
        payable
    {
        (kernel, gasLimit, attempted, wokbToken) = (kernel_, gasLimit_, false, address(wokb));
        wokb.deposit{value: msg.value}();
        bool wokbIs0 = pair.token0() == address(wokb);
        pair.swap(wokbIs0 ? wokbOut : 0, wokbIs0 ? 0 : wokbOut, address(this), hex"01");
    }

    function _settle() internal {
        attempted = true;
        (ok, ret) = kernel.call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
    }

    receive() external payable {
        _settle();
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        _settle();
        uint256 borrowed = amount0 + amount1;
        MockWOKB(payable(wokbToken)).transfer(msg.sender, borrowed + (borrowed * 3) / 997 + 1);
    }
}

/// @notice Drives several kernels through random trades, time, settles with random gas limits, settles made
///         from inside a Manager call or a flash swap, third-party claims, donations, graduation and every
///         failure switch of the mocks.
///
///         Checks that need a before/after comparison are made here, around each action. A failed check is
///         recorded (never reverted, which the fuzzer would ignore) and surfaces through `violations()`.
contract Handler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant NATIVE = address(0);

    /// @dev Tests run with an effectively unlimited gas limit, and some mock failure modes burn all the gas
    ///      they are given. Every call a handler makes into the mock world is therefore capped.
    uint256 internal constant CALL_GAS = 6_000_000;

    struct Ctx {
        Kernel kernel;
        MockToken token;
        MockVault vault;
        Envelope env;
        uint256 chipId;
        bytes netlist;
        bool tampered;
    }

    Ctx[] internal ctxs;
    MockManager internal manager;
    MockRouter internal router;
    MockWOKB internal wokb;
    MockCircuits internal circuits;
    MockSealedVM internal sealedVM;
    MockBeacon internal beacon;
    address internal impl;
    address internal implV2;
    Lens internal lens;

    address[] internal actors;
    address internal whale;

    // ---- ghosts
    uint256 public violations;
    string public lastViolation;
    uint256 public settlesOk;
    uint256 public settlesStepFailed;
    uint256 public settlesFallback;
    uint256 public settlesSealed;
    uint256 public settlesGraduated;
    uint256 public settlesGasReverted;
    uint256 public buysExecuted;
    uint256 public swapsExecuted;
    uint256 public replays;
    uint256 public lockedSettlesSame; // settles made under a held lock that did what any caller's would
    uint256 public lockedSettlesReverted; // settles made under a held lock that reverted with LockHeld
    mapping(address => uint32) public lastRecordEpoch;
    LockProbe internal probe;

    constructor(
        MockManager manager_,
        MockRouter router_,
        MockWOKB wokb_,
        MockCircuits circuits_,
        MockSealedVM sealedVM_,
        MockBeacon beacon_,
        address impl_,
        address implV2_,
        Lens lens_
    ) {
        manager = manager_;
        router = router_;
        wokb = wokb_;
        circuits = circuits_;
        sealedVM = sealedVM_;
        beacon = beacon_;
        impl = impl_;
        implV2 = implV2_;
        lens = lens_;
        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.deal(a, 1_000_000 ether);
        }
        whale = makeAddr("whale");
        vm.deal(whale, 10_000_000 ether);
        probe = new LockProbe();
    }

    address internal immutable owner = msg.sender;

    /// @dev Setup only: the test contract registers the kernels before the campaign starts.
    function add(Kernel k, MockToken t, MockVault v, Envelope memory e, uint256 chipId, bytes memory netlist) external {
        require(msg.sender == owner, "setup only");
        ctxs.push(Ctx(k, t, v, e, chipId, netlist, false));
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

    // ================================================================== market

    function trade(uint256 k, uint256 actorSeed, uint256 amount, bool isBuy) external {
        Ctx storage c = _ctx(k);
        address a = actors[actorSeed % actors.length];
        address pair = c.token.pairAddr();
        if (c.token.balanceOfReverts()) return;
        uint256 k0 = address(c.kernel).balance;
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        if (pair == address(0)) {
            if (isBuy) {
                amount = bound(amount, 0.001 ether, 12 ether);
                vm.prank(a);
                try manager.buy{value: amount, gas: CALL_GAS}(address(c.token), amount, 0) {} catch {}
            } else {
                uint256 bal = c.token.balanceOf(a);
                if (bal == 0) return;
                amount = bound(amount, 1, bal);
                vm.startPrank(a);
                c.token.approve(address(manager), amount);
                try manager.sell{gas: CALL_GAS}(address(c.token), amount, 0) {} catch {}
                vm.stopPrank();
            }
        } else {
            address[] memory path = new address[](2);
            if (isBuy) {
                amount = bound(amount, 0.001 ether, 12 ether);
                path[0] = address(wokb);
                path[1] = address(c.token);
                vm.prank(a);
                try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount, gas: CALL_GAS}(
                    0, path, a, block.timestamp
                ) {}
                    catch {}
            } else {
                uint256 bal = c.token.balanceOf(a);
                if (bal == 0) return;
                amount = bound(amount, 1, bal);
                path[0] = address(c.token);
                path[1] = address(wokb);
                vm.startPrank(a);
                c.token.approve(address(router), amount);
                try router.swapExactTokensForETHSupportingFeeOnTransferTokens{gas: CALL_GAS}(
                    amount, 0, path, a, block.timestamp
                ) {}
                    catch {}
                vm.stopPrank();
            }
        }
        _noOutflow(c, k0, t0, "trade");
    }

    function graduate(uint256 k) external {
        Ctx storage c = _ctx(k);
        if (c.token.pairAddr() != address(0) || c.token.balanceOfReverts()) return;
        uint256 k0 = address(c.kernel).balance;
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        // more than the whole curve can cost at any tax and surcharge: the Manager refunds the excess
        uint256 cost = 2_000 ether;
        vm.prank(whale);
        try manager.buy{value: cost, gas: CALL_GAS}(address(c.token), cost, 0) {} catch {}
        _noOutflow(c, k0, t0, "graduate");
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 3 * 900);
        vm.warp(block.timestamp + secs);
    }

    // ================================================================== third parties

    function claimFor(uint256 k, bool tokenAsset) external {
        Ctx storage c = _ctx(k);
        if (c.token.balanceOfReverts()) return;
        uint256 k0 = address(c.kernel).balance;
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        vm.prank(actors[0]);
        try c.vault.claimFor{gas: CALL_GAS}(address(c.kernel), tokenAsset ? address(c.token) : NATIVE) {} catch {}
        _noOutflow(c, k0, t0, "claimFor");
    }

    function donateVault(uint256 k, uint256 amount) external {
        Ctx storage c = _ctx(k);
        amount = bound(amount, 1, 5 ether);
        vm.prank(actors[1]);
        (bool ok,) = address(c.vault).call{value: amount}("");
        ok;
    }

    /// A plain transfer into a kernel must be refused, whoever sends it (the launcher and the payee included).
    function donateKernel(uint256 k, uint256 amount, uint256 senderSeed) external {
        Ctx storage c = _ctx(k);
        amount = bound(amount, 1, 5 ether);
        address[5] memory senders = [actors[0], actors[1], c.env.launcher, c.env.allowancePayee, whale];
        address s = senders[senderSeed % 5];
        vm.deal(s, s.balance + amount);
        uint256 k0 = address(c.kernel).balance;
        vm.prank(s);
        (bool ok,) = address(c.kernel).call{value: amount}("");
        if (ok) _fail("a plain transfer into the kernel was accepted");
        if (address(c.kernel).balance != k0) _fail("kernel balance moved on a refused transfer");
    }

    /// A forced transfer (self-destruct, block reward) cannot be refused; it must simply be inflow.
    function forceSend(uint256 k, uint256 amount) external {
        Ctx storage c = _ctx(k);
        amount = bound(amount, 1, 2 ether);
        vm.deal(address(c.kernel), address(c.kernel).balance + amount);
    }

    /// Tokens reach the kernel behind its back: before graduation through a third party's buyTo, after it by
    /// a plain transfer.
    function giftTokens(uint256 k, uint256 amount) external {
        Ctx storage c = _ctx(k);
        address a = actors[2];
        if (c.token.balanceOfReverts()) return;
        uint256 k0 = address(c.kernel).balance;
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        if (c.token.pairAddr() == address(0)) {
            amount = bound(amount, 0.001 ether, 1 ether);
            vm.prank(a);
            try manager.buyTo{value: amount, gas: CALL_GAS}(address(c.token), amount, 0, address(c.kernel)) {} catch {}
        } else {
            uint256 bal = c.token.balanceOf(a);
            if (bal == 0) return;
            amount = bound(amount, 1, bal);
            vm.prank(a);
            try c.token.transfer{gas: CALL_GAS}(address(c.kernel), amount) {} catch {}
        }
        _noOutflow(c, k0, t0, "giftTokens");
    }

    // ================================================================== credits and locked tokens

    function withdraw(uint256 k, uint256 who, bool tokenAsset) external {
        Ctx storage c = _ctx(k);
        address[4] memory payees = [c.env.allowancePayee, c.env.sink, actors[3], c.env.launcher];
        address p = payees[who % 4];
        address asset = tokenAsset ? address(c.token) : NATIVE;
        if (tokenAsset && c.token.balanceOfReverts()) return;
        uint256 credit = c.kernel.creditOf(p, asset);
        if ((p == actors[3] || p == c.env.launcher) && p != c.env.allowancePayee && p != c.env.sink && credit != 0) {
            _fail("somebody who is neither the allowance payee nor the sink holds a credit");
        }
        uint256 kBefore = _bal(asset, address(c.kernel), c);
        uint256 pBefore = _bal(asset, p, c);
        uint256 total = c.kernel.totalCredits(asset);
        vm.prank(actors[0]); // anyone
        try c.kernel.withdrawCredit{gas: CALL_GAS}(p, asset) returns (uint256 paid) {
            if (paid != credit) _fail("withdraw paid something other than the credit");
            if (p != address(c.kernel)) {
                if (_bal(asset, address(c.kernel), c) != kBefore - paid) _fail("kernel paid out more than the credit");
                if (_bal(asset, p, c) != pBefore + paid) _fail("the payee did not receive the credit");
            }
            if (c.kernel.creditOf(p, asset) != 0) _fail("credit not cleared");
            if (c.kernel.totalCredits(asset) != total - paid) _fail("totalCredits not reduced by the payment");
        } catch {
            // a token transfer can be made to fail by the token's failure switch; the credit must remain
            if (c.kernel.creditOf(p, asset) != credit) _fail("a failed withdrawal changed the credit");
        }
    }

    function burnLocked(uint256 k) external {
        Ctx storage c = _ctx(k);
        if (c.token.balanceOfReverts()) return;
        uint256 locked = c.kernel.lockedTokens();
        uint256 t0 = c.token.balanceOf(address(c.kernel));
        uint256 d0 = c.token.balanceOf(DEAD);
        uint256 k0 = address(c.kernel).balance;
        try c.kernel.burnLocked{gas: CALL_GAS}() returns (uint256 burned) {
            if (burned != locked) _fail("burnLocked burned something other than the locked tokens");
            if (c.token.balanceOf(address(c.kernel)) != t0 - burned) _fail("burnLocked moved other tokens");
            if (c.token.balanceOf(DEAD) != d0 + burned) _fail("locked tokens did not go to 0xdEaD");
            if (c.kernel.lockedTokens() != 0) _fail("locked not cleared");
        } catch {
            if (c.kernel.lockedTokens() != locked) _fail("a failed burnLocked changed the books");
            if (c.token.balanceOf(address(c.kernel)) != t0) _fail("a failed burnLocked moved tokens");
        }
        if (address(c.kernel).balance != k0) _fail("burnLocked moved native value");
    }

    // ================================================================== failure switches

    function faultEvaluator(uint8 mode, bool sealedOne) external {
        mode = mode % 9; // 0 normal .. 8; the programmed override (9) is not a function of the netlist
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
        which = which % 10;
        if (which == 0) {
            c.vault.setMode(mode % 4);
        } else if (which == 1) {
            manager.setTokensMode(mode % 6);
        } else if (which == 2) {
            manager.setBuyMode(mode % 4);
        } else if (which == 3) {
            manager.setPairOfReverts(mode % 2 == 1);
        } else if (which == 4) {
            manager.setSnipeReverts(mode % 2 == 1);
        } else if (which == 5) {
            manager.setPaused(1, mode % 2 == 1 ? uint64(block.timestamp + 5 * 900) : 0);
        } else if (which == 6) {
            manager.setFounderRound(address(c.token), mode % 2 == 1 ? uint64(block.timestamp + 3 * 900) : 0);
        } else if (which == 7) {
            router.setMode(mode % 3);
        } else if (which == 8) {
            c.token.setFailure(mode % 5 == 1, mode % 5 == 2, mode % 5 == 3, mode % 5 == 4 ? DEAD : address(0));
        } else {
            c.token.setPairMode(mode % 4); // the read the graduation latch makes
        }
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
        manager.setPairOfReverts(false);
        manager.setSnipeReverts(false);
        manager.setPaused(1, 0);
        router.setMode(0);
        for (uint256 i = 0; i < ctxs.length; i++) {
            Ctx storage c = ctxs[i];
            c.vault.setMode(0);
            c.token.setFailure(false, false, false, address(0));
            c.token.setPairMode(0);
            manager.setFounderRound(address(c.token), 0);
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
        uint256 kernelNative;
        uint256 kernelTok;
        uint256 vaultNative;
        uint256 vaultTok;
        uint256 managerNative;
        uint256 dead;
        uint256 pairWokb;
        uint256 pairTok;
        uint256 locked;
        uint256 burned;
        uint32 count;
        uint32 epoch;
        uint32 lastStepEpoch;
        bool graduated;
        bytes32 state;
        uint256 allowCredit;
    }

    function _snap(Ctx storage c) internal view returns (Snap memory s) {
        s.kernelNative = address(c.kernel).balance;
        s.kernelTok = c.token.balanceOf(address(c.kernel));
        s.vaultNative = address(c.vault).balance;
        s.vaultTok = c.token.balanceOf(address(c.vault));
        s.managerNative = address(manager).balance;
        s.dead = c.token.balanceOf(DEAD);
        address pair = c.token.pairAddr();
        if (pair != address(0)) {
            s.pairWokb = wokb.balanceOf(pair);
            s.pairTok = c.token.balanceOf(pair);
        }
        s.locked = c.kernel.lockedTokens();
        s.burned = c.kernel.burnedTokens();
        s.count = c.kernel.count();
        s.epoch = c.kernel.epochNow();
        s.lastStepEpoch = c.kernel.lastStepEpoch();
        s.graduated = c.kernel.graduated();
        s.state = c.kernel.state();
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
                address(c.kernel).balance,
                address(c.vault).balance,
                address(manager).balance,
                c.kernel.totalCredits(NATIVE),
                c.kernel.totalCredits(address(c.token))
            )
        );
        return keccak256(abi.encode(a, b));
    }

    // The fuzzer picks functions uniformly. Settles and trades are what the invariants are about, so they
    // appear several times.
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

    function tradeBuy(uint256 k, uint256 actorSeed, uint256 amount) external {
        this.trade(k, actorSeed, amount, true);
    }

    /// A settle made from inside a call into the IgnixManager (its reentrancy lock is held).
    function settleInsideManager(uint256 k, uint256 via, bool warpFirst) external {
        if (warpFirst) vm.warp(block.timestamp + 900);
        Ctx storage c = _ctx(k);
        // the lock is the Manager's: a zero-token sell of any token still on its curve holds it
        address live;
        for (uint256 i = 0; i < ctxs.length; i++) {
            Ctx storage o = ctxs[(via % ctxs.length + i) % ctxs.length];
            if (o.token.pairAddr() == address(0)) {
                live = address(o.token);
                break;
            }
        }
        if (live == address(0) || c.token.balanceOfReverts()) return;
        _settleUnderLock(c, true, live);
    }

    /// A settle made from inside a flash swap on the token's own pair (the pair's lock is held).
    function settleInsidePair(uint256 k, bool warpFirst) external {
        if (warpFirst) vm.warp(block.timestamp + 900);
        Ctx storage c = _ctx(k);
        if (c.token.pairAddr() == address(0) || c.token.balanceOfReverts()) return;
        _settleUnderLock(c, false, address(0));
    }

    /// A caught failure must be one every caller would see, and so must a success. From one state: what
    /// the settle does when sent normally, and what it does from inside the lock. Either the two are the
    /// same (same record and balances, or the same revert), or the one under the lock reverted with LockHeld,
    /// changed nothing, and the normal one went through.
    function _settleUnderLock(Ctx storage c, bool managerLock, address live) internal {
        Snap memory s = _snap(c);
        (bool refOk, bytes4 refErr, bytes32 refDigest) = _reference(c);
        if (!_runUnderLock(c, managerLock, live)) return; // the outer call never reached the callback
        bytes memory ret = probe.ret();
        bytes4 err = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        if (probe.ok()) {
            // (a zero-token sell and a repaid flash swap leave every balance `_digest` reads as it was)
            if (!refOk) _fail("a settle under a held lock succeeded where a normal one reverts");
            else if (_digest(c) != refDigest) _fail("a held lock changed what a settle wrote");
            lockedSettlesSame++;
            _afterSettleUnderLock(c, s, managerLock);
        } else if (err == Kernel.LockHeld.selector) {
            if (!refOk) _fail("LockHeld although a normal settle would not have reached a buy");
            if (_digestQuick(c, s)) _fail("a settle that reverted with LockHeld changed state or balances");
            if (managerLock && c.token.pairAddr() != address(0)) {
                _fail("the Manager's lock reverted a settle of a graduated token");
            }
            if (!managerLock && !c.env.buyEnabled) _fail("the pair's lock reverted a kernel that never swaps");
            lockedSettlesReverted++;
        } else {
            if (refOk || refErr != err) _fail("a settle under a held lock reverted differently from a normal one");
            if (_digestQuick(c, s)) _fail("a reverted settle changed state or balances");
        }
    }

    /// @dev What an amply funded settle sent normally does from this exact state; the state is restored.
    function _reference(Ctx storage c) internal returns (bool ok, bytes4 err, bytes32 digest) {
        uint256 snapId = vm.snapshotState();
        bytes memory ret;
        (ok, ret) = _call(c, 60_000_000);
        if (ok) digest = _digest(c);
        else if (ret.length >= 4) err = bytes4(ret);
        vm.revertToState(snapId);
    }

    /// @return reached the lock holder was called back and made its settle attempt
    function _runUnderLock(Ctx storage c, bool managerLock, address live) internal returns (bool reached) {
        if (managerLock) {
            try probe.insideManager{gas: 90_000_000}(manager, live, address(c.kernel), 60_000_000) {
                reached = true;
            } catch {}
        } else {
            MockPair pair = MockPair(c.token.pairAddr());
            uint256 out = wokb.balanceOf(address(pair)) / 4;
            if (out == 0) return false;
            vm.deal(address(this), out);
            try probe.insidePair{gas: 90_000_000, value: out}(pair, wokb, out, address(c.kernel), 60_000_000) {
                reached = true;
            } catch {}
        }
        reached = reached && probe.attempted();
    }

    /// @dev Bookkeeping after a successful settle under a lock: the record is one more record of the campaign.
    function _afterSettleUnderLock(Ctx storage c, Snap memory s, bool managerLock) internal {
        if (managerLock) {
            _afterSettle(c, s);
        } else {
            // the flash swap moved WOKB through the pair around the settle, so the route checks that compare
            // the pair's balances before and after do not apply; the record itself was compared above
            uint32 n = c.kernel.count();
            Record memory r = c.kernel.records(n);
            if (r.epoch <= lastRecordEpoch[address(c.kernel)]) _fail("two records in one epoch");
            lastRecordEpoch[address(c.kernel)] = r.epoch;
            settlesOk++;
            if (r.flags & RecordFlags.GRADUATED != 0) settlesGraduated++;
            if (r.flags & RecordFlags.FALLBACK != 0) settlesFallback++;
            if (r.flags & RecordFlags.SEALED != 0) settlesSealed++;
            _replay(c, n);
        }
    }

    /// One settle attempt with ample gas, or (randomGas) with a random gas limit that is compared against
    /// what the same settle does with ample gas.
    function _settle(uint256 k, uint256 gasSeed, bool randomGas) internal {
        Ctx storage c = _ctx(k);
        // token balance reads are needed for the checks below; with balanceOf broken there is nothing to compare
        bool tokenReadable = !c.token.balanceOfReverts();
        Snap memory s;
        if (tokenReadable) s = _snap(c);
        else return _settleBlind(c);

        // reference: what an amply funded settle does from this exact state
        uint256 snapId = vm.snapshotState();
        (bool refOk, bytes memory refRet) = _call(c, 60_000_000);
        bytes32 refDigest = refOk ? _digest(c) : bytes32(0);
        vm.revertToState(snapId);

        bytes4 refErr = refRet.length >= 4 ? bytes4(refRet) : bytes4(0);
        if (!refOk) {
            // a funded settle may only refuse for two reasons
            bool notDue = refErr == Kernel.EpochNotElapsed.selector;
            bool inGrace =
                refErr == Kernel.StepFailed.selector && uint256(s.epoch) - s.lastStepEpoch < c.env.fallbackEpochs;
            if (!notDue && !inGrace) _fail("a funded settle reverted for a reason other than epoch or grace period");
            if (notDue && s.epoch > c.kernel.lastEpoch()) _fail("EpochNotElapsed although a new epoch has begun");
        } else if (s.epoch <= c.kernel.lastEpoch()) {
            _fail("a second settle in one epoch succeeded");
        }

        uint256 gasLimit = randomGas ? bound(gasSeed, 30_000, 13_000_000) : 60_000_000;
        (bool ok, bytes memory ret) = _call(c, gasLimit);
        if (!ok) {
            bytes4 err = ret.length >= 4 ? bytes4(ret) : bytes4(0);
            if (refOk) {
                // the only difference from the reference is the gas limit
                if (!randomGas) _fail("settle with ample gas diverged from its own reference");
                if (err != Kernel.InsufficientGas.selector && err != bytes4(0)) {
                    _fail("under-funded settle reverted with something other than a lack of gas");
                }
                settlesGasReverted++;
            } else if (err == Kernel.StepFailed.selector) {
                settlesStepFailed++;
            }
            // a revert moved nothing
            if (_digestQuick(c, s)) _fail("a reverted settle changed state or balances");
            return;
        }
        if (!refOk) _fail("a settle succeeded where the amply funded one reverts");
        if (_digest(c) != refDigest) _fail("the gas limit changed the outcome of a settle");
        _afterSettle(c, s);
    }

    function _settleBlind(Ctx storage c) internal {
        (bool ok, bytes memory ret) = _call(c, 60_000_000);
        if (ok) return;
        bytes4 err = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        if (err != Kernel.EpochNotElapsed.selector && err != Kernel.StepFailed.selector) {
            _fail("a funded settle reverted while the token balance was unreadable");
        }
    }

    function _call(Ctx storage c, uint256 gasLimit) internal returns (bool ok, bytes memory ret) {
        vm.prank(actors[3]);
        (ok, ret) = address(c.kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
    }

    /// @return changed true if anything a settle could touch differs from the snapshot
    function _digestQuick(Ctx storage c, Snap memory s) internal view returns (bool changed) {
        return c.kernel.count() != s.count || c.kernel.state() != s.state || address(c.kernel).balance != s.kernelNative
            || c.token.balanceOf(address(c.kernel)) != s.kernelTok || address(c.vault).balance != s.vaultNative
            || c.kernel.graduated() != s.graduated || c.kernel.lockedTokens() != s.locked;
    }

    /// Value may leave a kernel in a settle only to the Manager (curve buy), to the pair (V2 buy) or to 0xdEaD.
    function _afterSettle(Ctx storage c, Snap memory s) internal {
        settlesOk++;
        Kernel kn = c.kernel;
        uint32 n = kn.count();
        Record memory r = kn.records(n);
        if (n != s.count + 1) _fail("count did not advance by one");
        if (r.epoch != s.epoch) _fail("record epoch is not the current epoch");
        if (r.epoch <= lastRecordEpoch[address(kn)]) _fail("two records in one epoch");
        lastRecordEpoch[address(kn)] = r.epoch;
        if (r.buyExecuted > r.buyDecided) _fail("executed more than decided");
        if (uint256(r.allow) * 256 > uint256(r.inflow) * c.env.capT) _fail("allowance above capT of the inflow");
        if (uint256(r.allow) * 2 > r.inflow) _fail("more than half of an inflow became allowance");

        bool grad = r.flags & RecordFlags.GRADUATED != 0;
        bool fallbackUsed = r.flags & RecordFlags.FALLBACK != 0;
        if (grad) settlesGraduated++;
        if (fallbackUsed) settlesFallback++;
        if (r.flags & RecordFlags.SEALED != 0) settlesSealed++;
        if (fallbackUsed) {
            if (kn.state() != s.state) _fail("the fallback changed the chip state");
            if (uint256(r.epoch) - s.lastStepEpoch < c.env.fallbackEpochs) _fail("fallback inside the grace period");
            if (r.flags & RecordFlags.SEALED != 0) _fail("flag 2 on a record no evaluator answered");
            if (kn.lastStepEpoch() != s.lastStepEpoch) _fail("the fallback counted as a persisted step");
        } else if (kn.lastStepEpoch() != r.epoch) {
            _fail("an answered beat was not persisted");
        }

        if (grad) _checkGraduatedRoutes(c, s, r);
        else _checkCurveRoutes(c, s, r);
        _replay(c, n);
    }

    function _checkCurveRoutes(Ctx storage c, Snap memory s, Record memory r) internal {
        Kernel kn = c.kernel;
        uint256 claimed = (s.vaultNative > 0 && r.flags & RecordFlags.CLAIM_FAILED == 0) ? s.vaultNative : 0;
        uint256 spent = c.env.buyEnabled ? r.buyExecuted : 0;
        if (address(kn).balance + spent != s.kernelNative + claimed) {
            _fail("curve: native left by a route other than the buy");
        }
        // the buy's value is in the Manager, except its tax, which the Manager forwarded to the vault
        if (address(manager).balance + address(c.vault).balance + claimed != s.managerNative + s.vaultNative + spent) {
            _fail("curve: the buy's value is not in the Manager and the vault");
        }
        if (c.token.balanceOf(address(kn)) != s.kernelTok + r.tokensOut) {
            _fail("curve: token balance changed by something other than the buy");
        }
        if (kn.lockedTokens() != s.locked + r.tokensOut) _fail("curve: bought tokens are not all locked");
        if (c.token.balanceOf(DEAD) != s.dead) _fail("curve: tokens reached 0xdEaD");
        if (!c.env.buyEnabled && r.tokensOut != 0) _fail("a kernel with buys disabled bought");
        if (r.nativeIn != 0) _fail("curve: nativeIn is not zero");
        if (spent != 0) buysExecuted++;
    }

    function _checkGraduatedRoutes(Ctx storage c, Snap memory s, Record memory r) internal {
        Kernel kn = c.kernel;
        address pair = c.token.pairAddr();
        uint256 claimedNative = _sub(s.vaultNative, address(c.vault).balance, "vault native grew in a graduated settle");
        uint256 swept = _sub(wokb.balanceOf(pair), s.pairWokb, "pair WOKB fell during a settle");
        if (address(kn).balance + swept != s.kernelNative + claimedNative) {
            _fail("graduated: native left by a route other than the pair");
        }
        if (!c.env.buyEnabled && swept != 0) _fail("a kernel with buys disabled swapped");
        if (r.nativeIn != swept) _fail("graduated: nativeIn is not the OKB that reached the pair");
        if (r.allow != 0) _fail("graduated: an allowance was paid");
        if (r.clampBits & 28 != 0) _fail("graduated: an allowance clamp (K2, K2C, K2L) was recorded");
        uint256 deadDelta = _sub(c.token.balanceOf(DEAD), s.dead, "0xdEaD balance fell");
        if (deadDelta != r.tokensOut) _fail("graduated: tokensOut is not what reached 0xdEaD");
        uint256 burnedDirect = c.env.buyEnabled ? r.buyExecuted : 0;
        uint256 swapNet = _sub(deadDelta, burnedDirect, "burned less than the direct burn");
        uint256 pairOut = _sub(s.pairTok, c.token.balanceOf(pair), "pair token balance grew in a settle");
        uint256 swapTax = _sub(pairOut, swapNet, "swap delivered more than the pair paid out");
        // the vault lost what the kernel claimed and gained the tax of the kernel's own swap
        if (
            c.token.balanceOf(address(kn)) + burnedDirect + c.token.balanceOf(address(c.vault))
                != s.kernelTok + s.vaultTok + swapTax
        ) _fail("graduated: tokens left by a route other than 0xdEaD");
        if (kn.lockedTokens() != s.locked) _fail("graduated: locked tokens changed in a settle");
        if (kn.burnedTokens() != s.burned + deadDelta) _fail("graduated: burnedTokens is not what reached 0xdEaD");
        if (swept != 0) swapsExecuted++;
    }

    /// Both evaluators must reproduce the record. Faults are lifted for the replay: it asks what the taped
    /// chip computes, not whether a broken dependency is still broken.
    function _replay(Ctx storage c, uint32 n) internal {
        uint256 snapId = vm.snapshotState();
        clearFaults();
        bool okT;
        bool okS;
        try lens.replayOn(address(c.kernel), n, false) returns (Lens.Replay memory p) {
            okT = p.ok;
        } catch {}
        try lens.replayOn(address(c.kernel), n, true) returns (Lens.Replay memory p) {
            okS = p.ok;
        } catch {}
        vm.revertToState(snapId);
        if (!okT) _fail("Lens.replay on TapeOut does not reproduce the record");
        if (!okS) _fail("Lens.replay on the sealed evaluator does not reproduce the record");
        replays += 2;
    }

    // ================================================================== helpers

    /// @dev a - b, or a recorded violation (never a revert, which the fuzzer would swallow)
    function _sub(uint256 a, uint256 b, string memory why) internal returns (uint256) {
        if (b > a) {
            _fail(why);
            return 0;
        }
        return a - b;
    }

    function _bal(address asset, address who, Ctx storage c) internal view returns (uint256) {
        if (asset == NATIVE) return who.balance;
        if (c.token.balanceOfReverts()) return 0;
        return c.token.balanceOf(who);
    }

    function _noOutflow(Ctx storage c, uint256 k0, uint256 t0, string memory what) internal {
        if (address(c.kernel).balance < k0) _fail(string.concat("native left the kernel during ", what));
        if (!c.token.balanceOfReverts() && c.token.balanceOf(address(c.kernel)) < t0) {
            _fail(string.concat("tokens left the kernel during ", what));
        }
    }
}
