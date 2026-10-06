// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProbeBase} from "./ProbeBase.sol";
import {IIgnixToken} from "../src/interfaces/IIgnixToken.sol";
import {IDirectedVault} from "../src/interfaces/IDirectedVault.sol";
import {IWOKB} from "../src/interfaces/IUniswapV2.sol";

/// Review probes for docs/design/kernel-v2.md (adversarial review, 2026-10-06). Fork only, read-only:
/// nothing here is broadcast. The platform signer is replaced in fork storage exactly as in the other probes.

interface IERC20R {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniV3PoolR {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256, int256);
}

interface IUniV3FactoryR {
    function getPool(address, address, uint24) external view returns (address);
}

/// A sketch of the converter the review proposes as option (d): USD₮0 in, native OKB pushed into an
/// OKB-quoted Directed vault, where the v1 kernel claims it as tax. Not production code: no TWAP guard here,
/// the test measures the execution price against the pool's own 10-minute TWAP instead.
contract ConverterSketch {
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    uint160 internal constant MIN_SQRT_RATIO_PLUS_1 = 4295128740;
    address public immutable POOL;
    address public immutable VAULT;

    constructor(address pool, address vault) {
        POOL = pool;
        VAULT = vault;
    }

    function flush() external returns (uint256 usdtIn, uint256 okbOut) {
        usdtIn = IERC20R(USDT0).balanceOf(address(this));
        // USD₮0 is token0, WOKB token1: zeroForOne
        IUniV3PoolR(POOL).swap(address(this), true, int256(usdtIn), MIN_SQRT_RATIO_PLUS_1, "");
        okbOut = IWOKB(WOKB).balanceOf(address(this));
        IWOKB(WOKB).withdraw(okbOut);
        (bool ok,) = VAULT.call{value: okbOut}("");
        require(ok, "vault refused");
    }

    function uniswapV3SwapCallback(int256 a0, int256, bytes calldata) external {
        require(msg.sender == POOL, "pool");
        if (a0 > 0) IERC20R(USDT0).transfer(POOL, uint256(a0));
    }

    receive() external payable {
        require(msg.sender == WOKB, "only WOKB");
    }
}

contract NativeRecipient {
    function claim(IDirectedVault v) external returns (uint256) {
        return v.claim(address(0));
    }

    receive() external payable {}
}

