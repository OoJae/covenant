// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ICPU} from "./interfaces/ICPU.sol";
import {Transistors} from "./Transistors.sol";
import {NetlistVM} from "./lib/NetlistVM.sol";
import {SSTORE2} from "./lib/SSTORE2.sol";

/// @title Circuits — 一台 CPU 的电路（ERC-721，实现 ICPU）
/// @notice 该合约地址 = 这台 CPU 的身份。持有全部网表，实现永久的 eval/step。
///         流片后无 setter、无 owner 权限、无升级路径（逻辑虽在 beacon 后，但一旦封印即冻结）。
contract Circuits is Initializable, ERC721Upgradeable, ICPU {
    uint256 internal constant MAX_CHUNK = 24000; // EIP-170 (24576) 下的安全分块

    struct Circ {
        address[] chunks;  // 网表的 SSTORE2 指针（按顺序拼接）
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gateCount;
        bool exists;
    }

    uint256 internal constant MAX_PINS = 1 << 16; // nIn/nOut 上界，防超大 nIn 造成 eval OOG（审计 L-4）

    Transistors public transistorsContract;
    mapping(uint256 => Circ) internal _circ;
    uint256 public nextId;
    // 注：factory 的存储声明放在合约末尾（append-only 布局，审计二轮 R2-1）。

    event TapedOut(uint256 indexed circuitId, address indexed author, uint32 gateCount, uint32 nState);
    event FeeHeld(uint256 indexed circuitId, uint256 amount);   // 国库没收成功、费用暂留本合约

    /// @notice 每次流片收取的协议费（每个电路一份），全额转入协议国库。常量不占存储槽，信标升级不改布局。
    uint256 public constant TAPEOUT_FEE = 0.0013 ether;
    address public constant TREASURY = 0xEBeceDeA36e598b64E17f8d519EB77441C539F76;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(string calldata name_, string calldata symbol_, address transistors_, address factory_)
        external initializer
    {
        __ERC721_init(name_, symbol_);
        transistorsContract = Transistors(transistors_);
        factory = factory_;
    }

    function transistors() external view returns (address) {
        return address(transistorsContract);
    }

    // ------------------------------------------------------------------ 流片

    /// @notice 把网表蚀刻上链，铸出电路 NFT。不可逆。
    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256 circuitId) {
        require(msg.value == TAPEOUT_FEE, "tapeout fee");
        require(nOut > 0, "no outputs");
        require(nIn <= MAX_PINS && nOut <= MAX_PINS, "too many pins"); // L-4
        (uint256 nNand, uint256 nLatch, uint32 nState, uint32 gateCount) =
            NetlistVM.analyze(nl, nIn, nOut, factory);

        // 从调用者处销毁对应数量的晶体管
        if (nNand > 0) transistorsContract.burnFrom(msg.sender, transistorsContract.NAND(), nNand);
        if (nLatch > 0) transistorsContract.burnFrom(msg.sender, transistorsContract.LATCH(), nLatch);

        // SSTORE2 写入网表（超长自动分块）
        circuitId = ++nextId;
        Circ storage c = _circ[circuitId];
        c.nIn = nIn; c.nOut = nOut; c.nState = nState; c.gateCount = gateCount; c.exists = true;

        uint256 off = 0;
        while (off < nl.length) {
            uint256 end = off + MAX_CHUNK;
            if (end > nl.length) end = nl.length;
            c.chunks.push(SSTORE2.write(nl[off:end]));
            off = end;
        }

        _mint(msg.sender, circuitId);
        emit TapedOut(circuitId, msg.sender, gateCount, nState);

        // 转账限 3 万 gas、失败不回滚：国库出任何问题都卡不住全网流片；没转出去的钱留在本合约，任何人可调 sweepFees 补转
        (bool ok, ) = TREASURY.call{value: msg.value, gas: 30_000}("");
        if (!ok) emit FeeHeld(circuitId, msg.value);
    }

    /// @notice 把本合约里滞留的流片费转给国库。只能转给常量 TREASURY，任何人可调。
    function sweepFees() external {
        (bool ok, ) = TREASURY.call{value: address(this).balance}("");
        require(ok, "sweep");
    }

    // ------------------------------------------------------------------ ICPU（永久 view）

    function netlist(uint256 circuitId) public view returns (bytes memory nl) {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        for (uint256 i = 0; i < c.chunks.length; i++) {
            nl = bytes.concat(nl, SSTORE2.read(c.chunks[i]));
        }
    }

    function circuitInfo(uint256 circuitId)
        external view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount)
    {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        return (c.nIn, c.nOut, c.nState, c.gateCount);
    }

    function eval(uint256 circuitId, bytes calldata inputs)
        external view returns (bytes memory outputs)
    {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        require(c.nState == 0, "has latch: use step");
        (, outputs) = NetlistVM.run(netlist(circuitId), c.nIn, c.nOut, "", inputs);
    }

    function step(uint256 circuitId, bytes calldata state, bytes calldata inputs)
        external view returns (bytes memory newState, bytes memory outputs)
    {
        Circ storage c = _circ[circuitId];
        require(c.exists, "no circuit");
        (newState, outputs) = NetlistVM.run(netlist(circuitId), c.nIn, c.nOut, state, inputs);
    }

    // ---- 追加式存储（append-only；新变量一律加在这里，绝不插到已有变量前，审计二轮 R2-1）----
    address public factory; // 工厂地址，作为 REF 目标白名单登记表（审计 H-2）
    /// @dev 预留存储槽，供开发期升级新增状态变量而不错位（审计 L-3）。
    uint256[44] private __gap;
}
