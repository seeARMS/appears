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
export const STATUS = "Free for Mac";
/** Where the Download buttons go. The release script puts the latest build here. */
export const DOWNLOAD_URL = "/Appears.dmg";
export const DOWNLOAD_LABEL = "Download for Mac";
export const REQUIREMENTS = `Free and open source. Needs a ${HARDWARE} running ${OPERATING_SYSTEM}.`;

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
/** Each row's `icon` names an icon in src/components/Icon.astro. */
export const PRIVACY = [
  {
    icon: "laptop",
    label: "Everything happens on your Mac",
    text: "Appears does all its work on your Mac. No account, no cloud, nothing uploaded.",
  },
  {
    icon: "eye-off",
    label: "It forgets what it sees",
    text: "It reads what you're working on, uses it, and lets it go. The only thing it remembers is which suggestions you found useful.",
  },
  {
    icon: "lock",
    label: "It skips private things",
    text: "Password managers, password fields and private browser windows are off limits. Pause it from the menu bar whenever you like.",
  },
  {
    icon: "code",
    label: "Anyone can check",
    text: `It's open source under the ${LICENSE} license, so these promises aren't just promises.`,
  },
] as const;

// --- Get it ------------------------------------------------------------------------

export const GET_HEADING = "Try it on your Mac.";
export const GET_TEXT = "Download Appears, give it a few minutes to get to know your files, and get back to work. It'll speak up when it has something.";

// --- Share card --------------------------------------------------------------------

export const CARD = {
  summary: "A Mac menu bar app that quietly shows related files you already have. On-device; nothing leaves the Mac.",
  footer: "appea.rs",
  alt: "Appears: what you already have, before you think to look for it.",
};