contract Q12_KernelV2Review is ProbeBase {
    IERC20R internal constant USDT0 = IERC20R(0x779Ded0c9e1022225f8E0630b35a9b54bE713736);
    IUniV3FactoryR internal constant UNIV3 = IUniV3FactoryR(0x4B2ab38DBF28D31D467aA8993f6c2585981D6804);

    function setUp() public {
        _fork();
    }

    /// The doc's "approve, buyTo, reset to 0" assumes approve never reverts. Classic Ethereum USDT reverts
    /// on a non-zero to non-zero approve; measure USD₮0 on X Layer.
    function test_R1_usdt0_approve_nonzero_to_nonzero_and_return_value() public {
        address k = makeAddr("kernel-like");
        deal(address(USDT0), k, 10e6);
        vm.startPrank(k);
        assertTrue(USDT0.approve(address(M), 5e6), "approve returns true");
        bool ok = USDT0.approve(address(M), 7e6);
        assertTrue(ok);
        assertEq(USDT0.allowance(k, address(M)), 7e6, "non-zero to non-zero approve is accepted");
        assertTrue(USDT0.approve(address(M), 0));
        vm.stopPrank();
    }

    /// The doc rejects (b) because "on-chain liquidity cannot turn USD₮0 into OKB". It checked only the
    /// Uniswap V2 pair and hookless V4 pools. Uniswap V3 on X Layer has a deep USD₮0/WOKB pool.
    function test_R2_univ3_usdt0_wokb_pool_is_deep_and_canonical() public {
        address pool = UNIV3.getPool(address(USDT0), WOKB, 500);
        assertEq(pool, 0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082, "canonical 0.05% pool");
        assertEq(IUniV3PoolR(pool).token0(), address(USDT0));
        assertEq(IUniV3PoolR(pool).token1(), WOKB);
        uint256 u = USDT0.balanceOf(pool);
        uint256 w = IWOKB(WOKB).balanceOf(pool);
        emit log_named_uint("pool USDT0 (6 dp)", u);
        emit log_named_uint("pool WOKB (wei)", w);
        emit log_named_uint("in-range liquidity", IUniV3PoolR(pool).liquidity());
        assertGt(u, 100_000e6, "more than 100k USD0 in the pool");
        assertGt(w, 500 ether, "more than 500 WOKB in the pool");
        (,,, uint16 card,,,) = IUniV3PoolR(pool).slot0();
        emit log_named_uint("observation cardinality", card);
    }

    /// Option (d), end to end on the fork: x402-style USD₮0 arrives at a converter, which swaps it on the
    /// Uniswap V3 0.05% pool, unwraps and pushes native OKB into an OKB-quoted Directed vault; the
    /// recipient (the v1 kernel's place) then claims it as ordinary tax. The execution price is compared
    /// with the pool's 10-minute TWAP.
    function test_R3_option_d_usdt0_to_native_vault_via_univ3() public {
        NativeRecipient r = new NativeRecipient();
        (, IDirectedVault vault) = _launch(_defaultCfg(address(r)));
        assertEq(vault.QUOTE(), address(0), "native quote");
        address pool = UNIV3.getPool(address(USDT0), WOKB, 500);
        ConverterSketch c = new ConverterSketch(pool, address(vault));

        // TWAP over the last 10 minutes: tick = (cum[1]-cum[0]) / 600
        uint32[] memory ago = new uint32[](2);
        ago[0] = 600;
        (int56[] memory cum,) = IUniV3PoolR(pool).observe(ago);
        int256 twapTick = int256(cum[1] - cum[0]) / 600;
        emit log_named_int("10-min TWAP tick", twapTick);

        uint256[3] memory sizes = [uint256(0.5e6), 1_000e6, 20_000e6];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            deal(address(USDT0), address(c), sizes[i]);
            uint256 v0 = address(vault).balance;
            (uint256 inU, uint256 outW) = c.flush();
            assertEq(inU, sizes[i]);
            assertEq(address(vault).balance - v0, outW, "native OKB reached the vault");
            assertEq(vault.claimableNow(address(r), address(0)), address(vault).balance, "claimable as tax");
            uint256 got = r.claim(vault);
            assertEq(got, outW, "the recipient claimed exactly the converted OKB");
            assertEq(address(vault).balance, 0);
            // price paid in USDT0 base units per 1 OKB, x1e6 for readability
            emit log_named_uint("USDT0 in (base units)", inU);
            emit log_named_uint("OKB out (wei)", outW);
            emit log_named_uint("USDT0 per OKB (6 dp)", (inU * 1e18) / outW);
            vm.revertToState(snap);
        }
    }

    // ───────── unit shift: the Flow Governor's OKB-calibrated codes on USD₮0 amounts ─────────
    // Copies of KernelMath.lg8 / exp8 (contracts/core/src/KernelMath.sol, kernel v1), byte for byte in logic.

    function _msb(uint256 x) internal pure returns (uint256 r) {
        while (x > 1) {
            x >>= 1;
            ++r;
        }
    }

    function _lg8(uint256 x) internal pure returns (uint256 c) {
        if (x == 0) return 0;
        uint256 e = _msb(x);
        uint256 m = e >= 3 ? (x >> (e - 3)) & 7 : (x << (3 - e)) & 7;
        c = 8 * e + m + 1;
        if (c > 1023) c = 1023;
    }

    function _exp8(uint256 c) internal pure returns (uint256) {
        if (c == 0) return 0;
        if (c > 1023) c = 1023;
        uint256 k = c - 1;
        return ((8 + (k & 7)) << (k >> 3)) >> 3;
    }

    /// lg8(x << k) == lg8(x) + 8k and exp8(c + 8k) >> k == exp8(c): a kernel that adds 8k to every amount
    /// code (and shifts a decoded ceiling right by k) presents USD₮0 amounts to a chip exactly as amounts
    /// 2^k times larger. With k = 33, 1 OKB of the chip's calibration reads as 1e18 / 2^33 = 116.4 USD₮0.
    function testFuzz_R4_lg8_is_exactly_shift_invariant(uint256 x, uint8 k8, uint16 c16) public pure {
        uint256 k = bound(k8, 0, 40);
        x = bound(x, 1, type(uint128).max);
        if (_lg8(x) + 8 * k <= 1023) assertEq(_lg8(x << k), _lg8(x) + 8 * k);
        uint256 c = bound(c16, 1, 1023 - 8 * k);
        assertEq(_exp8(c + 8 * k) >> k, _exp8(c));
    }

    function test_R4b_codes_of_usdt0_amounts_with_shift_33() public pure {
        assertEq(_lg8(1e6), 160, "1 USD0, unshifted (doc)");
        assertEq(_lg8(0.5e6), 152, "0.50 USD0 (doc)");
        assertEq(_lg8(8_000e6), 263, "8,000 USD0 (doc)");
        assertEq(_lg8(uint256(116e6) << 33), _lg8(1 ether), "116 USD0 shifted by 33 reads as 1 OKB");
        assertEq(_lg8(uint256(8_000e6) << 33), 527, "the USD0 curve target reads as about 68.7 OKB");
        assertEq(_lg8(85 ether), 530, "the OKB curve target");
    }
}
