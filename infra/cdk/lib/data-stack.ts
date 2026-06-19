import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';

/**
 * Aurora Serverless v2 PostgreSQL + pgvector, reachable over the RDS Data API.
 *
 * Cost design:
 *  - serverlessV2MinCapacity: 0  → the cluster scales to zero (auto-pauses) when
 *    idle, so it costs ~$0 between demos and wakes on the next query (~15s cold).
 *  - VPC with natGateways: 0 + isolated subnets → no ~$32/mo NAT gateway. The Data
 *    API is an AWS service endpoint, so nothing in the VPC needs outbound internet.
 */
export class DataStack extends cdk.Stack {
  public readonly cluster: rds.DatabaseCluster;
  public readonly secret: secretsmanager.ISecret;
  public readonly databaseName = 'spatialboard';

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [
        { name: 'isolated', subnetType: ec2.SubnetType.PRIVATE_ISOLATED, cidrMask: 24 },
      ],
    });

    this.cluster = new rds.DatabaseCluster(this, 'Cluster', {
      engine: rds.DatabaseClusterEngine.auroraPostgres({
        version: rds.AuroraPostgresEngineVersion.VER_16_4,
      }),
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      defaultDatabaseName: this.databaseName,
      enableDataApi: true,
      serverlessV2MinCapacity: 0, // scale to zero when idle
      serverlessV2MaxCapacity: 2, // hackathon ceiling
      writer: rds.ClusterInstance.serverlessV2('writer'),
      credentials: rds.Credentials.fromGeneratedSecret('postgres', {
        secretName: 'spatialboard/db',
      }),
      removalPolicy: cdk.RemovalPolicy.DESTROY, // hackathon: easy teardown
    });

    this.secret = this.cluster.secret!;

    new cdk.CfnOutput(this, 'ClusterArn', { value: this.cluster.clusterArn });
    new cdk.CfnOutput(this, 'SecretArn', { value: this.secret.secretArn });
    new cdk.CfnOutput(this, 'DatabaseName', { value: this.databaseName });
  }
}
