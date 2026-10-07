// TEMPORARY, Track 3 branch only. Track 1 owns this file: its all.ts imports tokens.css, fonts.css, base.css,
// components.css and pages.css, in that order, and replaces this one at merge. Until then the landing is built
// against the old stylesheet plus the brand tokens and fonts, and track1-stub.css stands in for the shared classes
// the landing uses (.btn, .label, .plate, .ledger, .register, .terminal, .tag, .mark, the clause heading).
// Delete track1-stub.css with this file.

import '../style.css';
import './tokens.css';
import './fonts.css';
import './track1-stub.css';
