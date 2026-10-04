// Error taxonomy. The scheduler branches on these classes, so every failure that reaches it is one of them.

/** Bad environment or flags. The process exits with code 2 and does not retry. */
export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

/**
 * The node executed the call and the call failed: revert, out of gas, bad opcode.
 * Deterministic for the current chain state, so there is no point asking another RPC.
 */
export class RevertError extends Error {
  readonly reason: string;
  readonly data: string | null;
  constructor(reason: string, data: string | null = null) {
    super(`execution reverted: ${reason}`);
    this.name = 'RevertError';
    this.reason = reason;
    this.data = data;
  }
}

/** Transport failure, timeout, rate limit or a node-side fault. The pool switches RPC and backs off. */
export class RpcError extends Error {
  readonly host: string;
  readonly method: string;
  constructor(host: string, method: string, detail: string) {
    super(`${method} via ${host}: ${detail}`);
    this.name = 'RpcError';
    this.host = host;
    this.method = method;
  }
}

/** Every configured RPC failed for several rounds in a row. */
export class RpcUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RpcUnavailableError';
  }
}

/** The node refused the transaction because the wallet cannot pay for it. */
export class InsufficientFundsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InsufficientFundsError';
  }
}

/** The nonce was already used. Either our own transaction was mined, or another instance got there first. */
export class NonceTooLowError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NonceTooLowError';
  }
}

/** A replacement was priced below what the node requires to evict the pending transaction. */
export class UnderpricedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UnderpricedError';
  }
}

/** The node refused the signed transaction for a reason another RPC would share (malformed, fee below base fee). */
export class TxRejectedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TxRejectedError';
  }
}

/** The transaction about to be signed is not a plain settle call. This is a bug: the process stops. */
export class GuardError extends Error {
  constructor(message: string) {
    super(`refusing to sign: ${message}`);
    this.name = 'GuardError';
  }
}
