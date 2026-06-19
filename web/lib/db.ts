import { RDSDataClient, ExecuteStatementCommand, type SqlParameter, type Field } from '@aws-sdk/client-rds-data';

const client = new RDSDataClient({ region: process.env.AWS_REGION ?? 'us-east-1' });

export type Row = Record<string, string | number | boolean | null>;

/** Execute a parameterized statement against Aurora over the RDS Data API. */
export async function query(sql: string, parameters: SqlParameter[] = []): Promise<Row[]> {
  const res = await client.send(
    new ExecuteStatementCommand({
      resourceArn: process.env.AURORA_CLUSTER_ARN!,
      secretArn: process.env.AURORA_SECRET_ARN!,
      database: process.env.DB_NAME ?? 'spatialboard',
      sql,
      parameters,
      includeResultMetadata: true,
    }),
  );
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
