import { useEffect } from 'preact/hooks';
import { ADDR, CHAIN } from './config.ts';
import { useAsync, useRoute } from './router.ts';
import { Judge } from './routes/Judge.tsx';
import { Landing } from './routes/Landing.tsx';
import { Processor } from './routes/Processor.tsx';
import { Failure, Loading } from './routes/shared.tsx';
import { Trust } from './routes/Trust.tsx';

// The circuit bench (netlist parser, simulator, die-shot renderer) is the heaviest part of the
// site and is loaded on demand, which keeps index.html plus its entry script well under the
// 96 KB budget. The browser caches the promise, so asking twice costs nothing.
const loadBench = () => import('./routes/Circuit.tsx');

function CircuitPage(props: { processor: string; id: string }) {
  const q = useAsync(loadBench, []);
  if (q.loading) return <Loading what="the circuit bench" />;
  if (q.error || !q.data) return <Failure error={q.error} retry={q.reload} />;
  const Bench = q.data.Circuit;
  return <Bench {...props} />;
}

export function App() {
  const route = useRoute();
  // Fetch the bench in the background once the first page is up, so opening a circuit is instant.
  useEffect(() => {
    const t = setTimeout(() => void loadBench().catch(() => {}), 1200);
    return () => clearTimeout(t);
  }, []);
  return (
    <>
      <header>
        <a class="brand" href="#/">
          Covenant
        </a>
        <nav>
          <a href="#/judge" aria-current={route.page === 'judge' ? 'page' : undefined}>
            Judge guide
          </a>
          <a href="#/trust" aria-current={route.page === 'trust' ? 'page' : undefined}>
            Trust model
          </a>
        </nav>
      </header>
      <main>
        {route.page === 'landing' && <Landing />}
        {route.page === 'processor' && <Processor address={route.processor} />}
        {route.page === 'circuit' && <CircuitPage processor={route.processor} id={route.id} />}
        {route.page === 'judge' && <Judge />}
        {route.page === 'trust' && <Trust />}
        {route.page === 'notfound' && (
          <article>
            <h1>Nothing at this address</h1>
            <p>
              <span class="mono">{route.hash}</span> is not a page. A processor is <span class="mono">#/p/0x…</span> and a circuit is{' '}
              <span class="mono">#/c/0x…/id</span>.
            </p>
            <p>
              <a href="#/">Back to the start</a>
            </p>
          </article>
        )}
      </main>
      <footer>
        Reads {CHAIN.name} (chain {CHAIN.id}) through {ADDR.rpc.map((u) => new URL(u).host).join(', ')}. No wallet, no cookies, no
        analytics.
      </footer>
    </>
  );
}
