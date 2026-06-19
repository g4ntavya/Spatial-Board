import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export interface IngestStackProps extends cdk.StackProps {
  cluster: rds.DatabaseCluster;
  secret: secretsmanager.ISecret;
  databaseName: string;
  queue: sqs.Queue;
  syncToken: string;
}

/**
 * Public ingest edge: HTTP API → Ingest Lambda. The Lambda clusters incoming
 * strokes into notes, upserts everything to Aurora over the Data API, and
 * enqueues each note ID for the Process worker. Returns instantly.
 */
export class IngestStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: IngestStackProps) {
    super(scope, id, props);

    const fn = new lambda.Function(this, 'IngestFn', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../lambdas/ingest')),
      timeout: cdk.Duration.seconds(60),
      memorySize: 512,
      environment: {
        CLUSTER_ARN: props.cluster.clusterArn,
        SECRET_ARN: props.secret.secretArn,
        DB_NAME: props.databaseName,
        QUEUE_URL: props.queue.queueUrl,
        SYNC_TOKEN: props.syncToken,
      },
    });

    props.cluster.grantDataApiAccess(fn);
    props.secret.grantRead(fn);
    props.queue.grantSendMessages(fn);

    const api = new apigw.HttpApi(this, 'SyncApi', {
      corsPreflight: {
        allowOrigins: ['*'],
        allowMethods: [apigw.CorsHttpMethod.POST, apigw.CorsHttpMethod.OPTIONS],
        allowHeaders: ['content-type', 'x-api-key'],
      },
    });

    api.addRoutes({
      path: '/sync',
      methods: [apigw.HttpMethod.POST],
      integration: new HttpLambdaIntegration('SyncIntegration', fn),
    });

    new cdk.CfnOutput(this, 'SyncUrl', { value: `${api.apiEndpoint}/sync` });
    new cdk.CfnOutput(this, 'SyncToken', { value: props.syncToken });
  }
}
