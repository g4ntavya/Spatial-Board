import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { shouldAnimate } from '../lib/motion';
import './TechStack.css';

gsap.registerPlugin(ScrollTrigger);

const groups = [
  {
    label: 'AWS & Web — the deliverable',
    items: [
      { name: 'Aurora Serverless v2 · pgvector', detail: 'Relational metadata, JSONB stroke blobs, full-text and vector search in one database' },
      { name: 'RDS Data API', detail: 'HTTP access to Aurora — no VPC or connection pooling from serverless' },
      { name: 'Bedrock Titan Embeddings v2', detail: '1024-dimension vectors powering semantic search' },
      { name: 'Bedrock Claude', detail: 'Note titles, categories and OCR cleanup' },
      { name: 'API Gateway · Lambda', detail: 'Receives stroke batches and clusters them into notes' },
      { name: 'SQS', detail: 'Decouples instant ingest from heavy Bedrock work' },
      { name: 'Next.js on Vercel', detail: 'Three-pane notes UI with semantic search and export' },
      { name: 'Clerk', detail: 'Authentication and shareable space links' },
    ],
  },
  {
    label: 'iOS — the capture device',
    items: [
      { name: 'ARKit', detail: 'WorldAnchors and session management' },
      { name: 'RealityKit', detail: '3D tube-mesh stroke rendering' },
      { name: 'Vision', detail: 'Hand pose and gesture detection' },
      { name: 'SwiftData', detail: 'Persistent spatial models, offline-first' },
      { name: 'Metal', detail: 'GPU-accelerated stroke processing' },
      { name: 'Swift 6', detail: 'Full concurrency with actors' },
    ],
  },
];

export default function TechStack() {
  const sectionRef = useRef(null);

  useEffect(() => {
    if (!shouldAnimate()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.stack-reveal', { y: 40, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.85, ease: 'power3.out',
        scrollTrigger: { trigger: sectionRef.current, start: 'top 80%' },
      });
      gsap.fromTo('.stack-row', { y: 24, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.6, stagger: 0.05, ease: 'power3.out',
        scrollTrigger: { trigger: '.stack-groups', start: 'top 85%' },
      });
    }, sectionRef);
    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="stack section" id="stack">
      <div className="container">
        <div className="stack-head">
          <span className="stack-reveal eyebrow">The stack</span>
          <h2 className="stack-reveal stack-title display">Deliberate choices, end to end.</h2>
        </div>

        <div className="stack-groups">
          {groups.map((g) => (
            <div key={g.label} className="stack-group">
              <h3 className="stack-group-label">{g.label}</h3>
              <ul className="stack-list">
                {g.items.map((item) => (
                  <li key={item.name} className="stack-row">
                    <span className="stack-name">{item.name}</span>
                    <span className="stack-detail">{item.detail}</span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
