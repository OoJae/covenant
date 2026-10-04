// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICPU — 一台合法链上 CPU 的永久接口（技术文档 §4）
/// @notice 一旦有电路按此接口被引用，签名就永远不能改。全部为 view：
///         调用永远免费、不产生交易、不需要钱包，任何人任何合约可调，永远。
interface ICPU {
    /// @notice 组合逻辑求值。电路含 LATCH 时 revert。
    /// @param inputs 位打包（小端位序）的输入引脚
    /// @return outputs 位打包的输出引脚
    function eval(uint256 circuitId, bytes calldata inputs)
        external view returns (bytes memory outputs);

    /// @notice 通用求值：给定当前状态与输入，返回下一周期状态与输出。
    ///         组合逻辑电路的 state 传空即可。
    function step(uint256 circuitId, bytes calldata state, bytes calldata inputs)
        external view returns (bytes memory newState, bytes memory outputs);

    /// @notice 组合所需的元信息。
    /// @return nIn        输入引脚数
    /// @return nOut       输出引脚数
    /// @return nState     LATCH 总数（含被引用电路的，递归累计）
    /// @return gateCount  晶体管总数（含被引用电路的，递归累计）
    function circuitInfo(uint256 circuitId) external view returns (
        uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount
    );

    /// @notice 原始网表字节流。
    function netlist(uint256 circuitId) external view returns (bytes memory);

    /// @notice 本 CPU 的晶体管合约地址。
    function transistors() external view returns (address);
}
