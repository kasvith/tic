import type { APIRoute } from 'astro';
import { site, features, shortcuts, faqs } from '../data/site';
import { competitors, comparePath, features as compareRows } from '../data/compare';
import { guides, guidePath } from '../data/guides';
import { llmsOverview } from '../data/llms';

// /llms-full.txt: the whole site as one Markdown file for LLMs (the curated summary is /llms.txt).
// Built from the same data as the pages, so it can't drift from them.
const qa = (items: { q: string; a: string }[]) => items.flatMap((f) => [`#### ${f.q}`, '', f.a, '']);

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
    '## FAQ',
    '',
    ...faqs.flatMap((f) => [`### ${f.q}`, '', f.a, '']),
    '## Guides',
    '',
    ...guides.flatMap((g) => [
      `### ${g.h1}`,
      '',
      `${site.url}${guidePath(g)}`,
      '',
      `Short answer: ${g.answer}`,
      '',
      ...g.sections.flatMap((s) => [
        `#### ${s.heading}`,
        '',
        ...(s.body ?? []).flatMap((p) => [p, '']),
        ...(s.steps ? [...s.steps.map((step, i) => `${i + 1}. ${step}`), ''] : []),
      ]),
      ...(g.table
        ? [`#### ${g.table.heading}`, '', ...g.table.rows.map(([label, ...cells]) => `- ${label}: ${cells.map((c, i) => `${g.table!.head[i + 1]}: ${c}`).join('; ')}`), '']
        : []),
      `#### ${g.tic.heading}`,
      '',
      ...g.tic.body.flatMap((p) => [p, '']),
      ...qa(g.faqs),
    ]),
    '## Comparisons',
    '',
    ...competitors.flatMap((c) => [
      `### Tic vs ${c.name}`,
      '',
      `${site.url}${comparePath(c)}`,
      '',
      c.lede,
      '',
      `#### ${c.name} and Tic, side by side`,
      '',
      ...compareRows.map((f) => `- ${f.label}: ${c.name}: ${c.values[f.id]}; Tic: ${f.tic}`),
      '',
      `#### ${c.keep.heading}`,
      '',
      ...c.keep.body.flatMap((p) => [p, '']),
      ...qa(c.faqs),
    ]),
  ].join('\n');

  return new Response(`${body}\n`, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
