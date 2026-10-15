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
  "Appears is a Mac menu bar app that notices what you're working on and quietly shows related things you already have and probably forgot: an old screenshot, a photo of a quote, a PDF from two years ago. You never type a query.";
export const STATUS = "In private testing";
export const STATUS_TEXT = `${STATUS}. There's no download yet. Free and open source (${LICENSE}), for a ${HARDWARE} running ${OPERATING_SYSTEM}.`;

/** Under the hero mock. Everything in the mock is made up. */
export const MOCK_CAPTION =
  "You're replying to Dana about her kitchen. Appears finds the photo you took of her handwritten quote last year, the city permit (page 3 has the scope of work), and your measurements note. You didn't ask for any of it.";
export const MOCK_NOTE = "A made-up example.";

/** The three results in the hero mock, in the order the panel shows them. */
export const MOCK_RESULTS = [
  {
    kind: "photo",
    title: "IMG_4471.jpg",
    reason: "Mentions Dana Ruiz · from May 2025",
  },
  {
    kind: "pdf",
    title: "permit-BLD-2024-0457.pdf",
    reason: "Also about “countertops” · from May 2025 · page 3",
  },
  {
    kind: "note",
    title: "Kitchen measurements",
    reason: "Mentions Dana · last edited April 2025",
  },
] as const;

// --- How it works ------------------------------------------------------------------

export const HOW_HEADING = "It reads the window you're in, then lets it go.";
export const HOW = [
  {
    title: "It looks where you look",
    text: "Through the macOS Accessibility API, Appears reads the window in front of you: the email you're replying to, the doc you're editing, the page you're reading. It reads only when something changes, keeps the text in memory, and throws it away.",
  },
  {
    title: "It already knows your files",
    text: "It indexes the files in your home folder and your Apple Notes with Google's EmbeddingGemma 2, running on the Mac, alongside ordinary full-text search. Text, screenshots and photos share one index, so a photo of a handwritten quote can match an email about it.",
  },
  {
    title: "It leans toward what you've forgotten",
    text: "Ranking weighs how long it's been since you last opened something, not only how similar it is. The note you wrote yesterday isn't news. The quote from two years ago is.",
  },
  {
    title: "It shows its reasons",
    text: "At most three things at a time, each with a one-line reason, like “mentions Dana Ruiz · last opened March 2024 · page 3”. Open one, Quick Look it, or drag it straight into the email you're writing.",
  },
] as const;

// --- Quiet -------------------------------------------------------------------------

export const QUIET_HEADING = "It doesn't interrupt.";
export const QUIET =
  "No notifications, no sounds, no pop-ups. When Appears has something worth seeing, its menu bar glyph changes, and you look when you want to. A hotkey asks it directly, any time.";
/** The menu bar glyph's states (drawn in mac/App/Sources/Glyph.swift; src/components/Glyph.astro on the site). */
export const GLYPHS = [
  { state: "idle", label: "Nothing to show" },
  { state: "indexing", label: "Indexing" },
  { state: "found", label: "Something's here" },
] as const;

// --- Privacy -----------------------------------------------------------------------

export const PRIVACY_HEADING = "Nothing leaves your Mac. Here's how that's enforced.";
export const PRIVACY = [
  {
    label: "The engine",
    text: "Reading your files, running the model and holding the index happen in a separate process inside the App Sandbox, with no network entitlement, so macOS blocks it from connecting anywhere. You can check it yourself with `codesign -d --entitlements -`.",
  },
  {
    label: "The menu bar app",
    text: "Reading the screen needs the Accessibility API, which Apple doesn't allow inside the sandbox. So the app that reads it contains no networking code, and it turns off its own network access at launch with macOS's built-in no-network sandbox profile.",
  },
  {
    label: "What it keeps",
    text: "Nothing about what you looked at. The only log is which suggestions you opened or dismissed, without the text of what you were doing.",
  },
  {
    label: "What it skips",
    text: "Password managers, secure text fields and private browser windows, by default. A pause switch stops it altogether.",
  },
] as const;

// --- Status ------------------------------------------------------------------------

export const NOW_HEADING = "Where it is now";
export const NOW = `Appears is in private testing, and there's no download yet. When it's ready it will be free and open source under the ${LICENSE} license, for a ${HARDWARE} running ${OPERATING_SYSTEM}.`;

// --- Share card --------------------------------------------------------------------

export const CARD = {
  summary: "A Mac menu bar app that quietly shows related files you already have. On-device; nothing leaves the Mac.",
  footer: "appea.rs",
  alt: "Appears: what you already have, before you think to look for it.",
};
