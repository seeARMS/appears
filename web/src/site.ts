// All of the site's copy. The page (src/pages/index.astro), its Markdown
// version (src/pages/index.md.ts), llms.txt (src/pages/llms.txt.ts) and the
// share card (scripts/og.ts) all read it, so they can't disagree.
//
// Copy may use two bits of Markdown, `code` and [links](https://…): the
// Markdown version uses it as it is, and src/lib/inline.ts turns it into HTML
// for the page. Shortcuts go in braces, like {Control–Shift–Space}: keycaps on
// the page, plain names in the Markdown (see inline.ts).

import landing from "../../demo/landing.json";

export const SITE = "https://appea.rs";
export const NAME = "Appears";
export const SOURCE_URL = "https://github.com/seeARMS/appears";
export const SOURCE_LABEL = "GitHub";

export const AUTHOR = {
  name: "Colin Armstrong",
  url: "https://armstr.ng",
  id: "https://armstr.ng/#person",
  // Kept word for word the same on every one of Colin's sites.
  disambiguation:
    "Founder and CEO of Paragraph (paragraph.com), a software engineer and entrepreneur in the San Francisco Bay Area who previously worked at Google and Coinbase.",
  sameAs: ["https://x.com/colinarms", "https://www.linkedin.com/in/colinarms", "https://github.com/seeARMS"],
};

/** The app's schema.org disambiguatingDescription, also llms.txt's summary. Keep it verbatim. */
export const SUMMARY =
  "Open-source Mac menu bar app at appea.rs, made by Colin Armstrong, that proactively finds messages, notes, photos and documents relevant to what you're working on, using an on-device model; nothing leaves the computer.";

export const TITLE = "Appears: your Mac remembers, so you don't have to";
export const DESCRIPTION =
  "Appears brings back the messages, notes, photos and files you already have, when they matter to what you're doing. Private, offline, on your Mac.";

export const OPERATING_SYSTEM = "macOS 26 or later";
export const HARDWARE = "Mac with Apple silicon";
export const PLATFORM_NOTE = "Apple silicon · macOS 26+";
export const LICENSE = "MIT";
export const LICENSE_URL = "https://opensource.org/license/mit";

// --- Hero --------------------------------------------------------------------------

export const HEADLINE = "Your Mac remembers, so you don't have to.";
export const LEDE =
  "Appears notices what you're working on and brings back the messages, notes, photos and files that go with it. You don't need to search or remember where you put them. Everything stays on your Mac.";
/** Where the Download buttons go. The release script puts the latest build here. */
export const DOWNLOAD_URL = `${SITE}/app.dmg`;
export const DOWNLOAD_LABEL = "Download for Mac";
/** Under the Download buttons on the page. */
export const NOTE = `Free and [open source](${SOURCE_URL}). ${PLATFORM_NOTE}.`;
/** The Markdown version and llms.txt keep the system requirements for agents. */
export const REQUIREMENTS = `${NOTE} The on-device model downloads during setup.`;

export const RELATED_SUMMARY = "A short list of suggestions, each with a reason to take a look. Open one, preview it, or drag it into what you're writing.";

export const SEARCH = {
  eyebrow: "Search by meaning",
  heading: "Or just ask.",
  text: "Press {Control–Shift–Space} and describe it the way you remember it. Appears looks through your messages, notes, files and photos at once, so you don't need the exact words or the file name.",
  caption: "The Appears search window, shown with made-up Messages conversations.",
  alt: "Appears searching for ‘kitchen quote’, with matching messages from Dana Ruiz and Joan Lee and an excerpt below each result.",
};

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

export const HOW_HEADING = "You keep working. It finds what you'll need.";
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
    text: RELATED_SUMMARY,
  },
] as const;

// --- Quiet -------------------------------------------------------------------------

