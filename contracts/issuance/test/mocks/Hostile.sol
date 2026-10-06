// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IKernelMin} from "../../src/interfaces/IKernelMin.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {Splitter} from "../../src/Splitter.sol";

// Adversarial counterparts used by the hostile-kernel, hostile-caller and hostile-maintainer tests.

/// @notice A "kernel" whose settle() calls back into the tank.
contract ReentrantKernel is IKernelMin {
    KeeperTank internal immutable TANK;
    uint256 internal immutable CHIP_ID;
    bool internal immutable SWALLOW;

    bool public reentryBlocked;
    uint256 public settles;

    constructor(KeeperTank tank, uint256 chipId_, bool swallow) {
        TANK = tank;
        CHIP_ID = chipId_;
        SWALLOW = swallow;
    }

    function chipId() external view returns (uint256) {
        return CHIP_ID;
    }

    function settle() external returns (uint32) {
        if (SWALLOW) {
            try TANK.settleAndRefund(address(this)) {}
            catch (bytes memory err) {
                reentryBlocked = bytes4(err) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
            }
        } else {
            TANK.settleAndRefund(address(this));
        }
        return uint32(++settles);
    }

    receive() external payable {}
}

/// @notice A "kernel" that, during settle(), pulls the Splitter and tops itself up in the tank.
contract BusyKernel is IKernelMin {
    KeeperTank internal immutable TANK;
    Splitter internal immutable SPLITTER;
    uint256 internal immutable CHIP_ID;

    uint256 public topUpPerSettle;
    bool public plainTransfer;
    uint256 public settles;

    constructor(KeeperTank tank, Splitter splitter, uint256 chipId_) {
        TANK = tank;
        SPLITTER = splitter;
        CHIP_ID = chipId_;
    }

    function chipId() external view returns (uint256) {
        return CHIP_ID;
    }

    function configure(uint256 topUpPerSettle_, bool plainTransfer_) external {
        topUpPerSettle = topUpPerSettle_;
        plainTransfer = plainTransfer_;
    }

    function settle() external returns (uint32) {
        SPLITTER.pull();
        if (topUpPerSettle != 0) {
            if (plainTransfer) {
                (bool ok,) = address(TANK).call{value: topUpPerSettle}("");
                require(ok, "plain top-up failed");
            } else {
                TANK.topUp{value: topUpPerSettle}(CHIP_ID);
            }
        }
        return uint32(++settles);
    }

    receive() external payable {}
}

/// @notice A "kernel" that sets and clears storage inside settle() to collect the largest EIP-3529 refund.
contract StorageRefundKernel is IKernelMin {
    uint256 internal immutable CHIP_ID;
    uint256 public slots;
    mapping(uint256 => uint256) internal _junk;

    constructor(uint256 chipId_, uint256 slots_) {
        CHIP_ID = chipId_;
        slots = slots_;
    }

    function chipId() external view returns (uint256) {
        return CHIP_ID;
    }

    function settle() external returns (uint32) {
        uint256 n = slots;
        for (uint256 i = 0; i < n; i++) {
            _junk[i] = 1;
        }
        for (uint256 i = 0; i < n; i++) {
            _junk[i] = 0;
        }
        return 1;
    }
}

/// @notice A "kernel" whose settle() succeeds and returns a very large buffer.
contract ReturnBombKernel is IKernelMin {
    uint256 internal immutable CHIP_ID;
    uint256 internal immutable SIZE;

    constructor(uint256 chipId_, uint256 size) {
        CHIP_ID = chipId_;
        SIZE = size;
    }

    function chipId() external view returns (uint256) {
        return CHIP_ID;
    }

    function settle() external view returns (uint32) {
        uint256 size = SIZE;
        assembly {
            return(0, size)
        }
    }
}

