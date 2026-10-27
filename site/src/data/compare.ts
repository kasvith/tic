import type { NoteColor } from '../components/Note.astro';

// The "X alternative" pages (src/pages/[app]-alternative.astro). One shared feature axis with Tic's
// column, and one column plus hand-written framing per competitor, so every page says something true
// and specific rather than swapping a name into a template. Add a competitor by adding an entry.

export const features: { id: string; label: string; tic: string }[] = [
  { id: 'desktop', label: 'Lives on the desktop', tic: 'Yes, each list is a floating sticky note' },
  { id: 'top', label: 'Keep on top of other windows', tic: 'Yes, per list' },
  { id: 'checkboxes', label: 'Checkboxes', tic: 'One on every task' },
  { id: 'subtasks', label: 'Subtasks', tic: 'Three levels deep. Finish the last subtask and the parent ticks itself' },
  { id: 'dates', label: 'Due dates and reminders', tic: 'No' },
  { id: 'sync', label: 'Sync between devices', tic: 'No, one Mac' },
  { id: 'formatting', label: 'Formatting', tic: 'Inline Markdown: bold, italic, code, strikethrough, links' },
  { id: 'images', label: 'Images', tic: 'Paste with ⌘V, crop in place' },
  { id: 'search', label: 'Search across lists', tic: 'Search Lists from the menu bar' },
  { id: 'done', label: 'Finished tasks', tic: 'Hide them, sink them to the bottom, or clear them in one click' },
  { id: 'look', label: 'Colours', tic: 'Six paper colours, or glass' },
  { id: 'account', label: 'Account', tic: 'None' },
  { id: 'price', label: 'Price', tic: 'Free and open source, MIT license' },
  { id: 'data', label: 'Where your data lives', tic: 'On your Mac, in a SQLite file you can open' },
  { id: 'platforms', label: 'Runs on', tic: 'macOS 14 Sonoma or later, Apple silicon' },
];

export interface Competitor {
  /** URL slug: the page is /<slug>-alternative/. */
  slug: string;
  name: string;
  /** Short name for links. */
  short: string;
  title: string;
  description: string;
  /** The crossed-out line above the H1. */
  strike: string;
  h1: string;
  lede: string;
  /** The "who each one is for" section: a heading and its paragraphs. */
  keep: { heading: string; body: string[] };
  faqs: { q: string; a: string }[];
  /** The competitor's column, keyed by feature id. */
  values: Record<string, string>;
  color: NoteColor;
}

