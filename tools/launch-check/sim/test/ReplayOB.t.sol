// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";

import {LaunchSim} from "../src/LaunchSim.sol";
import {IIgnixManager, IDirectedVault, IERC20Min, CurveToken} from "../src/Interfaces.sol";

/// @notice Proof (i) of the harness: the REAL createToken transaction of the OB token
///         (0x0ebe6f4bfb5bb1eadc2a4fd429eea32cc33ad9a30eead752cb2820aab6d454a1, block 71,350,520), re-executed on
///         a fork of the block before it through the same `_create` the launch-day command uses.
///
///         The fork must produce the real token address, the real vault, and every log of the real receipt,
///         byte for byte. The fixture (transaction, receipt, block) is ../test/fixtures/ob-launch.json, fetched
///         from the chain by tools/launch-check/test/fixtures/fetch.ts.
///
///         The kernel steps are skipped by the harness flag: OB's recipient is a plain wallet, and OB was
///         launched with a first buy.
///
/// forge-config: default.isolate = true
contract ReplayOB is LaunchSim {
    address internal constant OB_TOKEN = 0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe;
    address internal constant OB_VAULT = 0xeC7732C9dCF978C8a97E6c44499331757D240365;
    address internal constant OB_CREATOR = 0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404;

    string internal json;
    Inputs internal inp;
    uint256 internal realGasUsed;

    function setUp() public {
        json = vm.readFile("../test/fixtures/ob-launch.json");
        uint256 blockNumber = vm.parseJsonUint(json, ".block.number");
        uint256 blockTime = vm.parseJsonUint(json, ".block.timestamp");
        assertEq(blockNumber, 71_350_520);
        assertEq(vm.parseJsonBytes32(json, ".transaction.hash"), 0x0ebe6f4bfb5bb1eadc2a4fd429eea32cc33ad9a30eead752cb2820aab6d454a1);

        inp.from = vm.parseJsonAddress(json, ".transaction.from");
        inp.to = vm.parseJsonAddress(json, ".transaction.to");
        inp.value = vm.parseJsonUint(json, ".transaction.value");
        inp.data = vm.parseJsonBytes(json, ".transaction.input");
        inp.kernel = OB_CREATOR; // the real recipient: an ordinary wallet, not a kernel
        inp.skipKernel = true;
        inp.allowFirstBuy = true;
        realGasUsed = vm.parseJsonUint(json, ".receipt.gasUsed");

        // the state the real transaction ran on: the end of the previous block, at the real block's time
        vm.createSelectFork(_rpcUrl(), blockNumber - 1);
        vm.roll(blockNumber);
        vm.warp(blockTime);
        assertEq(block.chainid, 196);
    }

    function test_replay_of_the_real_OB_launch_gives_the_real_token_vault_and_logs() public {
        assertEq(inp.from, OB_CREATOR);
        assertEq(inp.value, 0.4 ether);
        assertEq(OB_TOKEN.code.length, 0, "the token does not exist before the launch");

        Created memory c = _simulate(inp);

        assertEq(c.token, OB_TOKEN, "same token address as on mainnet");
        assertEq(c.vault, OB_VAULT, "same vault address as on mainnet");
        assertEq(IDirectedVault(c.vault).RECIPIENT(), OB_CREATOR);

        // every log of the real receipt, in order: emitter, topics and data
        uint256 n = c.logs.length;
        assertEq(n, 10, "the real receipt has 10 logs");
        assertFalse(vm.keyExistsJson(json, ".receipt.logs[10]"), "and no eleventh");
        for (uint256 i; i < n; ++i) {
            string memory at = string.concat(".receipt.logs[", vm.toString(i), "]");
            assertEq(c.logs[i].emitter, vm.parseJsonAddress(json, string.concat(at, ".address")), string.concat("emitter of log ", vm.toString(i)));
            bytes32[] memory topics = vm.parseJsonBytes32Array(json, string.concat(at, ".topics"));
            assertEq(c.logs[i].topics.length, topics.length, string.concat("topic count of log ", vm.toString(i)));
            for (uint256 j; j < topics.length; ++j) {
                assertEq(c.logs[i].topics[j], topics[j], string.concat("topic of log ", vm.toString(i)));
            }
            assertEq(keccak256(c.logs[i].data), keccak256(vm.parseJsonBytes(json, string.concat(at, ".data"))), string.concat("data of log ", vm.toString(i)));
        }

        console2Gas(c.gasUsed);
    }

    /// @dev Every argument of createToken, as Solidity itself decodes the calldata.
    struct Decoded {
        IIgnixManager.CreateParams p;
        uint16 templateId;
        bytes vaultData;
        uint64 deadline;
        address factory;
        uint8 venue;
        uint64 protectionSecs;
        bytes sig;
    }

    function _decode(bytes memory data) internal pure returns (Decoded memory d) {
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = data[i + 4];
        }
        // The arguments of a call are the body of a tuple; one leading offset word makes them the encoding of
        // that tuple as a single value, which is what `Decoded` is.
        d = abi.decode(abi.encodePacked(uint256(32), args), (Decoded));
    }

    function test_replay_parameters_equal_the_calldata_and_the_real_chain() public {
        Created memory c = _simulate(inp);
        Decoded memory d = _decode(inp.data);

        // the values recorded in contracts/probes/FINDINGS.md section 1 for this launch
        assertEq(d.p.name, "OpenBook");
        assertEq(d.p.symbol, "OB");
        assertEq(d.p.taxBuyBps, 100);
        assertEq(d.p.taxSellBps, 100);
        assertEq(d.p.snipeStartBps, 5000);
        assertEq(d.p.snipeMins, 30);
        assertEq(d.p.firstBuy, 0.4 ether);
        assertEq(d.p.listingFee, 0);
        assertEq(d.p.graduation, 85 ether);
        assertEq(d.p.quote, address(0));
        assertEq(d.p.founderBps, 0);
        assertEq(d.templateId, 3);
        assertEq(d.venue, 1);
        assertEq(d.protectionSecs, 8_640_000);
        assertEq(abi.decode(d.vaultData, (address)), OB_CREATOR);
        assertEq(d.sig.length, 65);
        assertGe(d.deadline, block.timestamp);
        assertEq(inp.value, d.p.listingFee + d.p.firstBuy);

        _assertStored(c, d);
        _assertSameAsRealChain(c);

        // the first buy really traded: the creator holds tokens and the vault holds 1% of 0.4 OKB
        assertGt(IERC20Min(c.token).balanceOf(inp.from), 0);
        assertEq(c.vault.balance, 0.004 ether);
    }

    /// @dev What the Manager stored for the token the replay created equals the decoded calldata.
    function _assertStored(Created memory c, Decoded memory d) internal view {
        CurveToken memory t = M.tokens(c.token);
        assertEq(t.creator, inp.from);
        assertEq(t.buyFeeBps, d.p.buyFeeBps);
        assertEq(t.sellFeeBps, d.p.sellFeeBps);
        assertEq(t.taxBuyBps, d.p.taxBuyBps);
        assertEq(t.taxSellBps, d.p.taxSellBps);
        assertEq(t.quote, d.p.quote);
        assertEq(t.snipeStartBps, d.p.snipeStartBps);
        assertEq(t.snipeMins, d.p.snipeMins);
        assertEq(t.createdAt, block.timestamp);
        assertEq(IERC20Min(c.token).name(), d.p.name);
        assertEq(IERC20Min(c.token).symbol(), d.p.symbol);
        assertEq(IDirectedVault(c.vault).RECIPIENT(), abi.decode(d.vaultData, (address)));
        (bool ok, bytes memory ret) = c.vault.staticcall(abi.encodeWithSignature("FACTORY()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), d.factory);
    }

    /// @dev The launch settings of the replayed token equal the words the real chain returns for the real
    ///      token at the launch block (the fixture's eth_call of IgnixManager.tokens).
    function _assertSameAsRealChain(Created memory c) internal view {
        CurveToken memory t = M.tokens(c.token);
        CurveToken memory real = abi.decode(vm.parseJsonBytes(json, "$.chain['IgnixManager.tokens(token)']"), (CurveToken));
        assertEq(t.creator, real.creator);
        assertEq(t.buyFeeBps, real.buyFeeBps);
        assertEq(t.sellFeeBps, real.sellFeeBps);
        assertEq(t.taxBuyBps, real.taxBuyBps);
        assertEq(t.taxSellBps, real.taxSellBps);
        assertEq(t.quote, real.quote);
        assertEq(t.snipeStartBps, real.snipeStartBps);
        assertEq(t.snipeMins, real.snipeMins);
        assertEq(t.createdAt, real.createdAt);
        assertEq(t.sellable, real.sellable);
        assertEq(t.reserve, real.reserve);
    }

    function test_the_harness_refuses_the_real_OB_launch_when_no_flag_is_set() public {
        inp.skipKernel = false;
        inp.allowFirstBuy = false;
        vm.expectRevert(bytes("sim: tokens were sold inside createToken (a first buy)"));
        this.simulate(inp);
    }

    function simulate(Inputs memory i) external {
        _simulate(i);
    }

    function console2Gas(uint256 forkGas) internal {
        emit log_named_uint("real receipt gasUsed", realGasUsed);
        emit log_named_uint("fork gas of the same call", forkGas);
        assertEq(forkGas, realGasUsed, "fork gas (after refund) == the real receipt, to the unit");
    }
}
