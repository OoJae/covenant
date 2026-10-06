// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {X402PayeeProbe} from "../src/X402PayeeProbe.sol";

interface IUSDT0 {
    function balanceOf(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address, bytes32) external view returns (bool);
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// Fork of X Layer. Replays, against the exact probe the user would deploy, the on-chain half of an x402 "exact"
/// settlement: the payer's EIP-3009 authorization, submitted by a relayer EOA that has settled verified
/// OKX.AI agent revenue (tx 0xc37fc2ef...b203d711, counted by IGNIX for agent Vivra). This proves the chain side
/// only. Whether OKX's hosted facilitator (its verify step and KYT) accepts a contract payTo is what the live
/// check decides. Nothing here is broadcast.
contract X402PayeeProbeTest is Test {
    IUSDT0 internal constant USDT0 = IUSDT0(0x779Ded0c9e1022225f8E0630b35a9b54bE713736);
    bytes32 internal constant TWA_TYPEHASH = 0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;
    bytes32 internal constant AUTH_USED = keccak256("AuthorizationUsed(address,bytes32)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    address internal constant RELAYER = 0x58954C92C84e51F8295f97D01a6beC2829426e1B;
    address internal constant AGENT_WALLET = 0xBE5088307e15AAF8cF0c53bfCc4C612c9EaD6DA0; // Architect's payee today
    uint256 internal constant PRICE = 10_000; // 0.01 USD₮0
    uint256 internal constant FORK_BLOCK = 72_532_000;

    X402PayeeProbe internal probe;
    address internal payer;
    uint256 internal payerPk;

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), FORK_BLOCK);
        (payer, payerPk) = makeAddrAndKey("test payer (a team wallet, paying a non-kernel probe)");
        probe = new X402PayeeProbe(payer);
        deal(address(USDT0), payer, 1e6);
    }

    struct Auth {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function _sign(address to, uint256 value, bytes32 nonce) internal view returns (Auth memory a) {
        a.validAfter = block.timestamp - 60;
        a.validBefore = block.timestamp + 300; // the SDK's maxTimeoutSeconds default
        a.nonce = nonce;
        bytes32 sh = keccak256(abi.encode(TWA_TYPEHASH, payer, to, value, a.validAfter, a.validBefore, nonce));
        (a.v, a.r, a.s) = vm.sign(payerPk, keccak256(abi.encodePacked("\x19\x01", USDT0.DOMAIN_SEPARATOR(), sh)));
    }

    /// what the facilitator's simulation (eth_call) and then its transaction do
    function _submit(address to, uint256 value, Auth memory a) internal {
        vm.prank(RELAYER, RELAYER);
        USDT0.transferWithAuthorization(payer, to, value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s);
    }

    function _checkLogs(Vm.Log[] memory logs, bytes32 nonce) internal view {
        bool sawTransfer;
        bool sawAuth;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(USDT0)) continue;
            if (logs[i].topics[0] == TRANSFER) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), payer);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(probe));
                assertEq(abi.decode(logs[i].data, (uint256)), PRICE);
                sawTransfer = true;
            }
            if (logs[i].topics[0] == AUTH_USED) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), payer);
                assertEq(logs[i].topics[2], nonce);
                sawAuth = true;
            }
        }
        assertTrue(sawTransfer && sawAuth, "Transfer and AuthorizationUsed, as on chain for any x402 exact payment");
    }

    function test_probe_is_a_plain_contract_not_a_7702_delegation() public view {
        bytes memory c = address(probe).code;
        assertGt(c.length, 23, "real runtime code");
        assertFalse(c[0] == 0xef && c[1] == 0x01 && c[2] == 0x00, "not an EIP-7702 delegation designator");
        // the payee used today is a 7702-delegated EOA: code, but only the 23-byte designator
        bytes memory a = AGENT_WALLET.code;
        assertEq(a.length, 23);
        assertTrue(a[0] == 0xef && a[1] == 0x01 && a[2] == 0x00, "agent wallet is 0xef0100 || delegate");
        assertEq(probe.REFUND_TO(), payer);
    }

    function test_settlement_to_the_probe_then_round_trip_back_to_the_payer() public {
        bytes32 nonce = keccak256("x402 live check 1");
        Auth memory a = _sign(address(probe), PRICE, nonce);
        uint256 p0 = USDT0.balanceOf(payer);

        vm.recordLogs();
        _submit(address(probe), PRICE, a);
        _checkLogs(vm.getRecordedLogs(), nonce);
        assertEq(USDT0.balanceOf(address(probe)), PRICE, "the contract payee holds the payment");
        assertTrue(USDT0.authorizationState(payer, nonce));

        // replay refused
        vm.expectRevert();
        this.submitExternal(address(probe), PRICE, a);

        // anyone sweeps it back: the test never becomes revenue
        vm.prank(makeAddr("anyone"));
        assertEq(probe.sweep(), PRICE);
        assertEq(USDT0.balanceOf(address(probe)), 0);
        assertEq(USDT0.balanceOf(payer), p0, "round trip complete");
        assertEq(probe.sweep(), 0, "a second sweep is a no-op");
    }

    function submitExternal(address to, uint256 value, Auth memory a) external {
        _submit(to, value, a);
    }

    function test_probe_refuses_plain_okb_and_a_zero_refund_address() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(probe).call{value: 1}("");
        assertFalse(ok, "no receive: plain OKB reverts");
        vm.expectRevert(X402PayeeProbe.ZeroRefundTo.selector);
        new X402PayeeProbe(address(0));
    }
}

