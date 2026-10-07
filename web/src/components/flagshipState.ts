// The footer's live Seal: the flagship kernel's state() (its chip's 64 latches), read with one eth_call and named
// by its MODE field. Loaded on demand by the colophon (src/app.tsx) once the footer is near the screen and the
// browser is idle, so the entry script carries neither the kernel read surface nor the chip's field map for it.

import { read } from '@covenant/chain';
import { kernel } from '@covenant/chain/kernel';
import { COVENANT, rpc } from '../config.ts';
import { fgModeName, fgState } from '../kernel/chip.ts';

/** The state's 8 bytes as hex and the Flow Governor mode they hold; null when no flagship kernel is recorded. */
export async function readFlagshipState(): Promise<{ hex: string; mode: string } | null> {
  if (!COVENANT.kernel) return null;
  // state() is a bytes32 with the state string first: the Flow Governor's 64 latches are its first 8 bytes.
  const hex = (await read(rpc, kernel(COVENANT.kernel).state())).slice(0, 18);
  const mode = fgState(hex).find((f) => f.name === 'MODE')?.value ?? 0;
  return { hex, mode: fgModeName(mode) };
}
