// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SitePublisher} from "../src/SitePublisher.sol";

/// @title Publish - publishes a static site into the DeWEB container of one TapeOut circuit on X Layer.
///
/// @notice Run it WITHOUT --broadcast first: that only simulates against a fork of the live chain and prints
///         the plan. With --broadcast every listed call becomes a real transaction signed by the account
///         that holds the circuit; the opening fee and the name fee are not refundable. See ../../NOTES.md.
///
///         Environment:
///           PROCESSOR         the processor: address of its Circuits contract
///           CIRCUIT_ID        the circuit whose container receives the site (the sender must hold it)
///           SITE_DIR          the site directory, absolute or relative to this Foundry project
///                             (default ../../../web/dist, the repository's build output)
///           PROCESSOR_NUMBER  optional: the processor's index in the factory (plan.ts prints it); saves a scan
///           MONTHS            months (30 days each) of name activation to pay for if the container is not
///                             activated; 0 = do not pay (default 1)
///           RENEW             true = pay for MONTHS more even if it is already activated (default false)
///           FALLBACK          optional: path served for unknown paths without an extension (default: none)
///           PRUNE             true = remove on-chain files that are not in SITE_DIR (default false)
///
///         What it sends, in this order, skipping what is already done:
///           1. opener.open(processor, id)                paying FEE() exactly (0.08 OKB when written)
///           2. per file: putFile, then appendChunk for each further 24,000 bytes; HTML files last
///           3. setFallback                               only with FALLBACK
///           4. removeFile per stale path                 only with PRUNE=true
///           5. binding.bind(name, container, MONTHS)     paying MONTHS * monthlyFee() exactly
///         After the calls it reads every file back and stops with an error unless the bytes are identical.
contract Publish is Script, SitePublisher {
    function run() external {
        Options memory o = Options({
            months: vm.envOr("MONTHS", uint256(1)),
            renew: vm.envOr("RENEW", false),
            fallbackPath: vm.envOr("FALLBACK", string("")),
            prune: vm.envOr("PRUNE", false),
            processorNumber: vm.envOr("PROCESSOR_NUMBER", UNKNOWN)
        });
        publish(
            vm.envAddress("PROCESSOR"), vm.envUint("CIRCUIT_ID"), vm.envOr("SITE_DIR", string("../../../web/dist")), o
        );
    }

    /// @notice `forge script ... --sig "runWith(address,uint256,string)" <processor> <circuit id> <site dir>`:
    ///         the three inputs as arguments instead of environment variables, every option at its default.
    ///         (Not an overload of `run`: forge refuses a script with two functions of that name.)
    function runWith(address processor, uint256 circuitId, string calldata siteDir) external {
        publish(processor, circuitId, siteDir, Options(1, false, "", false, UNKNOWN));
    }

    function publish(address processor, uint256 circuitId, string memory siteDir, Options memory o)
        public
        returns (Target memory t, Step[] memory steps)
    {
        SiteFile[] memory files = loadSite(siteDir);

        // The account forge broadcasts from is the origin of this run (--sender, or the only signer given).
        // Everything is checked for that account before a broadcast is started.
        address sender = tx.origin;
        t = inspect(processor, circuitId, sender, o.processorNumber);
        steps = plan(t, files, o);
        _logPlan(t, files, steps, sender);
        require(
            sender.balance >= valueOf(steps),
            "Publish: the sending account holds less OKB than the fees to pay (gas comes on top)"
        );

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(broadcaster == sender, "Publish: forge broadcasts from another account than the one that was checked");
        for (uint256 i; i < steps.length; i++) {
            (bool ok, bytes memory ret) = steps[i].target.call{value: steps[i].value}(steps[i].data);
            if (!ok) {
                console2.log("FAILED at step", i + 1, steps[i].label);
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        vm.stopBroadcast();

        // Read everything back on the simulated chain. A difference stops the script before anything is sent.
        requirePublished(t, files, o);
        _logResult(t, files, steps, o);
    }

    function _logPlan(Target memory t, SiteFile[] memory files, Step[] memory steps, address sender) private view {
        uint256 bytesTotal;
        for (uint256 i; i < files.length; i++) bytesTotal += files[i].data.length;

        console2.log("== DeWEB publication ==");
        console2.log("chain id / block          ", block.chainid, block.number);
        console2.log("processor (Circuits)      ", t.processor);
        console2.log("processor number          ", t.processorNumber);
        console2.log("circuit id                ", t.circuitId);
        console2.log("circuit holder            ", t.holder);
        console2.log("sender                    ", sender);
        console2.log("  balance (wei)           ", sender.balance);
        console2.log("container                 ", t.container);
        console2.log("  opened / name activated ", t.opened, t.live);
        console2.log("  activated until (unix)  ", t.paidUntil);
        console2.log("on-chain name             ", t.name);
        console2.log("opening fee (wei)         ", t.openFee);
        console2.log("name fee per 30 days (wei)", t.monthlyFee);
        console2.log("site files / bytes        ", files.length, bytesTotal);
        if (!t.implementationsAccepted) {
            console2.log(
                "WARNING: the SiteRegistry or DomainBinding implementation is not the one the official gateway accepts;"
            );
            console2.log("         tapekit.org will refuse every X Layer site (store-changed) until it is updated.");
        }
        console2.log("");
        console2.log("Transactions, in order:", steps.length);
        for (uint256 i; i < steps.length; i++) {
            console2.log(string.concat("  ", vm.toString(i + 1), ". ", steps[i].label));
            console2.log("       to / value (wei) / calldata bytes:", steps[i].target, steps[i].value, steps[i].data.length);
        }
        console2.log("fees paid to the protocol (wei):", valueOf(steps));
        if (steps.length == 0) console2.log("Nothing to send: the container already holds this site.");
    }

    function _logResult(Target memory t, SiteFile[] memory files, Step[] memory steps, Options memory o) private pure {
        console2.log("");
        console2.log("== Read back from the simulated chain ==");
        console2.log("files identical to the local build (bytes, size, content type, SHA-256):", files.length);
        console2.log("transactions:", steps.length);
        console2.log(string.concat("gateway:  https://", t.host, ".tapekit.org/"));
        console2.log(string.concat("status:   https://", t.host, ".tapekit.org/.tape/status"));
        if (o.months == 0 && !t.live) {
            console2.log("NOTE: MONTHS=0 and the name is not activated: the gateway answers HTTP 402 until bind is paid.");
        }
        console2.log("(a run without --broadcast sent nothing; after a broadcast, check with tools/deweb/verify.ts)");
    }
}
