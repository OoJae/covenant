import type { RefObject } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { Bond, Icon, Wordmark } from './components/Icon.tsx';
import type { MenuSheet, NavLink } from './components/MenuSheet.tsx';
import { Seal } from './components/Seal.tsx';
import { ADDR, CHAIN, COVENANT, REPO, SIMULATION } from './config.ts';
import { useAsync, useRoute, type Route } from './router.ts';
import { Landing } from './routes/Landing.tsx';
import { Failure, Loading } from './routes/shared.tsx';

// Everything but the landing page loads on demand, which keeps index.html plus its entry script within the entry
// budget: the circuit bench (netlist parser, simulator, die-shot renderer), the kernel pages (the same, plus the
// Flow Governor's netlist), the two text-heavy guides, the processor page and the not-found page; and two pieces of
// the frame, the phone menu sheet and the footer's live chain read. The browser caches each promise, so asking
// twice costs nothing.
const loadBench = () => import('./routes/Circuit.tsx');
const loadKernelPages = () => import('./routes/kernelPages.tsx');
const loadGuides = () => import('./routes/guidePages.tsx');
const loadProcessor = () => import('./routes/Processor.tsx');
const loadNotFound = () => import('./routes/NotFound.tsx');
const loadSheet = () => import('./components/MenuSheet.tsx');
const loadFlagship = () => import('./components/flagshipState.ts');
type SheetComponent = typeof MenuSheet;

/** Where a copy of this site is stored on X Layer (TapeOut DeWEB, probe circuit 1's container). */
const MIRROR = 'https://1-2-283.tapekit.org/';
const COLD = '0x0000000000000000';

function GuidePage({ page }: { page: 'judge' | 'trust' }) {
  const q = useAsync(loadGuides, []);
  if (q.loading) return <Loading page what={page === 'judge' ? 'the judge guide' : 'the trust model'} />;
  if (q.error || !q.data) return <Failure page error={q.error} retry={q.reload} />;
  return page === 'judge' ? <q.data.Judge /> : <q.data.Trust />;
}

function ProcessorPage({ address }: { address: string }) {
  const q = useAsync(loadProcessor, []);
  if (q.loading) return <Loading page what="the processor page" />;
  if (q.error || !q.data) return <Failure page error={q.error} retry={q.reload} />;
  return <q.data.Processor address={address} />;
}

function NotFoundPage({ hash }: { hash: string }) {
  const q = useAsync(loadNotFound, []);
  if (q.loading) return <Loading page what="the page" />;
  if (q.error || !q.data) return <Failure page error={q.error} retry={q.reload} />;
  return <q.data.NotFound hash={hash} />;
}

function CircuitPage(props: { processor: string; id: string }) {
  const q = useAsync(loadBench, []);
  if (q.loading) return <Loading page what="the circuit bench" />;
  if (q.error || !q.data) return <Failure page error={q.error} retry={q.reload} />;
  const Bench = q.data.Circuit;
  return <Bench {...props} />;
}

function KernelPage(props: { page: 'vault' | 'audit' | 'hostile'; kernel?: string; n?: number }) {
  const q = useAsync(loadKernelPages, []);
  if (q.loading) return <Loading page what="the kernel pages" />;
  if (q.error || !q.data) return <Failure page error={q.error} retry={q.reload} />;
  const { Vault, Audit, Hostile } = q.data;
  if (props.page === 'vault') return <Vault kernel={props.kernel!} />;
  if (props.page === 'audit') return <Audit kernel={props.kernel!} n={props.n!} />;
  return <Hostile />;
}

const same = (a: string | null | undefined, b: string | null | undefined): boolean => !!a && !!b && a.toLowerCase() === b.toLowerCase();

const short = (a: string): string => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** A kernel's name in the nav (Vault v1, Vault v2), or its short address. */
function vaultName(kernel: string): string {
  if (same(kernel, COVENANT.kernel)) return COVENANT.kernelV2 ? 'Vault v1' : 'Vault';
  if (same(kernel, COVENANT.kernelV2)) return 'Vault v2';
  return `Vault ${short(kernel)}`;
}

