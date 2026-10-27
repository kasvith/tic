import type { APIRoute } from 'astro';
import { site, release, features, shortcuts, faqs } from '../data/site';
import { competitors, comparePath } from '../data/compare';

// llms.txt (https://llmstxt.org): a Markdown summary of the page for LLMs, built from the same data.
export const GET: APIRoute = () => {
  const body = [
    `# ${site.name}`,
    '',
    `> ${site.summary}`,
    '',
    [release && `Latest version: ${release.version} (released ${release.date}).`, 'Free and open source under the MIT license.', `Made by ${site.author.name}.`]
      .filter(Boolean)
      .join(' '),
    '',
    '## Features',
    '',
    ...features.map((f) => `- **${f.title}**: ${f.body}`),
    '',
    '## Keyboard shortcuts',
    '',
    ...shortcuts.map((s) => `- ${s.keys.join(' ')}: ${s.action}`),
    '',
    '## Install',
    '',
    `1. Paste in Terminal: \`${site.install}\`. It installs Tic to Applications and opens it; run it again to update.`,
    `2. Or download the .dmg from the [latest release](${site.download}) and move Tic.app to Applications. Tic isn’t notarized yet, so a downloaded copy needs \`xattr -c /Applications/Tic.app\` once in Terminal.`,
    '3. Open Tic and press ⌘N to make a list. Turn on Launch at Login from the menu bar icon.',
    '',
    ...(release?.notes.length ? [`## What’s new in ${release.version}`, '', ...release.notes.map((n) => `- ${n}`), ''] : []),
    '## FAQ',
    '',
    ...faqs.flatMap((f) => [`### ${f.q}`, '', f.a, '']),
    '## Links',
    '',
    `- [Website](${site.url}/): the Tic landing page`,
    ...competitors.map((c) => `- [Tic vs ${c.name}](${site.url}${comparePath(c)}): ${c.description}`),
    `- [Download](${site.download}): latest release on GitHub`,
    `- [Source code](${site.repo}): Swift 6, SwiftUI + AppKit, SQLite via GRDB`,
    `- [Changelog](${site.changelog}): release history`,
  ].join('\n');

  return new Response(`${body}\n`, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
