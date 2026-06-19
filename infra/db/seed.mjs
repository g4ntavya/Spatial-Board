// Seeds a demo account + sample notes so the web app has something to show.
// Notes get real Titan embeddings (semantic search works) and an SVG so they
// render. Run: CLUSTER_ARN=... SECRET_ARN=... DB_NAME=spatialboard node seed.mjs

import { RDSDataClient, ExecuteStatementCommand } from '@aws-sdk/client-rds-data';
import { BedrockRuntimeClient, InvokeModelCommand } from '@aws-sdk/client-bedrock-runtime';
import { scryptSync, randomBytes, randomUUID, createHash } from 'crypto';

const rds = new RDSDataClient({ region: process.env.AWS_REGION ?? 'us-east-1' });
const bedrock = new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? 'us-east-1' });
const { CLUSTER_ARN, SECRET_ARN, DB_NAME = 'spatialboard' } = process.env;

const DEMO_EMAIL = 'demo@spatialboard.app';
const DEMO_PASSWORD = 'spatial-demo-2026';

const exec = (sql, parameters = []) =>
  rds.send(new ExecuteStatementCommand({ resourceArn: CLUSTER_ARN, secretArn: SECRET_ARN, database: DB_NAME, sql, parameters }));

const uuidP = (name, v) => ({ name, value: { stringValue: v }, typeHint: 'UUID' });
const strP = (name, v) => ({ name, value: { stringValue: v } });

function uuidFrom(...parts) {
  const h = createHash('sha1').update(parts.join('|')).digest('hex');
  const y = ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${y}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
const hashPassword = (pw) => {
  const salt = randomBytes(16);
  return `scrypt$${salt.toString('hex')}$${scryptSync(pw, salt, 64).toString('hex')}`;
};
const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

// Theme-aware "handwriting" SVG: no background, ink uses currentColor so it
// adapts to light/dark on the web. (Real synced notes render your actual AR
// strokes; these seeded samples use a handwriting font as a stand-in.)
function svgNote(title, lines) {
  const h = 116 + lines.length * 50 + 24;
  const rows = lines
    .map((l, i) => `<text x="46" y="${132 + i * 50}" font-family="Caveat, cursive" font-size="34" fill="currentColor">${esc(l)}</text>`)
    .join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 860 ${h}" width="860" height="${h}"><text x="46" y="66" font-family="Caveat, cursive" font-size="46" fill="currentColor">${esc(title)}</text><line x1="46" y1="84" x2="320" y2="84" stroke="#e0a93b" stroke-width="3"/>${rows}</svg>`;
}

async function embed(text) {
  const r = await bedrock.send(
    new InvokeModelCommand({
      modelId: 'amazon.titan-embed-text-v2:0',
      contentType: 'application/json',
      accept: 'application/json',
      body: JSON.stringify({ inputText: text.slice(0, 8000) }),
    }),
  );
  return JSON.parse(Buffer.from(r.body).toString()).embedding;
}

const samples = [
  { title: 'Integration by parts', category: 'Math', lines: ['∫ u dv = uv − ∫ v du', 'ex: ∫ x·eˣ dx = x·eˣ − eˣ + C', 'pick u = x (it simplifies)'] },
  { title: 'Grocery run', category: 'To-do', lines: ['milk · eggs · coffee beans', 'spinach, olive oil, lemons', 'paper towels'] },
  { title: 'App idea — spatial reminders', category: 'Idea', lines: ['pin notes to real places', 'AR glasses notify on proximity', 'sync across devices'] },
  { title: 'Standup notes', category: 'Notes', lines: ['shipped iOS → AWS sync', 'debugging handwriting OCR', 'demo on Friday'] },
];

async function main() {
  if (!CLUSTER_ARN || !SECRET_ARN) {
    console.error('Set CLUSTER_ARN and SECRET_ARN');
    process.exit(1);
  }
  const userId = uuidFrom('user', DEMO_EMAIL);
  const spaceId = uuidFrom('space', userId, 'Default');

  console.log('Creating demo user…');
  await exec(
    `INSERT INTO users (id, email, password_hash) VALUES (:id,:email,:ph)
     ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash`,
    [uuidP('id', userId), strP('email', DEMO_EMAIL), strP('ph', hashPassword(DEMO_PASSWORD))],
  );

  await exec(
    `INSERT INTO spaces (id, user_id, name, color_hex) VALUES (:id,:uid,:name,:c)
     ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name`,
    [uuidP('id', spaceId), uuidP('uid', userId), strP('name', 'My Notes'), strP('c', '#E0A93B')],
  );

  // Clean re-seed: clear any existing notes in this space first.
  await exec(`DELETE FROM notes WHERE space_id = :sid`, [uuidP('sid', spaceId)]);

  for (const s of samples) {
    const noteId = randomUUID();
    const text = s.lines.join('. ');
    const search = `${s.title}. ${text}`;
    const vector = await embed(search);
    const svg = svgNote(s.title, s.lines);
    await exec(
      `INSERT INTO notes (id, space_id, title, ocr_text, category, svg, search_vector, embedding, status, world_origin)
       VALUES (:id,:sid,:title,:ocr,:cat,:svg, to_tsvector('english', :search), (:emb)::vector, 'processed', '{}'::jsonb)
       ON CONFLICT (id) DO NOTHING`,
      [
        uuidP('id', noteId),
        uuidP('sid', spaceId),
        strP('title', s.title),
        strP('ocr', text),
        strP('cat', s.category),
        strP('svg', svg),
        strP('search', search),
        strP('emb', `[${vector.join(',')}]`),
      ],
    );
    console.log('  + note:', s.title);
  }

  console.log('\nDone. Demo credentials:');
  console.log('  email:   ', DEMO_EMAIL);
  console.log('  password:', DEMO_PASSWORD);
}

main().catch((e) => { console.error(e); process.exit(1); });
