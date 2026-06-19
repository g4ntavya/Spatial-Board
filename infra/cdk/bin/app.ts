#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { DataStack } from '../lib/data-stack.js';
import { IngestStack } from '../lib/ingest-stack.js';
import { ProcessStack } from '../lib/process-stack.js';

const app = new cdk.App();

// Account 251335055096 / us-east-1 — Bedrock models (Titan Embed v2, Claude Sonnet 4.6) live here.
const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1',
};

// A shared secret the iOS app sends as `x-api-key`. Override with
//   cdk deploy -c syncToken=<your-own>
// so it stays stable across deploys. A default is generated otherwise.
const syncToken =
  (app.node.tryGetContext('syncToken') as string | undefined) ??
  'sb-dev-' + Math.random().toString(36).slice(2, 14);

const data = new DataStack(app, 'SpatialBoardData', { env });

const processStack = new ProcessStack(app, 'SpatialBoardProcess', {
  env,
  cluster: data.cluster,
  secret: data.secret,
  databaseName: data.databaseName,
  claudeModelId: 'us.anthropic.claude-sonnet-4-6',
  embedModelId: 'amazon.titan-embed-text-v2:0',
});

new IngestStack(app, 'SpatialBoardIngest', {
  env,
  cluster: data.cluster,
  secret: data.secret,
  databaseName: data.databaseName,
  queue: processStack.queue,
  syncToken,
});

app.synth();