export const QUIET_HEADING = "It never interrupts you.";
export const QUIET =
  "No notifications, no sounds, no pop-ups. When Appears finds something worth a look, the little ring in your menu bar gets a dot. Click it when you're ready, or press a shortcut to ask any time.";
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
// For people who want the detail. Plain answers, no FAQPage markup (see AGENTS.md).

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
      "Documents, PDFs, images and screenshots in your home folder, plus Apple Notes, Messages and their locally downloaded photos when you grant Full Disk Access. It skips system files, code projects and caches. Settings → Sources lets you include or exclude folders and turn Notes or Messages off. Only content already downloaded to this Mac can be searched by meaning.",
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
      "Press {Shift–Command–Space} to ask any time.",
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
      "The first pass through your files takes a while, and pauses in Low Power Mode. After that it checks for changes. Search time depends on your Mac, your library and whether indexing is still running.",
    ],
  },
  {
    q: "What does it cost, and what do I need?",
    a: [`Nothing: it's free and open source (${LICENSE}). It needs a ${HARDWARE} running ${OPERATING_SYSTEM}.`],
  },
] as const;

// --- Get it ------------------------------------------------------------------------

export const GET_HEADING = "Get back what you already have.";
export const GET_TEXT = "Download Appears and pick the apps and folders it can look through. The on-device model downloads during setup. Once everything is indexed, things start turning up while you work.";

// --- Search guides -----------------------------------------------------------------
// These pages describe capabilities in the public v0.1.0 release as well as
// current builds. Avoid promises about result counts or newer preview controls.

export const GUIDES_HEADING = "Find something you remember.";
export const GUIDES_INTRO = "Start with the detail you still have. These guides show how to search it, which sources to enable, and what to check when something is missing.";
export const GUIDE_TEXT = {
  label: "Search guides",
  nav: "Guides",
  example: "From the demo library",
  exampleNote: "A made-up query and source excerpt. Your results depend on what's in your index.",
  steps: "Try it in Appears",
  related: "More search guides",
  downloadHeading: "Find it on your Mac.",
  downloadText: "Download Appears, choose your sources, and let the first index finish. The model downloads during setup; after that, search works offline.",
};

export interface SearchGuide {
  slug: string;
  title: string;
  heading: string;
  description: string;
  summary: string;
  intro: string[];
  example: { query: string; source: string; excerpt: string; explanation: string };
  steps: { title: string; text: string }[];
  sections: { heading: string; paragraphs: string[] }[];
}

export const guidePath = (slug: string) => `/guides/${slug}/`;
export const guideMarkdownPath = (slug: string) => `/guides/${slug}.md`;

