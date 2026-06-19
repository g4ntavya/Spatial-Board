// Auth Lambda — our own email/password auth (no third party).
//   POST /signup  { email, password } -> { token, email }
//   POST /login   { email, password } -> { token, email }
// Passwords are scrypt-hashed in Aurora; sessions are HS256 JWTs we sign and
// the ingest Lambda verifies. Runtime-bundled @aws-sdk only; no npm install.

import { RDSDataClient, ExecuteStatementCommand } from '@aws-sdk/client-rds-data';
import { scryptSync, randomBytes, timingSafeEqual, createHmac, createHash } from 'crypto';

const rds = new RDSDataClient({});
const { CLUSTER_ARN, SECRET_ARN, DB_NAME, AUTH_JWT_SECRET } = process.env;

const exec = (sql, parameters = []) =>
  rds.send(new ExecuteStatementCommand({ resourceArn: CLUSTER_ARN, secretArn: SECRET_ARN, database: DB_NAME, sql, parameters }));

// userId = sha1("user|"+email) — identical to ingest + web/lib/identity.ts
function uuidFrom(...parts) {
  const h = createHash('sha1').update(parts.join('|')).digest('hex');
  const y = ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${y}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

const hashPassword = (pw) => {
  const salt = randomBytes(16);
  return `scrypt$${salt.toString('hex')}$${scryptSync(pw, salt, 64).toString('hex')}`;
};
const verifyPassword = (pw, stored) => {
  const [scheme, saltHex, hashHex] = (stored ?? '').split('$');
  if (scheme !== 'scrypt') return false;
  const dk = scryptSync(pw, Buffer.from(saltHex, 'hex'), 64);
  const want = Buffer.from(hashHex, 'hex');
  return dk.length === want.length && timingSafeEqual(dk, want);
};

const b64u = (s) => Buffer.from(s).toString('base64url');
function signJwt(email) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = b64u(JSON.stringify({ sub: email, email, iat: now, exp: now + 60 * 60 * 24 * 30 }));
  const sig = createHmac('sha256', AUTH_JWT_SECRET).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${sig}`;
}

const reply = (statusCode, body) => ({ statusCode, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });

export const handler = async (event) => {
  const path = event.requestContext?.http?.path ?? event.rawPath ?? '';
  let body;
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
    body = JSON.parse(raw ?? '{}');
  } catch {
    return reply(400, { error: 'invalid json' });
  }

  const email = String(body.email ?? '').trim().toLowerCase();
  const password = String(body.password ?? '');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply(400, { error: 'invalid email' });
  if (password.length < 8) return reply(400, { error: 'password must be at least 8 characters' });

  const userId = uuidFrom('user', email);

  if (path.endsWith('/signup')) {
    const existing = await exec(`SELECT password_hash FROM users WHERE id = :id`, [{ name: 'id', value: { stringValue: userId }, typeHint: 'UUID' }]);
    if ((existing.records ?? []).length && existing.records[0][0]?.stringValue) {
      return reply(409, { error: 'account already exists' });
    }
    await exec(
      `INSERT INTO users (id, email, password_hash) VALUES (:id, :email, :ph)
       ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash`,
      [
        { name: 'id', value: { stringValue: userId }, typeHint: 'UUID' },
        { name: 'email', value: { stringValue: email } },
        { name: 'ph', value: { stringValue: hashPassword(password) } },
      ],
    );
    return reply(200, { token: signJwt(email), email });
  }

  // default: /login
  const res = await exec(`SELECT password_hash FROM users WHERE id = :id`, [{ name: 'id', value: { stringValue: userId }, typeHint: 'UUID' }]);
  const stored = (res.records ?? [])[0]?.[0]?.stringValue;
  if (!stored || !verifyPassword(password, stored)) return reply(401, { error: 'invalid email or password' });
  return reply(200, { token: signJwt(email), email });
};
