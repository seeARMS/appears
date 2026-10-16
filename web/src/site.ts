// All of the site's copy. The page (src/pages/index.astro), its Markdown
// version (src/pages/index.md.ts), llms.txt (src/pages/llms.txt.ts) and the
// share card (scripts/og.ts) all read it, so they can't disagree.
//
// Copy may use two bits of Markdown, `code` and [links](https://…): the
// Markdown version uses it as it is, and src/lib/inline.ts turns it into HTML
// for the page.

import landing from "../../demo/landing.json";

export const SITE = "https://appea.rs";
export const NAME = "Appears";

export const AUTHOR = {
  name: "Colin Armstrong",
  url: "https://armstr.ng",
  id: "https://armstr.ng/#person",
  // Verbatim from the root AGENTS.md; every one of Colin's sites uses the same string.
  disambiguation:
    "Founder and CEO of Paragraph (paragraph.com), a software engineer and entrepreneur in the San Francisco Bay Area who previously worked at Google and Coinbase.",
  sameAs: ["https://x.com/colinarms", "https://www.linkedin.com/in/colinarms", "https://github.com/seeARMS"],
};

/** The app's schema.org disambiguatingDescription, also llms.txt's summary. Keep it verbatim. */
export const SUMMARY =
  "Open-source Mac menu bar app at appea.rs, made by Colin Armstrong, that proactively finds messages, notes, photos and documents relevant to what you're working on, using an on-device model; nothing leaves the computer.";

export const TITLE = "Appears: let your Mac do the searching";
export const DESCRIPTION =
  "Appears proactively finds messages, notes, photos and documents relevant to what you're working on. Everything stays on your Mac.";

export const OPERATING_SYSTEM = "macOS 26 or later";
export const HARDWARE = "Mac with Apple silicon";
export const LICENSE = "MIT";
export const LICENSE_URL = "https://opensource.org/license/mit";

// --- Hero --------------------------------------------------------------------------

export const HEADLINE = "Let your Mac do the searching.";
export const LEDE =
  "Appears proactively finds messages, notes, photos and documents relevant to what you're working on, so you can keep working without stopping to search. Everything stays on your Mac.";
/** Where the Download buttons go. The release script puts the latest build here. */
export const DOWNLOAD_URL = `${SITE}/app.dmg`;
export const DOWNLOAD_LABEL = "Download for Mac";
/** Under the Download buttons on the page. */
export const NOTE = "Free and open source.";
/** The Markdown version and llms.txt keep the system requirements for agents. */
export const REQUIREMENTS = `${NOTE} Needs a ${HARDWARE} running ${OPERATING_SYSTEM}. The on-device model downloads during setup.`;

/** Under the hero mock. Everything in the mock is made up. */
export const MOCK_CAPTION =
  "You're writing a plan. Appears finds an earlier decision in Messages, the original project brief and your notes from the last review. You can check them from the menu bar without typing a search.";
export const MOCK_NOTE = "A made-up example.";
export const MOCK_EMAIL = landing.email;
export const MOCK_PANEL_CONTEXT = `${MOCK_EMAIL.subject} · Mail`;

/** The three results in the hero mock, in the order the panel shows them, under their group labels. */
export const MOCK_RESULTS = [
  {
    kind: "message",
    group: "Messages",
    title: landing.message.title,
    reason: landing.message.reason,
  },
  {
    kind: "pdf",
    group: "Files",
    title: landing.document.title,
    reason: landing.document.reason,
  },
  {
    kind: "note",
    group: "Notes",
    title: landing.note.title,
    reason: landing.note.reason,
  },
] as const;

/** The upcoming meeting in the hero mock's third scenario, also shown in a Calendar widget on its desktop. */
export const MOCK_MEETING = landing.meeting;

/**
 * The hero mock's scenarios, in the order of its tabs. The first is the email
 * above; Mock.astro plays each one and moves the pointer between them. `kind`
 * names a result's thumbnail ("plant" is the photo you open, drawn in
 * PlantPhoto.astro). `app` and `clock` are what the mock's menu bar shows.
 */