/** The document title of a route, so a tab, the history and a screen reader name the page. */
export function titleFor(route: Route): string {
  const page = ((): string | null => {
    switch (route.page) {
      case 'landing':
        return null;
      case 'vault':
        return vaultName(route.kernel);
      case 'audit':
        return `Settle ${route.n} · ${vaultName(route.kernel)}`;
      case 'processor':
        return `Processor ${short(route.processor)}`;
      case 'circuit':
        return `Circuit ${route.id} · Processor ${short(route.processor)}`;
      case 'hostile':
        return 'Hostile chip';
      case 'judge':
        return 'Judge guide';
      case 'trust':
        return 'Trust';
      default:
        return 'Not found';
    }
  })();
  return page ? `${page} · Covenant` : 'Covenant · a token’s tax, routed by a chip';
}

function navLinks(route: Route): NavLink[] {
  const k = route.page === 'vault' || route.page === 'audit' ? route.kernel : null;
  const links: NavLink[] = [];
  if (COVENANT.kernel) links.push({ href: `#/k/${COVENANT.kernel}`, text: COVENANT.kernelV2 ? 'Vault v1' : 'Vault', current: same(k, COVENANT.kernel) });
  if (COVENANT.kernelV2) links.push({ href: `#/k/${COVENANT.kernelV2}`, text: 'Vault v2', current: same(k, COVENANT.kernelV2) });
  links.push(
    { href: '#/hostile', text: 'Hostile chip', current: route.page === 'hostile' },
    { href: '#/judge', text: 'Judge guide', current: route.page === 'judge' },
    { href: '#/trust', text: 'Trust', current: route.page === 'trust' },
  );
  return links;
}

/**
 * True while a full-width silicon surface (the landing's die, the vault's band, the footer) passes under the
 * header. One IntersectionObserver whose root is the strip of the viewport the header covers watches every such
 * surface; the page is scanned again when it changes (pages arrive after their data) and on resize. A silicon
 * surface that has paper over it (the landing's stage once its paper has come in sets data-cover="paper") does not
 * count, so the header turns to paper with it.
 */
