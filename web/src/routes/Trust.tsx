// #/trust
// What each party can and cannot do, stated only as far as the code enforces it (chips/INTERFACE.md section 13,
// contracts/core/NOTES.md). The owners and thresholds are read live, so the page cannot drift from the chain.

import type { ComponentChildren } from 'preact';
import { readAll } from '@covenant/chain';
import { beaconImpl, kernelFactory, ownerOf, safe } from '@covenant/chain/kernel';
import { Address } from '../components/common.tsx';
import { SimBanner } from '../components/kit.tsx';
import { ADDR, COVENANT, REPO, rpc } from '../config.ts';
import { useAsync } from '../router.ts';

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
  const [tapeout, ignix] = await Promise.all([who(tapeoutOwner), who(ignixOwner)]);
  return {
    tapeout,
    ignix,
    beacon: beaconAddr,
    beaconOwner: beaconOwner instanceof Error ? null : beaconOwner,
    beaconNow: beaconNow instanceof Error || !beaconAddr ? null : beaconNow,
    impl0: typeof impl0 === 'string' ? impl0 : null,
    pinsLive: typeof pins === 'boolean' ? pins : null,
  };
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

function Party({ name, can, cannot, children }: { name: string; can: ComponentChildren[]; cannot: ComponentChildren[]; children?: ComponentChildren }) {
  return (
    <section class="party">
      <h2>{name}</h2>
      {children && <p>{children}</p>}
      <div class="cancannot">
        <div>
          <h3>Can</h3>
          <ul>{can.map((c, i) => <li key={i}>{c}</li>)}</ul>
        </div>
        <div>
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
    <article>
      <SimBanner />
      <p class="crumbs">
        <a href="#/">Covenant</a> / trust model
      </p>
      <h1>Who can change what</h1>
      <p class="lede">
        Covenant's own contracts have no owner, no upgrade path and no pause. The two platforms it runs on do have owners, and this page
        says exactly what that lets them do. Unaudited.
      </p>

      <Party
        name="The Covenant team"
        can={[
          'Choose a kernel’s envelope and chip once, when the kernel is created. Anyone else can create a kernel the same way.',
          'Launch the reference token from the launcher wallet and bind it (first buy 0). Anyone can call settle().',
        ]}
        cannot={[
          'Change an envelope, a chip or a route after creation: kernels are fixed clones with the envelope in their bytecode, and the implementation has no owner, setter, upgrade or pause (the vault page scans its code).',
          'Take the tax. Value leaves a kernel only to a curve buy (the tokens come back and cannot move), after graduation to 0xdEaD or to a router buy whose tokens go to 0xdEaD, or as a pull credit to the envelope’s allowance payee within its caps.',
          'Stop settles. If the chip stops answering, the fallback word applies after the envelope’s fallbackEpochs (at most 30 days).',
        ]}
      >
        Kernel, KernelFactory, Fab, SealedVM, Lens, KeeperTank, Splitter and TeamRegistry: none of them has an owner function. Sources:{' '}
        <a href={`${REPO}/tree/main/contracts`}>contracts/</a>.
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
        name="The keeper, and anyone who settles"
        can={['Call settle() once per epoch, or skip epochs. The input word records how many epochs a settle covers (DT).', 'Choose when within an epoch to settle.']}
        cannot={['Supply any input: every bit of the input word is assembled by the kernel from chain state.', 'Starve the chip of gas into a failure: every external call gets a fixed gas amount or the whole settle reverts first.', 'Be needed: the keeper is liveness only; anyone can call settle() and the KeeperTank refunds gas from the chip’s own prepaid allowance.']}
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

      <section class="party">
        <h2>This site</h2>
        <ul>
          <li>Static files: no wallet, no cookies, no analytics. It sends read calls to {hosts.join(' and ')} and nothing else.</li>
          <li>
            A MATCH compares your browser’s result with one node operator’s answer. The public endpoints are both run by OKX; a node that lied
            could fake a MATCH, which is why every check prints a <span class="mono">cast</span> command for a node you choose.
          </li>
          <li>
            The local simulations are this site’s own TAP-20 implementation and a port of the kernel’s clip, tested against TAP-20’s vectors and
            Covenant’s golden vectors. They are not the code the chain runs, which is the point of comparing.
          </li>
        </ul>
      </section>

      <section class="party">
        <h2>Not done</h2>
        <ul>
          <li>No audit. The contracts have unit, fuzz, invariant and fork tests (contracts/core/NOTES.md); that is not an audit.</li>
          <li>Adoption is zero: the only token a chip routes, or will route, is the team’s own reference token, and its flows are small.</li>
        </ul>
      </section>
      {q.error && <p class="warn">Could not read the owners: {q.error.message}</p>}
    </article>
  );
}
