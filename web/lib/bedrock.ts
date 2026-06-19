import { BedrockRuntimeClient, InvokeModelCommand } from '@aws-sdk/client-bedrock-runtime';

const client = new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? 'us-east-1' });

/** Embed a search query with Titan v2 (same model the pipeline used for notes). */
export async function embedQuery(text: string): Promise<number[]> {
  const r = await client.send(
    new InvokeModelCommand({
      modelId: process.env.BEDROCK_EMBED_MODEL_ID ?? 'amazon.titan-embed-text-v2:0',
      contentType: 'application/json',
      accept: 'application/json',
      body: JSON.stringify({ inputText: text.slice(0, 8000) }),
    }),
  );
  return JSON.parse(Buffer.from(r.body).toString()).embedding as number[];
}
