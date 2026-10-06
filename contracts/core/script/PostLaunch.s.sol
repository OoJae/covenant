// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IKernelPostLaunch {
    function bind(address token) external;
    function token() external view returns (address);
    function vault() external view returns (address);
}

interface IKernelV2PostLaunch {
    function quote() external view returns (address);
}

interface IManagerPostLaunch {
    function vaultOf(address token) external view returns (address);
}

interface IDirectedVaultPostLaunch {
    function RECIPIENT() external view returns (address);
    function TOKEN() external view returns (address);
    function QUOTE() external view returns (address);
}

interface ISplitterPostLaunch {
    function pull() external;
    function TANK() external view returns (address);
}

interface ITeamRegistryPostLaunch {
    function isTeam(address wallet) external view returns (bool);
    function isInvited(address wallet) external view returns (bool);
    function invite(address wallet) external;
}

/// @title PostLaunch: the deployer's transactions after the two IGNIX launches
/// @notice One transaction per function, so that forge keeps one broadcast record per step
///         (broadcast/PostLaunch.s.sol/196/<function>-latest.json) and asks for the keystore password once per step:
///           bindV1(kernel, token)        kernel v1 (native OKB quote) bound to the reference token (CVREF)
///           bindV2(kernel, token)        kernel v2 (USD₮0 quote) bound to the Architect token
///           pull(splitter)               Splitter.pull(): the processor's mint proceeds, 85% to the KeeperTank and
///                                        15% to the maintainer (anyone may call it)
///           invite(registry, wallet)     TeamRegistry.invite(wallet), so that wallet can declare itself
///         deploy/post-launch.sh checks every precondition on chain before it runs these, rehearses them on a fork
///         and records the result in deployments/xlayer.json. The checks below repeat the ones a wrong argument
///         would break, so that forge's own simulation stops before anything is signed.
///
///         Simulate (sends nothing):
///           forge script script/PostLaunch.s.sol -s "bindV1(address,address)" <kernel> <token> \
///             --rpc-url https://rpc.xlayer.tech --sender <deployer>
contract PostLaunch is Script {
    uint256 internal constant XLAYER_CHAIN_ID = 196;
    address internal constant MANAGER = 0x96B51c57e5346D0C0198899243cf851D1E23C309;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;

    function bindV1(address kernel, address token) external {
        _bind(kernel, token, address(0));
    }

    function bindV2(address kernel, address token) external {
        require(IKernelV2PostLaunch(kernel).quote() == USDT0, "PostLaunch: the v2 kernel does not quote in USDT0");
        _bind(kernel, token, USDT0);
    }

    function pull(address splitter) external {
        _chain();
        require(splitter.code.length != 0, "PostLaunch: the Splitter has no code");
        address tank = ISplitterPostLaunch(splitter).TANK();
        uint256 before = tank.balance;
        vm.startBroadcast();
        ISplitterPostLaunch(splitter).pull();
        vm.stopBroadcast();
        console2.log("KeeperTank balance before, after (wei):", before, tank.balance);
    }

    function invite(address registry, address wallet) external {
        _chain();
        require(registry.code.length != 0, "PostLaunch: the TeamRegistry has no code");
        require(wallet != address(0), "PostLaunch: the wallet is the zero address");
        ITeamRegistryPostLaunch r = ITeamRegistryPostLaunch(registry);
        require(!r.isInvited(wallet) && !r.isTeam(wallet), "PostLaunch: the wallet is invited or listed already");
        vm.startBroadcast();
        r.invite(wallet);
        vm.stopBroadcast();
        require(r.isInvited(wallet), "PostLaunch: the invitation did not take");
    }

    function _bind(address kernel, address token, address quote) internal {
        _chain();
        require(kernel.code.length != 0 && token.code.length != 0, "PostLaunch: the kernel or the token has no code");
        IKernelPostLaunch k = IKernelPostLaunch(kernel);
        require(k.token() == address(0), "PostLaunch: the kernel is bound already");
        address vault = IManagerPostLaunch(MANAGER).vaultOf(token);
        require(vault != address(0), "PostLaunch: IGNIX has no vault for this token");
        IDirectedVaultPostLaunch v = IDirectedVaultPostLaunch(vault);
        require(v.RECIPIENT() == kernel, "PostLaunch: the vault's recipient is not the kernel");
        require(v.TOKEN() == token, "PostLaunch: the vault is for another token");
        require(v.QUOTE() == quote, "PostLaunch: the vault's quote is not the kernel's");
        vm.startBroadcast();
        k.bind(token);
        vm.stopBroadcast();
        require(k.token() == token && k.vault() == vault, "PostLaunch: the kernel is not bound to the token");
        console2.log("bound: kernel, token, vault", kernel, token, vault);
    }

    function _chain() internal view {
        if (block.chainid != XLAYER_CHAIN_ID) revert("PostLaunch: not X Layer (chain id 196)");
    }
}
