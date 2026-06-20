import { RDSDataClient, ExecuteStatementCommand, type SqlParameter, type Field } from '@aws-sdk/client-rds-data';

const client = new RDSDataClient({ region: process.env.AWS_REGION ?? 'us-east-1' });

export type Row = Record<string, string | number | boolean | null>;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Execute a parameterized statement against Aurora over the RDS Data API.
 * The cluster scales to zero (auto-pause) to save cost; the first query after a
 * pause throws DatabaseResumingException while it wakes. We retry transparently
 * with backoff so callers never see the cold start. */
export async function query(sql: string, parameters: SqlParameter[] = []): Promise<Row[]> {
  const cmd = new ExecuteStatementCommand({
    resourceArn: process.env.AURORA_CLUSTER_ARN!,
    secretArn: process.env.AURORA_SECRET_ARN!,
    database: process.env.DB_NAME ?? 'spatialboard',
    sql,
    parameters,
    includeResultMetadata: true,
  });

  let res;
  const maxAttempts = 8;
  for (let attempt = 1; ; attempt++) {
    try {
      res = await client.send(cmd);
      break;
    } catch (err) {
      const resuming =
        (err as { name?: string })?.name === 'DatabaseResumingException' ||
        /resuming after being auto-paused/i.test((err as Error)?.message ?? '');
      if (!resuming || attempt >= maxAttempts) throw err;
      await sleep(Math.min(1000 * attempt, 4000)); // 1s,2s,3s,4s,4s… ≈ resume time
    }
  }
  const cols = (res.columnMetadata ?? []).map((c) => c.name ?? '');
  return (res.records ?? []).map((rec) => {
    const o: Row = {};
    rec.forEach((f: Field, i: number) => {
      o[cols[i]] = f.isNull
        ? null
        : (f.stringValue ?? f.longValue ?? f.doubleValue ?? f.booleanValue ?? null);
    });
    return o;
  });
}

export const str = (name: string, value: string): SqlParameter => ({ name, value: { stringValue: value } });
