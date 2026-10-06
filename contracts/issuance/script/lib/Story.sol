// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @notice The story string the Covenant processor must carry, built WITHOUT any code from src/.
///         The text below is typed from the approved template, sentence by sentence; addresses are rendered
///         by Foundry's own EIP-55 implementation (`vm.toString`), not by OpenZeppelin's, and the commit by
///         Foundry's hex encoder. The tests and the Ignite script compare this string with what the Splitter
///         writes on-chain, byte for byte.
///         Off-chain only: it uses a cheatcode and is never deployed.
library Story {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev TapeOut's own site shows this many characters of a story and no more.
    uint256 internal constant SHOWN = 600;

    /// @notice The part that stands alone: 556 characters, no address, no URL.
    function head() internal pure returns (string memory) {
        return string.concat(
            "COVENANT (CVNT): transistors for vault chips, circuits meant to route an IGNIX token's trading tax (intended use; not enforced here). ",
            "SUPPLY 67,108,864 (2^26), fixed; NAND and LATCH share the cap; burned transistors are never re-minted. ",
            "PRICE 0.00002 OKB each, fixed. ",
            "No per-wallet cap, no presale, no team allocation. ",
            "PROCEEDS are split by an immutable contract with no owner: 85% keeper tank (prepays the settlement gas of the chips whose transistors paid in), 15% maintainer. ",
            "TRUST (at creation): unaudited; TapeOut's owner can upgrade processor logic. "
        );
    }

    function expected(address splitter, address tank, address maintainer, address registry, bytes20 commit)
        internal
        pure
        returns (string memory s)
    {
        s = string.concat(
            head(),
            "DETAILS: TapeOut's own fees are extra and not ours (at creation: 0.00066 OKB per mint call, 0.0013 OKB per tape-out). ",
            "This processor's creator and payee is splitter ",
            vm.toString(splitter),
            "; anyone may call pull() to pay out, and no key can change the splitter's payees or shares. ",
            "Keeper tank ",
            vm.toString(tank),
            " refunds the gas of a chip's settlements, up to that chip's prepaid allowance ",
            "(85% of the mint price of the transistors it burned, plus top-ups). "
        );
        s = string.concat(
            s,
            "Maintainer ",
            vm.toString(maintainer),
            ". ",
            "Team wallets are listed in registry ",
            vm.toString(registry),
            ": the deployer, then wallets that a listed wallet invited and that declared themselves. ",
            "SOURCE: https://github.com/OoJae/covenant commit ",
            commitHex(commit),
            "."
        );
    }

    /// @notice A git commit as git prints it: 40 lower-case hex characters, no 0x prefix.
    function commitHex(bytes20 commit) internal pure returns (string memory) {
        return vm.replace(vm.toString(abi.encodePacked(commit)), "0x", "");
    }

    /// @notice What TapeOut's own site shows of `story`: its first 600 characters.
    function shown(string memory story) internal pure returns (string memory) {
        bytes memory all = bytes(story);
        if (all.length <= SHOWN) return story;
        bytes memory cut = new bytes(SHOWN);
        for (uint256 i = 0; i < SHOWN; i++) {
            cut[i] = all[i];
        }
        return string(cut);
    }
}
