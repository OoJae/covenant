// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2, Vm} from "forge-std/Test.sol";

import {
    IIgnixManager,
    IDirectedVault,
    IERC20Min,
    IERC721Min,
    IKernelV1,
    IKernelExt,
    IKernelExtV2,
    IKernelFactoryV1,
    ILens,
    IFabV1,
    CurveToken,
    Envelope,
    Globals,
    GlobalsV2,
    Record
} from "./Interfaces.sol";

/// @title Fork simulation of one exact createToken transaction
/// @notice Runs the transaction a wallet is about to sign on a fork of X Layer and then drives the token's
///         kernel through its first life cycle:
///
///           0. with a deployment (the default for launch day): the kernel is one the deployment's KernelFactory
///              created, its globals name the deployment's Circuits, Fab and SealedVM and the IgnixManager, it
///              holds its chip, its envelope's launcher is the sender, and the Lens steps its chip on both
///              evaluators within the kernel's gas, with the same answer;
///           1. the launcher performs the exact call (same calldata, same value);
///           2. the new token is found from the return value AND from the Manager's TokenCreated event;
///           3. vaultOf(token).RECIPIENT() must be the kernel, and nothing may have been bought;
///           4. kernel.bind(token), called by an UNRELATED address, must succeed (it can only if the token's
///              creator is the envelope's launcher), and the factory must then name this kernel for the token;
///           5. an unrelated funded address buys on the curve: the tax must land in the vault;
///           6. one epoch later kernel.settle() must write a record and move the vault's tax into the kernel.
///
///         Any deviation reverts with a message that starts with "sim:". Nothing here sends a transaction to
///         a real network or uses a key: forks and cheatcodes only.
///
///         Kernel v2 (contracts/core-v2, a launch quoted in USD₮0; `Deployment.quote` is USD₮0): the same steps, with
///         the kernel's GlobalsV2 (its quote and code shift must be the deployment's), the vault quoted in USD₮0,
///         the outsider's buy paid in USD₮0 (dealt to an unrelated address on the fork, never a team wallet) and
///         every balance of step 6 read in USD₮0.
///
/// @dev    The kernel is used through chips/INTERFACE.md sections 7 and 10 (bind, settle, token, vault, count,
///         records, epochNow, lastEpoch, reserve, envelope) and IKernelExt.globals(). What happens inside settle
///         is judged from the outside: the vault's Claimed event, IGNIX's Trade events and balances.
abstract contract LaunchSim is Test {
    IIgnixManager internal constant M = IIgnixManager(0x96B51c57e5346D0C0198899243cf851D1E23C309);
    string internal constant DEFAULT_RPC = "https://rpc.xlayer.tech";

    bytes32 internal constant T_TOKEN_CREATED =
        keccak256("TokenCreated(address,address,address,uint256,string,address,address,uint16)");
    bytes32 internal constant T_TRADE =
        keccak256("Trade(address,address,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint128)");
    bytes32 internal constant T_CLAIMED = keccak256("Claimed(address,address,uint256)");

    /// Record flag "vault claim failed" (chips/INTERFACE.md section 10).
    uint8 internal constant FLAG_CLAIM_FAILED = 4;

    /// @notice The deployed Covenant contracts the kernel must belong to (deploy/rehearsal.json format).
    struct Deployment {
        bool present; // false: harness self-tests with a mock kernel only
        address kernelFactory;
        address circuits;
        address fab;
        address sealedVM;
        address lens; // zero: the Lens preflight is not run
        uint256 chipId;
        address quote; // zero: kernel v1 (native OKB); USD₮0: kernel v2 (contracts/core-v2)
        uint256 quoteShift; // kernel v2: the code shift the deployment's KernelFactoryV2 pins
    }

    struct Inputs {
        address from; // the launcher: msg.sender of createToken
        address to; // must be the IgnixManager proxy
        uint256 value; // msg.value, in wei
        bytes data; // the exact calldata
        address kernel; // the vault recipient that must bind
        bool skipKernel; // harness self-tests only: stop after the creation
        bool allowFirstBuy; // harness self-tests only: the replay of a real launch that bought
        Deployment dep;
    }

    struct Created {
        address token;
        address vault;
        uint256 gasUsed; // gas of the createToken call, after refunds
        Vm.Log[] logs; // every log of the creating call
    }

    function _rpcUrl() internal view returns (string memory) {
        return vm.envOr("XLAYER_RPC_URL", DEFAULT_RPC);
    }

    // ───────────────────────────── the whole simulation ─────────────────────────────

    function _simulate(Inputs memory inp) internal returns (Created memory c) {
        require(block.chainid == 196, "sim: not a fork of X Layer (chain id 196)");
        if (inp.dep.present && !inp.skipKernel) _checkDeployment(inp);
        c = _create(inp);
        _checkLaunch(inp, c);
        if (inp.skipKernel) {
            console2.log("KERNEL CHECKS SKIPPED: bind and settle were NOT simulated. This run approves nothing.");
            return c;
        }
        _bind(inp, c);
        uint256 tax = inp.dep.quote == address(0) ? _outsiderBuy(c) : _outsiderBuyQuote(inp, c);
        _settle(inp, c, tax);
    }

    // ───────────────────────────── 0: the kernel belongs to the deployment ─────────────────────────────

    /// @dev The globals both kernel generations have. For kernel v2, its quote and code shift are checked here.
    struct KernelInfo {
        address manager;
        address factory;
        address circuits;
        address fab;
        address sealedVM;
        uint256 chipId;
        uint32 nState;
        uint32 gateCount;
    }

    function _kernelInfo(Inputs memory inp) internal view returns (KernelInfo memory g) {
        if (inp.dep.quote == address(0)) {
            Globals memory v1 = IKernelExt(inp.kernel).globals();
            (g.manager, g.factory, g.circuits, g.fab, g.sealedVM) = (v1.manager, v1.factory, v1.circuits, v1.fab, v1.sealedVM);
            (g.chipId, g.nState, g.gateCount) = (v1.chipId, v1.nState, v1.gateCount);
        } else {
            GlobalsV2 memory v2 = IKernelExtV2(inp.kernel).globals();
            require(v2.quote == inp.dep.quote, "sim: the v2 kernel's quote is not the deployment's (USDT0)");
            require(IKernelExtV2(inp.kernel).quote() == inp.dep.quote, "sim: kernel.quote() is not the deployment's (USDT0)");
            require(v2.quoteShift == inp.dep.quoteShift, "sim: the v2 kernel's code shift is not the deployment's");
            (g.manager, g.factory, g.circuits, g.fab, g.sealedVM) = (v2.manager, v2.factory, v2.circuits, v2.fab, v2.sealedVM);
            (g.chipId, g.nState, g.gateCount) = (v2.chipId, v2.nState, v2.gateCount);
        }
    }

    /// @dev What `who` holds of the launch's quote: native OKB for kernel v1, USD₮0 for kernel v2.
    function _quoteBalance(Inputs memory inp, address who) internal view returns (uint256) {
        return inp.dep.quote == address(0) ? who.balance : IERC20Min(inp.dep.quote).balanceOf(who);
    }

    function _checkDeployment(Inputs memory inp) internal view {
        Deployment memory d = inp.dep;
        require(inp.kernel.code.length != 0, "sim: the kernel address has no code");
        require(d.kernelFactory.code.length != 0, "sim: the deployment's KernelFactory has no code on this chain");
        require(
            IKernelFactoryV1(d.kernelFactory).isKernel(inp.kernel),
            "sim: the kernel was not created by the deployment's KernelFactory"
        );
        KernelInfo memory g = _kernelInfo(inp);
        require(g.factory == d.kernelFactory, "sim: the kernel's globals name another KernelFactory");
        require(g.manager == address(M), "sim: the kernel is wired to another IgnixManager");
        require(
            d.circuits == address(0) || g.circuits == d.circuits, "sim: the kernel's processor is not the deployment's Circuits"
        );
        require(d.fab == address(0) || g.fab == d.fab, "sim: the kernel's Fab is not the deployment's Fab");
        require(
            d.sealedVM == address(0) || g.sealedVM == d.sealedVM, "sim: the kernel's SealedVM is not the deployment's SealedVM"
        );
        require(d.chipId == 0 || g.chipId == d.chipId, "sim: the kernel's chip is not the deployment's chip");
        require(IKernelV1(inp.kernel).chipId() == g.chipId, "sim: kernel.chipId() and globals().chipId differ");
        require(IFabV1(g.fab).isChip(g.chipId), "sim: the Fab did not tape out the kernel's chip");
        require(IERC721Min(g.circuits).ownerOf(g.chipId) == inp.kernel, "sim: the kernel does not hold its chip NFT");
        Envelope memory e = IKernelV1(inp.kernel).envelope();
        require(e.launcher == inp.from, "sim: the kernel's envelope launcher is not the sender of createToken");
        require(e.buyEnabled, "sim: the kernel's envelope has buys disabled");
        console2.log("the kernel belongs to the deployment");
        if (d.quote != address(0)) {
            console2.log("  kernel v2, quote", d.quote);
            console2.log("  code shift (bits)", d.quoteShift);
        }
        console2.log("  KernelFactory  ", d.kernelFactory);
        console2.log("  chip id        ", g.chipId);
        console2.log("  gates, latches ", uint256(g.gateCount), uint256(g.nState));
        console2.log("  epoch (s)      ", uint256(e.epochLen));
        if (d.lens != address(0)) {
            ILens.Preflight memory p = ILens(d.lens).preflight(inp.kernel);
            require(p.tapeoutRan, "sim: Lens.preflight: TapeOut's step did not answer within the kernel's step gas");
            require(p.sealedRan, "sim: Lens.preflight: the sealed evaluator did not answer within its gas");
            require(p.agree, "sim: Lens.preflight: the two evaluators disagree");
            console2.log("  preflight gas: TapeOut", p.tapeoutGas, "of", p.stepFloor);
            console2.log("  preflight gas: sealed ", p.sealedGas, "of", p.sealedFloor);
        }
    }

    // ───────────────────────────── 1 and 2: the exact call, and the token it creates ─────────────────────────────

    function _create(Inputs memory inp) internal returns (Created memory c) {
        require(inp.to == address(M), "sim: `to` is not the IgnixManager proxy");
        require(
            inp.data.length >= 4 && bytes4(inp.data) == IIgnixManager.createToken.selector,
            "sim: the calldata is not a createToken call"
        );
        require(inp.from.balance >= inp.value, "sim: the launcher's balance is below the value of the transaction");

        vm.recordLogs();
        vm.prank(inp.from, inp.from);
        (bool ok, bytes memory ret) = inp.to.call{value: inp.value}(inp.data);
        Vm.Gas memory g = vm.lastFrameGas();
        if (!ok) revert(string.concat("sim: createToken reverted: ", _errorName(ret)));
        require(ret.length == 32, "sim: createToken did not return one address");
        c.token = abi.decode(ret, (address));
        c.gasUsed = uint256(g.gasTotalUsed) - uint256(int256(g.gasRefunded));
        c.logs = vm.getRecordedLogs();

        // the Manager's own announcement must name the same token, this creator and a vault
        bool found;
        for (uint256 i; i < c.logs.length; ++i) {
            Vm.Log memory l = c.logs[i];
            if (l.emitter != address(M) || l.topics.length != 4 || l.topics[0] != T_TOKEN_CREATED) continue;
            require(!found, "sim: more than one TokenCreated event");
            found = true;
            require(address(uint160(uint256(l.topics[1]))) == c.token, "sim: TokenCreated names another token");
            require(address(uint160(uint256(l.topics[2]))) == inp.from, "sim: TokenCreated names another creator");
            (,, address vault,,) = abi.decode(l.data, (uint256, string, address, address, uint16));
            c.vault = vault;
        }
        require(found, "sim: the Manager emitted no TokenCreated event");
        require(c.token.code.length != 0, "sim: no code at the new token");
        require(c.vault != address(0) && M.vaultOf(c.token) == c.vault, "sim: vaultOf(token) is not the vault of the event");

        console2.log("createToken succeeded on the fork");
        console2.log("  token          ", c.token);
        console2.log("  name           ", IERC20Min(c.token).name());
        console2.log("  ticker         ", IERC20Min(c.token).symbol());
        console2.log("  vault          ", c.vault);
        console2.log("  gas used       ", c.gasUsed);
    }

    // ───────────────────────────── 3: the vault points at the kernel; nothing was bought ─────────────────────────────

    function _checkLaunch(Inputs memory inp, Created memory c) internal view {
        IDirectedVault v = IDirectedVault(c.vault);
        require(v.RECIPIENT() == inp.kernel, "sim: the vault RECIPIENT is not the kernel");
        require(v.TOKEN() == c.token, "sim: the vault TOKEN is not the new token");
        CurveToken memory t = M.tokens(c.token);
        require(t.creator == inp.from, "sim: the token's creator is not the launcher");
        console2.log("  vault RECIPIENT", v.RECIPIENT());
        console2.log("  tax buy / sell (bps)", t.taxBuyBps, t.taxSellBps);

        if (!inp.allowFirstBuy) {
            require(t.sold == 0, "sim: tokens were sold inside createToken (a first buy)");
            require(IERC20Min(c.token).balanceOf(inp.from) == 0, "sim: the launcher holds tokens after createToken (a first buy)");
            require(_quoteBalance(inp, c.vault) == 0, "sim: the vault holds tax right after createToken (a first buy)");
            for (uint256 i; i < c.logs.length; ++i) {
                require(
                    !(c.logs[i].emitter == address(M) && c.logs[i].topics[0] == T_TRADE),
                    "sim: a Trade event was emitted inside createToken (a first buy)"
                );
            }
        }
        if (!inp.skipKernel) {
            if (inp.dep.quote == address(0)) {
                require(v.QUOTE() == address(0), "sim: the vault's quote is not native OKB (kernel v1 cannot bind it)");
            } else {
                require(v.QUOTE() == inp.dep.quote, "sim: the vault's quote is not USDT0 (kernel v2 cannot bind it)");
                require(t.quote == inp.dep.quote, "sim: the curve's quote is not USDT0 (kernel v2 cannot bind it)");
            }
            require(M.snipeBpsNow(c.token) == 0, "sim: anti-snipe is on (the kernel skips buys while it is)");
            (, uint64 founderEndsAt,,) = M.founderRound(c.token);
            require(founderEndsAt == 0, "sim: a founder round is open");
        }
    }

    // ───────────────────────────── 4: bind ─────────────────────────────

    function _bind(Inputs memory inp, Created memory c) internal {
        IKernelV1 k = IKernelV1(inp.kernel);
        require(inp.kernel.code.length != 0, "sim: the kernel address has no code");
        require(k.token() == address(0), "sim: the kernel is already bound to a token");

        // An unrelated caller: bind then succeeds only if the token's creator is the envelope's launcher, which
        // is what lets the keeper (or anyone) bind. The launcher itself could bind a token another wallet made.
        address binder = makeAddr("sim: unrelated binder");
        vm.prank(binder, binder);
        try k.bind(c.token) {}
        catch (bytes memory err) {
            revert(string.concat("sim: kernel.bind(token) reverted: ", _bindError(err)));
        }
        require(k.token() == c.token, "sim: kernel.token() is not the new token after bind");
        require(k.vault() == c.vault, "sim: kernel.vault() is not the token's vault after bind");
        if (inp.dep.present) {
            require(
                IKernelFactoryV1(inp.dep.kernelFactory).kernelOf(c.token) == inp.kernel,
                "sim: the KernelFactory does not name this kernel for the token after bind"
            );
        }
        console2.log("kernel.bind(token) succeeded, called by an unrelated address");
        console2.log("  kernel         ", inp.kernel);
        console2.log("  chip id        ", k.chipId());
    }

    // ───────────────────────────── 5: an unrelated buyer pays tax into the vault ─────────────────────────────

    function _outsiderBuy(Created memory c) internal returns (uint256 tax) {
        address buyer = makeAddr("sim: unrelated funded buyer");
        uint256 amount = 1 ether;
        vm.deal(buyer, 10 ether);
        uint256 before = c.vault.balance;
        vm.prank(buyer, buyer);
        M.buy{value: amount}(c.token, amount, 0);
        tax = c.vault.balance - before;
        CurveToken memory t = M.tokens(c.token);
        require(tax == (amount * t.taxBuyBps) / 10_000, "sim: the vault did not receive amount * taxBuyBps / 10000");
        require(tax != 0, "sim: the buy put no tax in the vault");
        require(IERC20Min(c.token).balanceOf(buyer) != 0, "sim: the buyer received no tokens");
        console2.log("an unrelated address bought 1 OKB on the curve");
        console2.log("  tax in the vault (wei)", tax);
    }

    /// @dev Kernel v2: the same buy in USD₮0. The buyer is an unrelated address the fork credits with USD₮0 (a storage
    ///      write, `deal`); no team wallet pays or buys anything.
    function _outsiderBuyQuote(Inputs memory inp, Created memory c) internal returns (uint256 tax) {
        address buyer = makeAddr("sim: unrelated funded buyer");
        uint256 amount = 10e6; // 10 USD₮0
        IERC20Min q = IERC20Min(inp.dep.quote);
        deal(address(q), buyer, 100e6);
        uint256 before = q.balanceOf(c.vault);
        vm.startPrank(buyer, buyer);
        q.approve(address(M), amount);
        M.buy(c.token, amount, 0);
        vm.stopPrank();
        tax = q.balanceOf(c.vault) - before;
        CurveToken memory t = M.tokens(c.token);
        require(tax == (amount * t.taxBuyBps) / 10_000, "sim: the vault did not receive amount * taxBuyBps / 10000 (USDT0)");
        require(tax != 0, "sim: the buy put no tax in the vault");
        require(IERC20Min(c.token).balanceOf(buyer) != 0, "sim: the buyer received no tokens");
        console2.log("an unrelated address bought 10 USDT0 on the curve");
        console2.log("  tax in the vault (USDT0 base units)", tax);
    }

    // ───────────────────────────── 6: one epoch later, settle ─────────────────────────────

    /// @dev Working values of the settle step, kept in memory to stay inside the stack.
    struct SettleView {
        uint32 last; // kernel.lastEpoch() before settle
        uint32 n0; // kernel.count() before settle
        uint256 kernelBefore;
        uint256 vaultBefore;
        uint256 reserveBefore;
        uint256 spent; // native OKB the kernel paid for its own curve buy
        uint256 taxBack; // tax of that buy, which returns to the kernel's own vault
        bool claimed;
    }

    function _settle(Inputs memory inp, Created memory c, uint256 tax) internal {
        IKernelV1 k = IKernelV1(inp.kernel);
        SettleView memory s;

        // Warp to the next epoch using only epochNow(): the epoch length is in the envelope, whose layout
        // chips/INTERFACE.md does not declare.
        s.last = k.lastEpoch();
        uint256 steps;
        while (k.epochNow() <= s.last) {
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 60);
            require(++steps <= 44_640, "sim: kernel.epochNow() did not advance within 31 days");
        }

        s.n0 = k.count();
        s.kernelBefore = _quoteBalance(inp, inp.kernel);
        s.vaultBefore = _quoteBalance(inp, c.vault);
        s.reserveBefore = k.reserve();
        require(s.vaultBefore >= tax && s.vaultBefore != 0, "sim: the vault lost its tax before settle");

        (uint32 n, Vm.Log[] memory logs) = _callSettle(k);

        // a record was written
        require(k.count() == s.n0 + 1 && n == s.n0 + 1, "sim: settle did not write exactly one record");
        Record memory r = k.records(n);
        require(r.epoch == k.lastEpoch() && r.epoch > s.last, "sim: the record's epoch is not the settled epoch");
        require(r.time == block.timestamp, "sim: the record's time is not the block time");
        require(r.flags & FLAG_CLAIM_FAILED == 0, "sim: the record says the vault claim failed (flag 4)");

        // the vault's tax moved into the kernel
        _readSettleLogs(inp, c, logs, s);
        require(s.claimed, "sim: the vault emitted no Claimed event during settle");
        require(
            uint256(r.inflow) + s.reserveBefore == s.kernelBefore + s.vaultBefore,
            "sim: the record's inflow is not the tax that was in the vault"
        );
        require(
            _quoteBalance(inp, inp.kernel) == s.kernelBefore + s.vaultBefore - s.spent,
            "sim: the kernel's balance is not (before + claimed tax - its own curve buy)"
        );
        require(
            _quoteBalance(inp, c.vault) == s.taxBack, "sim: the vault is not empty apart from the tax of the kernel's own buy"
        );

        console2.log("kernel.settle() wrote a record one epoch later");
        console2.log("  record number  ", uint256(n));
        console2.log("  epoch          ", uint256(r.epoch));
        if (inp.dep.quote == address(0)) {
            console2.log("  inflow (wei)   ", uint256(r.inflow));
            console2.log("  flags          ", uint256(r.flags));
            console2.log("  clampBits      ", uint256(r.clampBits));
            console2.log("  allowance (wei)", uint256(r.allow));
            console2.log("  buy decided (wei)", uint256(r.buyDecided));
            console2.log("  kernel buy (wei)", s.spent);
            console2.log("  kernel balance (wei)", inp.kernel.balance);
        } else {
            console2.log("  inflow (USDT0 base units)", uint256(r.inflow));
            console2.log("  flags          ", uint256(r.flags));
            console2.log("  clampBits      ", uint256(r.clampBits));
            console2.log("  input word     ", vm.toString(abi.encodePacked(r.inputs)));
            console2.log("  allowance (USDT0 base units)", uint256(r.allow));
            console2.log("  buy decided (USDT0 base units)", uint256(r.buyDecided));
            console2.log("  kernel buy (USDT0 base units)", s.spent);
            console2.log("  kernel USDT0 balance", IERC20Min(inp.dep.quote).balanceOf(inp.kernel));
        }
    }

    /// @dev settle() is called by an unrelated address: anyone may call it.
    function _callSettle(IKernelV1 k) private returns (uint32 n, Vm.Log[] memory logs) {
        address keeper = makeAddr("sim: unrelated keeper");
        vm.deal(keeper, 1 ether);
        vm.recordLogs();
        vm.prank(keeper, keeper);
        try k.settle() returns (uint32 n_) {
            n = n_;
        } catch (bytes memory err) {
            revert(string.concat("sim: kernel.settle() reverted: ", _errorName(err)));
        }
        logs = vm.getRecordedLogs();
    }

    /// @dev What settle did, read from the vault's Claimed event and from IGNIX's Trade events.
    function _readSettleLogs(Inputs memory inp, Created memory c, Vm.Log[] memory logs, SettleView memory s) private pure {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length != 3) continue;
            if (l.emitter == c.vault && l.topics[0] == T_CLAIMED) {
                require(address(uint160(uint256(l.topics[1]))) == inp.kernel, "sim: the vault paid someone other than the kernel");
                require(
                    l.topics[2] == bytes32(uint256(uint160(inp.dep.quote))),
                    "sim: the vault paid an asset other than the launch's quote before graduation"
                );
                require(abi.decode(l.data, (uint256)) == s.vaultBefore, "sim: the vault did not pay its whole balance");
                s.claimed = true;
            } else if (l.emitter == address(M) && l.topics[0] == T_TRADE) {
                require(address(uint160(uint256(l.topics[1]))) == c.token, "sim: settle traded another token");
                require(address(uint160(uint256(l.topics[2]))) == inp.kernel, "sim: settle bought for someone other than the kernel");
                (bool isBuy, uint256 gross, uint256 taxFee) = _tradeFields(l.data);
                require(isBuy, "sim: settle sold on the curve");
                s.spent += gross;
                s.taxBack += taxFee;
            }
        }
    }

    /// @dev Trade(..., bool isBuy, uint256 gross, uint256 net, uint256 curveQuote, uint256 tokens, uint256 platformFee, uint256 taxFee, uint128 collected)
    function _tradeFields(bytes memory data) private pure returns (bool isBuy, uint256 gross, uint256 taxFee) {
        require(data.length == 256, "sim: unexpected Trade event data");
        uint256 b;
        assembly ("memory-safe") {
            b := mload(add(data, 0x20))
            gross := mload(add(data, 0x40))
            taxFee := mload(add(data, 0xe0))
        }
        isBuy = b != 0;
    }

    // ───────────────────────────── revert data, in words ─────────────────────────────

    function _errorName(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4) return "(no revert data)";
        bytes4 s = bytes4(ret);
        if (s == bytes4(keccak256("BadSignature()"))) {
            return "BadSignature(): the calldata, the sender or the Manager's fee settings are not what the platform signed";
        }
        if (s == bytes4(keccak256("SignatureExpired()"))) return "SignatureExpired(): the deadline has passed";
        if (s == bytes4(keccak256("FactoryChanged()"))) return "FactoryChanged(): the template factory was rotated after signing";
        if (s == bytes4(keccak256("BadValue()"))) return "BadValue(): msg.value is not listingFee + firstBuy, or a launch rule is broken";
        if (s == bytes4(keccak256("FeeTooHigh()"))) return "FeeTooHigh(): a fee, tax or anti-snipe value is out of range";
        if (s == bytes4(keccak256("Paused()"))) return "Paused(): the path is paused on the Manager";
        if (s == bytes4(keccak256("NotConfigured()"))) return "NotConfigured()";
        if (s == bytes4(keccak256("ECDSAInvalidSignature()"))) return "ECDSAInvalidSignature()";
        if (s == bytes4(keccak256("ECDSAInvalidSignatureLength(uint256)"))) return "ECDSAInvalidSignatureLength(uint256)";
        if (s == bytes4(keccak256("ECDSAInvalidSignatureS(bytes32)"))) return "ECDSAInvalidSignatureS(bytes32)";
        if (s == bytes4(keccak256("EpochNotElapsed()"))) return "EpochNotElapsed()";
        if (s == bytes4(keccak256("InsufficientGas()"))) return "InsufficientGas()";
        if (s == bytes4(keccak256("StepFailed()"))) return "StepFailed(): the chip evaluator failed";
        if (s == bytes4(keccak256("NotBound()"))) return "NotBound()";
        if (s == bytes4(keccak256("LockHeld()"))) return "LockHeld(): a buy was refused because the caller holds the callee's lock";
        if (s == bytes4(keccak256("OnlyClone()"))) return "OnlyClone(): this is the kernel implementation, not a kernel";
        if (s == bytes4(0x08c379a0) && ret.length >= 68) {
            bytes memory body = new bytes(ret.length - 4);
            for (uint256 i; i < body.length; ++i) {
                body[i] = ret[i + 4];
            }
            return abi.decode(body, (string));
        }
        return vm.toString(ret);
    }

    /// @dev `BindCheck(uint8)` and its codes are the kernel's own (contracts/core/src/Kernel.sol `bind`, interface
    ///      revision 2). They are not part of chips/INTERFACE.md, so an unknown error is printed raw.
    function _bindError(bytes memory err) internal pure returns (string memory) {
        if (err.length == 36 && bytes4(err) == bytes4(keccak256("BindCheck(uint8)"))) {
            uint256 code = uint8(err[35]);
            if (code == 1) return "BindCheck(1): the Manager has no vault for the token";
            if (code == 2) return "BindCheck(2): the vault RECIPIENT is not this kernel";
            if (code == 3) return "BindCheck(3): the vault TOKEN is another token";
            if (code == 4) return "BindCheck(4): the quote is not native OKB";
            if (code == 5) return "BindCheck(5): neither the token's creator nor the caller is the envelope's launcher";
            if (code == 6) return "BindCheck(6): the token has no tax";
            if (code == 7) return "BindCheck(7): the kernel does not hold its chip NFT";
        }
        if (err.length >= 4 && bytes4(err) == bytes4(keccak256("AlreadyBound()"))) return "AlreadyBound()";
        return _errorName(err);
    }
}
