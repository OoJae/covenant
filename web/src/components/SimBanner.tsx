// The banner a fork build shows on every page with chain data: nothing shown happened on X Layer. Its own module,
// so the landing's entry script can carry it without the rest of kit.tsx. Styles: src/styles/components.css.

import { SIMULATION } from '../config.ts';

export function SimBanner() {
  if (!SIMULATION) return null;
  return (
    <div class="plate warn silicon simbanner" role="note">
      <strong>SIMULATION</strong> This build reads a local anvil fork of X Layer (block {SIMULATION.block}) made by{' '}
      <span class="mono">web/scripts/fork-fixture.sh</span>. Nothing shown here happened on X Layer.
    </div>
  );
}
