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
  tic: { heading: string; body: string[]; note: { title: string; icon?: string; color: NoteColor; tasks: Task[] } };
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
          'It’s Mac only: there’s no iPhone app and no due dates, though it can sync the lists you choose between your Macs. If you need a phone or dates, use Reminders.',
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
        a: 'No. Tic is a Mac app: it keeps your lists in a local SQLite file and can sync the ones you choose between your Macs, but not to a phone. If you need your list on your phone, use Reminders.',
      },
    ],
    compare: ['stickies', 'apple-reminders'],
  },
  {
    slug: 'sync-stickies-between-macs',
    title: 'Can Stickies sync between Macs? | Tic',
    description:
      'Stickies on Mac keeps its notes on one Mac, with no iCloud sync. How to get your notes onto another Mac, why the iCloud Drive trick goes wrong, and sticky notes that do sync.',
    h1: 'Can Stickies sync between two Macs?',
    answer:
      'No. Stickies keeps its notes on the Mac you wrote them on and has no iCloud setting, so a note on your MacBook never shows up on your iMac. You can send your notes to Apple Notes, which syncs through iCloud, or use Tic, a free sticky-note to-do app that syncs the lists you choose between your Macs.',
    published: '2026-11-06',
    modified: '2026-11-06',
    sections: [
      {
        heading: 'Why Stickies doesn’t sync',
        body: [
          'Stickies saves each note as a file in your user Library on that Mac. It has no iCloud option, in the app or in System Settings, so signing in to the same Apple Account on both Macs makes no difference.',
        ],
      },
      {
        heading: 'Send your notes to Notes, which does sync',
        body: [
          'Stickies can copy all its notes into Apple Notes in one go. Notes syncs through iCloud, so they then appear on every Mac signed in to your Apple Account. In Notes they’re ordinary notes, though, not small notes on the desktop, and later edits in Stickies don’t follow them.',
        ],
        steps: [
          'In Stickies, choose File › Export All to Notes, then click Export All. The notes are copied into Notes, in a folder for each note colour, and also stay in Stickies.',
          'On each Mac, open System Settings, click your name, then click iCloud.',
          'On macOS 15 or later, click See All next to Saved to iCloud. On macOS 14, click Show All under Apps Using iCloud. Make sure Notes is turned on.',
        ],
      },
      {
        heading: 'Why not put the Stickies folder in iCloud Drive?',
        body: [
          'Some guides suggest moving Stickies’ folder into iCloud Drive and linking it back. Apple doesn’t offer this, and Stickies expects its files to belong to one Mac. With Stickies open on two Macs, each one saves its own copy of the same notes, so an edit on one Mac can overwrite an edit on the other.',
        ],
      },
    ],
    table: {
      heading: 'Sticky notes that sync between Macs',
      head: ['', 'Stickies', 'Apple Notes', 'Tic'],
      rows: [
        ['Syncs between Macs', 'No', 'Yes, with iCloud', 'Yes, the lists you choose'],
        ['Needs the same Apple Account on both', 'No sync', 'Yes', 'No: any folder both Macs share'],
        ['A note on the desktop', 'Yes', 'No, inside the Notes app', 'Yes'],
        ['Checkboxes', 'No', 'Yes', 'Yes'],
        ['On iPhone', 'No', 'Yes', 'No'],
      ],
    },
    tic: {
      heading: 'Sticky notes that sync: Tic',
      body: [
        'Tic keeps each list as a small note on your desktop, like Stickies, with a checkbox on every line. Turn on sync in Tic’s Settings and choose which lists travel. Tic keeps them in step through iCloud Drive, or through a Dropbox, Google Drive or OneDrive folder if one of your Macs isn’t on your personal iCloud. Each Mac still decides which lists are open and where they sit.',
        'Sync is new and marked experimental. Tic is free and open source, and needs macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'This week',
        color: 'yellow',
        tasks: [
          { t: 'Send slides to Sam', done: true },
          { t: 'Book train home' },
          { t: 'Check Friday times', l: 1 },
          { t: 'Mark essays' },
        ],
      },
    },
    faqs: [
      {
        q: 'Do Stickies sync with iCloud?',
        a: 'No. Stickies has no iCloud setting. Its notes stay on the Mac you wrote them on.',
      },
      {
        q: 'How do I get my Stickies onto another Mac?',
        a: 'In Stickies, choose File › Export All to Notes. The notes are copied into Apple Notes, which syncs through iCloud to every Mac signed in to your Apple Account.',
      },
      {
        q: 'Can Stickies sync to my iPhone?',
        a: 'No. Stickies is Mac only. Notes you export from Stickies into Apple Notes do show up on your iPhone through iCloud.',
      },
      {
        q: 'Is there a sticky-note app for Mac that syncs between Macs?',
        a: 'Tic does. It’s free and open source, and syncs the lists you choose through iCloud Drive or another folder your Macs share. There’s no iPhone app.',
      },
    ],
    compare: ['stickies'],
  },
  {
    slug: 'sync-to-do-list-between-macs',
    title: 'How to sync a to-do list between two Macs | Tic',
    description:
      'Keep the same to-do list on a work Mac and a home Mac: Reminders and Notes through iCloud, what to do when your work Mac isn’t on your iCloud, and a desktop list app that syncs through any shared folder.',
    h1: 'How to sync a to-do list between two Macs',
    answer:
      'If both Macs are signed in to the same Apple Account, Reminders and Notes checklists sync through iCloud on their own. If your work Mac isn’t on your personal iCloud, use an app that syncs through a folder both Macs can reach, such as Dropbox. Tic, a free desktop to-do app, does that for the lists you choose.',
    published: '2026-11-06',
    modified: '2026-11-06',
    sections: [
      {
        heading: 'Reminders, through iCloud',
        body: [
          'Reminders keeps every list in your iCloud account on each Mac, iPhone and iPad signed in to it, with due dates and alerts.',
        ],
        steps: [
          'On each Mac, open System Settings and click your name at the top of the sidebar.',
          'Click iCloud. On macOS 15 or later, click See All next to Saved to iCloud. On macOS 14, click Show All under Apps Using iCloud.',
          'Turn on Reminders, then click Done.',
        ],
      },
      {
        heading: 'A Notes checklist, through iCloud',
        body: [
          'A checklist in Notes syncs the same way: turn on Notes in that same iCloud list. In a note, click the Checklist button or press Shift-Command-L, and each line gets a box you can tick. The list lives inside the Notes app rather than on the desktop.',
        ],
      },
      {
        heading: 'When your work Mac isn’t on your iCloud',
        body: [
          'Both of those need the same Apple Account on both Macs. A work Mac is often signed in to a work account, or set up by your employer with iCloud turned off, and then iCloud can’t carry your list across.',
          'What works instead is a sync app both Macs can run, such as Dropbox, Google Drive or OneDrive, with a list app that keeps its lists in a folder there. Check your employer’s rules before putting work tasks in a personal account.',
        ],
      },
    ],
    table: {
      heading: 'Which one to pick',
      head: ['', 'Reminders', 'Notes checklist', 'Tic'],
      rows: [
        ['Syncs through', 'iCloud', 'iCloud', 'iCloud Drive, or any folder both Macs share'],
        ['Same Apple Account on both Macs', 'Needed', 'Needed', 'Not needed'],
        ['Where the list lives', 'The Reminders app, or a desktop widget', 'Inside the Notes app', 'A sticky note on the desktop'],
        ['Due dates and alerts', 'Yes', 'No', 'No'],
        ['On iPhone', 'Yes', 'Yes', 'No'],
      ],
    },
    tic: {
      heading: 'A desktop list that syncs through any folder: Tic',
      body: [
        'Tic puts each list in a sticky note on your Mac desktop. Turn on sync in Settings, pick a folder both Macs share (iCloud Drive by default, or a Dropbox, Google Drive, OneDrive or Syncthing folder), then switch on sync for the lists you want on both. Lists you don’t switch on stay on their own Mac.',
        'Each Mac keeps its own choice of which lists are open and where they sit, so a laptop and a desktop can look different while holding the same tasks. Sync is new and marked experimental. Tic is free and open source, for macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Home and work',
        color: 'green',
        tasks: [
          { t: 'Renew passport' },
          { t: 'Book dentist', done: true },
          { t: 'Pick up parcel' },
        ],
      },
    },
    faqs: [
      {
        q: 'Do Reminders sync between Macs?',
        a: 'Yes, when both Macs are signed in to the same Apple Account and Reminders is turned on for iCloud on each.',
      },
      {
        q: 'How do I sync a to-do list between a work Mac and a personal Mac?',
        a: 'If the work Mac isn’t signed in to your personal iCloud, use a sync app both Macs can run, such as Dropbox, and a list app that syncs through its folder. Tic does this and lets you choose which lists sync, so work lists can stay on the work Mac.',
      },
      {
        q: 'Does Tic need iCloud to sync?',
        a: 'No. Tic syncs through a folder your Macs share. iCloud Drive is the default, but a Dropbox, Google Drive, OneDrive or Syncthing folder works too, and there’s no Tic account.',
      },
      {
        q: 'Can I sync only some of my lists?',
        a: 'In Tic, yes. Each list has its own Sync switch, and new lists stay on their Mac until you turn it on.',
      },
    ],
    compare: ['apple-reminders', 'todoist'],
  },
  {
    slug: 'claude-to-do-list-mac',
    title: 'How to let Claude manage your to-do list on a Mac | Tic',
    description:
      'Connect Claude Desktop or Claude Code to a to-do list on your Mac desktop with MCP, so Claude can draft lists, add tasks and tick them off while you watch. Setup takes a minute.',
    h1: 'How to let Claude manage your to-do list on a Mac',
    answer:
      'Turn on AI agents in Tic, a free to-do app for the Mac desktop, then add Tic to Claude as an MCP server: paste one block into Claude Desktop’s config file, or run one command for Claude Code. Claude can then create lists, add tasks and tick them off, and every change shows up live in a sticky note on your desktop.',
    published: '2026-11-06',
    modified: '2026-11-06',
    sections: [
      {
        heading: 'Turn on AI agents in Tic',
        steps: [
          'Install Tic and open it.',
          'Press Command-Comma to open Settings, then click AI Agents.',
          'Turn on Allow AI agents to use Tic. It stays off until you do.',
        ],
      },
      {
        heading: 'Add Tic to Claude Desktop',
        steps: [
          'In Tic’s AI Agents tab, choose Claude Desktop from the Client pop-up and click Copy.',
          'In Claude Desktop, open Settings, click Developer, then click Edit Config. This opens claude_desktop_config.json.',
          'Paste the block into the file and save it. If the file already has an mcpServers section, add the tic entry inside it.',
          'Quit Claude Desktop completely and open it again, so it loads the new server.',
        ],
      },
      {
        heading: 'Or add Tic to Claude Code',
        body: ['Claude Code adds MCP servers with one command, and remembers them.'],
        steps: [
          'In Tic’s AI Agents tab, choose Claude Code from the Client pop-up and click Copy.',
          'Paste the command into Terminal and press Return. It looks like: claude mcp add tic -- "/Applications/Tic.app/Contents/MacOS/Tic" --mcp',
        ],
      },
      {
        heading: 'What to ask Claude',
        body: [
          'Ask in plain words. “Plan a weekend in Rome and put it in a new Tic list, with packing as subtasks.” “Add the action items from this meeting to my This week list.” “Tick off what we finished and clear the completed tasks.”',
          'Claude reads and changes your lists through Tic’s tools, and you see each change in the note as it happens. Writing to a note brings it forward without taking your keyboard away from the app you’re in.',
        ],
      },
    ],
    tic: {
      heading: 'Why Tic for this',
      body: [
        'Claude’s list lands where you’ll see it: a sticky note on your desktop that you can tick, edit and reorder yourself, and that’s still there tomorrow. Tic’s MCP server is off until you turn it on and only accepts connections from your own Mac. Tic is free and open source, for macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Rome weekend',
        color: 'green',
        tasks: [
          { t: 'Book flights', done: true },
          { t: 'Find a hotel near the old town' },
          { t: 'Pack' },
          { t: 'Passport', l: 1 },
          { t: 'Chargers', l: 1 },
        ],
      },
    },
    faqs: [
      {
        q: 'Can Claude add tasks to my to-do list on a Mac?',
        a: 'Yes, with an app that offers MCP tools, such as Tic. Turn on AI agents in Tic’s Settings, add Tic to Claude Desktop or Claude Code, and Claude can create lists, add tasks and tick them off.',
      },
      {
        q: 'Does Tic send my lists to Anthropic?',
        a: 'Tic sends nothing anywhere. When Claude reads or changes a list, that list becomes part of your conversation with Claude, like anything else you share in a chat.',
      },
      {
        q: 'Does it work with Claude on my iPhone?',
        a: 'No. Tic’s MCP server runs on your Mac, so it works with Claude Desktop and Claude Code on that Mac.',
      },
      {
        q: 'How do I stop Claude from using Tic?',
        a: 'Turn off Allow AI agents to use Tic in Settings › AI Agents. Claude’s next attempt to use Tic then fails until you turn it back on.',
      },
    ],
    compare: ['todoist', 'things-3'],
  },
  {
    slug: 'coding-agent-to-do-list',
    title: 'Give your coding agent a to-do list on your desktop | Tic',
    description:
      'Let Cursor, VS Code, Codex, Gemini CLI, Zed or Claude Code write its plan as a checklist on your Mac desktop and tick each step off as it works, over MCP. Setup for each client.',
    h1: 'Give your coding agent a to-do list on your desktop',
    answer:
      'Connect your agent to Tic over MCP and ask it to keep its plan in a Tic list. The plan appears as a sticky note on your desktop, and the agent ticks each step off as it finishes, so you can see where it’s up to without scrolling back through the chat. Tic adds itself to Cursor and VS Code in one click, and gives a copy-paste setup for Codex CLI, Gemini CLI, Zed, Windsurf and Claude Code.',
    published: '2026-11-06',
    modified: '2026-11-06',
    sections: [
      {
        heading: 'Connect your agent',
        body: [
          'In Tic, open Settings with Command-Comma, click AI Agents and turn on Allow AI agents to use Tic. Then choose your client from the Client pop-up:',
        ],
        steps: [
          'Cursor: click Add to Cursor, or paste the block into ~/.cursor/mcp.json.',
          'VS Code: click Add to VS Code, or run the code --add-mcp command Tic shows, once, in Terminal. VS Code asks you to trust the server the first time it starts it.',
          'Codex CLI: add the [mcp_servers.tic] block to ~/.codex/config.toml.',
          'Gemini CLI: add the block to ~/.gemini/settings.json.',
          'Zed: add the context_servers block to your Zed settings.',
          'Claude Code: run the claude mcp add command once in Terminal.',
        ],
      },
      {
        heading: 'Ask it to work from a checklist',
        body: [
          'Most coding agents read a project instructions file, such as AGENTS.md, CLAUDE.md or Cursor’s rules. Add a line there so the agent does this every time:',
          '“Before a task with several steps, write the plan as a Tic list named after the task, one step per task and sub-steps nested under it. Tick each step off in Tic as you finish it.”',
        ],
      },
      {
        heading: 'What you see',
        body: [
          'The list opens on your desktop without taking the keyboard from your editor. Each tick appears as the agent makes it, and finishing every sub-step ticks its parent. You can tick, edit or reorder the list yourself too, since it’s the same list the agent reads.',
          'When the work is done, ask the agent to clear the completed tasks, or use Clean Up in the list’s ⋯ options.',
        ],
      },
    ],
    table: {
      heading: 'What the agent can do in Tic',
      head: ['Tool', 'What it does'],
      rows: [
        ['create_note', 'Makes a new list on the desktop, optionally with tasks and subtasks'],
        ['add_tasks', 'Adds tasks to a list, nested up to three levels'],
        ['update_task', 'Edits a task or ticks it; ticking a parent ticks its subtasks'],
        ['move_task', 'Reorders or re-nests a task, keeping its ticks'],
        ['clear_completed', 'Removes the ticked tasks from a list'],
        ['list_notes, get_note', 'Reads your lists and their tasks'],
        ['focus_note', 'Brings a list to the front when it needs your attention'],
        ['set_task_image', 'Attaches a screenshot or image to a task'],
      ],
    },
    tic: {
      heading: 'A plan you can see: Tic',
      body: [
        'Tic keeps each list as a small note on your Mac desktop, so the agent’s plan sits beside your editor instead of in a scrolling chat. Its MCP server is off until you turn it on and runs entirely on your Mac. Tic is free and open source, for macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Add dark mode',
        color: 'purple',
        tasks: [
          { t: 'Read the theme code', done: true },
          { t: 'Add colour tokens', done: true },
          { t: 'Update the components' },
          { t: 'Buttons', l: 1, done: true },
          { t: 'Menus', l: 1 },
          { t: 'Run the tests' },
        ],
      },
    },
    faqs: [
      {
        q: 'Can Cursor keep a to-do list?',
        a: 'Yes, through MCP. Add Tic to Cursor from Tic’s Settings › AI Agents in one click, and Cursor’s agent can create lists in Tic and tick tasks off.',
      },
      {
        q: 'Which coding agents work with Tic?',
        a: 'Cursor, VS Code, Claude Code, Codex (the CLI, the IDE extension and the ChatGPT desktop app, which share one config), Gemini CLI, Windsurf and Zed. Tic’s Settings shows the setup for each, and most other MCP clients accept the standard block it gives too.',
      },
      {
        q: 'Does Tic need an account or an API key?',
        a: 'No. Tic’s MCP server runs on your Mac and only takes connections from it. There’s nothing to sign up for.',
      },
      {
        q: 'Can the agent delete my tasks?',
        a: 'It can, if you ask it to: deleting tasks and lists is one of Tic’s tools, and it can’t be undone. Tic’s writes are the same ones you’d make yourself, and you can turn agents off in Settings › AI Agents at any time.',
      },
    ],
    compare: ['todoist'],
  },
  {
    slug: 'mcp-to-do-list',
    title: 'What is an MCP to-do list? | Tic',
    description:
      'MCP lets AI assistants use your apps. An MCP to-do list is one that Claude, Cursor or another agent can read and update. What it can do, what stays private, and how to set one up on a Mac.',
    h1: 'What is an MCP to-do list?',
    answer:
      'MCP, the Model Context Protocol, is an open standard that lets AI assistants use tools in other apps. An MCP to-do list is a list app that offers those tools, so an assistant like Claude or Cursor can read your lists, add tasks and tick them off when you ask. Tic is a free one for the Mac desktop: its lists are sticky notes, and the assistant’s changes show up in them live.',
    published: '2026-11-06',
    modified: '2026-11-06',
    sections: [
      {
        heading: 'How it works',
        body: [
          'An MCP client, such as Claude Desktop, Claude Code, Cursor or VS Code, starts the app’s MCP server and asks which tools it has. When you ask for something like “add oat milk to my groceries list”, the assistant picks a tool, here add_tasks, and the app makes the change.',
          'With Tic, the client starts Tic with an --mcp switch, which passes each request to the Tic app that’s already running. That’s why a change appears in your note the moment the assistant makes it.',
        ],
      },
      {
        heading: 'What an assistant can do with your lists',
        body: [
          'Turn a plan into a list, with subtasks nested up to three levels. Add tasks, edit them and tick them off. Reorder tasks, clear the finished ones, attach an image to a task, or bring a list to the front. It can also read every list, so it can answer “what’s left on my list for today?”',
        ],
      },
      {
        heading: 'What stays private',
        body: [
          'Tic’s MCP server is off until you turn it on in Settings › AI Agents. It listens only on your Mac, through a local socket that only your user account can open, and Tic itself sends nothing over the network.',
          'The assistant does see the lists it reads or changes. Those become part of your conversation with it, like anything else you share in a chat.',
        ],
      },
      {
        heading: 'Set one up on your Mac',
        steps: [
          'Install Tic and open it.',
          'Press Command-Comma to open Settings, click AI Agents and turn on Allow AI agents to use Tic.',
          'Choose your assistant from the Client pop-up and follow the setup it shows: one click for Cursor and VS Code, a command for Claude Code, a block to paste for the others.',
          'Restart the assistant if it asks you to, then ask it to make you a list.',
        ],
      },
    ],
    table: {
      heading: 'A list in the chat, or an MCP to-do list',
      head: ['', 'A list the assistant writes in the chat', 'An MCP to-do list'],
      rows: [
        ['Where it lives', 'In the conversation', 'In your list app, on your desktop'],
        ['Ticked off as work gets done', 'No, you ask for a new version', 'Yes, the assistant ticks it'],
        ['You can edit it too', 'Only by copying it out', 'Yes, it’s the same list'],
        ['Still there next week', 'Somewhere in your chat history', 'In your lists'],
      ],
    },
    tic: {
      heading: 'An MCP to-do list for the Mac desktop: Tic',
      body: [
        'Each Tic list is a sticky note on your desktop, with a checkbox on every task, subtasks and Markdown. Its MCP server works with Claude Desktop, Claude Code, Cursor, VS Code, Codex CLI, Gemini CLI, Windsurf and Zed, and is off until you turn it on. Tic is free and open source, for macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Today',
        color: 'blue',
        tasks: [
          { t: 'Reply to the design review', done: true },
          { t: 'Draft the launch post' },
          { t: 'Outline', l: 1, done: true },
          { t: 'First draft', l: 1 },
          { t: 'Book the dentist' },
        ],
      },
    },
    faqs: [
      {
        q: 'What does MCP stand for?',
        a: 'Model Context Protocol. It’s an open standard for connecting AI assistants to the tools and data in other apps.',
      },
      {
        q: 'Which AI apps can use an MCP to-do list?',
        a: 'Any MCP client that can start a server on your Mac. Tic shows the setup for Claude Desktop, Claude Code, Cursor, VS Code, Codex (which the ChatGPT desktop app shares), Gemini CLI, Windsurf and Zed, plus a standard block most other clients accept. ChatGPT on the web only connects to servers on the internet, so it can’t use Tic.',
      },
      {
        q: 'Is it safe to let an AI edit my to-do list?',
        a: 'The assistant can only use the tools the app offers, and only while you have it turned on. In Tic those include deleting tasks and lists, which can’t be undone, so it’s worth reading what the assistant plans to do before it does it.',
      },
      {
        q: 'Do I need an account or an API key?',
        a: 'Not for Tic. Its MCP server runs on your Mac with nothing to sign up for. Your AI assistant may need its own account.',
      },
    ],
    compare: ['todoist', 'things-3', 'apple-reminders'],
  },
  {
    slug: 'chatgpt-codex-to-do-list',
    title: 'How to connect ChatGPT and Codex to your to-do list on a Mac | Tic',
    description:
      'Let OpenAI’s Codex and the ChatGPT desktop app create lists, add tasks and tick them off in sticky notes on your Mac desktop, over MCP. One setup covers the Codex CLI, the Codex IDE extension and the ChatGPT desktop app.',
    h1: 'How to connect ChatGPT and Codex to a to-do list on your Mac',
    answer:
      'Add Tic to Codex’s config.toml file, or run one codex mcp add command, and Codex can create lists, add tasks and tick them off in sticky notes on your desktop. The ChatGPT desktop app, the Codex CLI and the Codex IDE extension all read that same file, so one setup covers all three. ChatGPT on the web can’t connect: it only uses MCP servers on the internet, and Tic’s runs on your Mac.',
    published: '2026-11-06',
    modified: '2026-11-06',
    sections: [
      {
        heading: 'Turn on AI agents in Tic',
        steps: [
          'Install Tic and open it.',
          'Press Command-Comma to open Settings, then click AI Agents.',
          'Turn on Allow AI agents to use Tic. It stays off until you do.',
        ],
      },
      {
        heading: 'Add Tic to Codex',
        body: ['Codex keeps its MCP servers in ~/.codex/config.toml. Either paste Tic’s block into that file or let Codex add it for you.'],
        steps: [
          'In Tic’s AI Agents tab, choose Codex CLI from the Client pop-up and click Copy.',
          'Open ~/.codex/config.toml in a text editor (create it if it isn’t there), paste the [mcp_servers.tic] block and save.',
          'Or skip the file and run this once in Terminal: codex mcp add tic -- "/Applications/Tic.app/Contents/MacOS/Tic" --mcp',
        ],
      },
      {
        heading: 'ChatGPT on your Mac, and on the web',
        body: [
          'The ChatGPT desktop app reads the same Codex configuration, so once Tic is in config.toml there’s nothing more to set up there. The same goes for the Codex IDE extension in VS Code and similar editors.',
          'ChatGPT in a browser is different. It doesn’t read files on your Mac and only connects to MCP servers on the internet, so it can’t reach Tic.',
        ],
      },
      {
        heading: 'What to ask',
        body: [
          'Ask in plain words: “Make a Tic list for this release, with the checks as subtasks.” “Add these three bugs to my This week list.” “Tick off the steps you’ve finished.”',
          'For coding work, Codex reads an AGENTS.md file in your project. Add a line there, such as “Keep your plan for multi-step tasks in a Tic list and tick each step off as you finish it”, and Codex will keep a checklist on your desktop as it works.',
        ],
      },
    ],
    table: {
      heading: 'Which OpenAI apps can use Tic',
      head: ['', 'Uses Tic', 'How'],
      rows: [
        ['Codex CLI', 'Yes', 'The [mcp_servers.tic] block in ~/.codex/config.toml, or codex mcp add'],
        ['Codex IDE extension', 'Yes', 'The same config.toml'],
        ['ChatGPT desktop app', 'Yes', 'The same config.toml'],
        ['ChatGPT on the web', 'No', 'It only connects to MCP servers on the internet'],
      ],
    },
    tic: {
      heading: 'A to-do list Codex can tick: Tic',
      body: [
        'Each Tic list is a sticky note on your Mac desktop, with a checkbox on every task and subtasks three levels deep. When Codex changes a list you see it straight away, and you can tick, edit or reorder it yourself. Tic’s MCP server is off until you turn it on and only accepts connections from your own Mac. Tic is free and open source, for macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Release 2.4',
        color: 'pink',
        tasks: [
          { t: 'Bump the version', done: true },
          { t: 'Run the checks' },
          { t: 'Unit tests', l: 1, done: true },
          { t: 'UI tests', l: 1 },
          { t: 'Write the release notes' },
        ],
      },
    },
    faqs: [
      {
        q: 'Can ChatGPT add tasks to my to-do list?',
        a: 'The ChatGPT desktop app on a Mac can, through the same Codex configuration as the Codex CLI: add Tic to ~/.codex/config.toml. ChatGPT on the web can’t, because it only connects to MCP servers on the internet.',
      },
      {
        q: 'Does Codex support MCP?',
        a: 'Yes. Codex reads MCP servers from ~/.codex/config.toml (or a .codex/config.toml in a trusted project), and codex mcp add adds one from Terminal.',
      },
      {
        q: 'Where is Codex’s MCP config file?',
        a: 'At ~/.codex/config.toml in your home folder. Each server is a [mcp_servers.<name>] table; Tic’s Settings › AI Agents gives you the block to paste.',
      },
      {
        q: 'Do I need an OpenAI API key for Tic?',
        a: 'Not for Tic. Its MCP server runs on your Mac with nothing to sign up for. Codex and ChatGPT need their own sign-in, as usual.',
      },
    ],
    compare: ['todoist'],
  },
  {
    slug: 'sticky-note-over-full-screen-app',
    title: 'How to keep a sticky note on top of a full-screen app on Mac | Tic',
    description:
      'Stickies’ Float on Top can’t reach an app in full screen, which runs in its own space. Two workarounds, and a free sticky note that stays over full-screen apps.',
    h1: 'How to keep a sticky note on top of a full-screen app on Mac',
    answer:
      'Stickies can’t do it. Window › Float on Top keeps a note in front of other windows, but an app in full screen moves into its own space, and a Stickies note doesn’t appear there. Maximise the app instead of going full screen, or use Tic, a free sticky-note to-do app whose pinned lists can stay over full-screen apps.',
    published: '2026-11-24',
    modified: '2026-11-24',
    sections: [
      {
        heading: 'Why a floating Stickies note vanishes in full screen',
        body: [
          'In Stickies, Window › Float on Top keeps a note in front of your other windows. That works on your desktop, but full screen happens somewhere else. When you click an app’s green button, macOS gives the app its own space, just as a second desktop is its own space.',
          'A Stickies note belongs to the desktop it sits on and isn’t set to show on any other space. Floating or not, it stays behind when you switch to the full-screen app, and it’s still there when you swipe back.',
        ],
      },
      {
        heading: 'Maximise the app instead of going full screen',
        body: [
          'A maximised window fills the screen but stays on your desktop, with the menu bar and Dock still showing. A floating note stays in front of it.',
        ],
        steps: [
          'If the app is in full screen, hold the pointer over the green button in the top-left corner of the window and choose Exit Full Screen.',
          'On macOS 15 or later, hold the pointer over the green button and click Fill, or press Fn-Control-F. On macOS 14, hold Option and click the green button.',
          'Click your Stickies note and choose Window › Float on Top. Choose Window › Translucent as well if you want to see the app through the note.',
        ],
      },
      {
        heading: 'Or put your list beside the app in Split View',
        body: [
          'Split View shows two apps side by side, both in full screen, in a space of their own. If your list is in another app’s window, you can keep it next to your work there. Each app gets only part of the screen, though.',
        ],
        steps: [
          'Hold the pointer over the green button of the app you’re working in. On macOS 15 or later, choose Full Screen › Left of Screen or Right of Screen. On macOS 14, choose Tile Window to Left of Screen or Tile Window to Right of Screen.',
          'On the other side of the screen, click the window with your list.',
          'Drag the bar between the two windows to make your list’s side narrower.',
        ],
      },
      {
        heading: 'Keep a Tic list on top of full-screen apps',
        body: [
          'Tic can do what Stickies can’t. Each list is its own sticky note, and a pinned list can stay in view over apps in full screen.',
        ],
        steps: [
          'Hover over the list’s header and click the pin. The list now stays above your other windows.',
          'Click ⋯ in the header and turn on Over full-screen apps. The switch appears only while the list is pinned.',
          'Put any app in full screen. The list stays on top of it, and on every desktop. Unpin the list later and it goes back to its own desktop.',
        ],
      },
    ],
    table: {
      heading: 'Stickies and Tic over other apps',
      head: ['', 'Stickies', 'Tic'],
      rows: [
        ['Keep a note in front of other windows', 'Window › Float on Top', 'Pin the list'],
        ['In front of a maximised window', 'Yes', 'Yes'],
        ['In front of an app in full screen', 'No', 'Yes, with Over full-screen apps'],
        ['Checkboxes', 'No', 'Yes'],
        ['Price', 'Free, built in', 'Free and open source'],
      ],
    },
    tic: {
      heading: 'A sticky note that stays over full-screen apps: Tic',
      body: [
        'Tic keeps the Stickies idea, small notes on your desktop, and makes each one a to-do list with a checkbox on every line, subtasks and Markdown. Pin a list, turn on Over full-screen apps, and it stays in view whatever you have in full screen, from your slides to your code editor.',
        'Lists folded into tabs at the edge of the screen can come along too: turn on Show tabs over full-screen apps in Settings › General › Docked tabs. It’s off until you turn it on. Tic is free and open source, and needs macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Release day',
        icon: '🚀',
        color: 'purple',
        tasks: [
          { t: 'Merge the release branch', done: true },
          { t: 'Tag <code>v2.4.0</code>', done: true },
          { t: 'Watch the deploy' },
          { t: 'Error rates', l: 1 },
          { t: 'Sign-ups', l: 1 },
          { t: 'Post the changelog' },
        ],
      },
    },
    faqs: [
      {
        q: 'Does Stickies’ Float on Top work over full-screen apps?',
        a: 'No. Float on Top keeps a note in front of other windows on its desktop, but an app in full screen runs in its own space, and Stickies notes don’t appear there.',
      },
      {
        q: 'Why does my sticky note disappear when I go full screen?',
        a: 'Full screen moves the app into its own space, separate from your desktop. The note hasn’t gone anywhere. Swipe left or right with three or four fingers on the trackpad, or press Control with the Left or Right Arrow key, to get back to it.',
      },
      {
        q: 'How do I make an app fill the screen without going full screen?',
        a: 'Maximise it. On macOS 15 or later, hold the pointer over the green button and click Fill, or press Fn-Control-F. On macOS 14, Option-click the green button. The menu bar and Dock stay visible, and a floating note stays in front.',
      },
      {
        q: 'Can a Tic list stay on top of a full-screen app?',
        a: 'Yes. Click the pin on the list, then turn on Over full-screen apps in its ⋯ options. Lists docked at the screen edge can do the same with Show tabs over full-screen apps in Settings › General.',
      },
      {
        q: 'What do I need to run Tic?',
        a: 'A Mac with Apple silicon and macOS 14 Sonoma or later. Tic is free and open source under the MIT license, and installs with one Terminal command from tic.kasvith.me.',
      },
    ],
    compare: ['stickies'],
  },
  {
    slug: 'sticky-notes-screen-edge-mac',
    title: 'How to keep sticky notes at the side of your Mac screen | Tic',
    description:
      'Stickies can’t tuck a note into the edge of your Mac screen. How to collapse and float a note instead, what Stage Manager does, and lists that dock to the side.',
    h1: 'How to keep sticky notes at the side of your Mac screen',
    answer:
      'Stickies can’t dock a note to the edge of the screen. The nearest you get is to double-click a note’s title bar to collapse it, drag it to the side, and choose Window › Float on Top so it stays in front of your other windows. For a list that folds into the edge and slides out when you click it, use Tic, a free sticky-note to-do app for Mac.',
    published: '2026-11-24',
    modified: '2026-11-24',
    sections: [
      {
        heading: 'Collapse a Stickies note and park it at the side',
        body: ['Stickies has no way to tuck a note into the edge of the screen, but you can shrink a note down and keep it there.'],
        steps: [
          'Double-click the note’s title bar. The note collapses, and its first line shows in the title bar.',
          'Drag the note by its title bar to the side of the screen.',
          'Choose Window › Float on Top so the note stays in front of your other windows.',
          'To read or edit the note, double-click the title bar to expand it, then double-click again to collapse it.',
          'With several notes, choose Window › Arrange By, then choose an option to group them.',
        ],
      },
      {
        heading: 'What a collapsed note can’t do',
        body: [
          'A collapsed note is still a bar on your screen, not something folded into the edge. With Float on Top it sits over whatever is under it, and without it other windows cover the note.',
          'It also doesn’t put itself away: a note you expand stays open until you double-click it again. Float on Top is set one note at a time, and a Stickies note is plain text, with nothing to tick.',
        ],
        link: { href: '/guides/stickies-checkboxes/', label: 'How to add checkboxes in Stickies' },
      },
      {
        heading: 'Stage Manager keeps apps at the side, not notes',
        body: [
          'Stage Manager, built into macOS, lines up your recently used apps along the left side of the screen and puts the window you’re working in at the centre. Click an app on the left to switch to it. If you turn off Show recent apps in Stage Manager, they stay hidden until you move the pointer to the left edge of the screen.',
          'It arranges every app on your Mac, though, rather than giving one note a spot at the edge. To try it, choose Apple menu › System Settings, click Desktop & Dock, then turn on Stage Manager.',
        ],
      },
    ],
    table: {
      heading: 'Stickies or Tic at the side of the screen',
      head: ['', 'Stickies, collapsed', 'Tic, docked'],
      rows: [
        ['What stays at the side', 'The note’s title bar, wherever you drag it', 'A thin sliver in the list’s colour, in the left or right edge'],
        ['In front of other windows', 'With Window › Float on Top, set per note', 'Yes, on top of every window'],
        ['What you see at a glance', 'The note’s first line', 'Point at it: the list’s name, icon and open tasks'],
        ['Open it', 'Double-click the title bar', 'Click the tab'],
        ['Put it away', 'Double-click the title bar again', 'It goes back by itself when you move on, or press Esc'],
        ['Checkboxes', 'No', 'Yes'],
      ],
    },
    tic: {
      heading: 'Lists that dock to the edge: Tic',
      body: [
        'Tic makes each to-do list its own sticky note, and any list can fold into the side of the screen. Drag it by its header to the left or right edge of a display, including the edge between two displays, and it folds into a tab. Or choose Dock to Edge from the list’s ⋯ menu to send it to the nearer edge.',
        'A docked list rests as a thin sliver in its colour, on top of every window, so nothing hides it. Point at it and it slides out into a tab with the list’s name, its icon and how many tasks are open. Click the tab and the list opens at full size with the cursor already in Add a task: click, type, Return, and get on with your work. It slides back a second after the pointer leaves, unless you’ve typed something you haven’t added yet, or straight away with Esc, the →| button in its header, or a click anywhere else.',
        'Drag a tab along the edge to move it; tabs on one edge stack. To undock a list, drag it away from the edge or choose Undock from its ⋯ menu. For a list you’d rather leave where it is, double-click its title to roll it up to a bar, as in Stickies. Tic is free and open source, and needs macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Follow-ups',
        icon: '📌',
        color: 'pink',
        tasks: [
          { t: 'Send Sam the <strong>contract</strong>', done: true },
          { t: 'Call the bank back' },
          { t: 'Book the team lunch' },
          { t: 'Check dietary needs', l: 1 },
        ],
      },
    },
    faqs: [
      {
        q: 'Can Stickies notes dock to the side of the screen?',
        a: 'No. Stickies has no dock or edge feature. You can collapse a note by double-clicking its title bar, drag it to the side, and choose Window › Float on Top to keep it in front of other windows.',
      },
      {
        q: 'How do I collapse a sticky note on a Mac?',
        a: 'In Stickies, double-click the note’s title bar. The note collapses and shows its first line in the title bar. Double-click the title bar again to expand it.',
      },
      {
        q: 'Does Stage Manager keep windows at the side of the screen?',
        a: 'It keeps your recently used apps along the left side of the screen, with the window you’re working in at the centre, and you click an app to switch to it. It works with whole apps, not single notes.',
      },
      {
        q: 'Can a docked Tic list show over full-screen apps?',
        a: 'Yes, if you turn it on. In Tic’s Settings › General › Docked tabs, turn on Show tabs over full-screen apps. It’s off by default.',
      },
      {
        q: 'How do I undock a list in Tic?',
        a: 'Drag the tab or the open list away from the edge, click the lit dock button in the open list’s header, or choose Undock from the list’s ⋯ menu. You can also right-click the tab and choose Undock.',
      },
    ],
    compare: ['stickies'],
  },
  {
    slug: 'emoji-in-sticky-notes-mac',
    title: 'How to add emoji to sticky notes on Mac | Tic',
    description:
      'Add emoji to a Stickies note with Control-Command-Space or Globe-E, use one as the note’s label, and give each to-do list in Tic its own emoji or symbol icon.',
    h1: 'How to add emoji to sticky notes on Mac',
    answer:
      'Click in a Stickies note and press Control-Command-Space, or Fn-E or Globe-E, to open the Character Viewer. Search for an emoji and click it. In Stickies an emoji is just text, and notes have no title or icon, so an emoji at the start of the first line is the nearest thing to a label. Tic, a free sticky-note to-do app, gives each list its own emoji or symbol icon.',
    published: '2026-11-24',
    modified: '2026-11-24',
    sections: [
      {
        heading: 'Add an emoji to a Stickies note',
        steps: [
          'Click in your Stickies note where the emoji should go.',
          'Press Control-Command-Space, or Fn-E or Globe-E, or choose Edit › Emoji & Symbols. The Character Viewer opens.',
          'Type a word such as “heart” or “star” in its search field.',
          'Click an emoji to add it to the note. If the viewer is expanded to its full window, double-click it instead.',
        ],
      },
      {
        heading: 'Faster: type the word, then press Fn-E',
        body: [
          'Type a common word such as heart or thumbs up, then press Fn-E or Globe-E. macOS suggests matching emoji. Press Return to replace the word with the suggested emoji, or choose another suggestion. If nothing matches, the Character Viewer opens instead.',
          'To open the viewer with a single key, open System Settings, click Keyboard, and set “Press fn key to” or “Press Globe key to” to Show Emoji & Symbols.',
        ],
      },
      {
        heading: 'Use an emoji as a note’s label',
        body: [
          'Stickies notes have no title or icon of their own. When you collapse a note by double-clicking its title bar, the title bar shows the note’s first line. Start that line with an emoji, such as 🛒 Groceries, and you can tell your collapsed notes apart at a glance.',
        ],
      },
      {
        heading: 'What an emoji in Stickies can’t do',
        body: [
          'An emoji in Stickies is a character in the note’s text, like any letter. No setting makes it the note’s icon, so your label is whatever sits at the start of the first line, and editing that line can delete it.',
          'The Character Viewer also has ☐ and ☑ symbols, which make a note look like a checklist, but you can’t tick them with a click.',
        ],
        link: { href: '/guides/stickies-checkboxes/', label: 'How to add checkboxes in Stickies' },
      },
    ],
    table: {
      heading: 'Emoji in Stickies and in Tic',
      head: ['', 'Stickies', 'Tic'],
      rows: [
        ['Emoji in the text', 'Yes, from the Character Viewer', 'Yes, in any task'],
        ['An icon for each note', 'No. Start the first line with an emoji', 'Yes, an emoji or one of 12 symbols'],
        ['Where the label shows', 'In the text, and in the title bar when the note is collapsed', 'Before the title, on the rolled-up bar and on the docked tab'],
        ['Checkboxes', 'No', 'One on every task'],
        ['Price', 'Free, built in', 'Free and open source'],
      ],
    },
    tic: {
      heading: 'An emoji or a symbol for every list: Tic',
      body: [
        'In Tic each to-do list is its own sticky note, and each one can have an icon. Open the list’s ⋯ options, choose Icon, and pick from the Emoji or Symbols tab. The icon sits before the list’s title, stays on the bar when you roll the list up, and shows on the list’s tab when you dock it at the edge of the screen.',
        'Emoji keep their own colours. The 12 symbols, from a shopping cart and a light bulb to a calendar and a gift, are drawn in the list’s own ink, so they match the note. Emoji you’ve picked lately come first in every list’s picker. All emoji… opens the macOS Emoji & Symbols viewer for any other emoji, and Remove clears the icon.',
        'If you sync a list between your Macs, its icon goes with it, and an AI agent connected over MCP can set a list’s icon. Tasks can hold emoji too, like any text. Tic is free and open source, and needs macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Groceries',
        icon: '🛒',
        color: 'green',
        tasks: [
          { t: 'Oat milk', done: true },
          { t: 'Bread' },
          { t: 'Birthday party 🎂' },
          { t: 'Candles', l: 1, done: true },
          { t: 'Balloons', l: 1 },
        ],
      },
    },
    faqs: [
      {
        q: 'How do I type emoji on a Mac?',
        a: 'Press Control-Command-Space, or Fn-E or Globe-E, or choose Edit › Emoji & Symbols in the app you’re typing in. Search for the emoji in the Character Viewer and click it to add it.',
      },
      {
        q: 'Can one key open the emoji picker on a Mac?',
        a: 'Yes. Open System Settings, click Keyboard, and set “Press fn key to” or “Press Globe key to” to Show Emoji & Symbols. Pressing that key then opens the Character Viewer.',
      },
      {
        q: 'Can a Stickies note have a title or an icon?',
        a: 'No. A Stickies note is just its text. When you collapse a note, its title bar shows the first line, so an emoji at the start of that line works as a label.',
      },
      {
        q: 'Can I give a to-do list an icon on a Mac?',
        a: 'In Tic, yes. Choose Icon in a list’s ⋯ options, then pick an emoji or one of 12 symbols drawn in the list’s ink. Tic is free and open source, and installs with one Terminal command from tic.kasvith.me.',
      },
      {
        q: 'Can I put emoji inside tasks in Tic?',
        a: 'Yes. A task is text, so you can add emoji with Control-Command-Space, the same as anywhere else on your Mac.',
      },
    ],
    compare: ['stickies'],
  },
  {
    slug: 'hide-notes-when-screen-sharing-mac',
    title: 'How to hide sticky notes when screen sharing on a Mac | Tic',
    description:
      'Keep sticky notes out of a Zoom, Teams or Google Meet screen share on Mac: share one window, hide Stickies with Command-H, or cover private lists in Tic.',
    h1: 'How to hide sticky notes when screen sharing on a Mac',
    answer:
      'Share one window instead of your entire screen. Zoom, Microsoft Teams and Google Meet all let you pick a single window, so the call sees that window rather than your desktop and the notes on it. If you have to share the whole screen, click a Stickies note and press Command-H to hide every note first. Tic, a free sticky-note to-do app, can also mark lists private and cover them while you share.',
    published: '2026-11-24',
    modified: '2026-11-24',
    sections: [
      {
        heading: 'Share one window, not your whole screen',
        body: [
          'When you share your entire screen, everyone on the call sees everything you see, sticky notes included. Zoom, Teams and Meet each let you share a single window instead.',
          'The first time you share, macOS asks you to let the app record your screen (for Meet, your browser). If you missed the prompt, allow it in System Settings › Privacy & Security.',
        ],
        steps: [
          'Zoom: click Share in the meeting controls. On the Screens tab, choose the window of the app you want to show rather than your screen, then click Share. Hold Shift to pick more than one app.',
          'Microsoft Teams: select Share in the meeting controls, then choose a window instead of your entire screen.',
          'Google Meet: click Present now at the bottom, choose A window or A tab instead of Your entire screen, then click Share.',
        ],
      },
      {
        heading: 'Or use the share menu built into macOS',
        body: ['On macOS 15 Sequoia or later, depending on your Mac model, macOS has its own screen-sharing menu for video calls.'],
        steps: [
          'Start a call in FaceTime, or another video app that supports macOS’s screen sharing.',
          'Click the Video status menu in the menu bar, then click the Screen Share icon.',
          'Hold the pointer over the window you want to show and click Share This Window. Click Stop Sharing when you’re done.',
        ],
      },
      {
        heading: 'Sharing the whole screen? Hide Stickies first',
        body: [
          'Sometimes you need the whole screen, say to move between apps in a demo. Then hide the notes before you start. It works for any app, but the notes vanish for you too, so a list you wanted to glance at during the call goes with them.',
        ],
        steps: [
          'Click any Stickies note so Stickies is the front app.',
          'Press Command-H. macOS hides all of Stickies’ windows, so every note goes at once.',
          'Or click the app you’re about to show and press Option-Command-H, which hides every other app, Stickies included.',
          'After the call, switch back to Stickies to see your notes again.',
        ],
      },
      {
        heading: 'Keep notifications out of the share too',
        body: [
          'A message banner can pop up mid-share just as easily as a note can sit on the screen. macOS can pause notifications while you share: open System Settings, click Notifications, and under Notification Center turn off notifications when mirroring or sharing the display.',
        ],
      },
    ],
    tic: {
      heading: 'Private lists in Tic',
      body: [
        'Tic puts each to-do list in its own sticky-note window, with real checkboxes, subtasks and Markdown, and lets you mark the lists nobody else should see. Switch on Private in a list’s ⋯ options, or turn on Treat every list as private in Settings › General. A dim lock after the title marks a private list, and the setting travels with the list if you sync it between Macs.',
        'A private list’s window, and any picture you open from it, is marked to be left out of screen captures, and capture tools that honour that mark leave it out of screenshots and shares. Not every tool does: on macOS 15.4 and later, reports say macOS’s newer capture system ignores it. So before you share your whole screen, choose Cover Private Lists from Tic’s menu bar menu, and every private list shows a plain Private cover instead of its title, icon and tasks. Tic can’t yet tell when a share starts, so you switch the cover on yourself, and off again after the call.',
        'Tic is free and open source, and needs macOS 14 Sonoma or later on Apple silicon.',
      ],
      note: {
        title: 'Before the call',
        icon: '🎥',
        color: 'pink',
        tasks: [
          { t: 'Close personal tabs', done: true },
          { t: 'Turn on Cover Private Lists', done: true },
          { t: 'Share the demo' },
          { t: 'One window, not the screen', l: 1, done: true },
          { t: 'Notifications off', l: 1 },
        ],
      },
    },
    faqs: [
      {
        q: 'Can people see my sticky notes when I share my screen?',
        a: 'Yes, if you share your entire screen and the notes are on it. Share a single window instead, or hide Stickies with Command-H before you start.',
      },
      {
        q: 'How do I hide Stickies on a Zoom call?',
        a: 'Share the app’s window instead of your screen: click Share, then choose that window on the Screens tab. If you need the whole screen, click a Stickies note and press Command-H first.',
      },
      {
        q: 'Does Command-H close my Stickies notes?',
        a: 'No. It hides Stickies’ windows without quitting the app, and the notes stay as they were. Switch back to Stickies to see them again.',
      },
      {
        q: 'Does Tic hide itself from screen shares automatically?',
        a: 'Not reliably. A private list’s window is marked to be left out of captures, which some share tools honour, but on macOS 15.4 and later reports say macOS’s newer capture system ignores the mark. Tic can’t yet tell when a share starts, so switch on Cover Private Lists from its menu bar menu before you share.',
      },
      {
        q: 'Can I stop notifications appearing while I share my screen?',
        a: 'Yes. In System Settings › Notifications, under Notification Center, turn off notifications when mirroring or sharing the display.',
      },
    ],
    compare: ['stickies'],
  },
];

export const guidePath = (g: Guide) => `/guides/${g.slug}/`;
