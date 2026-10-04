// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SSTORE2 — 把数据作为合约字节码存储（写一次、读无数次），约 200 gas/字节。
/// @notice 网表正是这种场景（技术文档 §3.3）。运行时字节以 0x00(STOP) 开头，
///         保证这段"数据合约"不可被当作代码执行。
library SSTORE2 {
    uint256 internal constant DATA_OFFSET = 1; // 前导 STOP 字节

    /// @notice 把 data 部署成一个数据合约，返回其地址（指针）。
    function write(bytes memory data) internal returns (address pointer) {
        bytes memory runtime = abi.encodePacked(hex"00", data); // STOP + data
        // 极简创建代码：把 runtime 原样返回作为部署后字节码。
        bytes memory creation = abi.encodePacked(
            hex"60_0B_59_81_38_03_80_92_59_39_F3", // 见 solmate SSTORE2 注释
            runtime
        );
        assembly {
            pointer := create(0, add(creation, 0x20), mload(creation))
        }
        require(pointer != address(0), "SSTORE2_WRITE_FAILED");
    }

    /// @notice 读回全部数据（跳过前导 STOP 字节）。
    function read(address pointer) internal view returns (bytes memory) {
        uint256 size = pointer.code.length;
        if (size <= DATA_OFFSET) return "";
        return _readCode(pointer, DATA_OFFSET, size - DATA_OFFSET);
    }

    function _readCode(address pointer, uint256 start, uint256 len)
        private view returns (bytes memory out)
    {
        out = new bytes(len);
        assembly {
            extcodecopy(pointer, add(out, 0x20), start, len)
        }
    }
}
