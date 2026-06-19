// Applies schema.sql to Aurora over the RDS Data API (the cluster lives in
// private subnets, so psql from a laptop can't reach it — the Data API can).
//
// Usage (values come from `cdk deploy` outputs):
//   CLUSTER_ARN=... SECRET_ARN=... DB_NAME=spatialboard node apply.mjs

import { RDSDataClient, ExecuteStatementCommand } from '@aws-sdk/client-rds-data';
import { readFileSync } from 'fs';

const client = new RDSDataClient({ region: process.env.AWS_REGION ?? 'us-east-1' });
const { CLUSTER_ARN, SECRET_ARN, DB_NAME = 'spatialboard' } = process.env;

if (!CLUSTER_ARN || !SECRET_ARN) {
  console.error('Set CLUSTER_ARN and SECRET_ARN (from cdk deploy outputs).');
  process.exit(1);
}

const sql = readFileSync(new URL('./schema.sql', import.meta.url), 'utf8');
const statements = sql
  .replace(/^\s*--.*$/gm, '')
  .split(/;\s*$/m)
  .map((s) => s.trim())
  .filter(Boolean);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function run(statement, attempt = 1) {
  try {
    await client.send(
      new ExecuteStatementCommand({ resourceArn: CLUSTER_ARN, secretArn: SECRET_ARN, database: DB_NAME, sql: statement }),
    );
    console.log('  ok:', statement.split('\n')[0].slice(0, 64));
  } catch (err) {
    // Aurora may be resuming from scale-to-zero on the first call (~15s).
    if (attempt <= 6 && /resuming|paused|not currently available|DatabaseResuming/i.test(String(err))) {
      console.log(`  …cluster waking, retry ${attempt}`);
      await sleep(5000);
      return run(statement, attempt + 1);
    }
    throw err;
  }
}

console.log(`Applying ${statements.length} statements to ${DB_NAME}…`);
for (const s of statements) await run(s);
console.log('Schema applied.');
