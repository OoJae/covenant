// The judge guide and the trust model, loaded together on demand (see app.tsx), with the inner pages' styles
// (styles/pages.ts).
import { pageStyles } from '../styles/pages.ts';

pageStyles();

export { Judge } from './Judge.tsx';
export { Trust } from './Trust.tsx';
