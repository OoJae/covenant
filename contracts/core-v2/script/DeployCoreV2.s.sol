// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {KernelFactoryV2} from "../src/KernelFactoryV2.sol";
import {LensV2} from "../src/LensV2.sol";

interface IManagerLikeV2 {
    function V2_ROUTER02() external view returns (address);
    function V2_FACTORY() external view returns (address);
}

interface IRouterLikeV2 {
    function factory() external view returns (address);
}

interface IFabLikeV2 {
    function CIRCUITS() external view returns (address);
}

interface IBeaconLikeV2 {
    function implementation() external view returns (address);
}

interface IQuoteLikeV2 {
    function decimals() external view returns (uint8);
}

interface IUniV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @title DeployCoreV2: deploys KernelFactoryV2 (which deploys the KernelV2 implementation) and LensV2 on X Layer
/// @notice Two creations, no initialisation, nothing to configure afterwards. The factory's pins (IGNIX, USD₮0
///         and its code shift, the Covenant processor, the Fab, the sealed evaluator, TapeOut's beacon and the
///         pinned implementation) are fixed in its bytecode; every kernel it creates copies them.
///
///         Inputs (environment). Every one defaults to the address recorded in deployments/xlayer.json or verified
///         by the fork tests of this package (block 72,530,000), and can be overridden:
///
///           COVENANT_CIRCUITS     the Covenant processor's circuits (0xaC90A95b…)
///           COVENANT_FAB          the Fab for that processor (0xdcac8c47…)
///           COVENANT_SEALED_VM    the sealed evaluator (0x19c248cf…)
///           COVENANT_MANAGER      IgnixManager (proxy)
///           COVENANT_V2_ROUTER    Uniswap V2 Router02
///           COVENANT_QUOTE        USD₮0
///           COVENANT_QUOTE_SHIFT  the code shift in bits (33: NOTES.md section 3)
///           COVENANT_RATE_POOL    the canonical Uniswap V3 USD₮0/WOKB 0.05% pool, read to check the shift
///           COVENANT_BEACON, COVENANT_IMPL0, COVENANT_IMPL0_HASH   TapeOut's beacon and the pinned implementation
///
///         The shift check. The shift is right while the market price of OKB in USD₮0 is in the band for which it
///         is the nearest whole number of bits (82.3 to 164.6 USD₮0 per OKB for 33). The script reads the pool's
///         spot price and refuses outside the band. The price is read once, here; the kernels never read it.
///
///         Chain guard: X Layer (196) only, unless REHEARSAL=true on a local fork with another chain id. On chain
///         196 REHEARSAL is ignored: the price-band check always applies there.
///
///         Simulate (sends nothing, needs no key), from a scratch copy of this package (forge writes a dry-run
///         record under broadcast/; this repository's broadcast folders hold only real deployments):
///           forge script script/DeployCoreV2.s.sol --rpc-url https://rpc.xlayer.tech
///         The command the wallet holder signs is in NOTES.md section 7.
contract DeployCoreV2 is Script {
    uint256 internal constant XLAYER_CHAIN_ID = 196;

    // X Layer mainnet (deployments/xlayer.json; fork-verified at block 72,530,000)
    address internal constant DEFAULT_CIRCUITS = 0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b;
    address internal constant DEFAULT_FAB = 0xdCAc8c47aF534dC0cDE30f60056bCe7D63a79aFE;
    address internal constant DEFAULT_SEALED_VM = 0x19C248cF463c1E167121e52b77abA7EC68CBE47B;
    address internal constant DEFAULT_MANAGER = 0x96B51c57e5346D0C0198899243cf851D1E23C309;
    address internal constant DEFAULT_V2_ROUTER = 0x182a927119D56008d921126764bF884221b10f59;
    address internal constant DEFAULT_QUOTE = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    uint256 internal constant DEFAULT_QUOTE_SHIFT = 33;
    address internal constant DEFAULT_RATE_POOL = 0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082;
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address internal constant DEFAULT_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address internal constant DEFAULT_IMPL0 = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    bytes32 internal constant DEFAULT_IMPL0_HASH = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    struct Pins {
        address manager;
        address v2Router;
        address quote;
        uint256 quoteShift;
        address ratePool;
        address circuits;
        address fab;
        address sealedVM;
        address beacon;
        address impl0;
        bytes32 impl0Hash;
    }

    function defaults() public pure returns (Pins memory p) {
        p.manager = DEFAULT_MANAGER;
        p.v2Router = DEFAULT_V2_ROUTER;
        p.quote = DEFAULT_QUOTE;
        p.quoteShift = DEFAULT_QUOTE_SHIFT;
        p.ratePool = DEFAULT_RATE_POOL;
        p.circuits = DEFAULT_CIRCUITS;
        p.fab = DEFAULT_FAB;
        p.sealedVM = DEFAULT_SEALED_VM;
        p.beacon = DEFAULT_BEACON;
        p.impl0 = DEFAULT_IMPL0;
        p.impl0Hash = DEFAULT_IMPL0_HASH;
    }

    function run() external returns (KernelFactoryV2 factory, LensV2 lens) {
        Pins memory p = defaults();
        p.circuits = vm.envOr("COVENANT_CIRCUITS", p.circuits);
        p.fab = vm.envOr("COVENANT_FAB", p.fab);
        p.sealedVM = vm.envOr("COVENANT_SEALED_VM", p.sealedVM);
        p.manager = vm.envOr("COVENANT_MANAGER", p.manager);
        p.v2Router = vm.envOr("COVENANT_V2_ROUTER", p.v2Router);
        p.quote = vm.envOr("COVENANT_QUOTE", p.quote);
        p.quoteShift = vm.envOr("COVENANT_QUOTE_SHIFT", p.quoteShift);
        p.ratePool = vm.envOr("COVENANT_RATE_POOL", p.ratePool);
        p.beacon = vm.envOr("COVENANT_BEACON", p.beacon);
        p.impl0 = vm.envOr("COVENANT_IMPL0", p.impl0);
        p.impl0Hash = vm.envOr("COVENANT_IMPL0_HASH", p.impl0Hash);
        return deploy(p);
    }

    /// @notice The shift for which the pool's spot price is in the band: the whole number of bits nearest to
    ///         log2(wei of OKB per base unit of USD₮0). Returns 0 if the pool cannot be read or is not USD₮0/WOKB.
    function shiftFromPool(address pool, address quote) public view returns (uint256 s, uint256 usdPerOkbMicro) {
        if (pool.code.length == 0) return (0, 0);
        if (IUniV3PoolLike(pool).token0() != quote || IUniV3PoolLike(pool).token1() != WOKB) return (0, 0);
        (uint160 sqrtP,,,,,,) = IUniV3PoolLike(pool).slot0();
        // wei per USD₮0 base unit = sqrtP^2 / 2^192; with q = sqrtP >> 64 it is q^2 / 2^64 (q < 2^96)
        uint256 q = uint256(sqrtP) >> 64;
        uint256 m = q * q; // price * 2^64
        if (m == 0) return (0, 0);
        usdPerOkbMicro = (uint256(1e18) << 64) / m; // 10^18 / price
        // nearest s: 2^(2s - 1) <= price^2 < 2^(2s + 1), i.e. 2^(2s - 1 + 128) <= m^2 < 2^(2s + 1 + 128)
        uint256 m2 = m * m;
        for (s = 1; s < 60; s++) {
            if (m2 < (uint256(1) << (2 * s + 1 + 128))) break;
        }
    }

    /// @notice REHEARSAL=true counts only on a chain other than X Layer (a local fork with its own chain id). On
    ///         chain 196 it switches nothing off, so a REHEARSAL left set in the shell after a rehearsal cannot
    ///         skip the price-band check of a mainnet deployment.
    function rehearsalAllowed() public view returns (bool) {
        return vm.envOr("REHEARSAL", false) && block.chainid != XLAYER_CHAIN_ID;
    }

    function deploy(Pins memory p) public returns (KernelFactoryV2 factory, LensV2 lens) {
        bool rehearsal = rehearsalAllowed();
        require(block.chainid == XLAYER_CHAIN_ID || rehearsal, "DeployCoreV2: not X Layer (196); REHEARSAL=true only");
        _requireCode(p.manager, "DeployCoreV2: manager has no code");
        _requireCode(p.v2Router, "DeployCoreV2: router has no code");
        _requireCode(p.quote, "DeployCoreV2: quote has no code");
        _requireCode(p.circuits, "DeployCoreV2: circuits has no code");
        _requireCode(p.fab, "DeployCoreV2: Fab has no code");
        _requireCode(p.sealedVM, "DeployCoreV2: SealedVM has no code");
        _requireCode(p.beacon, "DeployCoreV2: beacon has no code");
        _requireCode(p.impl0, "DeployCoreV2: pinned implementation has no code");
        require(p.impl0.codehash == p.impl0Hash, "DeployCoreV2: pinned code hash is not the implementation's");
        require(IManagerLikeV2(p.manager).V2_ROUTER02() == p.v2Router, "DeployCoreV2: not the Manager's router");
        require(
            IRouterLikeV2(p.v2Router).factory() == IManagerLikeV2(p.manager).V2_FACTORY(),
            "DeployCoreV2: router and Manager use different V2 factories"
        );
        require(IQuoteLikeV2(p.quote).decimals() == 6, "DeployCoreV2: the quote does not have 6 decimals");
        require(IFabLikeV2(p.fab).CIRCUITS() == p.circuits, "DeployCoreV2: the Fab is for another processor");
        (uint256 poolShift, uint256 rateMicro) = shiftFromPool(p.ratePool, p.quote);
        require(
            poolShift == p.quoteShift || rehearsal,
            "DeployCoreV2: the OKB/USDT0 price is outside the band of this shift (NOTES.md section 3)"
        );
        address liveImpl = IBeaconLikeV2(p.beacon).implementation();

        vm.startBroadcast();
        factory = new KernelFactoryV2(
            p.manager, p.v2Router, p.quote, p.quoteShift, p.circuits, p.fab, p.sealedVM, p.beacon, p.impl0, p.impl0Hash
        );
        lens = new LensV2(address(factory));
        vm.stopBroadcast();

        require(factory.manager() == p.manager, "KernelFactoryV2: manager");
        require(factory.v2Router() == p.v2Router, "KernelFactoryV2: router");
        require(factory.quote() == p.quote, "KernelFactoryV2: quote");
        require(factory.quoteShift() == p.quoteShift, "KernelFactoryV2: shift");
        require(factory.circuits() == p.circuits, "KernelFactoryV2: circuits");
        require(factory.fab() == p.fab, "KernelFactoryV2: Fab");
        require(factory.sealedVM() == p.sealedVM, "KernelFactoryV2: SealedVM");
        require(factory.beacon() == p.beacon, "KernelFactoryV2: beacon");
        require(factory.impl0() == p.impl0, "KernelFactoryV2: pinned implementation");
        require(factory.impl0Hash() == p.impl0Hash, "KernelFactoryV2: pinned code hash");
        address kernelImpl = factory.kernelImpl();
        require(kernelImpl.code.length != 0, "KernelFactoryV2: no KernelV2 implementation");
        require(kernelImpl.code.length < 24_576, "KernelV2 implementation over the code size limit");
        require(address(lens.FACTORY()) == address(factory), "LensV2: factory");
        require(factory.pinsLive() == (liveImpl == p.impl0), "KernelFactoryV2: pinsLive disagrees with the beacon");

        console2.log("chain id                         ", block.chainid);
        console2.log("USDT0 per OKB (micro), pool spot ", rateMicro);
        console2.log("shift from the pool / pinned     ", poolShift, p.quoteShift);
        console2.log("KernelFactoryV2                  ", address(factory));
        console2.log("  runtime bytes                  ", address(factory).code.length);
        console2.log("KernelV2 implementation          ", kernelImpl);
        console2.log("  runtime bytes                  ", kernelImpl.code.length);
        console2.log("LensV2                           ", address(lens));
        console2.log("  runtime bytes                  ", address(lens).code.length);
        console2.log("pinsLive                         ", factory.pinsLive());
    }

    function _requireCode(address a, string memory why) internal view {
        require(a.code.length != 0, why);
    }
}
