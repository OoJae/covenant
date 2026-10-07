// #/trust
// What each party can and cannot do, stated only as far as the code enforces it (chips/INTERFACE.md section 13,
// contracts/core/NOTES.md; for kernel v2, chips/INTERFACE-V2.md section 13 and contracts/core-v2/NOTES.md). The
// owners and thresholds are read live, so the page cannot drift from the chain.

import type { ComponentChildren } from 'preact';
import { readAll } from '@covenant/chain';
import { beaconImpl, erc20, kernelFactory, kernelFactoryV2, ownerOf, safe } from '@covenant/chain/kernel';
import { Address } from '../components/common.tsx';
import { SimBanner } from '../components/kit.tsx';
import { ADDR, COVENANT, REPO, rpc } from '../config.ts';
import { useAsync } from '../router.ts';
import { PageHead } from './shared.tsx';

const MANAGER = '0x96B51c57e5346D0C0198899243cf851D1E23C309';

interface Who {
  owner: string | null;
  threshold: number | null;
  owners: number | null;
}

async function readOwners() {
  const f = COVENANT.kernelFactory ? kernelFactory(COVENANT.kernelFactory) : null;
  const [beacon, pins, impl0] = f ? await readAll(rpc, [f.beacon(), f.pinsLive(), f.impl0()] as const) : [null, null, null];
  const beaconAddr = typeof beacon === 'string' ? beacon : null;
  const [tapeoutOwner, beaconOwner, ignixOwner, beaconNow] = await readAll(rpc, [
    ownerOf(ADDR.factory),
    ownerOf(beaconAddr ?? ADDR.factory),
    ownerOf(MANAGER),
    beaconImpl(beaconAddr ?? ADDR.factory),
  ] as const);
  const who = async (o: string | Error): Promise<Who> => {
    if (o instanceof Error) return { owner: null, threshold: null, owners: null };
    const [t, os] = await readAll(rpc, [safe(o).threshold(), safe(o).owners()] as const);
    return { owner: o, threshold: t instanceof Error ? null : t, owners: os instanceof Error ? null : os.length };
  };
  const [tapeout, ignix, tetherOwner] = await Promise.all([who(tapeoutOwner), who(ignixOwner), readTether()]);
  return {
    tapeout,
    ignix,
    tether: tetherOwner,
    beacon: beaconAddr,
    beaconOwner: beaconOwner instanceof Error ? null : beaconOwner,
    beaconNow: beaconNow instanceof Error || !beaconAddr ? null : beaconNow,
    impl0: typeof impl0 === 'string' ? impl0 : null,
    pinsLive: typeof pins === 'boolean' ? pins : null,
  };
}

/** Kernel v2's quote asset (read from KernelFactoryV2) and its owner, once deployments/xlayer.json records a v2 factory. */
async function readTether(): Promise<{ quote: string; symbol: string | null; owner: string | null } | null> {
  if (!COVENANT.kernelFactoryV2) return null;
  const [quote] = await readAll(rpc, [kernelFactoryV2(COVENANT.kernelFactoryV2).quote()] as const);
  if (quote instanceof Error) return null;
  const [owner, symbol] = await readAll(rpc, [ownerOf(quote), erc20(quote).symbol()] as const);
  return { quote, symbol: symbol instanceof Error ? null : symbol, owner: owner instanceof Error ? null : owner };
}

function Safe({ w, what }: { w: Who | undefined; what: string }) {
  if (!w) return <span class="muted">reading…</span>;
  if (!w.owner) return <span class="warn">could not be read</span>;
  return (
    <>
      {what} <Address value={w.owner} />
      {w.threshold !== null && w.owners !== null ? (
        <>
          , a Safe needing <b>
            {w.threshold} of {w.owners}
          </b>{' '}
          signatures (read now)
        </>
      ) : (
        ' (not a Safe, or it could not be read)'
      )}
    </>
  );
}

/** One party as a deed: what it can do, and what it cannot (under a gold rule: the part the code guarantees). */
function Party({ name, can, cannot, children }: { name: string; can: ComponentChildren[]; cannot: ComponentChildren[]; children?: ComponentChildren }) {
  return (
    <section class="clause party">
      <span class="clause__no" aria-hidden="true">
        Party
      </span>
      <h2 class="clause__title">{name}</h2>
      {children && <p>{children}</p>}
      <div class="cancannot">
        <div class="deed deed--can">
          <h3>Can</h3>
          <ul>{can.map((c, i) => <li key={i}>{c}</li>)}</ul>
        </div>
        <div class="deed deed--cannot">
          <h3>Cannot</h3>
          <ul>{cannot.map((c, i) => <li key={i}>{c}</li>)}</ul>
        </div>
      </div>
    </section>
  );
}

