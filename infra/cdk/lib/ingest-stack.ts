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

    // Shared HS256 secret: the auth Lambda signs JWTs with it, ingest verifies.
    const authJwtSecret = (this.node.tryGetContext('authJwtSecret') as string) ?? '';

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
        AUTH_JWT_SECRET: authJwtSecret,
      },
    });

    props.cluster.grantDataApiAccess(fn);
    props.secret.grantRead(fn);
    props.queue.grantSendMessages(fn);

    // Our own email/password auth: issues the JWTs that ingest verifies above.
    const authFn = new lambda.Function(this, 'AuthFn', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../lambdas/auth')),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      environment: {
        CLUSTER_ARN: props.cluster.clusterArn,
        SECRET_ARN: props.secret.secretArn,
        DB_NAME: props.databaseName,
        AUTH_JWT_SECRET: authJwtSecret,
      },
    });
    props.cluster.grantDataApiAccess(authFn);
    props.secret.grantRead(authFn);

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

    const authIntegration = new HttpLambdaIntegration('AuthIntegration', authFn);
    api.addRoutes({ path: '/login', methods: [apigw.HttpMethod.POST], integration: authIntegration });
    api.addRoutes({ path: '/signup', methods: [apigw.HttpMethod.POST], integration: authIntegration });

    new cdk.CfnOutput(this, 'SyncUrl', { value: `${api.apiEndpoint}/sync` });
    new cdk.CfnOutput(this, 'AuthUrl', { value: api.apiEndpoint });
    new cdk.CfnOutput(this, 'SyncToken', { value: props.syncToken });
  }
}
