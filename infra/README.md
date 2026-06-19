# Infra — Phase 0 Foundation

AWS backend for the SpatialBoard web companion. See [docs/AWS_PLAN.md](../docs/AWS_PLAN.md).

## What Phase 0 stands up

```
API Gateway (HTTP API)  →  Ingest Lambda  →  SQS  →  Process Lambda
                                 │                         │
                                 └────► Aurora SLv2 ◄───────┘
                                        Postgres + pgvector
                                        (RDS Data API enabled)
```

## Approach: AWS CDK (TypeScript)

We provision with CDK so the infrastructure itself is a reviewable craftsmanship artifact.
Target layout (to be built Phase 0):

```
infra/
├── README.md            ← this file
├── db/
│   └── schema.sql       ← Postgres DDL (done)
├── cdk/
│   ├── bin/app.ts       ← CDK entrypoint
│   ├── lib/
│   │   ├── data-stack.ts    ← Aurora SLv2 cluster, pgvector, Data API, Secrets
│   │   ├── ingest-stack.ts  ← API Gateway + Ingest Lambda + SQS
│   │   └── process-stack.ts ← Process Lambda (SQS consumer) + Bedrock IAM
│   ├── package.json
│   └── cdk.json
└── lambdas/
    ├── ingest/          ← upsert strokes, cluster into notes, enqueue
    └── process/         ← project→SVG, Bedrock OCR/embed/title, write back
```

## Phase 0 checklist (Day 1–3)

- [ ] AWS account + CLI configured; Bedrock model access enabled (Titan Embed v2, Claude)
- [ ] CDK bootstrap (`cdk bootstrap`)
- [ ] **data-stack**: Aurora Serverless v2 PostgreSQL cluster
  - [ ] Enable **RDS Data API** + Secrets Manager credential
  - [ ] Min/max ACU set low (0.5–2) for cost
- [ ] Apply [db/schema.sql](db/schema.sql) (psql or Data API `BatchExecuteStatement`)
  - [ ] `CREATE EXTENSION vector;` succeeds
- [ ] **ingest-stack**: HTTP API + Lambda + SQS queue
- [ ] **process-stack**: SQS-triggered Lambda with `bedrock:InvokeModel` + Data API IAM
- [ ] **Exit criterion:** `curl -X POST <api>/sync -d '{...}'` → row visible in `strokes`

## Key resource settings

| Resource | Setting | Note |
|---|---|---|
| Aurora | Serverless v2, Postgres 16+ | pgvector available |
| Aurora | Data API: **enabled** | HTTP access; no pooling from Vercel |
| Aurora | ACU 0.5 min / 2 max | hackathon-scale cost control |
| Bedrock | `amazon.titan-embed-text-v2:0` | 1024-dim embeddings |
| Bedrock | Claude (latest) | titles / categories / OCR cleanup |
| SQS | standard queue, DLQ after 3 | decouple ingest from processing |

## Vercel ↔ Aurora

The Next.js app talks to Aurora via the **RDS Data API** using an IAM user/role credential stored
in Vercel env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AURORA_CLUSTER_ARN`,
`AURORA_SECRET_ARN`). No VPC, no connection pool.
