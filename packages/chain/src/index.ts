// @covenant/chain: read-only access to the TapeOut contracts on X Layer over plain JSON-RPC.
// No viem, ethers or wagmi.
//
//   '@covenant/chain'         RPC client, ABI codec, TapeOut call descriptors, Multicall3 reader
//   '@covenant/chain/keccak'  keccak256 and the EIP-55 checksum
// src/signatures.ts lists every signature and selector used (reference data, checked by the tests).

export { createRpc, RpcError, isRevert } from './rpc.ts';
export type { Rpc, RpcOptions, RpcRequest, RpcErrorBody } from './rpc.ts';

export {
  strip,
  word,
  addressWord,
  bytesTail,
  toBytes,
  toHex,
  decUint,
  decBool,
  decAddress,
  decBytes,
  decString,
  decCircuitInfo,
  decStep,
  encAggregate3,
  decAggregate3,
  revertReason,
} from './abi.ts';
export type { CircuitInfo, StepResult, SubResult } from './abi.ts';

export { MULTICALL3, factory, processor, transistors, blockNumber, read, readAll, CallError } from './tapeout.ts';
export type { Call, ReadAllOptions } from './tapeout.ts';
