// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdStorage, StdStorage} from "forge-std/Test.sol";

import {LaunchSim} from "../src/LaunchSim.sol";
import {IIgnixManager, IVaultRegistry, IDirectedVault, IKernelV1, CurveToken, Record} from "../src/Interfaces.sol";
import {MockKernel, MockCircuits, MockKernelFactory} from "./MockKernel.sol";

/// @notice Proof (ii) of the harness: a complete launch through the LIVE IgnixManager on a fork, with the
///         platform signer replaced in fork storage (slot 5) by a throwaway key, exactly as
///         contracts/probes/test/ProbeBase.sol does, and a mock kernel as the vault recipient.
///
///         The calldata is built the way a wallet would receive it and is then handed to the SAME harness
///         the launch-day command runs. The harness must accept the good launch and must refuse each bad one.
contract MockKernelLaunch is LaunchSim {
    using stdStorage for StdStorage;

    uint256 internal constant PINNED_BLOCK = 72_369_000; // 2026-10-04 18:20:36 UTC, the block the probes use
    uint16 internal constant TEMPLATE_DIRECTED = 3;
    uint256 internal constant CHIP_ID = 1;

    address internal launcher = makeAddr("launcher (creates the token)");
    MockCircuits internal circuits;
    MockKernel internal kernel;
    uint256 internal signerKey;
    uint256 internal salt;

    struct Launch {
        IIgnixManager.CreateParams p;
        bytes vaultData;
        uint64 deadline;
        address factory;
        uint64 protectionSecs;
    }

    function setUp() public {
        vm.createSelectFork(_rpcUrl(), PINNED_BLOCK);
        assertEq(block.chainid, 196);
        vm.deal(launcher, 1 ether);
        circuits = new MockCircuits();
        kernel = new MockKernel(address(M), address(circuits), CHIP_ID, launcher, 900);
        circuits.mint(address(kernel), CHIP_ID);

        // fork-only: replace the platform signer (storage slot 5 of the Manager proxy) by a throwaway key
        address s;
        (s, signerKey) = makeAddrAndKey("launch-check sim: fork-only signer");
        uint256 slot = stdstore.target(address(M)).sig("signer()").find();
        assertEq(slot, 5, "signer slot moved");
        vm.store(address(M), bytes32(slot), bytes32(uint256(uint160(s))));
        assertEq(M.signer(), s);
    }

    // ───────────────────────────── building a launch ─────────────────────────────

    function _launch(address recipient) internal returns (Launch memory a) {
        a.p = IIgnixManager.CreateParams({
            name: "Covenant Reference",
            symbol: "CVREF",
            metadataURI: "ipfs://launch-check-sim",
            salt: bytes32(++salt),
            quote: address(0),
            graduation: 85 ether,
            buyFeeBps: 100,
            sellFeeBps: 100,
            taxBuyBps: 300,
            taxSellBps: 300,
            snipeStartBps: 0,
            snipeMins: 0,
            listingFee: 0,
            firstBuy: 0,
            founderBps: 0,
            founderSecs: 0,
            founderRoot: bytes32(0)
        });
        a.vaultData = abi.encode(recipient);
        a.deadline = uint64(block.timestamp + 30 minutes);
        a.factory = IVaultRegistry(M.REGISTRY()).factoryOf(TEMPLATE_DIRECTED);
        a.protectionSecs = 8_640_000;
    }

    /// @dev Signs for `sender` and returns the transaction a wallet would show.
    function _tx(Launch memory a, address sender, address kernel_) internal view returns (Inputs memory inp) {
        bytes32 inner = keccak256(
            abi.encode(
                block.chainid,
                address(M),
                sender,
                a.p,
                TEMPLATE_DIRECTED,
                a.vaultData,
                a.deadline,
                a.factory,
                uint8(1),
                a.protectionSecs,
                M.POOL_FEE(),
                M.LAUNCH_FACTORY()
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner)));
        inp.from = sender;
        inp.to = address(M);
        inp.value = a.p.listingFee + a.p.firstBuy;
        inp.data = abi.encodeCall(
            IIgnixManager.createToken,
            (a.p, TEMPLATE_DIRECTED, a.vaultData, a.deadline, a.factory, 1, a.protectionSecs, abi.encodePacked(r, s, v))
        );
        inp.kernel = kernel_;
    }

    /// @dev External so that a test can expect the harness to refuse.
    function simulate(Inputs memory inp) external returns (address token, address vault) {
        Created memory c = _simulate(inp);
        return (c.token, c.vault);
    }

    // ───────────────────────────── the good launch ─────────────────────────────

    function test_fork_launch_with_the_mock_kernel_binds_buys_and_settles() public {
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        Created memory c = _simulate(inp);

        // what the harness asserted, seen once more from here
        assertEq(IDirectedVault(c.vault).RECIPIENT(), address(kernel));
        assertEq(kernel.token(), c.token);
        assertEq(kernel.vault(), c.vault);
        assertEq(kernel.count(), 1);
        Record memory r = kernel.records(1);
        assertEq(r.epoch, 1, "settled in the first full epoch after bind");
        assertEq(r.inflow, 0.03 ether, "3% of the 1 OKB an outsider bought");
        assertEq(address(kernel).balance, 0.03 ether, "the tax is in the kernel");
        assertEq(c.vault.balance, 0, "and no longer in the vault");
        CurveToken memory t = M.tokens(c.token);
        assertEq(t.creator, launcher);
        assertEq(t.taxBuyBps, 300);
        assertEq(t.taxSellBps, 300);
        assertEq(t.snipeStartBps, 0);
    }

    function test_the_same_epoch_cannot_be_settled_twice_and_the_next_one_can() public {
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        _simulate(inp);
        vm.expectRevert(MockKernel.EpochNotElapsed.selector);
        kernel.settle();
        vm.warp(block.timestamp + 900);
        assertEq(kernel.settle(), 2);
        assertEq(kernel.records(2).inflow, 0, "nothing new arrived");
    }

    // ───────────────────────────── launches the harness must refuse ─────────────────────────────

    function test_refuses_when_the_vault_recipient_is_not_the_kernel() public {
        address other = makeAddr("some other recipient");
        Inputs memory inp = _tx(_launch(other), launcher, address(kernel));
        vm.expectRevert(bytes("sim: the vault RECIPIENT is not the kernel"));
        this.simulate(inp);
    }

    function test_refuses_a_first_buy() public {
        Launch memory a = _launch(address(kernel));
        a.p.firstBuy = 0.4 ether;
        Inputs memory inp = _tx(a, launcher, address(kernel));
        assertEq(inp.value, 0.4 ether);
        vm.expectRevert(bytes("sim: tokens were sold inside createToken (a first buy)"));
        this.simulate(inp);
    }

    function test_refuses_anti_snipe() public {
        Launch memory a = _launch(address(kernel));
        a.p.snipeStartBps = 5000;
        a.p.snipeMins = 30;
        Inputs memory inp = _tx(a, launcher, address(kernel));
        vm.expectRevert(bytes("sim: anti-snipe is on (the kernel skips buys while it is)"));
        this.simulate(inp);
    }

    function test_refuses_when_the_launcher_is_not_the_one_in_the_kernel() public {
        address stranger = makeAddr("another wallet");
        vm.deal(stranger, 1 ether);
        Inputs memory inp = _tx(_launch(address(kernel)), stranger, address(kernel));
        vm.expectRevert(
            bytes(
                "sim: kernel.bind(token) reverted: BindCheck(5): neither the token's creator nor the caller is the envelope's launcher"
            )
        );
        this.simulate(inp);
    }

    function test_refuses_a_kernel_the_deployments_factory_did_not_create() public {
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        MockKernelFactory f = new MockKernelFactory(); // knows no kernel
        inp.dep.present = true;
        inp.dep.kernelFactory = address(f);
        inp.dep.circuits = address(circuits);
        vm.expectRevert(bytes("sim: the kernel was not created by the deployment's KernelFactory"));
        this.simulate(inp);

        inp.dep.kernelFactory = makeAddr("no factory here");
        vm.expectRevert(bytes("sim: the deployment's KernelFactory has no code on this chain"));
        this.simulate(inp);
    }

    /// @dev The kernel's BindCheck(6) (no tax) cannot be reached through IGNIX: the Manager itself refuses a
    ///      Directed launch whose tax is 0 / 0 (measured here at the pinned block).
    function test_a_directed_launch_without_tax_is_refused_by_IGNIX_itself() public {
        Launch memory a = _launch(address(kernel));
        a.p.taxBuyBps = 0;
        a.p.taxSellBps = 0;
        Inputs memory inp = _tx(a, launcher, address(kernel));
        vm.expectRevert(
            bytes("sim: createToken reverted: BadValue(): msg.value is not listingFee + firstBuy, or a launch rule is broken")
        );
        this.simulate(inp);
    }

    function test_refuses_when_the_kernel_does_not_hold_its_chip() public {
        circuits.mint(launcher, CHIP_ID); // the chip NFT was never transferred to the kernel
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        vm.expectRevert(bytes("sim: kernel.bind(token) reverted: BindCheck(7): the kernel does not hold its chip NFT"));
        this.simulate(inp);
    }

    function test_refuses_a_kernel_that_is_already_bound() public {
        Inputs memory first = _tx(_launch(address(kernel)), launcher, address(kernel));
        _simulate(first);
        Inputs memory second = _tx(_launch(address(kernel)), launcher, address(kernel));
        vm.expectRevert(bytes("sim: the kernel is already bound to a token"));
        this.simulate(second);
    }

    function test_refuses_a_kernel_address_without_code() public {
        address nothing = makeAddr("no contract here");
        Inputs memory inp = _tx(_launch(nothing), launcher, nothing);
        vm.expectRevert(bytes("sim: the kernel address has no code"));
        this.simulate(inp);
    }

    function test_refuses_an_expired_signature() public {
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        vm.warp(block.timestamp + 30 minutes + 1);
        vm.expectRevert(bytes("sim: createToken reverted: SignatureExpired(): the deadline has passed"));
        this.simulate(inp);
    }

    function test_refuses_calldata_signed_for_another_wallet() public {
        address stranger = makeAddr("another wallet");
        Inputs memory inp = _tx(_launch(address(kernel)), stranger, address(kernel));
        inp.from = launcher; // the launcher presents a signature issued to someone else
        vm.expectRevert(
            bytes(
                "sim: createToken reverted: BadSignature(): the calldata, the sender or the Manager's fee settings are not what the platform signed"
            )
        );
        this.simulate(inp);
    }

    function test_refuses_a_value_that_is_not_the_listing_fee() public {
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        inp.value = 1 wei;
        vm.expectRevert(
            bytes("sim: createToken reverted: BadValue(): msg.value is not listingFee + firstBuy, or a launch rule is broken")
        );
        this.simulate(inp);
    }

    function test_refuses_a_launcher_that_cannot_pay_the_value() public {
        Launch memory a = _launch(address(kernel));
        a.p.listingFee = 5 ether;
        Inputs memory inp = _tx(a, launcher, address(kernel));
        vm.expectRevert(bytes("sim: the launcher's balance is below the value of the transaction"));
        this.simulate(inp);
    }

    function test_refuses_another_target_and_another_function() public {
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        inp.to = address(kernel);
        vm.expectRevert(bytes("sim: `to` is not the IgnixManager proxy"));
        this.simulate(inp);

        inp.to = address(M);
        inp.data = abi.encodeCall(IIgnixManager.buy, (address(1), 0, 0));
        vm.expectRevert(bytes("sim: the calldata is not a createToken call"));
        this.simulate(inp);
    }

    function test_refuses_a_kernel_whose_receive_rejects_the_vault() public {
        // a recipient that can bind but cannot be paid: settle must not pass
        StubbornKernel bad = new StubbornKernel(address(M), address(circuits), 2, launcher, 900);
        circuits.mint(address(bad), 2);
        Inputs memory inp = _tx(_launch(address(bad)), launcher, address(bad));
        vm.expectRevert(bytes("sim: the record says the vault claim failed (flag 4)"));
        this.simulate(inp);
    }

    function test_skipKernel_stops_after_the_creation() public {
        Inputs memory inp = _tx(_launch(address(kernel)), launcher, address(kernel));
        inp.skipKernel = true;
        Created memory c = _simulate(inp);
        assertEq(kernel.token(), address(0), "bind was not called");
        assertEq(IDirectedVault(c.vault).RECIPIENT(), address(kernel));
        assertEq(IKernelV1(address(kernel)).count(), 0);
    }
}

/// @notice TEST ONLY. A kernel whose receive() refuses everyone, so the vault's claim reverts TransferFailed().
contract StubbornKernel is MockKernel {
    constructor(address m, address c, uint256 id, address l, uint32 e) MockKernel(m, c, id, l, e) {}

    receive() external payable override {
        revert NotAccepted();
    }
}
