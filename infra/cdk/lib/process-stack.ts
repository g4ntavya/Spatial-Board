import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import { SqsEventSource } from 'aws-cdk-lib/aws-lambda-event-sources';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export interface ProcessStackProps extends cdk.StackProps {
  cluster: rds.DatabaseCluster;
  secret: secretsmanager.ISecret;
  databaseName: string;
  ocrModelId: string;
  embedModelId: string;
}

/**
 * SQS-decoupled note enrichment. Ingest enqueues note IDs here; this worker
 * projects strokes to SVG, runs Bedrock OCR + title/category (Claude) and a
 * Titan embedding, then writes the results back to Aurora. Decoupling means
 * the iOS sync request returns instantly and never waits on the model.
 */
export class ProcessStack extends cdk.Stack {
  public readonly queue: sqs.Queue;

  constructor(scope: Construct, id: string, props: ProcessStackProps) {
    super(scope, id, props);

    const dlq = new sqs.Queue(this, 'NotesDLQ', {
      retentionPeriod: cdk.Duration.days(14),
    });

    this.queue = new sqs.Queue(this, 'NotesQueue', {
      visibilityTimeout: cdk.Duration.seconds(180), // ≥ lambda timeout
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
    });

    const fn = new lambda.Function(this, 'ProcessFn', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../lambdas/process')),
      timeout: cdk.Duration.seconds(120),
      memorySize: 512,
      environment: {
        CLUSTER_ARN: props.cluster.clusterArn,
        SECRET_ARN: props.secret.secretArn,
        DB_NAME: props.databaseName,
        OCR_MODEL_ID: props.ocrModelId,
        EMBED_MODEL_ID: props.embedModelId,
      },
    });

    // DB access over the Data API (also grants read on the cluster secret).
    props.cluster.grantDataApiAccess(fn);
    props.secret.grantRead(fn);

    // Bedrock: invoke the Claude inference profile + the underlying foundation
    // models (Titan embed, and the per-region models behind the profile).
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['bedrock:InvokeModel'],
        resources: [
          `arn:aws:bedrock:*::foundation-model/*`,
          `arn:aws:bedrock:*:${this.account}:inference-profile/*`,
        ],
      }),
    );

    // Anthropic models are sold via AWS Marketplace; the first invocation must
    // be able to complete the account-wide subscription.
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['aws-marketplace:Subscribe', 'aws-marketplace:ViewSubscriptions', 'aws-marketplace:Unsubscribe'],
        resources: ['*'],
      }),
    );

    fn.addEventSource(new SqsEventSource(this.queue, { batchSize: 1 }));

    new cdk.CfnOutput(this, 'QueueUrl', { value: this.queue.queueUrl });
  }
}