/// @notice A kernel whose chipId() refuses, cheaply, when it is given less than 20,000 gas.
///         If the tank probed it with too little gas the probe would fail without burning the rest, and the
///         kernel's transfer would be accepted without being credited to its chip.
contract PickyKernel is IKernelMin {
    uint256 internal immutable CHIP_ID;

    constructor(uint256 chipId_) {
        CHIP_ID = chipId_;
    }

    function chipId() external view returns (uint256) {
        require(gasleft() >= 20_000, "kernel: not enough gas");
        return CHIP_ID;
    }

    function settle() external pure returns (uint32) {
        return 1;
    }

    function pay(address to, uint256 value, uint256 gasLimit) external returns (bool ok) {
        (ok,) = to.call{value: value, gas: gasLimit}("");
    }

    receive() external payable {}
}

/// @notice One hostile contract in both roles: the Splitter's maintainer and a kernel.
///         While it is being settled it re-enters the tank and pulls the Splitter; while the Splitter pays
///         it (it is the maintainer) it tries to pull again.
contract KernelAndMaintainer is IKernelMin {
    bytes4 internal constant REENTRANT = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    KeeperTank public tank;
    Splitter public splitter;
    uint256 public chip;
    bool public settleReentryBlocked;
    bool public pullReentryBlocked;
    uint256 public settles;

    function arm(KeeperTank tank_, Splitter splitter_, uint256 chip_) external {
        tank = tank_;
        splitter = splitter_;
        chip = chip_;
    }

    function chipId() external view returns (uint256) {
        return chip;
    }

    function settle() external returns (uint32) {
        try tank.settleAndRefund(address(this)) {}
        catch (bytes memory err) {
            settleReentryBlocked = bytes4(err) == REENTRANT;
        }
        splitter.pull(); // pays this contract its 15%, see receive()
        return uint32(++settles);
    }

    receive() external payable {
        if (msg.sender == address(splitter)) {
            (bool ok, bytes memory err) = address(splitter).call(abi.encodeCall(Splitter.pull, ()));
            if (!ok) pullReentryBlocked = bytes4(err) == REENTRANT;
        }
    }
}

/// @notice Answers chipId() with whatever it is told, without holding the chip.
contract LyingKernel is IKernelMin {
    uint256 public claimed;
    uint256 public settles;

    constructor(uint256 claimed_) {
        claimed = claimed_;
    }

    function chipId() external view returns (uint256) {
        return claimed;
    }

    function settle() external returns (uint32) {
        return uint32(++settles);
    }

    function pay(address to, uint256 value) external returns (bool ok) {
        (ok,) = to.call{value: value}("");
    }

    receive() external payable {}
}

/// @notice A contract sender with a permissive fallback: every call "succeeds" and returns nothing.
contract SilentWallet {
    function pay(address to, uint256 value, uint256 gasLimit) external returns (bool ok) {
        (ok,) = to.call{value: value, gas: gasLimit}("");
    }

    fallback() external payable {}

    receive() external payable {}
}

/// @notice A contract sender whose chipId() burns all the gas it is given.
contract GasTrapSender {
    function chipId() external pure returns (uint256) {
        while (true) {}
        return 0;
    }

    function pay(address to, uint256 value) external returns (bool ok) {
        (ok,) = to.call{value: value}("");
    }

    receive() external payable {}
}

/// @notice A contract sender whose chipId() returns fewer than 32 bytes.
contract ShortAnswerSender {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 31)
        }
    }

    function pay(address to, uint256 value) external returns (bool ok) {
        (ok,) = to.call{value: value}("");
    }
}

/// @notice Settles several kernels in one transaction and keeps the refunds.
contract BatchCaller {
    function run(KeeperTank tank, address[] calldata kernels) external {
        for (uint256 i = 0; i < kernels.length; i++) {
            tank.settleAndRefund(kernels[i]);
        }
    }

    /// @dev the first call reverts and is caught; the second must still be treated as the first of the transaction
    function runCatchingFirst(KeeperTank tank, address failing, address working) external {
        try tank.settleAndRefund(failing) {} catch {}
        tank.settleAndRefund(working);
    }

    receive() external payable {}
}

