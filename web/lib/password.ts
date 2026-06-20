import { scryptSync, timingSafeEqual, randomBytes } from 'crypto';

// Produces "scrypt$<saltHex>$<hashHex>" — identical format + params to the auth
// Lambda, so accounts created on web and iOS are interchangeable.
export function hashPassword(password: string): string {
  const salt = randomBytes(16);
  return `scrypt$${salt.toString('hex')}$${scryptSync(password, salt, 64).toString('hex')}`;
}

// Verifies a password against a stored "scrypt$<saltHex>$<hashHex>" value —
// the same format the auth Lambda writes.
export function verifyPassword(password: string, stored: string): boolean {
  const [scheme, saltHex, hashHex] = (stored ?? '').split('$');
  if (scheme !== 'scrypt' || !saltHex || !hashHex) return false;
  const dk = scryptSync(password, Buffer.from(saltHex, 'hex'), 64);
  const want = Buffer.from(hashHex, 'hex');
  return dk.length === want.length && timingSafeEqual(dk, want);
}
