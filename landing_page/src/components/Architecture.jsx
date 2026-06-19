import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { shouldAnimate } from '../lib/motion';
import './Architecture.css';

gsap.registerPlugin(ScrollTrigger);

const flow = [
  { id: 'ios', tier: 'Capture', name: 'iOS App', sub: 'SwiftData · batched on background', connector: 'POST strokes' },
  { id: 'gateway', tier: 'Edge', name: 'API Gateway', sub: 'HTTP API', connector: 'invoke' },
  { id: 'ingest', tier: 'Ingest', name: 'Ingest Lambda', sub: 'cluster · upsert raw', connector: 'enqueue' },
  { id: 'sqs', tier: 'Queue', name: 'SQS', sub: 'decoupled buffer', connector: 'consume' },
  {
    id: 'process', tier: 'Process', name: 'Process Lambda',
    sub: 'project → SVG · Bedrock OCR · Titan embed · Claude title',
    connector: 'write back',
  },
  { id: 'aurora', tier: 'Store', name: 'Aurora Serverless v2', sub: 'Postgres + pgvector', connector: 'Data API (HTTP)' },
  { id: 'web', tier: 'Read', name: 'Next.js on Vercel', sub: 'semantic search · export', connector: null },
];

export default function Architecture() {
  const sectionRef = useRef(null);

  useEffect(() => {
    if (!shouldAnimate()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.arch-reveal', { y: 40, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.85, ease: 'power3.out',
        scrollTrigger: { trigger: sectionRef.current, start: 'top 80%' },
      });
      gsap.fromTo('.arch-node', { y: 28, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.6, stagger: 0.08, ease: 'power3.out',
        scrollTrigger: { trigger: '.arch-flow', start: 'top 85%' },
      });
    }, sectionRef);
    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="architecture section" id="architecture">
      <div className="container">
        <div className="arch-head">
          <span className="arch-reveal eyebrow">Architecture</span>
          <h2 className="arch-reveal arch-title display">One path, no glue code.</h2>
          <p className="arch-reveal arch-lede lede">
            Instant ingest is decoupled from heavy Bedrock work by SQS, so the app
            never waits on the model and the pipeline scales to zero between sessions.
          </p>
        </div>

        <div className="arch-flow">
          {flow.map((node) => (
            <div key={node.id} className="arch-node-wrap">
              <div className="arch-node" id={`arch-${node.id}`}>
                <span className="arch-node-tier">{node.tier}</span>
                <span className="arch-node-name">{node.name}</span>
                <span className="arch-node-sub">{node.sub}</span>
              </div>
              {node.connector && (
                <div className="arch-connector" aria-hidden="true">
                  <span>{node.connector}</span>
                </div>
              )}
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
