// Checks on contract code that a browser can do with eth_getCode alone.
//
// A Covenant kernel is an OpenZeppelin clone with immutable arguments: the 45-byte ERC-1167 proxy, which forwards
// every call to one fixed implementation, followed by abi.encode(Globals, Envelope). The proxy has no way to change
// the address it forwards to, and the arguments are code, not storage. So "the envelope cannot change" and "the
// code cannot be upgraded" are properties of the bytes, which this module reads.

const CLONE_HEAD = '363d3d373d3d3d363d73';
const CLONE_TAIL = '5af43d82803e903d91602b57fd5bf3';

export interface CloneCheck {
  /** The code is exactly the ERC-1167 proxy followed by arguments. */
  isClone: boolean;
  /** The implementation the proxy forwards to (lower case), if it is a clone. */
  implementation: string | null;
  /** The immutable arguments appended to the proxy, as 0x hex. */
  args: string;
}

export function cloneOf(code: string): CloneCheck {
  const h = code.replace(/^0x/i, '').toLowerCase();
  if (!h.startsWith(CLONE_HEAD) || h.slice(60, 90) !== CLONE_TAIL) return { isClone: false, implementation: null, args: '0x' };
  return { isClone: true, implementation: '0x' + h.slice(20, 60), args: '0x' + h.slice(90) };
}

/** Function selectors whose presence would mean an owner, an upgrade path, a pause, or a way to give tokens away. */
export const FORBIDDEN_SELECTORS: readonly { sel: string; sig: string }[] = [
  { sel: '8da5cb5b', sig: 'owner()' },
  { sel: 'f2fde38b', sig: 'transferOwnership(address)' },
  { sel: '715018a6', sig: 'renounceOwnership()' },
  { sel: '3659cfe6', sig: 'upgradeTo(address)' },
  { sel: '4f1ef286', sig: 'upgradeToAndCall(address,bytes)' },
  { sel: '8456cb59', sig: 'pause()' },
  { sel: '3f4ba83a', sig: 'unpause()' },
  { sel: '095ea7b3', sig: 'approve(address,uint256)' },
  { sel: '23b872dd', sig: 'transferFrom(address,address,uint256)' },
  { sel: '42842e0e', sig: 'safeTransferFrom(address,address,uint256)' },
  { sel: 'b88d4fde', sig: 'safeTransferFrom(address,address,uint256,bytes)' },
  { sel: 'a22cb465', sig: 'setApprovalForAll(address,bool)' },
];

export interface CodeScan {
  bytes: number;
  /** Opcodes found by walking the code (push data skipped, the trailing metadata excluded). */
  delegatecall: number;
  callcode: number;
  selfdestruct: number;
  /** Forbidden selectors whose 4 bytes occur anywhere in the code. */
  selectors: string[];
}

/**
 * Walks runtime code opcode by opcode. The Solidity metadata at the end (its length is the last two bytes) is not
 * code and is skipped. A selector is reported if its four bytes occur anywhere, data included: an absent selector
 * cannot be pushed as a constant, so the code can neither answer that function nor call it on another contract.
 */
export function scanCode(code: string): CodeScan {
  const h = code.replace(/^0x/i, '').toLowerCase();
  const n = h.length / 2;
  const byte = (i: number): number => parseInt(h.slice(2 * i, 2 * i + 2), 16);
  let end = n;
  if (n >= 2) {
    const meta = (byte(n - 2) << 8) | byte(n - 1);
    if (meta + 2 <= n && byte(n - 2 - meta) >= 0xa0 && byte(n - 2 - meta) <= 0xbf) end = n - 2 - meta; // a CBOR map
  }
  const out: CodeScan = { bytes: n, delegatecall: 0, callcode: 0, selfdestruct: 0, selectors: [] };
  for (let i = 0; i < end; i++) {
    const op = byte(i);
    if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
    else if (op === 0xf4) out.delegatecall++;
    else if (op === 0xf2) out.callcode++;
    else if (op === 0xff) out.selfdestruct++;
  }
  // byte-aligned occurrences only
  const has = (sel: string): boolean => {
    for (let i = h.indexOf(sel); i >= 0; i = h.indexOf(sel, i + 1)) if (i % 2 === 0) return true;
    return false;
  };
  for (const s of FORBIDDEN_SELECTORS) if (has(s.sel)) out.selectors.push(s.sig);
  return out;
}
