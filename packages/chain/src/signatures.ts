// Every function this package calls: Solidity signature and 4-byte selector.
// Reference data for tests and for printing `cast call` lines; it is not part of the main
// entry, so it costs nothing in a bundle that does not import it.
// test/abi.test.ts checks each selector against keccak256(signature) and against the
// calldata the builders in tapeout.ts actually produce.

export const SIGNATURES = {
  // processor factory
  cpuCount: ['cpuCount()', 'a94da8a7'],
  cpuAt: ['cpuAt(uint256)', '4bc7cbbd'],
  isCPU: ['isCPU(address)', '5f5a364f'],
  // processor (ERC-721 "Circuits")
  name: ['name()', '06fdde03'],
  symbol: ['symbol()', '95d89b41'],
  nextId: ['nextId()', '61b8ce8c'],
  ownerOf: ['ownerOf(uint256)', '6352211e'],
  circuitInfo: ['circuitInfo(uint256)', '084d60f1'],
  netlist: ['netlist(uint256)', '3fc4be56'],
  eval: ['eval(uint256,bytes)', '934d06ea'],
  step: ['step(uint256,bytes,bytes)', 'e8281a1a'],
  transistors: ['transistors()', '6fbd1719'],
  // transistors (ERC-1155)
  supplyCap: ['supplyCap()', '8f770ad0'],
  mintPrice: ['mintPrice()', '6817c76c'],
  minted: ['minted()', '4f02c420'],
  story: ['story()', '46c922d1'],
  cpuName: ['cpuName()', '700ed104'],
  cpuSymbol: ['cpuSymbol()', '91254d67'],
  creator: ['creator()', '02d05d3f'],
  // Multicall3
  aggregate3: ['aggregate3((address,bool,bytes)[])', '82ad56cb'],
  getBlockNumber: ['getBlockNumber()', '42cbb15c'],
} as const satisfies Record<string, readonly [signature: string, selector: string]>;

export type FunctionName = keyof typeof SIGNATURES;
