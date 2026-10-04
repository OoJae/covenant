// The only place the private key is used. It goes into viem's account and nowhere else.

import { privateKeyToAccount } from 'viem/accounts';
import type { Hex } from 'viem';
import { ConfigError } from './errors.ts';
import type { Signer } from './keeper.ts';

export function signerFromKey(key: Hex): Signer {
  try {
    const account = privateKeyToAccount(key);
    return { address: account.address, signTransaction: (tx) => account.signTransaction(tx) };
  } catch {
    // Deliberately not forwarding the library's message: nothing here may be able to echo the key.
    throw new ConfigError('KEEPER_PRIVATE_KEY is not a valid secp256k1 private key');
  }
}
