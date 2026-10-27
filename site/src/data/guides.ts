import type { NoteColor, Task } from '../components/Note.astro';

// The how-to guides (src/pages/guides/[guide].astro), and the same text for /llms-full.txt. Each one
// answers a question people actually search for (Search Console), straight answer first, then the
// honest workarounds, then Tic. Every claim about another app is checked against Apple's own guides
// or the app itself; leave out anything that can't be confirmed.

export interface GuideSection {
  heading: string;
  body?: string[];
  steps?: string[];
  /** A link shown after the section's text. */
  link?: { href: string; label: string };
}

export interface Guide {
  slug: string;
  title: string;
  description: string;
  h1: string;
  /** The short answer at the top — the one paragraph a searcher needs. */
  answer: string;
  published: string;
  modified: string;
  sections: GuideSection[];
  /** An optional comparison table: a header row, then rows of cells. */
  table?: { heading: string; head: string[]; rows: string[][] };
  /** The closing pitch for Tic, with a note mock beside it. */
  tic: { heading: string; body: string[]; note: { title: string; color: NoteColor; tasks: Task[] } };
  faqs: { q: string; a: string }[];
  /** Comparison pages (by slug) that link back to this guide. */
  compare: string[];
}

export const guides: Guide[] = [
  {
    slug: 'stickies-checkboxes',
    title: 'How to add checkboxes in Stickies on Mac | Tic',
    description:
      'Stickies on Mac has no checkboxes. Here are the two workarounds, ☐ symbols and bulleted lists, what they can’t do, and a free sticky-note app with real checkboxes.',
    h1: 'How to add checkboxes in Stickies on Mac',
    answer:
      'Stickies has no checkbox feature. You can type ☐ and ☑ symbols from the Character Viewer, or make a bulleted list with Option-Tab, but neither can be ticked with a click, nested or cleared. For real checkboxes in a desktop note, use Tic, a free sticky-note to-do app for Mac.',
    published: '2026-10-27',
    modified: '2026-10-27',
    sections: [
      {
        heading: 'Add checkbox symbols to a Stickies note',
        steps: [
          'Click in your Stickies note where the first item should start.',
          'Press Control-Command-Space to open the Character Viewer.',
          'Search for “ballot” and click ☐ (Ballot Box) to insert an empty box.',
          'Type the item, press Return, and repeat for each line.',
          'To mark an item done, delete its ☐ and insert ☑ (Ballot Box with Check) in its place.',
        ],
      },
      {
        heading: 'Type ☐ faster with a text replacement',
        body: ['Opening the Character Viewer for every line gets old. macOS can swap a short code for the symbol as you type.'],
        steps: [
          'Open System Settings, choose Keyboard, then click Text Replacements.',
          'Click the add button and enter cbx under Replace and ☐ under With.',
          'In Stickies, type cbx followed by a space and it turns into ☐. If it doesn’t, choose Edit › Substitutions › Text Replacement in Stickies to turn it on.',
        ],
      },
      {
        heading: 'Or make a bulleted list',
        body: ['Stickies can format a plain list. It’s tidier than typing dashes, but there’s still nothing to tick.'],
        steps: [
          'Press Option-Tab, type the first item, then press Return to start the next one.',
          'Press Return twice after the last item to end the list.',
        ],
      },
      {
        heading: 'What these workarounds can’t do',
        body: [
          'A ☐ is just a character. Clicking it does nothing, so ticking an item means swapping symbols by hand, and a finished list is still a note full of text you delete yourself.',
          'Stickies also has no subtasks and no way to hide, sort or clear finished items. You can keep a note above other windows with Window › Float on Top, but it’s off by default and set one note at a time.',
        ],
      },
    ],
    tic: {
      heading: 'Real checkboxes in a sticky note: Tic',
      body: [
        'Tic keeps what’s good about Stickies, small notes that stay on your desktop, and makes every line a task. Click a checkbox to tick it. Press Shift-Tab to nest a step under a task, and when the last step is done the task ticks itself. Hide finished tasks, sink them to the bottom, or clear them in one click.',
        'Pin a list to keep it above your other windows. Everything stays on your Mac in a SQLite file, with no account. Tic is free and open source, and needs macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Before the weekend',
        color: 'yellow',
        tasks: [
          { t: 'Reply to Sam', done: true },
          { t: 'Book the car service' },
          { t: 'Pack for the trip' },
          { t: 'Chargers', l: 1, done: true },
          { t: 'Passport', l: 1 },
        ],
      },
    },
    faqs: [
      {
        q: 'Does Stickies on Mac have checkboxes?',
        a: 'No. Stickies has no checkbox or checklist feature. You can type ☐ and ☑ symbols or make a bulleted list, but you can’t tick either one with a click.',
      },
      {
        q: 'Can a Stickies note stay on top of other windows?',
        a: 'Yes. Click the note and choose Window › Float on Top. It’s off by default and applies to one note at a time.',
      },
      {
        q: 'Does Apple Notes have checkboxes?',
        a: 'Yes. In Notes, click the Checklist button or press Shift-Command-L, and each line gets a box you can tick. Notes keeps your checklist inside the Notes app rather than as a small note on the desktop.',
      },
      {
        q: 'Is there a free Stickies alternative with checkboxes?',
        a: 'Tic is one. It’s free and open source, puts a checkbox on every line, nests subtasks, and lets each list float above your other windows. Install it with one Terminal command from tic.kasvith.me.',
      },
      {
        q: 'Can I move my Stickies lists into Tic?',
        a: 'Not automatically. Make a list in Tic with ⌘N, then type or paste each line from the Stickies note and press Return after each one. Shift-Tab nests a line under the one above.',
      },
    ],
    compare: ['stickies'],
  },
  {
    slug: 'to-do-list-on-mac-desktop',
    title: 'How to keep a to-do list on your Mac desktop | Tic',
    description:
      'Four ways to keep a to-do list on your Mac desktop: Stickies, a Reminders widget, a Notes checklist, or Tic’s sticky-note lists. What each does well and where it falls short.',
    h1: 'How to keep a to-do list on your Mac desktop',
    answer:
      'To tick things off without opening an app, put a Reminders widget on the desktop or use a sticky-note to-do app like Tic. Stickies sits on the desktop but has no checkboxes, and a Notes checklist lives inside the Notes app.',
    published: '2026-10-27',
    modified: '2026-10-27',
    sections: [
      {
        heading: 'Stickies: built in, but no checkboxes',
        body: [
          'Stickies puts small notes on your desktop, and Window › Float on Top keeps a note above your other windows. It’s free and already on your Mac.',
          'A Stickies list is plain text, though. There’s nothing to tick, so finished items stay until you delete them.',
        ],
        link: { href: '/guides/stickies-checkboxes/', label: 'How to add checkboxes in Stickies' },
      },
      {
        heading: 'A Reminders widget on the desktop',
        body: [
          'On macOS 14 Sonoma or later you can put a Reminders widget on the desktop and tick reminders off right in the widget. Click it to open the full list in Reminders. Reminders also has due dates and syncs with your iPhone through iCloud.',
          'The widget sits on the desktop itself, so your open windows cover it.',
        ],
        steps: [
          'Control-click the desktop and choose Edit Widgets.',
          'Find Reminders in the widget gallery and drag a widget onto the desktop.',
        ],
      },
      {
        heading: 'A Notes checklist',
        body: [
          'Notes has real checklists. Click the Checklist button or press Shift-Command-L, and each line gets a box you can tick. Notes syncs with your iPhone through iCloud.',
          'The checklist lives inside the Notes app, with your other notes, rather than as its own small note on the desktop.',
        ],
      },
      {
        heading: 'Tic: a sticky note that’s a to-do list',
        body: [
          'Tic makes each list its own small note on your desktop, with a checkbox on every line. Drag it where you want it and pin it above your other windows if you like. It stays put across restarts.',
          'It runs on one Mac: there’s no iPhone app and no sync, and no due dates. If you need those, use Reminders.',
        ],
      },
    ],
    table: {
      heading: 'Which one to pick',
      head: ['', 'Stickies', 'Reminders widget', 'Notes checklist', 'Tic'],
      rows: [
        ['Tick items with a click', 'No', 'Yes', 'Yes', 'Yes'],
        ['Where the list lives', 'A note on the desktop', 'A widget on the desktop', 'Inside the Notes app', 'A note on the desktop'],
        ['Due dates and reminders', 'No', 'Yes', 'No', 'No'],
        ['Syncs with iPhone', 'No', 'Yes, with iCloud', 'Yes, with iCloud', 'No'],
        ['Price', 'Free, built in', 'Free, built in', 'Free, built in', 'Free and open source'],
      ],
    },
    tic: {
      heading: 'Try Tic',
      body: [
        'Each list is a small note on your desktop with a checkbox on every task, subtasks three levels deep, and Markdown. It’s free and open source, needs macOS 14 Sonoma or later on Apple silicon, and installs with one Terminal command.',
      ],
      note: {
        title: 'Today',
        color: 'blue',
        tasks: [
          { t: 'Send the invoice', done: true },
          { t: 'Review the pull request' },
          { t: 'Call the plumber' },
        ],
      },
    },
    faqs: [
      {
        q: 'Can I put a to-do list widget on my Mac desktop?',
        a: 'Yes. On macOS 14 Sonoma or later, Control-click the desktop, choose Edit Widgets, and drag a Reminders widget onto the desktop. You can tick reminders off in the widget.',
      },
      {
        q: 'How do I keep a to-do list on top of other windows on a Mac?',
        a: 'In Stickies, choose Window › Float on Top for the note. In Tic, pin the list. Desktop widgets sit under your windows, so they get covered.',
      },
      {
        q: 'Is there a free to-do list app that lives on the Mac desktop?',
        a: 'Yes. Tic is free and open source. Each list is a sticky note on the desktop with a checkbox on every task, and it installs with one Terminal command from tic.kasvith.me.',
      },
      {
        q: 'Does Tic sync with my iPhone?',
        a: 'No. Tic runs on one Mac and keeps everything in a local SQLite file. If you need your list on your phone, use Reminders.',
      },
    ],
    compare: ['stickies', 'apple-reminders'],
  },
];

export const guidePath = (g: Guide) => `/guides/${g.slug}/`;
