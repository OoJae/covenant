import { useEffect } from 'preact/hooks';
import { ADDR, CHAIN, COVENANT, SIMULATION } from './config.ts';
import { useAsync, useRoute } from './router.ts';
import { Landing } from './routes/Landing.tsx';
import { Processor } from './routes/Processor.tsx';
import { Failure, Loading } from './routes/shared.tsx';
import { ThemeToggle } from './theme.tsx';

// Everything but the landing page loads on demand, which keeps index.html plus its entry script under the 96 KB
// budget: the circuit bench (netlist parser, simulator, die-shot renderer), the kernel pages (the same, plus the
// Flow Governor's netlist), and the two text-heavy guides. The browser caches each promise, so asking twice costs nothing.
const loadBench = () => import('./routes/Circuit.tsx');
const loadKernelPages = () => import('./routes/kernelPages.tsx');
const loadGuides = () => import('./routes/guidePages.tsx');

function GuidePage({ page }: { page: 'judge' | 'trust' }) {
  const q = useAsync(loadGuides, []);
  if (q.loading) return <Loading what={page === 'judge' ? 'the judge guide' : 'the trust model'} />;
  if (q.error || !q.data) return <Failure error={q.error} retry={q.reload} />;
  return page === 'judge' ? <q.data.Judge /> : <q.data.Trust />;
}

function CircuitPage(props: { processor: string; id: string }) {
  const q = useAsync(loadBench, []);
  if (q.loading) return <Loading what="the circuit bench" />;
  if (q.error || !q.data) return <Failure error={q.error} retry={q.reload} />;
  const Bench = q.data.Circuit;
  return <Bench {...props} />;
}

function KernelPage(props: { page: 'vault' | 'audit' | 'hostile'; kernel?: string; n?: number }) {
  const q = useAsync(loadKernelPages, []);
  if (q.loading) return <Loading what="the kernel pages" />;
  if (q.error || !q.data) return <Failure error={q.error} retry={q.reload} />;
  const { Vault, Audit, Hostile } = q.data;
  if (props.page === 'vault') return <Vault kernel={props.kernel!} />;
  if (props.page === 'audit') return <Audit kernel={props.kernel!} n={props.n!} />;
  return <Hostile />;
}

export function App() {
  const route = useRoute();
  // Fetch the on-demand scripts in the background once the first page is up.
  useEffect(() => {
    const t = setTimeout(() => {
      void loadKernelPages().catch(() => {});
      void loadGuides().catch(() => {});
      void loadBench().catch(() => {});
    }, 1200);
    return () => clearTimeout(t);
  }, []);
  const here = (p: string): 'page' | undefined => (route.page === p ? 'page' : undefined);
  return (
    <>
      <header class="top">
        <a class="brand" href="#/" aria-label="Covenant, home">
          <svg viewBox="0 0 20 20" width="20" height="20" aria-hidden="true">
            <rect x="4" y="4" width="12" height="12" rx="1.5" class="pkg" />
            <path d="M7 1v3M10 1v3M13 1v3M7 16v3M10 16v3M13 16v3M1 7h3M1 10h3M1 13h3M16 7h3M16 10h3M16 13h3" class="pins" />
            <rect x="7" y="7" width="3" height="3" class="g1" />
            <rect x="10" y="10" width="3" height="3" class="g2" />
          </svg>
          Covenant
        </a>
        <nav>
          {COVENANT.kernel && (
            <a href={`#/k/${COVENANT.kernel}`} aria-current={route.page === 'vault' || route.page === 'audit' ? 'page' : undefined}>
              Vault
            </a>
          )}
          <a href="#/hostile" aria-current={here('hostile')}>
            Hostile chip
          </a>
          <a href="#/judge" aria-current={here('judge')}>
            Judge guide
          </a>
          <a href="#/trust" aria-current={here('trust')}>
            Trust
          </a>
          <ThemeToggle />
        </nav>
      </header>
      <main>
        {route.page === 'landing' && <Landing />}
        {route.page === 'processor' && <Processor address={route.processor} />}
        {route.page === 'circuit' && <CircuitPage processor={route.processor} id={route.id} />}
        {route.page === 'vault' && <KernelPage page="vault" kernel={route.kernel} />}
        {route.page === 'audit' && <KernelPage page="audit" kernel={route.kernel} n={route.n} />}
        {route.page === 'hostile' && <KernelPage page="hostile" />}
        {route.page === 'judge' && <GuidePage page="judge" />}
        {route.page === 'trust' && <GuidePage page="trust" />}
        {route.page === 'notfound' && (
          <article>
            <h1>Nothing at this address</h1>
            <p>
              <span class="mono">{route.hash}</span> is not a page. A processor is <span class="mono">#/p/0x…</span>, a circuit{' '}
              <span class="mono">#/c/0x…/id</span>, a kernel <span class="mono">#/k/0x…</span> and one of its settles{' '}
              <span class="mono">#/k/0x…/n</span>.
            </p>
            <p>
              <a href="#/">Back to the start</a>
            </p>
          </article>
        )}
      </main>
      <footer>
        {SIMULATION ? 'SIMULATION: reads a local fork at ' + SIMULATION.rpc : `Reads ${CHAIN.name} (chain ${CHAIN.id}) through ${ADDR.rpc.map((u) => new URL(u).host).join(', ')}`}. No
        wallet, no cookies, no analytics. Unaudited. Circuits run on TapeOut (MIT); netlist semantics per TAP-20.
      </footer>
    </>
  );
}