export const competitors: Competitor[] = [
  {
    slug: 'stickies',
    name: 'Apple Stickies',
    short: 'Stickies',
    title: 'A Stickies alternative with checkboxes for Mac | Tic',
    description:
      'Apple Stickies floats on the desktop but has no checkboxes. Tic is a free, open-source Mac app with sticky-note to-do lists that tick off, nest subtasks and stay on top.',
    strike: 'A Stickies note full of dashes',
    h1: 'A Stickies alternative with real checkboxes',
    lede:
      'Apple Stickies is free, built in and floats on the desktop. It’s a fine place for a phone number, but a to-do list in Stickies is a pile of dashes you delete by hand. Tic keeps the sticky-note idea and adds what a list needs: a checkbox on every line, subtasks, and a way to clear what’s done.',
    keep: {
      heading: 'Keep Stickies for notes. Use Tic for lists.',
      body: [
        'Stickies is still the right tool for a snippet you want to glance at: a reference number, an address, a paragraph you’re drafting. Tic doesn’t try to replace that.',
        'Anything with steps belongs in Tic. Each list is its own small note on the desktop, pinned above your work if you want it there. Tick a task and it’s done, not deleted. Nest the small steps under the big one, and the big one ticks itself when the last step is finished. When a list gets long, hide the finished tasks or clear them out.',
        'Everything stays on your Mac in a plain SQLite file. There is no account and no server, the same as Stickies.',
      ],
    },
    faqs: [
      {
        q: 'Is Tic a replacement for Apple Stickies?',
        a: 'For lists, yes. For a paragraph of notes or a phone number, Stickies is still the better scratchpad. The two run side by side.',
      },
      {
        q: 'Can you add checkboxes in Apple Stickies?',
        a: 'Not real ones. You can type ☐ and ☑ symbols from the Character Viewer or make a bulleted list with Option-Tab, but neither can be ticked with a click. Our guide to adding checkboxes in Stickies walks through both.',
      },
      {
        q: 'Can I import my Stickies notes into Tic?',
        a: 'Not automatically. Make a list in Tic with ⌘N, then type or paste each line from the Stickies note and press Return after each one. Shift-Tab nests a line under the one above.',
      },
      {
        q: 'Is Tic free like Stickies?',
        a: 'Yes. Tic is free and open source under the MIT license, with no account and no tracking.',
      },
    ],
    values: {
      desktop: 'Yes, floating notes',
      top: 'Yes, per note',
      checkboxes: 'No, bulleted lists only',
      subtasks: 'No',
      dates: 'No',
      sync: 'No',
      formatting: 'Rich text from the Font menu',
      images: 'Drag them in',
      search: 'No, only within the open note',
      done: 'Delete the line yourself',
      look: 'Six colours, with a translucent option',
      account: 'None',
      price: 'Free, built into macOS',
      data: 'On your Mac',
      platforms: 'Any Mac',
    },
    color: 'yellow',
  },
  {
    slug: 'todoist',
    name: 'Todoist',
    short: 'Todoist',
    title: 'A Todoist alternative that lives on your Mac desktop | Tic',
    description:
      'Todoist is a full task manager with sync and due dates. Tic is a free, open-source Mac app that keeps to-do lists on the desktop as sticky notes, with no account needed.',
    strike: 'One more window to switch to',
    h1: 'A Todoist alternative that stays on the desktop',
    lede:
      'Todoist is a proper task manager: projects, due dates, reminders, and sync to every device you own. It’s also one more window to switch to. Tic is for the list you want in front of you all day. It sits on the desktop as a sticky note, ticks off, nests subtasks, and asks for no account.',
    keep: {
      heading: 'Keep Todoist for the big picture. Put today on the desktop.',
      body: [
        'If you need due dates, reminders, shared projects or a list on your phone, Todoist does that and Tic doesn’t. Tic has no sync, no dates and no account.',
        'What Tic does is keep a short list visible while you work. Make a note for today, or for the thing you’re shipping this week, pin it above your windows, and tick things off without leaving what you’re doing. Plenty of people run both: Todoist as the system, a Tic note as the scratch list on top of it.',
        'Everything Tic stores stays on your Mac in a SQLite file. There’s no server and nothing to sign up for.',
      ],
    },
    faqs: [
      {
        q: 'Does Tic sync like Todoist?',
        a: 'No. Tic keeps every list on one Mac. If you need your tasks on a phone, keep Todoist for those.',
      },
      {
        q: 'Can Tic set due dates or reminders?',
        a: 'Not yet. Tic is a plain list with checkboxes and subtasks. Write the date in the task if you want it there.',
      },
      {
        q: 'Is Tic free?',
        a: 'Yes. Tic is free and open source under the MIT license, with no plan limits and no account.',
      },
    ],
    values: {
      desktop: 'No. A window, plus quick-add from the menu bar',
      top: 'No',
      checkboxes: 'Yes',
      subtasks: 'Yes, several levels',
      dates: 'Yes, with natural-language dates',
      sync: 'Yes, across every platform',
      formatting: 'Markdown in task names and comments',
      images: 'Attach files to comments',
      search: 'Yes, plus saved filters',
      done: 'Hidden once done; can be shown again',
      look: 'Colour-coded projects and themes',
      account: 'Required',
      price: 'Free plan with limits; Pro is a subscription',
      data: 'Todoist’s servers',
      platforms: 'Mac, Windows, Linux, iOS, Android, web',
    },
    color: 'pink',
  },
  {
    slug: 'things-3',
    name: 'Things 3',
    short: 'Things 3',
    title: 'A free Things 3 alternative for your Mac desktop | Tic',
    description:
      'Things 3 is a paid, polished task manager. Tic is a free, open-source Mac app that keeps to-do lists on the desktop as sticky notes, with checkboxes, subtasks and nothing to buy.',
    strike: 'Paying for a place to put a list',
    h1: 'A free Things 3 alternative that lives on the desktop',
    lede:
      'Things 3 is the polished choice for Mac and iPhone: areas, projects, deadlines, and a sync service of its own. It’s also a purchase per device, and a window you have to open. Tic is a free sticky note for the list you’re working through right now. It sits on the desktop, ticks off, and nests subtasks three deep.',
    keep: {
      heading: 'Keep Things for planning. Use Tic for the list in front of you.',
      body: [
        'If you plan in areas and projects, schedule with start dates and deadlines, and want the same list on your iPhone, Things does all of that and Tic doesn’t. Tic has no dates, no sync and no phone app.',
        'Tic is for the short list you want to see all day. Make a note for today, pin it above your work, paste a screenshot under the task it belongs to, and tick things off as you go. Finish the last subtask and the parent ticks itself.',
        'It costs nothing, the code is on GitHub, and your lists live in a SQLite file on your Mac.',
      ],
    },
    faqs: [
      {
        q: 'Is Tic really free?',
        a: 'Yes. Tic is free and open source under the MIT license. There is nothing to buy and no subscription.',
      },
      {
        q: 'Does Tic have an iPhone app?',
        a: 'No. Tic is a Mac app and keeps everything on one Mac.',
      },
      {
        q: 'Can I paste images into Tic?',
        a: 'Yes. Copy an image and press ⌘V. It sits under the task it belongs to and can be cropped in place. Things 3 doesn’t take attachments.',
      },
    ],
    values: {
      desktop: 'No. One window, plus Quick Entry',
      top: 'No',
      checkboxes: 'Yes',
      subtasks: 'One level: checklist items inside a to-do',
      dates: 'Yes: start dates, deadlines, reminders, repeats',
      sync: 'Yes, through Things Cloud',
      formatting: 'Markdown in notes',
      images: 'No attachments',
      search: 'Yes, Quick Find',
      done: 'Moved to the Logbook',
      look: 'Light and dark',
      account: 'Things Cloud account for sync',
      price: 'Paid once per platform: Mac, iPhone and iPad sold separately',
      data: 'On your devices, synced through Things Cloud',
      platforms: 'Mac, iPhone, iPad',
    },
    color: 'blue',
  },
  {
    slug: 'apple-reminders',
    name: 'Apple Reminders',
    short: 'Reminders',
    title: 'An Apple Reminders alternative for your Mac desktop | Tic',
    description:
      'Reminders is free and syncs, but lives in a window. Tic is a free, open-source Mac app that keeps to-do lists on the desktop as sticky notes pinned above your work.',
    strike: 'A list hidden behind ⌘Tab',
    h1: 'An Apple Reminders alternative you can pin above your work',
    lede:
      'Reminders is free, built in and syncs through iCloud, and on macOS 14 it even has a desktop widget. But a widget sits under your windows, and the app is one more thing to open. Tic gives each list its own sticky note you can pin above everything, with subtasks three levels deep and Markdown in every task.',
    keep: {
      heading: 'Keep Reminders for alarms and shared lists. Use Tic for the list on top.',
      body: [
        'Anything that needs a time, a location alert or a list shared with someone else belongs in Reminders. Tic has no dates, no alerts and no sync.',
        'Tic is for the list you want to see while you work. Pin it above your windows, nest the small steps under the big one, paste a screenshot under the task it belongs to, and tick things off. When the note gets long, hide the finished tasks or clear them out.',
        'Tic stores your lists in a SQLite file on your Mac. No account, no iCloud, no tracking.',
      ],
    },
    faqs: [
      {
        q: 'Does Tic sync with iCloud?',
        a: 'No. Tic keeps every list on one Mac, in a file you can open yourself.',
      },
      {
        q: 'Can Tic remind me at a time or place?',
        a: 'No. Tic is a checklist on the desktop, not an alarm. Keep Reminders for anything with a time.',
      },
      {
        q: 'Is Tic free like Reminders?',
        a: 'Yes. Tic is free and open source under the MIT license.',
      },
    ],
    values: {
      desktop: 'No. Desktop widgets on macOS 14, under your windows',
      top: 'No',
      checkboxes: 'Yes',
      subtasks: 'Yes, one level',
      dates: 'Yes, with time and location alerts',
      sync: 'Yes, through iCloud, with shared lists',
      formatting: 'Plain text, with a notes field',
      images: 'Yes, add images to a reminder',
      search: 'Yes, across lists',
      done: 'Hidden by default; Show Completed brings them back',
      look: 'List colours and icons',
      account: 'Apple Account for sync; works without one',
      price: 'Free, built into macOS',
      data: 'iCloud, or on your Mac without it',
      platforms: 'Mac, iPhone, iPad, Apple Watch, iCloud.com',
    },
    color: 'green',
  },
];

export const comparePath = (c: Competitor) => `/${c.slug}-alternative/`;
