import type { Task } from '../components/Note.astro';

// Latest release, parsed from the git-cliff CHANGELOG.md on GitHub at build time. A failed fetch
// just hides the version and "What's new" rather than breaking the build. The notes keep only what users
// notice (see `userFacingGroups`) — not Documentation, Miscellaneous Tasks, Refactor and the like.
const userFacingGroups = new Set(['Features', 'Bug Fixes', 'Performance', 'Security']);

async function latestRelease() {
  try {
    const res = await fetch('https://raw.githubusercontent.com/kasvith/tic/main/CHANGELOG.md');
    if (!res.ok) return undefined;
    const block = (await res.text()).split(/^## /m).find((b) => b.startsWith('['));
    const head = block?.match(/^\[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})/);
    if (!block || !head) return undefined;
    const notes = block
      .split(/^### /m)
      .slice(1)
      .filter((group) => userFacingGroups.has(group.split('\n')[0].trim()))
      .flatMap((group) => [...group.matchAll(/^- (.+)$/gm)].map((m) => m[1].replace(/^\*\(.+?\)\* /, '')));
    return { version: head[1], date: head[2], notes };
  } catch {
    return undefined;
  }
}

export const release = await latestRelease();

export const site = {
  name: 'Tic',
  url: 'https://tic.kasvith.me',
  title: 'Tic: Free sticky-note to-do lists for your Mac desktop',
  description:
    'Tic is a free, open-source Mac app that keeps your to-do lists on the desktop as floating sticky notes, with subtasks, Markdown and keyboard shortcuts.',
  summary:
    'Tic is a free, open-source macOS app that keeps to-do lists on the desktop as floating, Stickies-style sticky notes instead of hiding them behind a menu bar. Each list is its own small window with subtasks, inline Markdown, pasted images, solid or glass styles and keyboard shortcuts. It needs macOS 14 Sonoma or later on an Apple silicon Mac.',
  keywords: ['to-do list', 'sticky notes', 'Stickies alternative', 'desktop checklist', 'task manager', 'macOS', 'open source', 'MCP', 'AI agent'],
  repo: 'https://github.com/kasvith/tic',
  download: 'https://github.com/kasvith/tic/releases/latest',
  // curl doesn't add the quarantine flag a browser download gets, so this skips the Gatekeeper block.
  install: 'curl -fsSL https://tic.kasvith.me/install.sh | sh',
  changelog: 'https://github.com/kasvith/tic/blob/main/CHANGELOG.md',
  productHunt: 'https://www.producthunt.com/products/tic?utm_source=badge-follow&utm_medium=badge&utm_source=badge-tic',
  author: { name: 'Kasun Vithanage', url: 'https://kasvith.me', github: 'https://github.com/kasvith' },
};

// The app's own welcome note (AppDatabase.seedSampleDataIfEmpty), rendered as HTML.
export const welcomeTasks: Task[] = [
  { t: 'Tap the circle to finish a task' },
  { t: 'Break big tasks into subtasks' },
  { t: 'Hover a row and click the + below it', l: 1 },
  { t: '…or press Shift-Tab while editing', l: 1 },
  { t: '<em>Markdown</em> — <strong>bold</strong>, <code>code</code>, <s>strike</s>, <a href="https://kasvith.me">links</a>' },
  { t: 'Need detail? Press Shift-Return\nfor a new line in the same task' },
  { t: 'Completing a parent completes its subtasks', done: true },
  { t: 'buy milk', l: 1, done: true },
  { t: 'water the plants', l: 1, done: true },
];

export const shipTasks: Task[] = [
  { t: 'Write release notes', done: true },
  { t: 'Record the demo' },
  { t: 'Trim the intro', l: 1, done: true },
  { t: 'Export at <strong>1080p</strong>', l: 1 },
  { t: 'Tag <code>v0.4.0</code>', editing: true, hint: ['⇧⇥', 'nest'] },
];

export const groceryTasks: Task[] = [
  { t: 'Oat milk' },
  { t: 'Sourdough', done: true },
  { t: 'Coffee beans' },
  { t: 'Lemons ×3' },
];

export const weekTasks: Task[] = [
  { t: 'Dentist, <strong>Thu 3pm</strong>' },
  { t: 'Call mum', done: true },
  { t: 'Book flights to Rome' },
];

// The MCP section: an agent building a trip list live. Seeded done so no-JS/reduced-motion shows the
// finished cascade; the script un-ticks then re-ticks to animate it.
export const agentTasks: Task[] = [
  { t: 'Flights', done: true },
  { t: 'Book outbound', l: 1, done: true },
  { t: 'Book return', l: 1, done: true },
  { t: 'Lodging' },
  { t: 'Food &amp; coffee spots' },
];

// The looping demo conversation. `reveal` lists the note rows (by index) a tool call fills in;
// `tick` marks the message that checks the Flights subtree off. Rendered as chat bubbles.
export type ChatTurn =
  | { who: 'user'; text: string }
  | { who: 'agent'; text: string }
  | { who: 'tool'; label: string; reveal?: number[]; tick?: boolean };
export const agentChat: ChatTurn[] = [
  { who: 'user', text: 'Plan a 3-day trip to Kyoto 🗾' },
  { who: 'agent', text: 'On it — I’ll set this up in Tic 👇' },
  { who: 'tool', label: 'Created the note “Kyoto trip”' },
  { who: 'tool', label: 'Added Flights, Book outbound, Book return', reveal: [0, 1, 2] },
  { who: 'tool', label: 'Added Lodging and Food & coffee', reveal: [3, 4] },
  { who: 'user', text: 'Book the flights and check them off' },
  { who: 'tool', label: 'Checked off Flights', tick: true },
  { who: 'agent', text: 'Done ✓ Flights and both legs are ticked.' },
];

// Popular MCP clients that can drive Tic. Icons are Phosphor (generic, not brand logos).
export const mcpClients: { name: string; icon: string }[] = [
  { name: 'Claude', icon: 'sparkle' },
  { name: 'Claude Code', icon: 'terminal-window' },
  { name: 'Cursor', icon: 'cursor' },
  { name: 'VS Code', icon: 'code' },
  { name: 'Zed', icon: 'lightning' },
  { name: 'Codex CLI', icon: 'terminal-window' },
  { name: 'Gemini CLI', icon: 'sparkle' },
  { name: 'Windsurf', icon: 'wind' },
];

export const features = [
  {
    id: 'float',
    title: 'Lists that stay where you put them',
    body: 'Each list is its own small window on the desktop. Keep it above everything, or double-click the title to roll it up. Tic remembers where every note sits.',
  },
  {
    id: 'subtasks',
    title: 'Subtasks, notes and Markdown',
    body: 'Nest tasks three levels deep. Finish every subtask and the parent ticks itself off. Add a second line with Shift-Return, and write bold, italic, code, strikethrough or links right in the task.',
  },
  {
    id: 'agents',
    title: 'Let your AI agent draft the list',
    body: 'Tic speaks MCP, so Claude, Cursor, Zed and the Codex or Gemini CLIs can create notes, draft tasks and tick them off — live on your desktop. It’s off by default, with one-click setup for each client.',
  },
  {
    id: 'images',
    title: 'Paste screenshots right into a task',
    body: 'Copy a screenshot or image and press ⌘V. It sits under the task it belongs to, or waits in Add a task… until you press Return, so you can caption it first. Crop it in place, or double-click to open it in its own window to zoom in or send it to Preview.',
  },
  {
    id: 'look',
    title: 'Six paper colours, or glass',
    body: 'Give each list its own colour, or switch it to glass so your wallpaper shows through. On macOS 26 glass notes pick up Liquid Glass automatically.',
  },
  {
    id: 'search',
    title: 'Find any list in a keystroke',
    body: 'Open Search Lists from the menu bar to jump to any list. Type to filter, use the arrow keys to move and Return to open it.',
  },
  {
    id: 'tidy',
    title: 'Finished tasks, handled your way',
    body: 'Per list, hide completed tasks, sink them to the bottom, or clear them all out when the list gets long.',
  },
  {
    id: 'private',
    title: 'Private by default',
    body: 'Your lists live in a SQLite file on your Mac. There’s no account, no server and no tracking.',
  },
];

export const shortcuts: { keys: string[]; action: string }[] = [
  { keys: ['⌘', 'N'], action: 'New list' },
  { keys: ['Return'], action: 'Save the task you’re typing' },
  { keys: ['⇧', 'Return'], action: 'New line inside a task' },
  { keys: ['⌘', 'V'], action: 'Paste an image into a task' },
  { keys: ['⇧', 'Tab'], action: 'Nest a task under the one above' },
  { keys: ['⌃', '⇧', 'Tab'], action: 'Move a subtask back out' },
  { keys: ['↑', '↓'], action: 'Move through search results' },
];

export const faqs = [
  {
    q: 'How do I put a to-do list on my Mac desktop?',
    a: 'Install Tic and press ⌘N. The list opens as a sticky note on the desktop and stays where you put it. Click the pin to keep it on top of other windows, or double-click the title to roll it up to a bar.',
  },
  {
    q: 'Is Tic free?',
    a: 'Yes. Tic is free and open source under the MIT license. The code is on GitHub.',
  },
  {
    q: 'Which version of macOS do I need?',
    a: 'macOS 14 Sonoma or later, on a Mac with Apple silicon. Glass notes use Liquid Glass automatically on macOS 26.',
  },
  {
    q: 'macOS says Tic can’t be opened. What do I do?',
    a: `Tic isn’t notarized by Apple yet, so Gatekeeper blocks the first launch of a copy downloaded in a browser. Install it with the Terminal command instead, ${site.install}, and it opens straight away. If you already downloaded the .dmg, move Tic.app to Applications and run xattr -c /Applications/Tic.app in Terminal.`,
  },
  {
    q: 'How do I update Tic?',
    a: `Run the install command again: ${site.install}. It replaces the old copy and reopens Tic, with your lists untouched. Tic also shows Update Available in its menu bar menu when a new version is out.`,
  },
  {
    q: 'Where are my lists stored?',
    a: 'In a local SQLite database at ~/Library/Application Support/Tic/tic.sqlite. Nothing leaves your Mac.',
  },
  {
    q: 'Can AI agents add tasks to Tic?',
    a: 'Yes. Turn on the MCP server from the menu bar (AI Agents (MCP)…) and agents like Claude, Cursor, VS Code, Zed and the Codex or Gemini CLIs can create notes, draft tasks, tick them off and more. The window gives you a one-click or copy-paste setup for each. It is off by default and runs entirely on your Mac.',
  },
  {
    q: 'Does Tic sync between Macs?',
    a: 'Not yet. Tic keeps everything local on one Mac for now.',
  },
  {
    q: 'Can Tic open when I log in?',
    a: 'Yes. Turn on Launch at Login from the Tic menu in the menu bar.',
  },
];
