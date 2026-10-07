// The brand's marks and icons, drawn inline so no font or file is needed (docs/brand/README.md).
//
// - Bond: the logomark, one Manhattan wire bent into a C and closed by two pads, on the 32-unit grid. The wire and
//   the top pad take the text colour; the bottom pad is the accent (data-bond-pad: it blinks once per route change,
//   src/styles/motion.css).
// - Wordmark: "Covenant" in Bodoni Moda Italic 500, the text cut (opsz 18), outlined by docs/brand/tools/make_marks.py
//   then rounded here to whole font units (0.04 px at 64 px tall) and written with relative commands: 3.7 KB
//   instead of 8.4 KB, the same outline to the unit (checked by replaying both paths).
// - Icon: the sprite of docs/brand/icons.svg on its 24 grid, 1.5 stroke, square caps, right angles only. Arrows are
//   wires that end in a pad. Decorative: every icon sits next to words that say the same thing.

export function Bond({ size = 28, class: cls }: { size?: number; class?: string }) {
  return (
    <svg class={cls ? `bond ${cls}` : 'bond'} viewBox="0 0 32 32" width={size} height={size} aria-hidden="true" focusable="false">
      <path d="M5 6h17v3H8v14h14v3H5zM20 3h9v9h-9z" fill="currentColor" />
      <rect data-bond-pad x="20" y="20" width="9" height="9" style={{ fill: 'var(--accent)' }} />
    </svg>
  );
}

const WORDMARK = 'm633 20q-158 0-276-64-118-65-183-184-66-119-66-282 0-205 70-388 69-182 191-322 122-140 280-220 158-80 335-80 121 0 214 50 93 50 142 148 49 97 36 240h-14q8-105-18-182-26-76-75-126-50-50-117-74-66-24-139-24-105 0-194 49-89 50-162 136-72 86-128 198-56 111-94 235-37 123-56 248-20 125-20 237 0 101 32 186 31 85 97 136 66 52 170 52 130 0 240-54 111-53 195-146 84-92 133-207h16q-46 123-135 222-89 100-210 158-121 58-264 58zm486-20-75-139q38-39 77-83 39-44 75-112l30-84h25l-110 418zm243-1082 7-71q-4-60-17-109-12-50-42-95l153-143h21l-97 418zm338 1102q-154 0-231-89-77-89-77-229 0-129 44-245 45-116 122-205 78-89 177-141 100-51 210-51 155 0 232 90 77 91 77 230 0 129-44 245-45 115-122 204-77 89-177 140-100 51-211 51zm-13-25q51 0 100-35 50-36 94-98 45-62 83-140 38-78 66-164 28-86 44-170 15-85 15-156 0-68-31-107-32-39-101-39-50 0-100 35-49 36-94 98-45 62-83 140-38 78-66 164-28 86-43 170-16 83-16 156 0 67 32 107 33 39 100 39zm1037 25q-96 0-153-34-57-33-75-97-18-63 3-151l136-568q2-9 4-20 1-10 1-17 0-16-9-25-9-9-27-9-34 0-66 19-31 18-61 54-30 36-58 89-28 53-55 124l-23-7q28-73 58-131 30-59 66-100 36-42 80-64 45-22 100-22 77 0 123 42 45 41 45 101 0 22-4 42-4 19-6 33l-107 459q-19 84-25 138-6 55 12 81 18 27 69 27 63 0 129-46 67-47 129-125 61-78 111-173 49-96 78-196 28-101 28-189 0-56-16-93-16-37-44-56-29-19-65-19v-23q36 0 66 16 29 16 46 45 17 28 17 67 0 53-38 90-39 36-91 36-58 0-92-35-34-35-34-93 0-52 36-90 36-38 90-38 44 0 78 22 34 23 53 66 19 43 19 105 0 91-30 195-30 105-82 206-53 100-120 183-68 83-143 132-76 49-153 49zm932 0q-100 0-167-41-68-41-103-113-35-72-35-166 0-117 44-231 43-114 120-206 78-93 182-148 104-55 225-55 118 0 183 56 65 56 65 138 0 79-54 142-53 62-144 106-91 43-204 69-114 26-236 34v-21q83-6 155-26 72-21 130-54 58-34 99-80 42-46 64-103 22-57 22-123 0-44-18-78-19-35-65-35-54 0-103 35-50 34-94 94-43 59-79 133-36 75-62 156-26 81-40 160-14 79-14 145 0 102 43 140 43 39 109 39 81 0 151-34 70-33 128-91 58-58 102-133l22 13q-41 74-102 138-61 63-142 101-81 39-182 39zm1322 0q-81 0-121-34-41-33-41-99 0-21 5-42 4-21 8-36l131-429q24-77 33-138 10-60-5-94-15-35-63-35-45 0-103 53-58 52-118 141-59 89-111 199-51 111-81 228h-18q21-81 57-173 36-91 84-180 48-88 105-161 57-73 120-116 62-43 126-43 86 0 132 41 45 41 54 109 10 68-15 150l-160 544q-3 9-4 19-2 10-2 18 0 16 8 26 8 11 27 11 73 0 131-70 59-70 121-225l23 8q-45 116-91 189-46 72-102 106-56 33-130 33zm-726-20 228-895h-137v-25h336l-235 920zm1407 20q-134 0-194-87-61-87-61-238 0-115 43-227 42-113 114-205 71-92 158-147 87-56 175-56 70 0 109 39 38 38 53 101 15 64 15 138 0 63-13 137-13 75-38 152-26 76-62 146-36 71-82 126-46 56-100 89-55 32-117 32zm47-51q53 0 104-40 50-40 94-107 44-67 77-150 33-83 51-170 19-86 19-164 0-68-12-121-12-52-39-82-27-29-73-29-49 0-98 44-48 45-92 119-44 74-78 163-34 89-54 179-19 90-19 166 0 96 32 144 33 48 88 48zm395 51q-75 0-111-39-35-40-35-103 0-17 1-31 1-14 3-24l28-148 48-153 28-169 66-273h197l-222 833q-4 15-4 31 0 16 9 27 9 11 29 11 45 0 85-29 40-29 81-95 40-65 83-174l24 8q-44 114-89 187-45 72-98 107-53 34-123 34zm1090 0q-81 0-121-34-41-33-41-99 0-21 5-42 4-21 8-36l131-429q24-77 33-138 10-60-5-94-15-35-63-35-45 0-103 53-58 52-118 141-59 89-111 199-51 111-81 228h-18q21-81 57-173 36-91 84-180 48-88 105-161 57-73 120-116 62-43 126-43 86 0 132 41 45 41 54 109 10 68-15 150l-160 544q-3 9-4 19-2 10-2 18 0 16 8 26 8 11 27 11 73 0 131-70 59-70 121-225l23 8q-45 116-91 189-46 72-102 106-56 33-130 33zm-726-20 228-895h-137v-25h336l-235 920zm1371 20q-66 0-107-20-41-20-60-52-18-32-18-67 0-18 5-48 6-30 14-60l241-893h188l-279 1018q-3 10-6 24-3 13-3 27 0 36 56 36 42 0 83-20 41-19 80-58 38-39 75-99 36-60 68-141l24 7q-44 111-97 189-52 77-117 117-65 40-147 40zm-179-915v-25h568v25z';

