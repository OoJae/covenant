// @covenant/dieshot: a deterministic floorplan of a TAP-20 netlist and a Canvas 2D renderer
// that animates one beat on it. No dependencies.

export {
  layout,
  decodeBlockMap,
  KIND_CONST,
  KIND_INPUT,
  KIND_NAND,
  KIND_LATCH,
  KIND_REF,
  ASPECT_COLS,
  ASPECT_ROWS,
} from './layout.ts';
export type { DieNetlist, BlockMap, Block, Layout } from './layout.ts';

export { createDieShot, THEME_DARK, THEME_LIGHT } from './render.ts';
export type { DieShot, DieShotOptions, Picked, Theme } from './render.ts';

export { sha256, sha256Hex } from './sha256.ts';
