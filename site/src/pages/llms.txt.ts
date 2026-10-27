import type { APIRoute } from 'astro';
import { site, release, features, shortcuts, faqs } from '../data/site';
import { competitors, comparePath } from '../data/compare';
import { guides, guidePath } from '../data/guides';
import { llmsOverview } from '../data/llms';

// llms.txt (https://llmstxt.org): a curated Markdown fact sheet for LLMs, built from the same data as
// the pages. The full text of every page is in /llms-full.txt.
export const GET: APIRoute = () => {
  const body = [
    ...llmsOverview(),
    '## Features',
    '',
    ...features.map((f) => `- **${f.title}**: ${f.body}`),
    '',
    '## Keyboard shortcuts',
    '',
    ...shortcuts.map((s) => `- ${s.keys.join(' ')}: ${s.action}`),
    '',
    ...(release?.notes.length ? [`## What’s new in ${release.version}`, '', ...release.notes.map((n) => `- ${n}`), ''] : []),
    '## Guides',
    '',
    ...guides.map((g) => `- [${g.h1}](${site.url}${guidePath(g)}): ${g.answer}`),
    '',
    '## Comparisons',
    '',
    ...competitors.map((c) => `- [Tic vs ${c.name}](${site.url}${comparePath(c)}): ${c.description}`),
    '',
    '## FAQ',
    '',
    ...faqs.flatMap((f) => [`### ${f.q}`, '', f.a, '']),
    '## Links',
    '',
    `- [Website](${site.url}/): the Tic landing page`,
    `- [Full text for LLMs](${site.url}/llms-full.txt): every page on this site as plain text`,
    `- [Download](${site.download}): latest release on GitHub`,
    `- [Source code](${site.repo}): Swift 6, SwiftUI + AppKit, SQLite via GRDB`,
    `- [Changelog](${site.changelog}): release history`,
  ].join('\n');

  return new Response(`${body}\n`, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
