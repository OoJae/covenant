// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ICircuitFactory, ICircuits, ITransistors} from "./interfaces/ITapeOut.sol";
import {KeeperTank} from "./KeeperTank.sol";
import {TeamRegistry} from "./TeamRegistry.sol";
import {Native} from "./lib/Native.sol";

/// @title Splitter - creates the Covenant processor and splits its mint proceeds, with no key anywhere.
///
/// @notice The constructor deploys the KeeperTank and the TeamRegistry, writes their addresses into the
///         processor's on-chain story and creates the processor through TapeOut's factory, all in one
///         transaction. This contract is therefore the processor's immutable `creator`: the only address
///         TapeOut will ever pay mint proceeds to. `pull()` collects them and pays 85% to the KeeperTank and
///         15% to the maintainer. Payees and shares are immutable.
///         There is no owner, no upgrade path and no pause.
contract Splitter is ReentrancyGuardTransient {
    // ------------------------------------------------------------------ what the processor is

    string public constant NAME = "Covenant";
    string public constant SYMBOL = "CVNT";

    /// @notice Transistor supply cap, 2^26. NAND and LATCH share it.
    uint256 public constant SUPPLY = 67_108_864;

    /// @notice Price of one transistor in wei (0.00002 OKB).
    uint256 public constant PRICE = 0.00002 ether;

    // ------------------------------------------------------------------ how proceeds are split

    uint256 public constant TANK_BPS = 8500;
    uint256 public constant MAINTAINER_BPS = 1500;
    uint256 private constant BPS = 10_000;

    /// @notice Gas offered to the maintainer when its share is pushed. Enough for an EOA or a Safe.
    uint256 public constant MAINTAINER_GAS = 50_000;

    /// @dev Gas that must be left when the maintainer push starts. Below it `pull()` reverts, so a caller
    ///      cannot make the push fail by starving it of gas. With 90,000 left the callee is always offered
    ///      the full MAINTAINER_GAS:
    ///        - a maintainer with code: the call costs 11,600 (cold address + value), 63/64 of the remaining
    ///          78,400 is 77,175, and after a push that burns all 50,000 there are 28,400 left for the
    ///          22,100 storage write and the two events;
    ///        - a never-used address: the call costs 36,600 (25,000 more for the new account), 63/64 of the
    ///          remaining 53,400 is 52,565, and such an address has no code that could make the push fail.
    uint256 private constant PUSH_MIN_GAS = 90_000;

    // TapeOut's own fees, as the story states them. Creation reverts if they differ.
    uint256 private constant TAPEOUT_PROTOCOL_FEE = 0.00066 ether;
    uint256 private constant TAPEOUT_TAPEOUT_FEE = 0.0013 ether;

    // ------------------------------------------------------------------ immutable wiring

    /// @notice The processor's Transistors contract (ERC-1155). This contract is its `creator`.
    address public immutable TRANSISTORS;
    /// @notice The processor's Circuits contract (ERC-721).
    address public immutable CIRCUITS;
    /// @notice Receives 85% plus rounding dust.
    address public immutable TANK;
    /// @notice Receives 15%.
    address public immutable MAINTAINER;
    /// @notice Where team wallets are listed, starting with the account that created this contract. Not a payee.
    address public immutable REGISTRY;

    /// @notice Maintainer share that could not be pushed and waits for `claimMaintainer()`.
    uint256 public maintainerOwed;

    // ------------------------------------------------------------------ events and errors

    event Ignited(
        address indexed transistors, address indexed circuits, address tank, address registry, address maintainer
    );
    /// @notice One split. `toMaintainer` was either pushed or, if MaintainerCredited was emitted, credited.
    event Pulled(uint256 toTank, uint256 toMaintainer);
    event MaintainerCredited(uint256 amount);
    event MaintainerClaimed(uint256 amount);

    error ZeroMaintainer();
    error ZeroCommit();
    error WrongDeployFee();
    error FactorySealed();
    error TapeOutFeesChanged();
    error ProcessorMismatch();
    error InsufficientGas();
    error TransferFailed();
    error NothingOwed();

    // ------------------------------------------------------------------ story (constructor only)

    // TapeOut's own site shows only the first 600 characters of a story, hides every address and rewrites
    // every URL. So the first 556 characters, STORY_HEAD, stand alone and hold no address and no URL.
    string private constant STORY_HEAD = "COVENANT (CVNT): transistors for vault chips, circuits meant to route an "
        "IGNIX token's trading tax (intended use; not enforced here). SUPPLY 67,108,864 (2^26), fixed; NAND and "
        "LATCH share the cap; burned transistors are never re-minted. PRICE 0.00002 OKB each, fixed. No per-wallet "
        "cap, no presale, no team allocation. PROCEEDS are split by an immutable contract with no owner: 85% keeper "
        "tank (prepays the settlement gas of the chips whose transistors paid in), 15% maintainer. TRUST (at "
        "creation): unaudited; TapeOut's owner can upgrade processor logic. ";
    string private constant STORY_0 = "DETAILS: TapeOut's own fees are extra and not ours (at creation: 0.00066 OKB "
        "per mint call, 0.0013 OKB per tape-out). This processor's creator and payee is splitter ";
    string private constant STORY_1 = "; anyone may call pull() to pay out, and no key can change the splitter's "
        "payees or shares. Keeper tank ";
    string private constant STORY_2 = " refunds the gas of a chip's settlements, up to that chip's prepaid allowance "
        "(85% of the mint price of the transistors it burned, plus top-ups). Maintainer ";
    string private constant STORY_3 = ". Team wallets are listed in registry ";
    string private constant STORY_4 = ": the deployer, then wallets that a listed wallet invited and that declared "
        "themselves. SOURCE: https://github.com/OoJae/covenant commit ";
    string private constant STORY_5 = ".";

    // ------------------------------------------------------------------ creation

    /// @param factory      TapeOut's CircuitFactory
    /// @param maintainer   receives 15%
    /// @param commit       git commit of the source, written into the story as 40 hex characters
    /// @dev `msg.value` must equal `factory.deployFee()` exactly: TapeOut credits any excess to a balance
    ///      that only this contract could withdraw, and it has no function to do so.
    ///      `msg.sender`, the account that sends the creation transaction, becomes entry 0 of the registry.
    constructor(address factory, address maintainer, bytes20 commit) payable {
        if (maintainer == address(0)) revert ZeroMaintainer();
        if (commit == bytes20(0)) revert ZeroCommit();
        if (msg.value != ICircuitFactory(factory).deployFee()) revert WrongDeployFee();

        // 1. The tank and the registry exist before the story is written, so the story can name them.
        TeamRegistry registry = new TeamRegistry(msg.sender);
        KeeperTank tank = new KeeperTank();

        // 2. The story, built from the real addresses.
        string memory story = _story(address(tank), maintainer, address(registry), commit);

        // 3. The processor. msg.sender of createCPU, this contract, becomes its immutable creator.
        (address transistors, address circuits) =
            ICircuitFactory(factory).createCPU{value: msg.value}(NAME, SYMBOL, story, SUPPLY, PRICE);

        // 4. The story's statements about TapeOut must be true at creation: its factory is not sealed, so
        //    its owner can upgrade processor logic, and its fees are the ones stated.
        if (ICircuitFactory(factory).isSealed()) revert FactorySealed();
        if (
            ICircuitFactory(factory).protocolFee() != TAPEOUT_PROTOCOL_FEE
                || ITransistors(transistors).protocolFee() != TAPEOUT_PROTOCOL_FEE
                || ICircuits(circuits).TAPEOUT_FEE() != TAPEOUT_TAPEOUT_FEE
        ) revert TapeOutFeesChanged();

        // 5. So must its statements about the processor itself, and the processor must carry exactly the
        //    story, name and symbol it was given.
        if (
            ITransistors(transistors).creator() != address(this) || ITransistors(transistors).supplyCap() != SUPPLY
                || ITransistors(transistors).mintPrice() != PRICE || ITransistors(transistors).circuits() != circuits
                || ICircuits(circuits).transistors() != transistors || !ICircuitFactory(factory).isCPU(circuits)
                || !Strings.equal(ITransistors(transistors).story(), story)
                || !Strings.equal(ITransistors(transistors).cpuName(), NAME)
                || !Strings.equal(ITransistors(transistors).cpuSymbol(), SYMBOL)
        ) revert ProcessorMismatch();

        tank.init(circuits, transistors);

        TRANSISTORS = transistors;
        CIRCUITS = circuits;
        TANK = address(tank);
        MAINTAINER = maintainer;
        REGISTRY = address(registry);

        // Emitted after the factory call because it reports what that call created.
        // A constructor cannot be re-entered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Ignited(transistors, circuits, address(tank), address(registry), maintainer);
    }

    // ------------------------------------------------------------------ paying out

    /// @notice Collects the mint proceeds TapeOut holds for this contract and splits everything this contract
    ///         has: 85% to the tank, 15% to the maintainer. Rounding dust goes to the tank.
    ///         Anyone may call, any number of times; with nothing to split it does nothing.
    /// @dev    If the maintainer cannot be paid within MAINTAINER_GAS its share is credited to
    ///         `maintainerOwed` instead, so the maintainer can never block the tank.
    function pull() external nonReentrant {
        // Reverts with "nothing owed" when nothing accrued since the last pull. Whatever the reason,
        // a failed withdrawal must not stop money already here from being split.
        try ITransistors(TRANSISTORS).withdraw() {} catch {}

        uint256 amount = address(this).balance - maintainerOwed;
        if (amount == 0) return;

        uint256 toMaintainer = amount * MAINTAINER_BPS / BPS;
        uint256 toTank = amount - toMaintainer;

        if (!Native.send(TANK, toTank, gasleft())) revert TransferFailed();

        if (toMaintainer != 0) {
            if (gasleft() < PUSH_MIN_GAS) revert InsufficientGas();
            if (!Native.send(MAINTAINER, toMaintainer, MAINTAINER_GAS)) {
                maintainerOwed += toMaintainer;
                // Reports the outcome of the push, so it can only come after it. pull() is nonReentrant.
                // forge-lint: disable-next-line(reentrancy-events)
                emit MaintainerCredited(toMaintainer);
            }
        }

        // Every event of pull() follows the withdraw() call that brings the money in. pull() is nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Pulled(toTank, toMaintainer);
    }

    /// @notice Sends the credited maintainer share to the maintainer, with all available gas.
    ///         Anyone may call; the money can only go to the maintainer.
    function claimMaintainer() external nonReentrant {
        uint256 amount = maintainerOwed;
        if (amount == 0) revert NothingOwed();

        maintainerOwed = 0;
        emit MaintainerClaimed(amount);
        if (!Native.send(MAINTAINER, amount, gasleft())) revert TransferFailed();
    }

    /// @notice TapeOut's Transistors contract pays proceeds in here. Anything else sent here is split too.
    receive() external payable {}

    // ------------------------------------------------------------------ internals

    function _story(address tank, address maintainer, address registry, bytes20 commit)
        private
        view
        returns (string memory s)
    {
        s = string.concat(STORY_HEAD, STORY_0, Strings.toChecksumHexString(address(this)), STORY_1);
        s = string.concat(s, Strings.toChecksumHexString(tank), STORY_2);
        s = string.concat(s, Strings.toChecksumHexString(maintainer), STORY_3);
        s = string.concat(s, Strings.toChecksumHexString(registry), STORY_4);
        s = string.concat(s, _hex(commit), STORY_5);
    }

    /// @dev `commit` as 40 lower-case hex characters. No 0x prefix: TapeOut's site would hide it as an address.
    function _hex(bytes20 commit) private pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory text = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            text[2 * i] = digits[uint8(commit[i]) >> 4];
            text[2 * i + 1] = digits[uint8(commit[i]) & 0x0f];
        }
        return string(text);
    }
}
