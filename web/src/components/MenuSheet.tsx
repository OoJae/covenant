// The menu below 768 px, loaded the first time the Menu button is pressed or pointed at (src/app.tsx), so the entry
// script does not carry it. A modal <dialog> on silicon: the focus stays inside, Esc closes it, and the button that
// opened it gets the focus back. It slides down with the reveal ease; the first time it opens, its links rise one
// after another (60 ms apart), and never again. Styles: src/styles/components.css (dialog.sheet).

import { useEffect, useRef } from 'preact/hooks';
import { CHAIN } from '../config.ts';
import { motionAllowed } from '../motion/prefs.ts';
import { Bond, Wordmark } from './Icon.tsx';

export interface NavLink {
  href: string;
  text: string;
  current: boolean;
}

export function MenuSheet({ open, links, routeKey, onClosed }: { open: boolean; links: NavLink[]; routeKey: string; onClosed: () => void }) {
  const dlg = useRef<HTMLDialogElement>(null);
  const opened = useRef(false);
  const closing = useRef(0);

  const close = (): void => {
    const d = dlg.current;
    if (!d?.open || closing.current) return;
    d.classList.remove('is-open');
    document.documentElement.classList.remove('sheet-open');
    closing.current = window.setTimeout(
      () => {
        closing.current = 0;
        d.close();
        onClosed();
      },
      motionAllowed() ? 260 : 0,
    );
  };

  useEffect(() => {
    const d = dlg.current;
    if (!d || !open || d.open) return;
    d.classList.toggle('is-first', !opened.current);
    opened.current = true;
    d.showModal();
    // The dialog itself takes the focus, not its first link: a tap must not ring the wordmark (Safari gives a link
    // focused this way :focus-visible). The next Tab reaches the wordmark, with its ring.
    d.focus();
    document.documentElement.classList.add('sheet-open');
    requestAnimationFrame(() => requestAnimationFrame(() => d.classList.add('is-open')));
  }, [open]);

  // A route change (a link in the sheet, or the back button) closes it. Not on mount: the sheet's code can arrive
  // after the button was pressed, and then it mounts already open.
  const shownRoute = useRef(routeKey);
  useEffect(() => {
    if (shownRoute.current === routeKey) return;
    shownRoute.current = routeKey;
    close();
  }, [routeKey]);
  useEffect(() => () => document.documentElement.classList.remove('sheet-open'), []);

  return (
    <dialog
      ref={dlg}
      class="sheet silicon"
      tabIndex={-1}
      aria-label="Menu"
      data-lenis-prevent
      onCancel={(e) => {
        e.preventDefault();
        close();
      }}
    >
      <div class="sheet__top">
        <a class="brand" href="#/" aria-label="Covenant, home" onClick={close}>
          <Bond size={26} />
          <Wordmark height={20} />
        </a>
        <button type="button" class="menu-btn" onClick={close}>
          Close
        </button>
      </div>
      <nav class="sheet__nav" aria-label="Main">
        {links.map((l, i) => (
          <a key={l.href} href={l.href} aria-current={l.current ? 'page' : undefined} style={{ '--i': i }} onClick={close}>
            <span>{l.text}</span>
          </a>
        ))}
      </nav>
      <p class="sheet__foot micro">
        Read-only · {CHAIN.name} {CHAIN.id} · no wallet
      </p>
    </dialog>
  );
}
