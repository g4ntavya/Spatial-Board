import { createHash } from 'crypto';

// Must match uuidFrom('user', email) in infra/lambdas/ingest/index.mjs so that
// the same Google account on iOS and web maps to the same user row.
export function userIdFromEmail(email: string): string {
  const h = createHash('sha1').update('user|' + email.toLowerCase()).digest('hex');
  const y = ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${y}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