function useOverSilicon(header: RefObject<HTMLElement | null>, routeKey: string): boolean {
  const [over, setOver] = useState(false);
  useEffect(() => {
    if (typeof IntersectionObserver !== 'function') return;
    let io: IntersectionObserver | null = null;
    let timer = 0;
    let hits = new Set<Element>();
    const COVER = '[data-cover="paper"]';
    const update = (): void => setOver([...hits].some((el) => !el.matches(COVER) && !el.querySelector(COVER)));
    const scan = (): void => {
      io?.disconnect();
      const h = header.current?.offsetHeight ?? 64;
      hits = new Set<Element>();
      io = new IntersectionObserver(
        (entries) => {
          for (const e of entries) {
            if (e.isIntersecting) hits.add(e.target);
            else hits.delete(e.target);
          }
          update();
        },
        { rootMargin: `0px 0px ${-Math.max(0, innerHeight - h)}px 0px` },
      );
      const wide = innerWidth * 0.9;
      for (const el of document.querySelectorAll('#main .silicon, .colophon')) {
        if (el.getBoundingClientRect().width >= wide && !el.parentElement?.closest('#main .silicon')) io.observe(el);
      }
    };
    const later = (): void => {
      clearTimeout(timer);
      timer = window.setTimeout(scan, 120);
    };
    scan();
    // New nodes mean a new scan; a cover coming or going only means a new answer.
    const mo = new MutationObserver((records) => (records.some((r) => r.type === 'childList') ? later() : update()));
    const main = document.getElementById('main');
    if (main) mo.observe(main, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-cover'] });
    addEventListener('resize', later);
    return () => {
      clearTimeout(timer);
      io?.disconnect();
      mo.disconnect();
      removeEventListener('resize', later);
    };
  }, [routeKey]);
  return over;
}

function Header({ route, routeKey }: { route: Route; routeKey: string }) {
  const header = useRef<HTMLElement>(null);
  const over = useOverSilicon(header, routeKey);
  const links = navLinks(route);
  const [open, setOpen] = useState(false);
  const [Sheet, setSheet] = useState<SheetComponent | null>(null);
  const menuBtn = useRef<HTMLButtonElement>(null);
  // The route the sheet was opened on: closed by following a link, it leaves the focus on the new page (router.ts
  // puts it on <main>); closed any other way, the focus goes back to the Menu button.
  const openedOn = useRef(routeKey);
  const latest = useRef(routeKey);
  latest.current = routeKey;
  // The sheet's code arrives the first time the button is pointed at, focused or pressed.
  const fetchSheet = (): Promise<void> =>
    Sheet
      ? Promise.resolve()
      : loadSheet().then((m) => {
          setSheet(() => m.MenuSheet);
        });
  return (
    <>
      <button type="button" class="skip" onClick={() => document.getElementById('main')?.focus()}>
        Skip to content
      </button>
      <header ref={header} class={`top ${over ? 'silicon is-over' : 'paper'}`}>
        <div class="top__in">
          <a class="brand" href="#/" aria-label="Covenant, home">
            <Bond size={26} />
            <Wordmark height={20} />
          </a>
          <nav class="nav" aria-label="Main">
            {links.map((l) => (
              <a key={l.href} href={l.href} aria-current={l.current ? 'page' : undefined}>
                {l.text}
              </a>
            ))}
          </nav>
          <button
            ref={menuBtn}
            type="button"
            class="menu-btn"
            aria-haspopup="dialog"
            aria-expanded={open}
            onPointerEnter={() => void fetchSheet().catch(() => {})}
            onFocus={() => void fetchSheet().catch(() => {})}
            onClick={() => {
              openedOn.current = routeKey;
              setOpen(true);
              // If the sheet cannot be loaded, the button simply does nothing; the links are also in the footer.
              fetchSheet().catch(() => setOpen(false));
            }}
          >
            Menu
            <Icon name="menu" size={22} />
          </button>
        </div>
      </header>
      {Sheet && (
        <Sheet
          open={open}
          links={links}
          routeKey={routeKey}
          onClosed={() => {
            setOpen(false);
            if (latest.current === openedOn.current) menuBtn.current?.focus();
            else document.getElementById('main')?.focus({ preventScroll: true });
          }}
        />
      )}
    </>
  );
}

/** Runs `f` when the browser is idle (or soon, where it cannot say). */
const whenIdle = (f: () => void): void => {
  if (typeof requestIdleCallback === 'function') requestIdleCallback(f, { timeout: 2000 });
  else setTimeout(f, 200);
};

/**
 * The colophon, on silicon: the flagship kernel's live Seal (its chip's 64 latches, read with one eth_call once the
 * footer comes near the screen and the browser is idle; the cold seal until then or if the read fails), the honesty
 * line, where the copy stored on X Layer lives, the font credits, the source and the demo film (a GitHub release).
 */
function Colophon({ links }: { links: NavLink[] }) {
  const foot = useRef<HTMLElement>(null);
  const [state, setState] = useState<{ hex: string; mode: string } | null | 'failed'>(null);
  useEffect(() => {
    const el = foot.current;
    if (!COVENANT.kernel || !el) return;
    let live = true;
    const ask = (): void =>
      whenIdle(() => {
        loadFlagship()
          .then((m) => m.readFlagshipState())
          .then(
            (s) => live && s && setState(s),
            () => live && setState('failed'),
          );
      });
    if (typeof IntersectionObserver !== 'function') {
      ask();
      return () => {
        live = false;
      };
    }
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting)) return;
        io.disconnect();
        ask();
      },
      { rootMargin: '400px 0px' },
    );
    io.observe(el);
    return () => {
      live = false;
      io.disconnect();
    };
  }, []);

  const hosts = ADDR.rpc.map((u) => new URL(u).host).join(', ');
  const s = state === 'failed' ? null : state;
  return (
    <footer ref={foot} class="colophon silicon">
      <div class="colophon__in">
        <a class="colophon__lock" href="#/" aria-label="Covenant, home">
          <Bond size={56} />
          <Wordmark height={44} />
        </a>
        <div class="colophon__text">
          <p>
            {SIMULATION ? `SIMULATION: reads a local fork at ${SIMULATION.rpc}` : `Reads ${CHAIN.name} (chain ${CHAIN.id}) through ${hosts}`}. No wallet, no cookies, no
            analytics. <strong>Unaudited. Adoption is zero.</strong>
          </p>
          <p>
            A copy of this site is stored on {CHAIN.name} at <a href={MIRROR}>1-2-283.tapekit.org</a>. Circuits run on TapeOut (MIT); netlist semantics per
            TAP-02 (formerly TAP-20). Source: <a href={REPO}>github.com/OoJae/covenant</a>.{' '}
            <a href={`${REPO}/releases/tag/demo-2026-10-08`}>Demo film, 2 min 20 s</a>.
          </p>
          <p class="muted">
            Set in Bodoni Moda, Instrument Sans and Fragment Mono, by their project authors, under the SIL Open Font License 1.1; self-hosted as subsets.
          </p>
        </div>
        {COVENANT.kernel && (
          <figure class="colophon__seal">
            <Seal hex={s ? s.hex : COLD} size={88} press={!!s} label={s ? 'The flagship kernel’s chip state, read now' : 'The cold seal'} />
            {/* A new reading is new lines in a box that stays put (components.css), not the old lines rewritten. */}
            <figcaption class="micro">
              {s ? (
                <span key="read">
                  Kernel v1 · read now
                  <br />
                  {s.mode} · {s.hex}
                </span>
              ) : (
                <span key={String(state)}>
                  {state === 'failed' ? 'Could not read kernel v1.' : 'Kernel v1 · not read yet'}
                  <br />
                  The cold seal: every latch 0.
                </span>
              )}
            </figcaption>
          </figure>
        )}
      </div>
      <nav class="colophon__nav" aria-label="Pages">
        {links.map((l) => (
          <a key={l.href} href={l.href} aria-current={l.current ? 'page' : undefined}>
            {l.text}
          </a>
        ))}
      </nav>
      <div class="colophon__base micro">
        <span>
          Covenant · read-only · {CHAIN.name} {CHAIN.id}
        </span>
        <span>Your token's tax, routed by a chip anyone can read and nobody can change.</span>
      </div>
    </footer>
  );
}

