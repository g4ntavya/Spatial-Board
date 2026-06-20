import { BedrockRuntimeClient, InvokeModelCommand, ConverseCommand } from '@aws-sdk/client-bedrock-runtime';

const client = new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? 'us-east-1' });

/** Ask Amazon Nova a question with a system instruction (used for RAG answers). */
export async function answer(system: string, user: string): Promise<string> {
  const out = await client.send(
    new ConverseCommand({
      modelId: process.env.BEDROCK_CHAT_MODEL_ID ?? 'amazon.nova-pro-v1:0',
      system: [{ text: system }],
      messages: [{ role: 'user', content: [{ text: user }] }],
      inferenceConfig: { maxTokens: 600, temperature: 0.2 },
    }),
  );
  return (out.output?.message?.content ?? []).map((c) => c.text).filter(Boolean).join('\n').trim();
}

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