export const GUIDES: SearchGuide[] = [
  {
    slug: "search-imessage-on-mac",
    title: "Search iMessage on Mac by meaning | Appears",
    heading: "Search iMessage by what you remember.",
    description: "Search iMessage on your Mac by describing what you remember. Set up Appears for local Messages search, check the source, and troubleshoot missing results.",
    summary: "Search iMessage by meaning, then open the conversation to check what was said.",
    intro: [
      "You remember a friend's advice about a plant, but not the words they used or when they sent it. In Appears, you can describe the idea and search the Messages conversations already on your Mac.",
      "Appears combines meaning-based search with text search for names, numbers and distinctive words. The search runs on your Mac, alongside any other sources you've enabled.",
    ],
    example: {
      query: "why are my plant's leaves turning yellow",
      source: "Rina Holt · Messages",
      excerpt: "Yellow leaves on a pothos almost always means overwatering. Let the top inch of soil dry out between waterings and make sure the pot drains.",
      explanation: "The useful detail is the advice in the conversation. You can start with the question you remember asking, then read the original message for context.",
    },
    steps: [
      { title: "Enable Messages", text: "Open Appears Settings → Sources and turn on Include Messages and photos. Grant Full Disk Access in macOS System Settings so Appears can read the local Messages database. Follow any restart prompt from macOS." },
      { title: "Let the first index run", text: "Messages and their photos must already be downloaded to this Mac. Leave Appears running while it builds the index; results become available as items are indexed." },
      { title: "Describe the conversation", text: "Press {Control–Shift–Space} to open search. Try a short description such as ‘the advice about yellow leaves’. Add a person's name or a distinctive number if you remember one." },
      { title: "Check the source", text: "Read the result's excerpt, use the arrow keys to select it, and press {Return} to open it in Messages. Read the surrounding conversation before relying on a detail." },
    ],
    sections: [
      { heading: "Use the details you still remember", paragraphs: ["A description helps when the wording has changed in your memory: ‘the last rent payment’ can be more useful than guessing an exact sentence. Names, amounts and unusual phrases help narrow the search when you know them.", "Try one idea at a time. If a broad query returns several conversations, add what the conversation was about rather than repeatedly rephrasing the same vague request."] },
      { heading: "If a conversation is missing", paragraphs: ["Check that you can see it in Messages on this Mac, that Full Disk Access is granted, and that Messages is enabled in Appears Settings → Sources. An unfinished index can also explain missing results.", "Photos attached to messages need to be downloaded locally before their contents can be indexed. Appears doesn't fetch your message history from iCloud or recover deleted messages."] },
      { heading: "What this search includes", paragraphs: ["The Messages source covers the conversations and downloaded photos in Apple's Messages app on this Mac. It doesn't connect to WhatsApp, Slack or other messaging services.", "Typed search doesn't need Accessibility or Screen Recording permission. Accessibility enables the separate proactive feature, which looks for related information while you work."] },
    ],
  },
  {
    slug: "search-apple-notes-and-documents",
    title: "Search Apple Notes and documents together on Mac | Appears",
    heading: "Search Apple Notes and documents together.",
    description: "Search Apple Notes, PDFs and documents together on your Mac with Appears. Learn how to enable sources, search by meaning, and check missing local content.",
    summary: "Look through Apple Notes, PDFs and documents with one description.",
    intro: [
      "Was the watering advice in Apple Notes, a document, or a message? Appears searches the sources you've enabled together, so you can begin with the detail you remember instead of choosing an app first.",
      "It matches the meaning of your description as well as specific words. A question about a plant can find a note titled ‘Plant care’, even if you never remember that title.",
    ],
    example: {
      query: "how often should I water the plant",
      source: "Plant care · Document",
      excerpt: "Water only when the top inch of soil is dry, about every 10 days. Less in winter.",
      explanation: "This excerpt comes from a text document in the demo library. With Apple Notes enabled, notes can appear in the same search alongside documents and PDFs.",
    },
    steps: [
      { title: "Choose the sources", text: "In Appears Settings → Sources, enable Include Apple Notes and grant Full Disk Access. Documents in your home folder are included by default, apart from skipped folders and file types." },
      { title: "Include other folders you need", text: "Add a folder to the Include list if your documents live outside your home folder or inside a normally skipped location. Download cloud-only files to this Mac to make their contents available." },
      { title: "Search for the detail", text: "Once the model is ready and items are indexed, press {Control–Shift–Space}. Describe the subject, decision or instruction you want, such as ‘the plan for the team offsite’." },
      { title: "Open the original", text: "Use the result's source and excerpt to check the match. Select it with the arrow keys and press {Return} to open the note or document in its app. For a file result, {Command–Return} reveals it in Finder." },
    ],
    sections: [
      { heading: "A subject works when a file name doesn't", paragraphs: ["Try ‘where we were going for the team offsite’ if you don't know whether the answer is in a meeting note, a venue list or a PDF. If you remember a name or a specific phrase, include it too.", "Search can return information with different wording, but a similar subject isn't proof that a result answers your question. Read the excerpt and open the original to check dates, decisions and surrounding context."] },
      { heading: "Local content is what counts", paragraphs: ["Apple Notes needs Full Disk Access. Documents and PDFs need to be readable on this Mac. A cloud-only file may be indexed by name without its contents; download it locally before expecting a search by meaning to find a passage inside it.", "Appears skips system data, code checkouts, build folders and caches by default. Use Settings → Sources to include a specific folder you want searched or exclude one you don't."] },
      { heading: "Other apps and formats", paragraphs: ["The Notes source reads Apple Notes. It doesn't sign in to other note services or search a web workspace. A local export in a supported document format, such as text or PDF, can be searched from an included folder.", "Email, audio and video aren't indexed. A scanned PDF may need on-device text recognition before its contents are searchable, so the first pass can take longer than it does for a text document."] },
    ],
  },
  {
    slug: "find-photos-and-screenshots-on-mac",
    title: "Find photos and screenshots on Mac by description | Appears",
    heading: "Find photos and screenshots by description.",
    description: "Find photos and screenshots on your Mac by describing them. Learn how Appears uses image matching and text recognition, and which local images it can search.",
    summary: "Describe a picture or the words inside a screenshot to find the local file.",
    intro: [
      "A photo of a quote can be named IMG_4471.jpg. A screenshot of an instruction can be named after the time you took it. Neither name tells you what's inside.",
      "Appears indexes local images using an on-device image model and text recognition. Search for what the picture shows, or for a detail in its readable text, alongside your documents, notes and Messages.",
    ],
    example: {
      query: "photo of the builder's kitchen quote",
      source: "IMG_4471.jpg · Photo",
      excerpt: "Ruiz & Daughters Builders — Quote Q-2291 — Kitchen remodel.",
      explanation: "This line is visible in the demo photo. Readable words give you another way to find an image whose file name says little about its contents.",
    },
    steps: [
      { title: "Make the image local", text: "Keep photos and screenshots in a folder Appears can read. For an image in Apple Photos, export it to a local folder first. For a Messages photo, download the attachment in Messages." },
      { title: "Include its source", text: "Images in your home folder are scanned by default. Add other folders in Settings → Sources. Messages photos also need Include Messages and photos enabled and Full Disk Access." },
      { title: "Describe what you remember", text: "After indexing, press {Control–Shift–Space}. Try the subject of the picture, such as ‘the plant by the window’, or distinctive text, such as a quote number. Start with one recognizable detail." },
      { title: "Preview and check", text: "Use the thumbnail and any matching text to choose a result. For a file result, press {Command–Y} to preview it, {Return} to open it, or {Command–Return} to reveal its location in Finder." },
    ],
    sections: [
      { heading: "Pictures and words give you different clues", paragraphs: ["A description of the subject can help find a photograph. A phrase, name or number can help find a screenshot, receipt or photographed document with readable text.", "The image model can return visually related pictures without an exact text match. Check the thumbnail or open the image rather than treating visual similarity as a factual answer."] },
      { heading: "Which pictures can be searched?", paragraphs: ["Appears searches supported image files in included folders and locally downloaded Messages photos when enabled. It doesn't read the Apple Photos library directly or fetch originals from iCloud.", "If a picture is only in Photos, export a copy into an included folder. If it's an undownloaded Messages attachment, open it in Messages first so the file exists on this Mac."] },
      { heading: "When a screenshot doesn't turn up", paragraphs: ["Check that the file is local, its folder isn't excluded, and indexing has reached it. The first pass through images and scanned documents can take time.", "Tiny, blurred or handwritten text may not be recognized accurately. Try a clearer phrase, the main subject of the image, or part of the file name if you remember it. There is no need to enable Screen Recording to search an image file you already have."] },
    ],
  },
];

// --- Share card --------------------------------------------------------------------

export const CARD = {
  summary: "Appears brings back the messages, notes, photos and files you already have, when they matter. Private, offline, on your Mac.",
  footer: "appea.rs",
  alt: "Appears: your Mac remembers, so you don't have to. Suggestions from Messages, notes and documents.",
};