const keyOf = (r: Route): string => JSON.stringify(r);

export function App() {
  const route = useRoute();
  const routeKey = keyOf(route);
  useEffect(() => {
    document.title = titleFor(route);
  }, [routeKey]);
  // Fetch the on-demand scripts in the background once the first page is up.
  useEffect(() => {
    const t = setTimeout(() => {
      void loadKernelPages().catch(() => {});
      void loadGuides().catch(() => {});
      void loadBench().catch(() => {});
      void loadProcessor().catch(() => {});
    }, 1200);
    return () => clearTimeout(t);
  }, []);
  // Without view transitions the keyed <main> rises on mount from the first route change on: router.ts sets the
  // class on <html> that motion.css keys the rise to (src/motion/transitions.ts routeEnter), so the first page keeps
  // its own entrance.
  const links = navLinks(route);
  return (
    <>
      <Header route={route} routeKey={routeKey} />
      <main id="main" tabIndex={-1} class="route" key={routeKey} data-page={route.page}>
        {route.page === 'landing' && <Landing />}
        {route.page === 'processor' && <ProcessorPage address={route.processor} />}
        {route.page === 'circuit' && <CircuitPage processor={route.processor} id={route.id} />}
        {route.page === 'vault' && <KernelPage page="vault" kernel={route.kernel} />}
        {route.page === 'audit' && <KernelPage page="audit" kernel={route.kernel} n={route.n} />}
        {route.page === 'hostile' && <KernelPage page="hostile" />}
        {route.page === 'judge' && <GuidePage page="judge" />}
        {route.page === 'trust' && <GuidePage page="trust" />}
        {route.page === 'notfound' && <NotFoundPage hash={route.hash} />}
      </main>
      <Colophon links={links} />
    </>
  );
}