export const MOCK_SCENARIOS = [
  {
    id: "email",
    label: "Writing an email",
    caption: MOCK_CAPTION,
    app: "Mail",
    clock: "Thu 10:42",
    context: MOCK_PANEL_CONTEXT,
    results: MOCK_RESULTS,
  },
  {
    id: "photo",
    label: "Opening a photo",
    caption:
      "You open a photo of your houseplant. Appears recognises the plant and finds a friend's advice in Messages, your care notes and a photo of the same plant from two years ago. Pictures are matched by what's in them, not their file names.",
    app: "Preview",
    clock: "Thu 12:15",
    context: `${landing.photo.file} · Preview`,
    results: [
      { kind: "message", group: "Messages", title: landing.photo.message.title, reason: landing.photo.message.reason },
      { kind: "note", group: "Notes", title: landing.photo.note.title, reason: landing.photo.note.reason },
      { kind: "plant", group: "Files", title: landing.photo.image.title, reason: landing.photo.image.reason },
    ],
  },
  {
    id: "meeting",
    label: "Before a meeting",
    caption: `Ten minutes before a meeting, Appears looks for what you'll need: ${landing.meeting.with}'s latest message, the quote you're discussing and a photo of the measurements you wrote down. You don't have to open anything.`,
    app: "Finder",
    clock: "Thu 1:50",
    context: `${landing.meeting.time} · ${landing.meeting.title}`,
    results: [
      { kind: "message", group: "Messages", title: landing.meeting.message.title, reason: landing.meeting.message.reason },
      { kind: "pdf", group: "Files", title: landing.meeting.document.title, reason: landing.meeting.document.reason },
      { kind: "photo", group: "Files", title: landing.meeting.image.title, reason: landing.meeting.image.reason },
    ],
  },
] as const;

// --- How it works ------------------------------------------------------------------

export const HOW_HEADING = "Keep working. Appears finds what's relevant.";
/** Each card's `scene` names its illustration in src/components/Scene.astro. */
export const HOW = [
  {
    scene: "notice",
    title: "It starts with what you're doing",
    text: "Writing an email, reading a document or making a plan: Appears uses the window in front of you to look for relevant information. It doesn't store what it reads.",
  },
  {
    scene: "gather",
    title: "It looks across your Mac",
    text: "Appears searches the contents of messages, Apple Notes, documents, screenshots and photos. Useful details can turn up together, even when they're in different places.",
  },
  {
    scene: "forgot",
    title: "It brings back forgotten details",
    text: "An older conversation or a note from last year can still help. Appears favours information you haven't opened in a while, so useful details don't stay buried.",
  },
  {
    scene: "reason",
    title: "It tells you why",
    text: "Up to three suggestions at a time, each with a short reason, such as the person mentioned or the matching page. Open one, preview it, or drag it into what you're writing.",
  },
] as const;

// --- Quiet -------------------------------------------------------------------------

export const QUIET_HEADING = "Proactive help, without interruptions.";
export const QUIET =
  "No notifications, no sounds, no pop-ups. When Appears finds something worth a look, the little ring in your menu bar gets a dot. Glance at it when you're ready, or press a shortcut to ask any time.";
/** The menu bar glyph's states (drawn in mac/App/Sources/Glyph.swift; src/components/Glyph.astro on the site). */
export const GLYPHS = [
  { state: "idle", label: "Nothing to show" },
  { state: "indexing", label: "Building your index" },
  { state: "found", label: "Found something relevant" },
  { state: "paused", label: "Paused" },
  { state: "setup", label: "Needs setup" },
] as const;

// --- Privacy -----------------------------------------------------------------------