export function Trust() {
  const q = useAsync(readOwners, []);
  const d = q.data;
  const hosts = ADDR.rpc.map((u) => new URL(u).host);
  return (
    <article class="page page--trust">
      <SimBanner />
      <PageHead
        crumbs={
          <>
            <a href="#/">Covenant</a> / trust model
          </>
        }
        title={
          <>
            Who can change <em>what</em>
          </>
        }
        lede="Covenant's own contracts have no owner, no upgrade path and no pause. The two platforms it runs on do have owners, and this page says exactly what that lets them do. Unaudited."
      />

      <Party
        name="The Covenant team"
        can={[
          'Choose a kernel’s envelope and chip once, when the kernel is created. Anyone else can create a kernel the same way.',
          'Launch the reference token from the launcher wallet and bind it (first buy 0). Anyone can call settle().',
          'Point the Covenant Architect’s x402 payTo at a kernel v2, or away from it, at any time: payTo is a seller setting and leaves no trace on chain. Revenue is routed only if it is paid to the kernel.',
        ]}
        cannot={[
          'Change an envelope, a chip or a route after creation: kernels are fixed clones with the envelope in their bytecode, and the implementation has no owner, setter, upgrade or pause (the vault page scans its code).',
          'Take more than the envelope’s allowance. Value leaves a kernel only to a curve buy (the tokens come back and cannot move), after graduation to 0xdEaD or to a router buy whose tokens go to 0xdEaD, or as a pull credit to the envelope’s allowance payee within its caps. The v1 kernel’s payee is the KeeperTank; the v2 kernel’s is the Covenant Architect’s agent wallet, a team wallet.',
          'Stop settles. If the chip stops answering, the fallback word applies after the envelope’s fallbackEpochs (at most 30 days).',
        ]}
      >
        Kernel, KernelFactory, Fab, SealedVM, Lens, KeeperTank, Splitter and TeamRegistry, and kernel v2's KernelV2, KernelFactoryV2 and LensV2: none of them
        has an owner function. Sources: <a href={`${REPO}/tree/main/contracts`}>contracts/</a>. The team’s own rule, which no code enforces: no team wallet
        trades the token or pays revenue into a kernel that buys it (self-payment is forbidden).
      </Party>

      <Party
        name="TapeOut"
        can={[
          <>
            Upgrade the code that stores and steps every circuit. The circuit beacon is owned by TapeOut’s factory{d?.beaconOwner ? <> (<Address value={d.beaconOwner} />)</> : ''}, whose owner is <Safe w={d?.tapeout} what="" />.
          </>,
          'Change what TapeOut’s Circuits contract says about chip ownership and netlists (it is behind that beacon).',
        ]}
        cannot={[
          <>
            Change what a kernel’s chip computes. On every settle the kernel checks the beacon’s implementation, its code hash, the chip’s pin counts and its netlist hash against values pinned in the factory; if any differs it steps the same netlist bytes on Covenant’s SealedVM, from the Fab’s own copy. Both evaluators compute the same function, so switching cannot change a result.{' '}
            {d && d.pinsLive !== null && <b>Pins hold now: {String(d.pinsLive)}.</b>}
          </>,
          'Stall a settle: if TapeOut’s step fails for any reason, the SealedVM is asked in the same settle.',
        ]}
      />

      <Party
        name="IGNIX"
        can={[
          <>
            Upgrade the IgnixManager, the contract that runs the curve, takes the tax on curve trades and executes the kernel’s buys. Its owner is <Safe w={d?.ignix} what="" />.
          </>,
          'Pause buys (the decided amounts wait in the kernel’s reserve) and pause claims for 72 hours at a time, renewably (the tax waits in the vault).',
          'With an upgrade: stop the buy leg or the claim (settles go on, the amounts wait), or make every settle revert (the tax waits in the vault). Covenant cannot constrain what upgraded Manager code does.',
        ]}
        cannot={['Change a vault’s recipient: RECIPIENT is an immutable of the Directed vault contract, and the token itself is not upgradeable.', 'Change a kernel’s envelope, chip or records.']}
      />

      <Party
        name="Tether, for a kernel v2 (USD₮0 quote)"
        can={[
          <>
            Block a kernel v2’s address. USD₮0’s owner is{' '}
            {d?.tether?.owner ? <Address value={d.tether.owner} /> : COVENANT.kernelFactoryV2 ? (d ? 'not readable now' : 'reading…') : 'read here once a kernel v2 is deployed'}
            {d?.tether?.owner ? ' (read now)' : ''}; the same owner can upgrade USD₮0. A blocked kernel still receives claims and payments and keeps settling, but its
            buys and its credit withdrawals fail until it is unblocked.
          </>,
          'Destroy a blocked kernel’s USD₮0. The kernel routes what is left and never reverts. After a destruction, USD₮0 that arrives later (tax or revenue) first refills the credits the destroyed balance covered, and the chip sees none of it until they are covered.',
          'Upgrade USD₮0. Every amount is measured by balance, so a fee on transfer would make claims arrive short and buys fail (the Manager’s exact quote no longer fills) without breaking the books.',
        ]}
        cannot={[
          'Change a kernel’s envelope, chip, code shift or records, or make a settle revert.',
          'Reach a kernel v1: it holds native OKB, not USD₮0.',
        ]}
      >
        {COVENANT.kernelFactoryV2
          ? 'Kernel v2 routes an IGNIX token quoted in USD₮0, so it holds USD₮0, which Tether controls.'
          : 'Kernel v2 (USD₮0 quote) is built and tested on an X Layer fork but not deployed; this applies once it is.'}{' '}
        On the curve a v2 kernel routes revenue paid to it (for example x402 with payTo = the kernel) as tax; after graduation the chip does not see revenue and a
        fixed rule buys the token with it and burns the tokens.
      </Party>

      <Party
        name="The keeper, and anyone who settles"
        can={['Call settle() once per epoch, or skip epochs. The input word records how many epochs a settle covers (DT).', 'Choose when within an epoch to settle.']}
        cannot={['Supply any input: every bit of the input word is assembled by the kernel from chain state.', 'Starve the chip of gas into a failure: every external call gets a fixed gas amount or the whole settle reverts first.', 'Be needed: the keeper is liveness only; anyone can call settle() and the KeeperTank refunds gas from the chip’s own prepaid allowance, once Splitter.pull() has paid it in.']}
      />

      <Party
        name="A chip’s author"
        can={['Write any netlist and tape it out through the Fab. Its answers are telemetry until proven; the routing fields are clipped.']}
        cannot={[
          'Exceed the envelope: at most allowCumBps of all tax (never more than half) can ever become allowance, and the allowance payee gets nothing else; everything else is bought and locked, burned, or waits in the reserve.',
          'Park the reserve: at or above the floor it is offered to the buy leg at floorRel/256 per settle or faster, so with a settle every epoch it halves within 30 days and one epoch.',
          'Make a settle revert by what it answers.',
        ]}
      >
        The hostile chip page shows a chip that asks for everything. The Flow Governor’s published proofs show it never needs clipping.
      </Party>

      <section class="clause party">
        <span class="clause__no" aria-hidden="true">
          Reading
        </span>
        <h2 class="clause__title">This site</h2>
        <ul>
          <li>Static files: no wallet, no cookies, no analytics. It sends read calls to {hosts.join(' and ')} and nothing else.</li>
          <li>
            A MATCH compares your browser’s result with one node operator’s answer. The public endpoints are both run by OKX; a node that lied
            could fake a MATCH, which is why every check prints a <span class="mono">cast</span> command for a node you choose.
          </li>
          <li>
            The local simulations are this site’s own TAP-02 implementation and a port of the kernel’s clip, tested against TAP-02’s vectors and
            Covenant’s golden vectors. They are not the code the chain runs, which is the point of comparing.
          </li>
        </ul>
      </section>

      <section class="clause party">
        <span class="clause__no" aria-hidden="true">
          Limits
        </span>
        <h2 class="clause__title">Not done</h2>
        <ul>
          <li>No audit. The contracts have unit, fuzz, invariant and fork tests (contracts/core/NOTES.md); that is not an audit.</li>
          <li>
            Adoption is zero: the only tokens bound to Covenant's kernels are the two the team launched itself, one per kernel (first buy 0, never
            traded by a team wallet).
          </li>
        </ul>
      </section>
      {q.error && <p class="warn">Could not read the owners: {q.error.message}</p>}
    </article>
  );
}
