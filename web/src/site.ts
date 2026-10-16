// All of the site's copy. The page (src/pages/index.astro), its Markdown
// version (src/pages/index.md.ts), llms.txt (src/pages/llms.txt.ts) and the
// share card (scripts/og.ts) all read it, so they can't disagree.
//
// Copy may use two bits of Markdown, `code` and [links](https://…): the
// Markdown version uses it as it is, and src/lib/inline.ts turns it into HTML
// for the page.

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
  "Open-source Mac menu bar app at appea.rs, made by Colin Armstrong, that notices what you're working on and shows related files you already have, such as old screenshots, photos and PDFs, using an on-device model; nothing leaves the computer.";

export const TITLE = "Appears: the files you forgot you had, when they matter";
export const DESCRIPTION =
  "Appears is an open-source Mac menu bar app that notices what you're working on and quietly shows related files you already have: old screenshots, photos, PDFs. It runs on the Mac, and nothing leaves it.";

export const OPERATING_SYSTEM = "macOS 26 or later";
export const HARDWARE = "Mac with Apple silicon";
export const LICENSE = "MIT";
export const LICENSE_URL = "https://opensource.org/license/mit";

// --- Hero --------------------------------------------------------------------------

export const HEADLINE = "What you already have, before you think to look for it.";
export const LEDE =
  "Appears lives in your menu bar and follows along while you work. When you already have something that helps, like an old screenshot, a photo of a quote or a PDF from two years ago, it shows up. No searching, no typing.";
/** Where the Download buttons go. The release script puts the latest build here. */
export const DOWNLOAD_URL = `${SITE}/app.dmg`;
export const DOWNLOAD_LABEL = "Download for Mac";
/** Under the Download buttons on the page. */
export const NOTE = "Free and open source.";
/** The Markdown version and llms.txt keep the system requirements for agents. */
export const REQUIREMENTS = `${NOTE} Needs a ${HARDWARE} running ${OPERATING_SYSTEM}. The on-device model downloads during setup.`;

/** Under the hero mock. Everything in the mock is made up. */
export const MOCK_CAPTION =
  "You're replying to Dana about her kitchen. Appears finds the photo you took of her handwritten quote last year, the city permit (page 3 has the scope of work), and your measurements note. You didn't ask for any of it.";
export const MOCK_NOTE = "A made-up example.";

/** The three results in the hero mock, in the order the panel shows them, under their group labels. */
export const MOCK_RESULTS = [
  {
    kind: "photo",
    group: "Files",
    title: "IMG_4471.jpg",
    reason: "Mentions Dana Ruiz · May 2025",
  },
  {
    kind: "pdf",
    group: "Files",
    title: "permit-BLD-2024-0457.pdf",
    reason: "Page 3: scope of work · May 2025",
  },
  {
    kind: "note",
    group: "Notes",
    title: "Kitchen measurements",
    reason: "Mentions Dana · April 2025",
  },
] as const;

// --- How it works ------------------------------------------------------------------

export const HOW_HEADING = "It does the remembering, so you don't have to.";
/** Each card's `scene` names its illustration in src/components/Scene.astro. */
export const HOW = [
  {
    scene: "notice",
    title: "It follows what you're doing",
    text: "Writing an email, reading a doc, planning a trip: Appears picks up on what's in front of you and looks for anything related. It doesn't keep a copy.",
  },
  {
    scene: "gather",
    title: "It knows your files, photos included",
    text: "It understands what's inside your documents, notes, screenshots and photos, not just their names. So a photo of a handwritten quote can turn up next to the email about it.",
  },
  {
    scene: "forgot",
    title: "It finds what you forgot",
    text: "It favours things you haven't opened in a while. The note you wrote yesterday isn't news. The quote from two years ago is.",
  },
  {
    scene: "reason",
    title: "It tells you why",
    text: "Up to three things at a time, each with a short reason, like “mentions Dana Ruiz · page 3”. Open one, preview it, or drag it straight into what you're writing.",
  },
] as const;

// --- Quiet -------------------------------------------------------------------------

export const QUIET_HEADING = "It never interrupts.";
export const QUIET =
  "No notifications, no sounds, no pop-ups. When Appears finds something worth a look, the little ring in your menu bar gets a dot. Glance at it when you're ready, or press a shortcut to ask any time.";
/** The menu bar glyph's states (drawn in mac/App/Sources/Glyph.swift; src/components/Glyph.astro on the site). */
export const GLYPHS = [
  { state: "idle", label: "Nothing to show" },
  { state: "indexing", label: "Getting to know your files" },
  { state: "found", label: "Something's here" },
  { state: "paused", label: "Paused" },
  { state: "setup", label: "Needs setup" },
] as const;

// --- Privacy -----------------------------------------------------------------------

export const PRIVACY_HEADING = "Your stuff stays on your Mac.";
export const PRIVACY_TEXT = "Appears sees a lot of what you do, so it's built to keep all of it to itself.";
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
      "It runs Google's EmbeddingGemma 2, a small open model, on your Mac. The model understands what text and pictures are about, so a photo of a handwritten quote matches an email about the same kitchen, even with no words in common.",
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
    q: "Which files does it look through?",
    a: [
      "Documents, PDFs, images and screenshots in your home folder, plus Apple Notes, Messages and their locally downloaded photos when you grant Full Disk Access. It skips system files, code projects and caches. Settings lets you include or exclude folders and turn Notes or Messages off.",
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
      "Rarely. Only when it's confident, a few times an hour at most, and less if you ignore it. The menu bar ring gets a dot; nothing pops up.",
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

export const GET_HEADING = "Try it on your Mac.";
export const GET_TEXT = "Download the small app and get started. The on-device model downloads while you set up, then Appears gets to know your files. Get back to work; it'll speak up when it has something.";

// --- Share card --------------------------------------------------------------------

export const CARD = {
  summary: "A Mac menu bar app that quietly shows related files you already have. On-device; nothing leaves the Mac.",
  footer: "appea.rs",
  alt: "Appears: what you already have, before you think to look for it.",
};