export const PRIVACY_HEADING = "Your information stays on your Mac.";
export const PRIVACY_TEXT = "Your messages, notes, photos and documents are personal. Appears processes them on your Mac, without uploading them.";
/** Each row's `art` names its illustration in src/components/PrivacyArt.astro. */
export const PRIVACY = [
  {
    art: "local",
    label: "Everything happens on your Mac",
    text: "No account, no cloud, nothing uploaded. During setup, a sandboxed helper that can't see your files or screen downloads the on-device model. After that, Appears works offline.",
  },
  {
    art: "forget",
    label: "It forgets what it sees",
    text: "It reads what you're working on, uses it, and lets it go. The only thing it remembers is which suggestions you found useful.",
  },
  {
    art: "private",
    label: "It skips private things",
    text: "Password managers, password fields and private browser windows are off limits. Pause it from the menu bar whenever you like.",
  },
  {
    art: "open",
    label: "Anyone can check",
    text: `It's open source under the ${LICENSE} license, so these promises aren't just promises.`,
  },
] as const;

// --- Questions ---------------------------------------------------------------------
// For people who want the detail. Plain answers, no FAQPage markup (see ../AGENTS.md).

export const FAQ_HEADING = "Questions, answered.";
/** Each answer is a few short paragraphs. */
export const FAQ = [
  {
    q: "How does it know what's related?",
    a: [
      "It runs Google's EmbeddingGemma 2, a small open model, on your Mac. The model matches the meaning of what's on your screen with information in your messages, notes, documents and pictures, even when the wording is different.",
      "A plain text search catches names and numbers alongside it. Things you haven't opened in a while get a boost.",
    ],
  },
  {
    q: "What does it look at on my screen?",
    a: [
      "Only the window in front of you: its title, what it shows, and what you're typing.",
      "That text stays in memory for one search, then it's gone.",
    ],
  },
  {
    q: "Which sources does it look through?",
    a: [
      "Documents, PDFs, images and screenshots in your home folder, plus Apple Notes, Messages and their locally downloaded photos when you grant Full Disk Access. It skips system files, code projects and caches. Settings lets you include or exclude folders and turn Notes or Messages off. Added folders stay up to date automatically, and Sources shows indexing progress, access needs and when each source was last checked.",
      "Optional Contacts access adds names and contact photos to Messages results. Contact details stay in memory on your Mac.",
      "Mail, Photos, audio and video aren't supported yet.",
    ],
  },
  {
    q: "Why is there a separate download during setup?",
    a: [
      "The model is about 900 MB, so the app downloads it while you set up, to keep the app itself small.",
      "A sandboxed helper does the download. It can't see your files or screen, and every file is checked before use. After that, Appears works offline.",
    ],
  },
  {
    q: "How can I be sure nothing leaves my Mac?",
    a: [
      "The part that reads your files and runs the model has no network access; macOS blocks it. The app itself has no networking code, and every build is checked for it.",
      "No account, no analytics, no crash reports.",
    ],
  },
  {
    q: "How often will it suggest something?",
    a: [
      "When it finds a confident match, after five seconds reading or a two-second pause after typing. New suggestions are at least one minute apart, and the same item won't repeat in that conversation. The menu bar ring gets a dot; nothing pops up.",
      "Press ⇧⌘Space to ask any time.",
    ],
  },
  {
    q: "Can it help me get ready for meetings?",
    a: [
      "With Calendar access (optional), it looks about 10 minutes before each meeting, using the title, who's invited and the notes. Join links and passcodes are left out.",
    ],
  },
  {
    q: "Will it slow down my Mac?",
    a: [
      "The first pass through your files takes a while, and pauses in Low Power Mode. After that it only checks what's changed, and a search takes a fraction of a second.",
    ],
  },
  {
    q: "What does it cost, and what do I need?",
    a: [`Nothing: it's free and open source (${LICENSE}). It needs a ${HARDWARE} running ${OPERATING_SYSTEM}.`],
  },
] as const;

// --- Get it ------------------------------------------------------------------------

export const GET_HEADING = "Let Appears do the searching.";
export const GET_TEXT = "Download Appears and choose which sources it can use. The on-device model downloads during setup. Once your sources are indexed, Appears can start finding useful information while you work.";

// --- Share card --------------------------------------------------------------------

export const CARD = {
  summary: "Appears proactively finds relevant messages, notes, photos and documents while you work. Everything stays on your Mac.",
  footer: "appea.rs",
  alt: "Appears: let your Mac do the searching. Proactive suggestions from Messages, notes and documents.",
};
