// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Transistors — 一台 CPU 的晶体管（ERC-1155，两种型号：NAND=0 / LATCH=1）
/// @notice 经 BeaconProxy 克隆。晶体管总数在创建时固定（芯片规格），mint 单调累加、
///         不超过总数；tapeout 时按量销毁。收入用拉取式分账：协议费记给协议钱包、
///         其余记给创建者，各自 withdraw()（审计 M-1，避免任一收款方拒收卡死 mint）。
contract Transistors is Initializable, ERC1155Upgradeable {
    uint256 public constant NAND = 0;
    uint256 public constant LATCH = 1;

    // 极简可升级安全的重入锁（审计 L-2 纵深防御）。存储起始为 0，等价于未进入。
    // 注：_entered 的存储声明放在合约末尾（append-only 布局，审计二轮 R2-1），此处仅定义修饰器。
    modifier nonReentrant() {
        require(_entered != 2, "reentrant");
        _entered = 2;
        _;
        _entered = 1;
    }

    address public creator;        // 创建者，mint 收入归他
    address public circuits;       // 配对的 Circuits 克隆，只有它能销毁
    address public protocolWallet; // 协议钱包
    uint256 public protocolFee;    // 每笔 mint 的协议费（写死进本克隆，创建后不可改）
    uint256 public mintPrice;      // 每个晶体管价格，创建者设定
    uint256 public supplyCap;      // 这台 CPU 一共有多少个晶体管
    uint256 public minted;         // 已 mint 总数（单调，销毁不回补）

    mapping(address => uint256) public owed; // 拉取式分账余额

    string public cpuName;
    string public cpuSymbol;
    string public story;

    event Minted(address indexed to, uint256 indexed id, uint256 amount, uint256 paid);
    event Withdrawn(address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata story_,
        address creator_,
        uint256 supplyCap_,
        uint256 mintPrice_,
        address protocolWallet_,
        uint256 protocolFee_,
        address circuits_
    ) external initializer {
        __ERC1155_init("");
        cpuName = name_;
        cpuSymbol = symbol_;
        story = story_;
        creator = creator_;
        supplyCap = supplyCap_;
        mintPrice = mintPrice_;
        protocolWallet = protocolWallet_;
        protocolFee = protocolFee_;
        circuits = circuits_;
    }

    /// @notice 铸造 amount 个 id 型号（NAND 或 LATCH）晶体管。
    ///         费用 = mintPrice*amount + protocolFee（每笔一次协议费）。
    ///         收入以拉取式记账：协议费记给协议钱包、其余记给创建者；多付部分退回买家。
    function mint(uint256 id, uint256 amount) external payable nonReentrant {
        require(id == NAND || id == LATCH, "bad id");
        require(amount > 0, "zero");
        require(minted + amount <= supplyCap, "supply cap");
        uint256 cost = mintPrice * amount + protocolFee;
        require(msg.value >= cost, "insufficient");

        // Checks-Effects：先记账，再 _mint（会触发接收方钩子），杜绝重入影响
        minted += amount;
        owed[protocolWallet] += protocolFee;
        owed[creator] += mintPrice * amount;
        uint256 refund = msg.value - cost;
        if (refund > 0) owed[msg.sender] += refund; // 多付退回，同样走拉取，避免 push 卡死

        _mint(msg.sender, id, amount, "");
        emit Minted(msg.sender, id, amount, msg.value);
    }

    /// @notice 提取应得的分账余额（拉取式，任一收款方拒收都不会卡死 mint）。
    function withdraw() external nonReentrant {
        uint256 amt = owed[msg.sender];
        require(amt > 0, "nothing owed");
        owed[msg.sender] = 0; // effects before interaction
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "withdraw failed");
        emit Withdrawn(msg.sender, amt);
    }

    /// @notice tapeout 时由配对的 Circuits 合约调用，按量销毁调用者的晶体管。
    /// @dev `from` 恒为发起 tapeout 的地址（Circuits.tapeout 传 msg.sender）；
    ///      访问受 msg.sender==circuits 限制（审计 L-5：该不变量由封印后冻结的 Circuits 逻辑保证）。
    function burnFrom(address from, uint256 id, uint256 amount) external {
        require(msg.sender == circuits, "only circuits");
        _burn(from, id, amount);
    }

    // ---- 追加式存储（append-only；新变量一律加在这里，绝不插到已有变量前，审计二轮 R2-1）----
    uint256 private _entered; // 重入锁存储槽
    /// @dev 预留存储槽（审计 L-3）。
    uint256[44] private __gap;
}
