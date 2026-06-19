import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { shouldAnimate } from '../lib/motion';
import './Features.css';

gsap.registerPlugin(ScrollTrigger);

const steps = [
  {
    num: '01',
    title: 'Capture',
    desc: 'Strokes are drawn in 3D space and stored locally in SwiftData. On app background, the session is batched and posted as idempotent, UUID-keyed geometry.',
    tags: ['iOS', 'ARKit', 'SwiftData'],
  },
  {
    num: '02',
    title: 'Ingest',
    desc: 'An API Gateway HTTP API hands the batch to a Lambda that clusters strokes into notes by spatial proximity, upserts them, and enqueues each note for processing.',
    tags: ['API Gateway', 'Lambda'],
  },
  {
    num: '03',
    title: 'Process',
    desc: 'An SQS-decoupled worker projects strokes to SVG, runs OCR and title-and-category generation on Bedrock Claude, and embeds the text with Titan — the real work.',
    tags: ['SQS', 'Bedrock', 'Titan', 'Claude'],
  },
  {
    num: '04',
    title: 'Index',
    desc: 'One database holds relational metadata, JSONB stroke blobs, full-text search vectors and 1024-dimension embeddings — a single deliberate data model.',
    tags: ['Aurora Serverless v2', 'pgvector'],
  },
  {
    num: '05',
    title: 'Read',
    desc: 'A three-pane Next.js app queries Aurora over the RDS Data API — no VPC pain — for keyword and semantic search. Ask for a topic; get notes you never tagged.',
    tags: ['Next.js', 'RDS Data API', 'Vercel'],
  },
];

export default function Features() {
  const sectionRef = useRef(null);

  useEffect(() => {
    if (!shouldAnimate()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.pipeline-reveal', { y: 40, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.85, ease: 'power3.out',
        scrollTrigger: { trigger: sectionRef.current, start: 'top 80%' },
      });
      gsap.fromTo('.pipeline-row', { y: 36, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.7, stagger: 0.09, ease: 'power3.out',
        scrollTrigger: { trigger: '.pipeline-list', start: 'top 85%' },
      });
    }, sectionRef);
    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="pipeline section" id="pipeline">
      <div className="container">
        <div className="pipeline-head">
          <span className="pipeline-reveal eyebrow">The pipeline</span>
          <h2 className="pipeline-reveal pipeline-title display">
            Five stages from a stroke in the air to a searchable note.
          </h2>
        </div>

        <div className="pipeline-list">
          {steps.map((s) => (
            <div key={s.num} className="pipeline-row" id={`pipeline-${s.num}`}>
              <span className="pipeline-num">{s.num}</span>
              <h3 className="pipeline-name">{s.title}</h3>
              <p className="pipeline-desc">{s.desc}</p>
              <ul className="pipeline-tags">
                {s.tags.map((t) => (
                  <li key={t}>{t}</li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