/** The outlined wordmark; `height` in CSS pixels, the width follows (about 5.27 times the height). */
export function Wordmark({ height = 22, class: cls }: { height?: number; class?: string }) {
  return (
    <svg
      class={cls ? `wordmark ${cls}` : 'wordmark'}
      viewBox="108 -1520 8118 1540"
      height={height}
      width={Math.round((height * 8118) / 1540)}
      aria-hidden="true"
      focusable="false"
    >
      <path d={WORDMARK} fill="currentColor" />
    </svg>
  );
}

export type IconName = 'arrow-right' | 'arrow-down' | 'external' | 'match' | 'differ' | 'chip' | 'clock' | 'lock' | 'menu';

// Per icon: the strokes (no fill) and the pads (filled), on the 24 grid.
const ICONS: Record<IconName, [string, string?]> = {
  'arrow-right': ['M3 12H16', 'M16 9.5h5v5h-5z'],
  'arrow-down': ['M12 3V16', 'M9.5 16h5v5h-5z'],
  external: ['M11 5H5V19H19V13M10 14H16.5V8', 'M14 3h5v5h-5z'],
  match: ['M4 4H20V20H4ZM8 10H16M8 14H16'],
  differ: ['M4 4H20V20H4ZM8 10H16M11 14H16', 'M7 12.5h3v3H7z'],
  chip: ['M7 7H17V17H7ZM10 7V3M14 7V3M10 21V17M14 21V17M3 10H7M3 14H7M17 10H21M17 14H21', 'M9 9h3v3H9z'],
  clock: ['M4 4H20V20H4ZM12 7V12H16'],
  lock: ['M5 11H19V20H5ZM8 11V5H16V11M12 14.5V16.5'],
  menu: ['M4 6H20M4 12H14M4 18H20', 'M15.5 9.5h5v5h-5z'],
};

export function Icon({ name, size = 20, class: cls }: { name: IconName; size?: number; class?: string }) {
  const [stroke, pad] = ICONS[name];
  // The arrow carries `wire-arrow` so it nudges forward on a pressable control's hover (src/styles/motion.css).
  const c = ['icon', name === 'arrow-right' && 'wire-arrow', cls].filter(Boolean).join(' ');
  return (
    <svg class={c} viewBox="0 0 24 24" width={size} height={size} aria-hidden="true" focusable="false">
      <path d={stroke} fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter" />
      {pad && <path d={pad} fill="currentColor" />}
    </svg>
  );
}
