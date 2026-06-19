import { scryptSync, timingSafeEqual } from 'crypto';

// Verifies a password against a stored "scrypt$<saltHex>$<hashHex>" value —
// the same format the auth Lambda writes.
export function verifyPassword(password: string, stored: string): boolean {
  const [scheme, saltHex, hashHex] = (stored ?? '').split('$');
  if (scheme !== 'scrypt' || !saltHex || !hashHex) return false;
  const dk = scryptSync(password, Buffer.from(saltHex, 'hex'), 64);
  const want = Buffer.from(hashHex, 'hex');
  return dk.length === want.length && timingSafeEqual(dk, want);
}
