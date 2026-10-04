// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICPU} from "../interfaces/ICPU.sol";

/// @dev 工厂登记表：只有它登记过的 Circuits 克隆才允许被 REF 引用（审计 H-2）。
interface ICircuitRegistry {
    function isCPU(address) external view returns (bool);
}

/// @title NetlistVM — 链上网表虚拟机（技术文档 §3/§4 的 Solidity 实现）
/// @notice 与 web/src 里的 JS 仿真器逐位一致：多字节整数大端(u24/u64)，位打包小端，
///         求值语义 state[t+1]=f(state[t],inputs)，输出=信号空间最后 nOut 个信号。
///         元件：NAND(0)=7字节 / LATCH(1)=4字节 / REF(2)=变长。
library NetlistVM {
    uint8 constant OP_NAND = 0x00;
    uint8 constant OP_LATCH = 0x01;
    uint8 constant OP_REF = 0x02;

    /// @dev 信号/状态/门数上界（= u24 信号空间上限）。防 uint32 截断与外部谎报 nState 触发 OOG（审计 H-2/L-1）。
    uint256 constant MAX_SIGNALS = 1 << 24;

    // ------------------------------------------------------------------ 解析/校验（tapeout 用）

    /// @notice 校验拓扑序并统计规模。含 REF 时递归调用被引用电路的 circuitInfo。
    /// @return nNand      本层 NAND 数
    /// @return nLatch     本层 LATCH 数
    /// @return nState     LATCH 总数（含被引用电路，递归）
    /// @return gateCount  晶体管总数（含被引用电路，递归）
    /// @param registry 工厂地址；REF 目标必须是它登记过的 CPU（审计 H-2）。
    function analyze(bytes memory nl, uint32 nIn, uint32 nOut, address registry)
        internal view
        returns (uint256 nNand, uint256 nLatch, uint32 nState, uint32 gateCount)
    {
        uint256 p = 0;
        uint256 outPos = uint256(2) + nIn; // 下一个输出信号索引
        uint256 stateAcc = 0;
        uint256 gateAcc = 0;
        uint256 maxLatchD = 0; // 追踪 LATCH.d 上界，事后校验（审计 M-2）

        while (p < nl.length) {
            uint8 op = uint8(nl[p]);
            p += 1;
            if (op == OP_NAND) {
                require(_u24(nl, p) < outPos && _u24(nl, p + 3) < outPos, "NAND: future signal");
                p += 6;
                nNand += 1;
                outPos += 1;
            } else if (op == OP_LATCH) {
                uint256 d = _u24(nl, p); // d 是时序引用，允许指向靠后信号，但必须存在
                if (d > maxLatchD) maxLatchD = d;
                p += 3;
                nLatch += 1;
                outPos += 1;
            } else if (op == OP_REF) {
                (uint256 np, uint256 addState, uint256 addGate, uint256 rOut) = _refCheck(nl, p, outPos, registry);
                p = np; stateAcc += addState; gateAcc += addGate; outPos += rOut;
            } else {
                revert("bad opcode");
            }
        }

        require(outPos >= uint256(2) + nIn + nOut, "too few signals for outputs");
        // M-2：LATCH.d 必须指向存在的信号（0 .. outPos-1），否则 step 会永久越界 revert
        require(nLatch == 0 || maxLatchD < outPos, "LATCH d out of range");
        // L-1：防 uint32 截断
        uint256 stateTotal = stateAcc + nLatch;
        uint256 gateTotal = gateAcc + nNand + nLatch;
        require(stateTotal <= MAX_SIGNALS && gateTotal <= type(uint32).max, "size overflow");
        nState = uint32(stateTotal);
        gateCount = uint32(gateTotal);
    }

    /// @dev 校验一个 REF 并返回其规模贡献（拆出以缓解 analyze 的栈压力）。
    function _refCheck(bytes memory nl, uint256 p, uint256 outPos, address registry)
        private view
        returns (uint256 newP, uint256 addState, uint256 addGate, uint256 rOut)
    {
        address cpu = _addr(nl, p);
        uint256 cid = _u64(nl, p + 20);
        uint8 rIn = uint8(nl[p + 28]);
        rOut = uint8(nl[p + 29]);
        p += 30;
        for (uint256 k = 0; k < rIn; k++) {
            require(_u24(nl, p) < outPos, "REF: future signal");
            p += 3;
        }
        // H-2：只允许引用工厂登记过的 CPU（本协议的、封印后不可变的 Circuits 克隆），
        //      杜绝引用任意/可变外部合约破坏"永不可改"、以及 selfdestruct/谎报触发的 DoS。
        require(registry != address(0) && ICircuitRegistry(registry).isCPU(cpu), "REF: target not a registered CPU");
        (uint32 sIn, uint32 sOut, uint32 sState, uint32 sGate) = ICPU(cpu).circuitInfo(cid);
        require(sIn == rIn && sOut == rOut, "REF: pin mismatch");
        // 纵深防御：即便被引用方也是本协议 CPU，仍对其状态规模设上界，防 OOG。
        // （sGate 本就是 uint32，无需再判上界——审计二轮 F4 去除赘余判断。）
        require(sState <= MAX_SIGNALS, "REF size");
        return (p, sState, sGate, rOut);
    }

    // ------------------------------------------------------------------ 本层真烧 / 直接引用（PoD v11 用）

    /// @notice 这份网表**本层真正烧掉**的 NAND 数与 LATCH 数。
    ///
    /// @dev    **不递归，这是重点。** REF 只是引用一份早已存在、早已被烧掉的电路，
    ///         不会再烧一次晶体管。所以「烧掉的量」必须只数本层，绝不能用递归的
    ///         `gateCount` 代替——同一份设计被 REF 引用 N 次，`gateCount` 放大 N 倍
    ///         而边际成本为零，等于给出无限刷分的通道。
    ///         链上实测：626 份网表递归 g 合计 300,702，而真烧只有 13,264（差 22.7 倍）。
    ///
    ///         纯字节扫描：不递归、不做任何外部调用，比 `analyze` / `depthOf` 便宜一个量级。
    function burnOf(bytes memory nl) internal pure returns (uint256 nNand, uint256 nLatch) {
        uint256 p = 0;
        while (p < nl.length) {
            uint8 op = uint8(nl[p]);
            p += 1;
            if (op == OP_NAND) { nNand += 1; p += 6; }
            else if (op == OP_LATCH) { nLatch += 1; p += 3; }
            else if (op == OP_REF) { p += 30 + uint256(uint8(nl[p + 28])) * 3; }
            else revert("bad opcode");
        }
    }

    /// @notice 这份网表**直接**引用了哪些电路（不递归、不去重）。
    ///
    /// @dev    PoD v11 的资格检查用：网表里每一个 REF 的目标都必须落在合格处理器上，
    ///         引用了外部处理器 = 完全不合格。这里只返回**直接**引用，由调用方按
    ///         (cpu, circuitId) 自己递归并把结果记进 storage——这样全网每个电路只查一次，
    ///         而不是每次注册都把整棵引用树重走一遍。
    function refTargets(bytes memory nl) internal pure returns (address[] memory cpus, uint256[] memory ids) {
        (,, uint256 nRef) = _scanSizes(nl, 0);
        cpus = new address[](nRef);
        ids = new uint256[](nRef);
        uint256 p = 0;
        uint256 i = 0;
        while (p < nl.length) {
            uint8 op = uint8(nl[p]);
            p += 1;
            if (op == OP_NAND) { p += 6; }
            else if (op == OP_LATCH) { p += 3; }
            else {
                cpus[i] = _addr(nl, p);
                ids[i] = _u64(nl, p + 20);
                p += 30 + uint256(uint8(nl[p + 28])) * 3;
                i += 1;
            }
        }
    }

    // ------------------------------------------------------------------ 关键路径深度（PoD 挖矿用）

    /// @dev 深度递归穿透 REF 的层数上限。真实链上电路最深见过 3 层，16 层留足余量，
    ///      同时挡住「无限自嵌套把 gas 烧穿」（REF 目标必是已流片的更早电路，本不可能成环，
    ///      但这是一条不依赖该前提的兜底）。
    uint256 private constant MAX_REF_LEVELS = 16;
    /// @dev 同一次深度计算里，最多记住多少个不同的被引用电路（备忘录容量）。
    ///      超出后只是重复计算（更费 gas），不影响结果。
    uint256 private constant MEMO_CAP = 64;

    /// @dev 递归备忘录：同一个 (cpu, circuitId) 在一次计算里只解一次。
    ///      memory 结构体按引用传递，所以整棵递归共用同一份。
    struct DepthMemo {
        bytes32[] keys;
        uint256[] vals;
        uint256 len;
    }

    /// @notice 关键路径深度（组合逻辑最长门级路径），**递归穿透 REF**。
    ///
    ///         语义：常量与输入引脚 = 0；`NAND` 输出 = 1 + max(两输入)；
    ///         `LATCH` 输出 = 0（寄存器边界，时序级之间重新起算）；
    ///         `REF` 的每个输出 = max(该 REF 全部输入信号的深度) + 被引用电路自身的深度。
    ///         电路深度 = 全部输出引脚深度的最大值。
    ///
    /// @dev    **为什么必须递归**：`gateCount` 本来就是递归统计的，深度若不递归，
    ///         把一个 1204 门、深度 114 的电路用一个 REF 包一层，深度会被算成 1。
    ///         PoD 的成本函数是 `C = A·d³`，这等于把权重放大 114³ ≈ 148 万倍。
    ///         链上真实数据里 68 个有规模的电路有 30 个含 REF，这是必修项，不是优化。
    ///
    ///         REF 按**黑盒**计价：它的每个输出都按「最坏输入 → 最坏输出」的路径算。
    ///         这对模块化设计是轻微高估（子电路里某个输出其实更浅），但方向是安全的——
    ///         **包一层 REF 永远不可能让深度变小**，刷分路径被堵死。
    ///
    /// @param registry 工厂地址；REF 目标必须是它登记过的 CPU（与 `analyze` 同一条白名单）。
    function depthOf(bytes memory nl, uint32 nIn, uint32 nOut, address registry)
        internal view returns (uint256)
    {
        DepthMemo memory memo = DepthMemo({
            keys: new bytes32[](MEMO_CAP),
            vals: new uint256[](MEMO_CAP),
            len: 0
        });
        return _depth(nl, nIn, nOut, registry, 0, memo);
    }

    function _depth(bytes memory nl, uint32 nIn, uint32 nOut, address registry, uint256 level, DepthMemo memory memo)
        private view returns (uint256 dep)
    {
        uint256 regIn;   // 终止在寄存器输入上的最长组合路径（见下面 OP_LATCH 那一段）
        require(level <= MAX_REF_LEVELS, "REF nesting too deep");
        (uint256 nSignals,,) = _scanSizes(nl, nIn);
        require(nSignals >= uint256(2) + nIn + nOut, "too few signals for outputs");

        uint256[] memory d = new uint256[](nSignals); // 常量(0/1)与输入引脚天然是 0
        uint256 p = 0;
        uint256 outPos = uint256(2) + nIn;

        while (p < nl.length) {
            uint8 op = uint8(nl[p]);
            p += 1;
            if (op == OP_NAND) {
                uint256 a = _u24(nl, p);
                uint256 b = _u24(nl, p + 3);
                p += 6;
                require(a < outPos && b < outPos, "NAND: future signal");
                d[outPos] = 1 + (d[a] > d[b] ? d[a] : d[b]);
                outPos += 1;
            } else if (op == OP_LATCH) {
                // ★ 2026-08-20 第五轮审计：LATCH 的**输出**深度确实是 0（寄存器边界），
                //   但它的 **d 输入**是一条组合路径的终点 —— 时钟周期由「最长组合路径」决定，
                //   而那条路径可以终止在输出引脚，也可以终止在寄存器输入。
                //   旧版只量输出引脚，于是把输出直接从寄存器引出就能得到 d≈0，
                //   `C = A·d^β` 当场塌掉，一个更差的时序电路既夺榜又拿满 QCAP 溢价。
                uint256 dIn = _u24(nl, p);
                require(dIn < nSignals, "LATCH: bad d");
                if (d[dIn] > regIn) regIn = d[dIn];
                p += 3;
                outPos += 1;
            } else {                 // REF
                (uint256 np, uint256 rOut, uint256 outDepth) = _depthRef(nl, p, d, outPos, registry, level, memo);
                for (uint256 k = 0; k < rOut; k++) d[outPos + k] = outDepth;
                p = np;
                outPos += rOut;
            }
        }

        for (uint256 i = 0; i < nOut; i++) {
            uint256 v = d[nSignals - nOut + i];
            if (v > dep) dep = v;
        }
        if (regIn > dep) dep = regIn;   // 寄存器输入上的那条路径同样决定时钟周期
    }

    /// @dev 处理一个 REF 的深度贡献（拆出来缓解栈压力）。
    function _depthRef(
        bytes memory nl, uint256 p, uint256[] memory d, uint256 outPos,
        address registry, uint256 level, DepthMemo memory memo
    ) private view returns (uint256 newP, uint256 rOut, uint256 outDepth) {
        address cpu = _addr(nl, p);
        uint256 cid = _u64(nl, p + 20);
        uint8 rIn = uint8(nl[p + 28]);
        rOut = uint8(nl[p + 29]);
        p += 30;

        uint256 inMax = 0;
        for (uint256 k = 0; k < rIn; k++) {
            uint256 s = _u24(nl, p);
            require(s < outPos, "REF: future signal");
            if (d[s] > inMax) inMax = d[s];
            p += 3;
        }
        outDepth = inMax + _subDepth(cpu, cid, registry, level + 1, memo);
        return (p, rOut, outDepth);
    }

    /// @dev 取被引用电路自身的深度：先查备忘录，未命中则取回它的网表递归计算。
    function _subDepth(address cpu, uint256 cid, address registry, uint256 level, DepthMemo memory memo)
        private view returns (uint256 v)
    {
        bytes32 key = keccak256(abi.encodePacked(cpu, cid));
        for (uint256 i = 0; i < memo.len; i++) {
            if (memo.keys[i] == key) return memo.vals[i];
        }
        // 与 analyze 同一条白名单：只认工厂登记过的 CPU（其网表已永久固化）。
        require(registry != address(0) && ICircuitRegistry(registry).isCPU(cpu), "REF: target not a registered CPU");
        (uint32 sIn, uint32 sOut,,) = ICPU(cpu).circuitInfo(cid);
        v = _depth(ICPU(cpu).netlist(cid), sIn, sOut, registry, level, memo);
        if (memo.len < MEMO_CAP) {
            memo.keys[memo.len] = key;
            memo.vals[memo.len] = v;
            memo.len += 1;
        }
    }

    // ------------------------------------------------------------------ 求值（eval/step 用）

    /// @notice 通用求值。stateBits/inputBits/返回值均为位打包（小端位序）。
    function run(
        bytes memory nl,
        uint32 nIn,
        uint32 nOut,
        bytes memory stateBits,
        bytes memory inputBits
    ) internal view returns (bytes memory newStateBits, bytes memory outputBits) {
        (uint256 nSignals, uint256 nLatch, uint256 nRef) = _scanSizes(nl, nIn);

        // 解析每个 REF 的子状态长度（circuitInfo），用于切片/放置状态
        uint256[] memory refNState = new uint256[](nRef);
        uint256 nState = nLatch;
        {
            uint256 p = 0; uint256 ri = 0;
            while (p < nl.length) {
                uint8 op = uint8(nl[p]); p += 1;
                if (op == OP_NAND) { p += 6; }
                else if (op == OP_LATCH) { p += 3; }
                else { // REF
                    address cpu = _addr(nl, p); uint256 cid = _u64(nl, p + 20);
                    uint8 rIn = uint8(nl[p + 28]);
                    p += 30 + uint256(rIn) * 3;
                    (,, uint32 sState,) = ICPU(cpu).circuitInfo(cid);
                    require(sState <= MAX_SIGNALS, "REF size"); // 防谎报 nState 触发 OOG（审计 H-2）
                    refNState[ri] = sState; nState += sState; ri += 1;
                }
            }
        }
        require(nState <= MAX_SIGNALS, "state overflow");

        bytes memory sig = new bytes(nSignals);
        sig[1] = 0x01; // 常量 1；常量 0 已是默认
        for (uint256 i = 0; i < nIn; i++) {
            if (_getBit(inputBits, i) == 1) sig[2 + i] = 0x01;
        }

        newStateBits = new bytes((nState + 7) / 8);
        uint256[] memory latchD = new uint256[](nLatch);
        uint256[] memory latchSlot = new uint256[](nLatch);

        _execute(nl, nIn, sig, stateBits, newStateBits, refNState, latchD, latchSlot);

        // 输出 = 信号空间最后 nOut 个信号
        outputBits = new bytes((uint256(nOut) + 7) / 8);
        for (uint256 i = 0; i < nOut; i++) {
            if (uint8(sig[nSignals - nOut + i]) == 1) _setBit(outputBits, i);
        }
    }

    /// @dev 主执行循环拆出来避免 stack too deep。
    function _execute(
        bytes memory nl,
        uint32 nIn,
        bytes memory sig,
        bytes memory stateBits,
        bytes memory newStateBits,
        uint256[] memory refNState,
        uint256[] memory latchD,
        uint256[] memory latchSlot
    ) private view {
        uint256 p = 0;
        uint256 outPos = uint256(2) + nIn;
        uint256 statePos = 0;
        uint256 refIdx = 0;
        uint256 li = 0;

        // 第一遍：按声明顺序算出所有信号
        while (p < nl.length) {
            uint8 op = uint8(nl[p]); p += 1;
            if (op == OP_NAND) {
                uint256 a = _u24(nl, p); uint256 b = _u24(nl, p + 3); p += 6;
                sig[outPos] = (uint8(sig[a]) & uint8(sig[b])) == 1 ? bytes1(0) : bytes1(uint8(1));
                outPos += 1;
            } else if (op == OP_LATCH) {
                uint256 d = _u24(nl, p); p += 3;
                sig[outPos] = bytes1(_getBit(stateBits, statePos)); // = 上一周期
                latchD[li] = d; latchSlot[li] = statePos; li += 1;
                statePos += 1; outPos += 1;
            } else { // REF
                (uint256 np, uint256 addedState, uint256 addedOut) =
                    _execRef(nl, p, sig, stateBits, newStateBits, statePos, outPos, refNState[refIdx]);
                p = np; statePos += addedState; outPos += addedOut; refIdx += 1;
            }
        }

        // 第二遍：LATCH 新状态取本周期 d（d 可指向靠后信号 → 反馈回路）
        for (uint256 i = 0; i < li; i++) {
            if (uint8(sig[latchD[i]]) == 1) _setBit(newStateBits, latchSlot[i]);
        }
    }

    /// @dev 处理一个 REF：黑盒 step 递归，写回子输出与子状态。
    function _execRef(
        bytes memory nl,
        uint256 p,
        bytes memory sig,
        bytes memory stateBits,
        bytes memory newStateBits,
        uint256 statePos,
        uint256 outPos,
        uint256 subN
    ) private view returns (uint256 newP, uint256 addedState, uint256 addedOut) {
        address cpu = _addr(nl, p);
        uint256 cid = _u64(nl, p + 20);
        uint8 rIn = uint8(nl[p + 28]);
        uint8 rOut = uint8(nl[p + 29]);
        p += 30;

        bytes memory subIn = new bytes((uint256(rIn) + 7) / 8);
        for (uint256 k = 0; k < rIn; k++) {
            if (uint8(sig[_u24(nl, p)]) == 1) _setBit(subIn, k);
            p += 3;
        }
        bytes memory subState = _slice(stateBits, statePos, subN);
        (bytes memory subNew, bytes memory subOut) = ICPU(cpu).step(cid, subState, subIn);
        for (uint256 k = 0; k < subN; k++) {
            if (_getBit(subNew, k) == 1) _setBit(newStateBits, statePos + k);
        }
        for (uint256 k = 0; k < rOut; k++) {
            sig[outPos + k] = bytes1(_getBit(subOut, k));
        }
        return (p, subN, rOut);
    }

    // ------------------------------------------------------------------ 内部：扫描与位操作

    /// @dev 只看字节即可算出：信号总数、LATCH 数、REF 数。
    /// @notice 数一数网表里有多少个元件是**活的** —— 即它的输出（经任意路径）真的影响到某个输出引脚。
    ///
    /// @dev    ★ 2026-08-20 第五轮审计：抽检条数 `n` 是按矿工自己的门数算的（电路越大、抽得越少，
    ///         下限 MIN_SAMPLES=3）。于是攻击者可以**灌哑元**——堆一批输出不接任何地方的死门——
    ///         把 n 压到 3，`0.5³ = 12.5%` 一碾就过，向量怎么设计都没用。
    ///         实测 651 门的组合电路就能把 n 压到 3。
    ///
    ///         对策：`n` 改按**活门数**算，gas 仍按总门数收。老实电路活门 == 总门，行为一个字不变；
    ///         灌了哑元的电路 n 不降、gas 照付，直接撞死在 `maxRunGas` 闸门上（实测 64.1M ≫ 12M）。
    ///
    ///         只处理 NAND / LATCH：挖矿路径上 REF 已被 `_requireRefsEligible` 彻底禁掉，
    ///         真遇到 REF 就当它整个是活的（保守，不会误伤）。
    function liveOf(bytes memory nl, uint32 nIn, uint32 nOut) internal pure returns (uint256 liveCount) {
        (uint256 nSignals,,) = _scanSizes(nl, nIn);
        require(nSignals >= uint256(2) + nIn + nOut, "too few signals for outputs");
        uint256 outPos = uint256(2) + nIn;

        // 每个信号的两个前驱（存 +1，0 = 无前驱）。REF 的输出记为「无前驱但恒活」。
        uint256[] memory pa = new uint256[](nSignals);
        uint256[] memory pb = new uint256[](nSignals);
        bool[] memory isRef = new bool[](nSignals);

        uint256 p = 0;
        uint256 sig = outPos;
        while (p < nl.length) {
            uint8 op = uint8(nl[p]); p += 1;
            if (op == OP_NAND) {
                pa[sig] = _u24(nl, p) + 1;
                pb[sig] = _u24(nl, p + 3) + 1;
                p += 6; sig += 1;
            } else if (op == OP_LATCH) {
                pa[sig] = _u24(nl, p) + 1;   // LATCH 的 d 可以指向后面的信号（时序反馈），下面的工作表能处理
                p += 3; sig += 1;
            } else {
                uint8 rIn = uint8(nl[p + 28]);
                uint8 rOut = uint8(nl[p + 29]);
                for (uint256 k = 0; k < rOut; k++) isRef[sig + k] = true;
                p += 30 + uint256(rIn) * 3; sig += rOut;
            }
        }

        bool[] memory live = new bool[](nSignals);
        uint256[] memory stack = new uint256[](nSignals);
        uint256 sp = 0;
        for (uint256 i = 0; i < nOut; i++) {
            uint256 o = nSignals - nOut + i;
            if (!live[o]) { live[o] = true; stack[sp++] = o; }
        }
        while (sp > 0) {
            uint256 x = stack[--sp];
            if (x < outPos) continue;                 // 常量与输入引脚不是元件
            if (isRef[x]) continue;                   // REF 的输入这里不展开（挖矿路径上不会出现）
            uint256 a = pa[x];
            if (a != 0 && !live[a - 1]) { live[a - 1] = true; stack[sp++] = a - 1; }
            uint256 b = pb[x];
            if (b != 0 && !live[b - 1]) { live[b - 1] = true; stack[sp++] = b - 1; }
        }
        for (uint256 i = outPos; i < nSignals; i++) if (live[i]) liveCount += 1;
    }

    function _scanSizes(bytes memory nl, uint32 nIn)
        private pure
        returns (uint256 nSignals, uint256 nLatch, uint256 nRef)
    {
        uint256 produced = 0;
        uint256 p = 0;
        while (p < nl.length) {
            uint8 op = uint8(nl[p]); p += 1;
            if (op == OP_NAND) { produced += 1; p += 6; }
            else if (op == OP_LATCH) { produced += 1; nLatch += 1; p += 3; }
            else if (op == OP_REF) {
                uint8 rIn = uint8(nl[p + 28]);
                uint8 rOut = uint8(nl[p + 29]);
                produced += rOut; nRef += 1;
                p += 30 + uint256(rIn) * 3;
            } else revert("bad opcode");
        }
        nSignals = uint256(2) + nIn + produced;
    }

    function _u24(bytes memory b, uint256 p) private pure returns (uint256) {
        return (uint256(uint8(b[p])) << 16) | (uint256(uint8(b[p + 1])) << 8) | uint256(uint8(b[p + 2]));
    }

    function _u64(bytes memory b, uint256 p) private pure returns (uint256 v) {
        for (uint256 i = 0; i < 8; i++) v = (v << 8) | uint8(b[p + i]);
    }

    function _addr(bytes memory b, uint256 p) private pure returns (address a) {
        uint256 v = 0;
        for (uint256 i = 0; i < 20; i++) v = (v << 8) | uint8(b[p + i]);
        a = address(uint160(v));
    }

    function _getBit(bytes memory b, uint256 i) private pure returns (uint8) {
        uint256 byteIdx = i >> 3;
        if (byteIdx >= b.length) return 0;
        return (uint8(b[byteIdx]) >> (i & 7)) & 1;
    }

    function _setBit(bytes memory b, uint256 i) private pure {
        b[i >> 3] = bytes1(uint8(b[i >> 3]) | uint8(1 << (i & 7)));
    }

    function _slice(bytes memory b, uint256 startBit, uint256 lenBits) private pure returns (bytes memory out) {
        out = new bytes((lenBits + 7) / 8);
        for (uint256 k = 0; k < lenBits; k++) {
            if (_getBit(b, startBit + k) == 1) _setBit(out, k);
        }
    }
}