/// @notice Settles several kernels in one transaction and records what each call cost it, so a test can
///         compare the gas the tank counted for a call with the gas that call really consumed.
contract MeteredBatch {
    uint256[] public frameGas;
    bool[] public succeeded;

    function run(KeeperTank tank, address[] calldata kernels) external {
        uint256 n = kernels.length;
        uint256[] memory gasSeen = new uint256[](n);
        bool[] memory ok = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 g = gasleft();
            try tank.settleAndRefund(kernels[i]) {
                ok[i] = true;
            } catch {}
            gasSeen[i] = g - gasleft();
        }
        delete frameGas;
        delete succeeded;
        for (uint256 i = 0; i < n; i++) {
            frameGas.push(gasSeen[i]);
            succeeded.push(ok[i]);
        }
    }

    receive() external payable {}
}

/// @notice A keeper contract that tries to settle again while it is being refunded.
contract ReentrantCaller {
    KeeperTank internal immutable TANK;
    address internal immutable KERNEL;
    bool internal immutable SWALLOW;

    bool public reentryBlocked;

    constructor(KeeperTank tank, address kernel, bool swallow) {
        TANK = tank;
        KERNEL = kernel;
        SWALLOW = swallow;
    }

    function run() external {
        TANK.settleAndRefund(KERNEL);
    }

    receive() external payable {
        if (SWALLOW) {
            try TANK.settleAndRefund(KERNEL) {}
            catch (bytes memory err) {
                reentryBlocked = bytes4(err) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
            }
        } else {
            TANK.settleAndRefund(KERNEL);
        }
    }
}

/// @notice A keeper contract that cannot receive OKB.
contract RejectingCaller {
    function run(KeeperTank tank, address kernel) external {
        tank.settleAndRefund(kernel);
    }
}

/// @notice A maintainer that only accepts OKB when told to.
contract ToggleMaintainer {
    bool public accept;

    function setAccept(bool accept_) external {
        accept = accept_;
    }

    receive() external payable {
        require(accept, "maintainer: not accepting");
    }
}

/// @notice A maintainer that tries to re-enter the Splitter while it is being paid.
contract ReentrantMaintainer {
    Splitter public splitter;
    /// @dev 0 = re-enter pull(), 1 = re-enter claimMaintainer()
    uint8 public target;
    bool public reentryBlocked;
    bool public failAfter;

    function arm(Splitter splitter_, uint8 target_, bool failAfter_) external {
        splitter = splitter_;
        target = target_;
        failAfter = failAfter_;
    }

    receive() external payable {
        if (address(splitter) != address(0)) {
            bytes memory data =
                target == 0 ? abi.encodeCall(Splitter.pull, ()) : abi.encodeCall(Splitter.claimMaintainer, ());
            (bool ok, bytes memory err) = address(splitter).call(data);
            // set on every attempt, so a nested call that goes through clears it
            reentryBlocked = !ok && bytes4(err) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
            require(!failAfter, "maintainer: refusing");
        }
    }
}

/// @notice An honest maintainer wallet whose receive hook needs about 40,000 gas (more than a Safe does).
contract SlowMaintainer {
    receive() external payable {
        uint256 start = gasleft();
        while (start - gasleft() < 40_000) {}
    }
}

/// @notice An honest maintainer wallet that refuses, cheaply, when it is offered less than 45,000 gas.
///         Unlike one that simply runs out of gas, it hands the unused gas back: a caller that could starve
///         the push would get this maintainer credited instead of paid.
contract PickyMaintainer {
    receive() external payable {
        require(gasleft() >= 45_000, "maintainer: not enough gas");
    }
}

/// @notice A maintainer that burns every unit of gas it is given.
contract GuzzlerMaintainer {
    receive() external payable {
        while (true) {}
    }
}

/// @notice A maintainer that reverts with a 100 kB buffer.
contract BombMaintainer {
    receive() external payable {
        assembly {
            revert(0, 100000)
        }
    }
}

/// @notice A wallet whose receive hook needs about 120,000 gas (far more than a 2,300 stipend or a 50,000 cap).
contract HeavyWallet {
    receive() external payable {
        uint256 start = gasleft();
        while (start - gasleft() < 120_000) {}
    }
}
