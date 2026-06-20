import NextAuth from 'next-auth';
import Credentials from 'next-auth/providers/credentials';
import { query, str } from './db';
import { verifyPassword } from './password';
import { userIdFromEmail } from './identity';

// Our own email/password auth (no third party). Passwords live in Aurora,
// scrypt-hashed by the auth Lambda; this verifies them on sign-in.
const THIRTY_DAYS = 60 * 60 * 24 * 30;

export const { handlers, auth, signIn, signOut } = NextAuth({
  trustHost: true,
  // Persistent login: the JWT session cookie survives browser restarts for 30 days
  // and its lifetime is refreshed each day the user is active.
  session: { strategy: 'jwt', maxAge: THIRTY_DAYS, updateAge: 60 * 60 * 24 },
  jwt: { maxAge: THIRTY_DAYS },
  providers: [
    Credentials({
      credentials: { email: {}, password: {} },
      authorize: async (creds) => {
        const email = String(creds?.email ?? '').trim().toLowerCase();
        const password = String(creds?.password ?? '');
        if (!email || !password) return null;
        const uid = userIdFromEmail(email);
        const rows = await query(`SELECT password_hash FROM users WHERE id = :id::uuid`, [str('id', uid)]);
        const ph = rows[0]?.password_hash as string | undefined;
        if (!ph || !verifyPassword(password, ph)) return null;
        return { id: uid, email };
      },
    }),
  ],
});
