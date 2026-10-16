# Appears: plan

Status: agreed 2026-10-15; v0 built the same day (M1, M2 and the code for M4's ambient mode; see README.md's "Not done yet"). M3, Colin's dogfooding, is next. Colin's decisions are under Decisions at the end. Research was done on 2026-10-14; anything marked *unverified* is checked in M0.

## What it is

Appears is a Mac menu bar app that notices what you're looking at and quietly shows related things you already have and probably forgot. That's the email you're replying to, the doc you're editing, the page you're reading. What it shows: an old screenshot, a photo, a PDF from two years ago (voice memos later). You never type a query. Site: [appea.rs](https://appea.rs). Open source (MIT).

It's the MIT Remembrance Agent idea (Rhodes, 1990s). Past attempts failed on keyword matching, per-app plugins and interruption cost. Multimodal embeddings on the Mac fix retrieval, and the Accessibility API fixes per-app plugins. Interruption cost is still unsolved, and it's the product: **deciding when to show something without being annoying.**

The wedge over every predecessor is cross-modal recall: you're replying to an email about a contractor, and Appears shows the photo of the quote you took two years ago and the permit PDF. Voice memos (the site-visit recording) come after v0.

## Landscape (October 2026)

- **macOS 27's Siri in Spotlight** has personal context and on-screen awareness, but it answers only when asked. It's the biggest platform risk: Apple could go proactive.
- **Littlebird** ($11M seed, March 2026) is the closest in shape. It reads the active window through Accessibility and has proactive "Routines", but keeps its memory in AWS. Appears differs by being local with no network, and by recalling files you own rather than a recording of your screen.
- **DigUp** (MIT, launched 2026-10-08, ~3.6k stars) is the closest technically. It's a Swift app that searches your files by content with EmbeddingGemma 2, but you type queries. Appears builds its own index and borrows ideas from DigUp where useful (MIT).
- **screenpipe** records everything and is built for querying and agents. It's now under a source-available license.
- **Raycast 2.0's Screen Awareness** sends the window to a cloud AI when you trigger it.
- **Smart Connections** is proactive, but only inside Obsidian.
- **Rewind** has shut down. **Heyday** narrowed to niche professionals.

## Promises

These are the product. Each one is enforced in code, by macOS, or by the release script, not just stated.

1. **Nothing leaves the Mac.**
   - **The engine** (indexing, the model, the index, file parsing) runs in an App Sandbox with no network entitlement, so macOS blocks every connection.
   - **The app** reads your screen through the Accessibility API, which Apple doesn't allow inside the sandbox. It is small and has no networking code, checked by a build script that fails if its binary imports a networking API. (Update 2026-10-15: the planned self-applied `sandbox_init` no-network profile makes macOS refuse Accessibility, so it was dropped.)
   - **Updates** go through Sparkle's separately sandboxed downloader.
   - **First-run model download (Colin, 2026-10-15):** keep the app download lightweight. A separate sandboxed `AppearsDownloader.xpc`, with network.client only and no user-file access, fetches the model pinned inside the signed app. Onboarding continues during download; indexing waits for verified completion. The app and engine retain their network restrictions.
   - The README says exactly which part is enforced how.
2. **It doesn't record your screen.** It reads only the current context, in memory, when something changes, and then throws it away. It keeps an index of files you already own, and a log of which suggestions you opened or dismissed. The log never holds the context's text (see Measuring).
3. **Silence is the default.** No notifications, no sounds, no pop-ups, ever. Most of the time it shows nothing.
4. **Earn push before shipping it.** During development, Appears answers only when asked (a hotkey or a click) while shadow mode logs what it would have suggested. Suggesting on its own is on by default at launch, but only once the logs show it's right often enough (see When to show something).
5. **Exclusions are on by default:** password managers, secure text fields, private browser windows (where they can be detected; see Context), and a pause switch.

## What comes from whosaid, and what doesn't

whosaid (`../whosaid`) already solved much of the engineering underneath this, and Appears reuses that engineering. **It does not reuse whosaid's UX, UI or visual design**: no search-bar-first layout, no capsule panel, no heade.rs tokens, and the site doesn't look like whosa.id. Appears gets its own interaction model and identity (see The app's design).

Reused, copied in as needed (no shared package, no provenance note):

- **EmbeddingGemma 2 on MLX:**
  - the vendored `EmbeddingGemma2Swift` port, `GemmaEmbedder` and the tokenizer;
  - the model scripts (`fetch-model.sh`, `prepare_model.py`, `reference_vectors.py`);
  - the tests against Google's reference vectors.
- **Index pieces:**
  - the `Embedder` protocol and prompt strings;
  - GRDB + FTS5 storage;
  - the float16 brute-force `VectorIndex` (Accelerate). DigUp does the same; sqlite-vec is still pre-1.0 and unnecessary at personal scale.
  - Reciprocal Rank Fusion.
- **Release plumbing:**
  - XcodeGen, Developer ID signing, notarization and the DMG;
  - Sparkle built with a sandboxed downloader;
  - a `release.sh` that enforces the engine's network prohibition and the downloader's isolation;
  - the Homebrew cask and the `SandboxProbe` tool.
- **Site conventions** from the root `../AGENTS.md`. These are shared by all of Colin's sites, not whosaid's design.

**What's different:**

- **The sandbox.** whosaid is one sandboxed app. Appears separates the UI, engine and first-run model downloader (see Permissions).
- **Everything new for Appears:** context capture, the file extractors, the ranker (forgottenness, novelty, diversity, calibration), the surface policy, the journal and eval harness, and all of the UI.

## Repository

```
appears/
  AGENTS.md              rules for agents (the promises, demo data only, no whosaid UX)
  README.md  LICENSE  VERSION
  .claude/launch.json    dev server for web/
  mac/
    project.yml          XcodeGen spec (Appears.xcodeproj is generated, not committed)
    App/                 menu bar app: status item, panel, settings, onboarding, context reader
    Engine/              the sandboxed XPC service: indexing, model, search
    Packages/AppearsKit/     builds and tests with the Command Line Tools
      Context/           Accessibility reader, browser URL, exclusions, OCR fallback
      Sources/           home folder + FSEvents, Notes, extractors per file type
      Index/             IndexStore (GRDB + FTS5), VectorIndex, Indexer
      Recall/            query building, candidates, ranking, surface policy, calibration
      Journal/           the suggestion log and metrics
      Fixtures/          loads demo/ for tests
    Packages/AppearsModel/   EmbeddingGemma 2 on MLX (needs Xcode for Metal), the `appears` CLI
    Tools/               ContextProbe, SandboxProbe, Snapshots (developer tools, never shipped)
    scripts/             fetch-model, prepare-model, reference-vectors, build-sparkle, release
  web/                   appea.rs (Astro, static)
  demo/                  made-up corpus and scenarios: tests, eval, screenshots, the site
  brand/                 mark and app icon
```

- **Names:** bundle ID `rs.appea.appears`, CLI `appears`.
- **Minimum macOS:** 26, for SpeechAnalyzer and current SwiftUI/AppKit.
- **No root package manager:** the two halves share no toolchain. `web/` reads `../VERSION` and `../demo/` at build time.

## The Mac app

### 1. Reading the current context

Event-driven, never polling the screen:

- **Triggers:** the frontmost app changes (`NSWorkspace`), or an `AXObserver` on that app reports a change of focused window, title, focused element or selection. Typing is debounced: a context is **settled** after about 2 s with no topic change.
- **What it reads:**
  - the app's bundle ID and window title (the Accessibility title, which doesn't need Screen Recording);
  - `AXDocument`, the file the window shows. It's the strongest "don't show me this" signal and a hint about the project.
  - the focused element's text (the reply you're writing) and the selection;
  - in mail compose windows, the recipients. People are one of the strongest recall cues (Microsoft Research).
- **Budgets:** an AX tree walk stops at about 50 ms or 8,000 characters.
- **Browsers:**
  - **Firefox:** `AXURL` on the page's web area.
  - **Chrome:** AppleScript gives the URL and `mode`, which says whether the window is incognito.
  - **Safari:** needs AppleScript and the Automation permission for the URL. **It has no API for private windows.** Ambient and shadow modes skip Safari's page text by default unless M0 finds a reliable signal. A pull is something you asked for, it's read in memory only, so it still works there.
- **Electron and Chromium apps** (Slack, VS Code, Notion) build their accessibility tree only after `AXManualAccessibility` is set. Google Docs draws to a canvas. M0 measures coverage app by app.
- **OCR fallback, on pull only:**
  - When the AX text is nearly empty, capture just the frontmost window with ScreenCaptureKit, read it with Vision on-device, and drop the image.
  - Since Sequoia, macOS asks again roughly monthly ("Allow For One Month") for any capture without the system picker, and there's no entitlement around it for an app like this.
  - So Screen Recording stays optional. Ambient mode never uses OCR.

**Building a query from a context:**

- Strip quoted replies, signatures and UI chrome.
- Weight the selection over what you're writing, over the title and URL, over the rest of the visible text.
- Produce two queries:
  - **Dense:** the most salient ~512 tokens, embedded with EmbeddingGemma 2.
  - **Sparse (FTS5):** names of people and organizations (`NLTagger`); email addresses, phone numbers, street addresses, and order or invoice numbers (`NSDataDetector`); and rare terms, by IDF from the index's own vocabulary.
- Hash the normalized context into a salted fingerprint. It caches results, and it stops the same item being shown twice for the same context.

### 2. Sources (v0)

**Everything sensible, by default.** There's nothing to choose during setup. Settings has one Include list and one Exclude list for anyone who wants control.

- **On by default:**
  - **Your home folder.** In practice that's Documents, Desktop, Downloads, iCloud Drive, the screenshots location (read from `com.apple.screencapture`), and any other folder you've made. It's watched with FSEvents.
  - **Apple Notes,** once Full Disk Access is granted.
  - **Messages and their locally downloaded photos** (added 2026-10-15), read directly and read-only from `~/Library/Messages/chat.db`. Appears owns its index; whosaid is not required. Settings → Sources has a default-on toggle that removes text and photos from the index when disabled. Each message uses a bounded conversation window; photos use native image embeddings plus OCR. New/edited messages are checked each minute, with full reconciliation every ten minutes for deletions and locally downloaded photos.
- **Skipped automatically:**
  - `~/Library`, hidden files, app bundles and libraries (Photos, Music);
  - code and build folders (`.git`, `node_modules`, `build`, virtualenvs);
  - caches, archives and very large files;
  - the exclusion list's apps' data folders.
- **iCloud files that aren't downloaded are indexed from metadata only**, because reading them would download them.
- **Include:** add folders outside home, such as an external drive or a project folder that matched a skip rule.
- **Exclude:** drop folders, file kinds, Notes or Messages. Excluding something removes it from the index straight away.
- **How the sandboxed engine gets access:** setup shows one open panel already pointed at your home folder, and one click grants it as a security-scoped bookmark. Folders added under Include are granted the same way.
- **Apple Notes details:**
  - `NoteStore.sqlite` lives in `group.com.apple.notes`, with each note's text as gzipped protobuf.
  - Locked notes are skipped. Attachments (scans, photos, PDFs) are indexed too.
  - **Access:** Full Disk Access, plus a read-only temporary-exception entitlement for the engine (the pattern whosaid uses for Messages). Temporary exceptions work for Developer ID apps.
- **Indexing order:** the default scope is large, so metadata goes in first, then content, most promising kinds first: documents and PDFs, then screenshots and images, then everything else.

**Extractors per kind.** Each produces units (chunks) in one vector space:

| Kind | Text for full-text search | Vectors |
| --- | --- | --- |
| Text, Markdown, RTF, HTML, Word | the text, in ~400-token chunks | text chunks, titled with the file name and folder |
| PDF | PDFKit text per page | text chunks; scanned pages (little text) as page images plus OCR |
| Images and screenshots | Vision OCR | the image itself, plus the OCR text when there's enough of it |
| Notes | the note's text | text chunks, plus attachments as above |
| Messages | sender, bounded conversation and OCR | text windows and locally downloaded photos |

- **Not in v0:** audio and Voice Memos, video, Mail and Photos (see the v1 backlog).
- **Indexing runs in the background** at utility priority. It pauses in Low Power Mode, at a serious thermal state, or on low battery.

### 3. Storage

All in the engine's container, excluded from backups, and each deletable in Settings:

- **`index.sqlite`** (GRDB, WAL):
  - `source`;
  - `item`: path, kind, title, size, created, modified, last used, content hash;
  - `unit`: item, kind, locator (page or time span), text, vector;
  - `unit_fts`.
  
  The model ID is stored, so changing the model re-embeds everything.
- **Vectors:** searched in memory by brute force. 100k units × 768 float16 is about 150 MB. That's fine for whosaid, which runs on demand, but heavy for an always-on menu bar app. So the plan is to measure first, then reach for Matryoshka truncation if needed: search at 256 dimensions and re-rank the top few hundred at 768. The model card calls 256 "near-lossless", and it cuts vector memory by two thirds.
- **`journal.sqlite`:** kept separate so it can be deleted on its own (see Measuring).
- **"Last used" dates** come from Spotlight's `kMDItemLastUsedDate`. It's still filled in on macOS 27, but it isn't updated for some files, and queries quietly return nothing for protected folders until access is granted. Appears' own `AXDocument` sightings of indexed files fill the gaps; that's a fact about your files, not about the context. The fallback is the modified date.

### 4. Ranking: relevant, forgotten, new, varied

**Candidates:**

- the top ~200 units by cosine for the dense query, across text and image units;
- the top ~100 by BM25 for the sparse query.

Fuse them with RRF, then roll units up to items: the best unit, plus a little extra for several matching units.

**Hard filters:**

- the document that's open now;
- anything opened or modified in the last 3 days;
- excluded folders;
- items already shown for this context;
- anything marked "never show".

**Score** = relevance × forgotten × novelty, then diversify:

- **forgotten(days since last use):** 0 under 3 days, rising to 1 by about 3 months (piecewise in log-days, tunable). The valuable hits are the ones you forgot.
- **novelty:** down-weights the current document's folder, the same email thread or subject, and items whose title just repeats the window title. Those are the obvious matches you don't need.
- **entity boost:** an exact match on a person, organization or project name counts strongly. Embeddings are weakest at names, invoice numbers and addresses.
- **diversity:** MMR over the top results, at most one item per folder, and a preference for mixed kinds across the three slots. There's no artificial boost for images; diversity lets them in.

**Every result explains itself in one line:** what matched, when you last opened it, and for PDFs, where. For example: "mentions Dana Ruiz · last opened March 2024 · page 3".

**Confidence.** Raw cosine isn't comparable across contexts, so confidence is built from features:

- the top score's margin over the rest of this context's candidates;
- whether the dense and sparse lists agree;
- an entity hit;
- whether what you're writing asks your own memory ("what was the wifi password again?", "I'll send you the itinerary"), which only adds to a match that already stands out;
- the item's kind and age;
- the app;
- dwell time;
- how much text the context had.

v0 uses hand-set rules. In M4, a logistic model is fitted on the journal, on the Mac, and retrained nightly. Its threshold is chosen to meet a target precision.

### 5. When to show something

This is the core of the product. There are three modes, and all three are in v0's code:

- **Pull (v0, on):**
  - The hotkey or a click on the menu bar item runs on the current context at once, with no dwell needed.
  - It always shows its best few results, with weak ones labelled as weak, because you asked.
  - Every pull is a labelled example.
- **Shadow (v0, invisible):**
  - The ambient policy runs on every settled context and logs what it would have shown, without showing anything.
  - When you later pull in the same context, the log says whether the shadow pick was what you opened.
  - This is how push earns its way in without burning trust.
- **Ambient (on by default at launch):** the menu bar item changes state when a settled context has a confident result. Nothing else happens until you look.
  - **Dwell:** ≥15 s in the context.
  - **Confidence:** at or above the calibrated threshold.
  - **Budget:** one per context, a few per hour. Each ignored or dismissed suggestion doubles the wait; an opened one resets it.
  - **Never** while the screen is shared or recorded, during a presentation, or in a Focus mode.
  - **Fades** on a context change or after about a minute.

**Ambient is on by default when Appears ships**, with a sensitivity slider and an off switch in Settings. Because it's on for everyone from the first launch, the bar to ship it is the dogfooding gate (starting numbers, tuned while dogfooding): shadow precision@1 ≥ 60% and about one dismissal a day at most, over a week of Colin's use. Until the gate is met, Colin's builds run pull plus shadow only. Release builds also stay quiet for the first few days after install, while the index fills, and until the menu bar glyph has a confident result.

### 6. The app's design (its own, not whosaid's)

**A design exploration comes before any UI code.** It produces two or three directions for the mark, the menu bar glyph, the app icon, type and colour, and the app and site share the result. The exploration has to meet these constraints:

- **The menu bar glyph is the whole ambient UI.**
  - **States:** idle; working (indexing), barely visible; something's here; paused; needs setup. The chosen Orbit mark uses an open ring, a shorter indexing arc, a detached discovery dot, and pause/setup symbols inside the ring.
  - **Legibility:** readable in light, dark and tinted menu bars, as a template image that doesn't rely on colour.
  - **Motion:** one quiet transition, no looping animation.
- **The panel hangs from the menu bar item and never takes focus** from the app you're in. It's a non-activating panel, so your cursor stays in the email. Esc, clicking away or a context change closes it.
- **Results are media-first, at most three.** Each shows a preview, its one-line reason and its age:
  - a photo's thumbnail;
  - a PDF page with the passage highlighted;
  - later, a voice memo's waveform with the matching span marked and playable in place;
  - a note's snippet.
- **Actions:**
  - open (Return or click);
  - Quick Look (Space);
  - reveal in Finder;
  - **drag out**: drag the quote photo straight into the reply you're writing;
  - copy.
- **Feedback takes one click:**
  - Not useful (×);
  - Not in this app;
  - Never show this file;
  - ⌘Z undoes it.
- **Hovering over the glyph** peeks at the top result in ambient mode.
- **Context recall has no query field.** Colin added a separate Spotlight-style semantic search on 2026-10-15: ⌃⇧Space (configurable), “Search Appears…” in the menu, or reopening the app. It searches the enabled index, including recent items, with typed queries kept in memory and out of the suggestion journal. The window uses Appears' existing zinc tokens and results-list design.
- **The default hotkey** is chosen in M2, after checking conflicts: ⌥Space is common for AI launchers, ⌥⇧Space is whosaid's, and ⌃⌥ is VoiceOver's. It's configurable either way.
- **Settings:**
  - Sources: Include and Exclude lists, plus counts of what's indexed;
  - Excluded apps and sites;
  - Suggest on its own (on), with a sensitivity slider;
  - Hotkey;
  - Pause (an hour, or until tomorrow);
  - What Appears has shown you (counts only);
  - Delete index, delete journal.
- **Onboarding is short and honest.** It says what Appears reads, what it never stores, and how the no-network promise is enforced. Then it asks for permissions one at a time, each with its reason, and ends with a first pull on a real window:
  - **Accessibility:** required.
  - **Home folder:** one click on an open panel that's already pointed at it.
  - **Full Disk Access:** optional, for Notes and Messages (including photos).
  - **Automation, for Safari and Chrome:** optional, for URLs.
  - **Calendar:** optional, for looking ahead to meetings (added 2026-10-15).
  - **Screen Recording:** optional, for OCR on pull.

### 7. Permissions and the process split

Apple doesn't allow the Accessibility API inside the App Sandbox, even after the user grants the permission (Apple DTS, 2024 and 2025). Mac App Store window managers that use it only survive because they predate the rule. So Appears can't be one sandboxed app like whosaid. The agreed split:

- **`Appears.app`: unsandboxed, Developer ID.**
  - **Does:** the menu bar UI, context reading (Accessibility, Apple Events for browser URLs, ScreenCaptureKit on pull), and FSEvents.
  - **Permission prompts** show "Appears", which is what people expect.
  - **Contains no networking code**, checked by `mac/scripts/check-no-network.sh`. The plan was also to call `sandbox_init` with a no-network profile at launch; tested 2026-10-15, any self-applied profile makes macOS refuse Accessibility, so that's out.
  - **Updates:** Sparkle has to use its Downloader XPC service, since the app can't reach the network itself.
- **`AppearsEngine.xpc`: App Sandbox, no network entitlement.**
  - **Does:** file parsing, the model, `index.sqlite`, `journal.sqlite` and search.
  - **File access:** the home folder and any Include folders, through bookmarks passed from the app, plus the read-only Notes exception.
  - **Why sandbox it:** the code that opens PDFs, images and documents from your disk is exactly the code that should be locked down.
- **`AppearsDownloader.xpc`: App Sandbox, network.client only.**
  - Downloads the model from pinned appea.rs URLs into its own container. Its no-payload XPC interface can't receive screen text, paths or arbitrary URLs.
  - Has no home-folder, user-selected-file or Automation entitlement. The engine reads the installed model using its existing read-only home access.
  - Checks every size and SHA-256, then installs the complete model atomically. Progress and Retry remain visible while onboarding continues independently.
- **`release.sh` refuses to ship if:**
  - the engine gains a network entitlement;
  - the app's binary links networking symbols it shouldn't;
  - the model downloader gains user-file access or any network entitlement besides network.client;
  - Sparkle's Downloader entitlements change.
- **M0 checks how macOS attributes permissions across the split.** Full Disk Access is checked against the "responsible" app, which should be `Appears.app` for its embedded XPC service.
  - **Fallback if attribution doesn't work:** a sandboxed main app, plus a tiny unsandboxed login-item helper (via `SMAppService`) that only reads Accessibility.
- **Distribution:** Developer ID and Homebrew, never the App Store.

### 8. Performance budget

These are targets to measure in M0, not guesses to trust:

- **Memory:** idle resident memory ≤ ~400 MB in the engine, with only the text encoder loaded (270M parameters, q8). The vision tower (170M) loads for indexing batches and unloads afterwards. v0 doesn't ship the audio tower.
  - The model card says to run it in bf16 or fp32, not fp16. The port's q8 profile keeps bf16 activations.
- **Speed:** a pull answers within 500 ms of the hotkey.
- **Idle cost:** close to zero. No timers, only events, and a settled context is embedded once and cached.
- **App size:** text + vision at q8, about 480 MB.

## Measuring

**The journal** runs from day one, on the Mac only.

- **One row per suggestion:**
  - time and trigger (pull, shadow or ambient);
  - app bundle ID and the salted context fingerprint;
  - dwell and candidate count;
  - the shown item IDs with their features and scores;
  - what happened, and how long it took: opened, previewed, dragged out, dismissed, muted, or ignored.
- **No context text in release builds.** Dev builds can keep context snippets for 14 days, so Colin can label shadow picks while dogfooding.
- **Daily metrics, in Settings and in `appears stats`:**
  - useful suggestions a day (opened, previewed or dragged out);
  - dismiss rate and ignore rate;
  - pull precision@1 and @3;
  - shadow precision.

**The eval harness.**

- **`demo/`** is a made-up corpus of a few hundred files: distractors, plus a handful of scenarios with known answers. The headline scenario is a kitchen remodel: a contractor's quote photo, site photos, a permit PDF and a note.
- **Scenarios** are contexts: an app, a window title, the email being written, and the expected hits.
- **Negative scenarios**, where the right answer is to show nothing. Default-to-silence needs a false-surface rate, not just recall.
- **`appears eval`** prints recall@3, MRR, forgotten-hit rate and false-surface rate.
- **The same corpus** feeds the tests, snapshots, the README GIF and the site's video.
- **No real data** anywhere in the repo.

**Dogfooding:** two weeks of Colin's use before anyone else sees it.

## The site (appea.rs)

- **A static Astro build.** Astro 7.3.8 is the latest stable (checked 2026-10-14).
  - `output: "static"`, no Cloudflare adapter: every page is a file.
  - **Markdown by negotiation:** to follow the root `../AGENTS.md`, a small hand-written Worker sees only `/` and `/index.md`. It serves Markdown at `/` when the Accept header prefers it and otherwise passes the request to `env.ASSETS.fetch(request)`.
  - The adapter isn't needed for that. whosaid uses the adapter; Appears doesn't need it.
- **One page at launch:**
  - a hero with a short loop of the contractor scenario, built from `demo/`;
  - how it decides when to show something, which is the differentiator;
  - sources;
  - the privacy promises, and exactly how each is enforced;
  - open source;
  - download: DMG and Homebrew, or a GitHub link before launch.
- **Its own visual identity,** from the design exploration. Nothing borrowed from whosa.id or heade.rs.
- **The `../AGENTS.md` conventions:**
  - all copy in `src/site.ts`, which the page, `/index.md` and `llms.txt` all read;
  - a charset for `llms.txt` in `_headers`;
  - structured data with `@id` `https://appea.rs/#app`, author `https://armstr.ng/#person` and Colin's disambiguation string;
  - no lastmod;
  - no analytics, since the pitch is that nothing leaves the Mac.
- **The update feed:** `/appcast.xml` serves a signed R2 object with a five-minute cache. The release build embeds the matching published GitHub release's changelog as native Markdown. Sparkle checks daily by default, with a switch in Settings and manual checks; scheduled discoveries appear quietly in Settings and the menu. The source build removes in-process networking and web views, leaving downloads in its sandboxed XPC service. Model updates follow the pin in each compatible app release.
- **Deploys:** to the Colin Personal Cloudflare account, through the `wrangler-personal` profile, and by Workers Builds with root directory `web`. A `redirect/` Worker sends www to the bare domain.
- **Draft disambiguation string:** "Open-source Mac menu bar app at appea.rs, made by Colin Armstrong, that notices what you're working on and shows related files you already have, such as old screenshots, photos and PDFs, using an on-device model; nothing leaves the computer."
- **Outside this repo, at launch:** add Appears to the root `../AGENTS.md` (the sites table, the shared `@id`s, the disambiguation string), and to armstr.ng's `src/data/profile.ts` and projects page.

## Milestones

**M0: Feasibility spikes (~1 week).** These answer the questions everything else depends on.

- **Context coverage:** a ContextProbe tool logs what Accessibility returns in about 15 apps: Mail, Outlook, Gmail in Safari and Chrome, Slack, Notes, Pages, Word, Google Docs, Notion, Obsidian, VS Code and Preview.
- **The split:**
  - Accessibility, Apple Events and ScreenCaptureKit in an unsandboxed app that has denied itself the network;
  - Full Disk Access attribution, the Notes temporary exception, and a home-folder bookmark from the sandboxed engine;
  - Sparkle's Downloader from an app that has no network.
- **Browsers:** URL reading in each browser, and any reliable signal for Safari's private windows.
- **Model:**
  - memory and latency with only the text encoder resident (q8 vs. bf16);
  - indexing time for a whole home folder with the default skips.
- **Files:**
  - reading Notes on macOS 27;
  - `kMDItemLastUsedDate` coverage.

**Exit:** go or no-go on the split, and the list of apps that need OCR.

**M1: Index and CLI (~2 weeks).**

- Scaffold the monorepo.
- Build AppearsKit (sources, extractors, store, vector index) and AppearsModel (the vendored port).
- Make the demo corpus.
- Write `appears index`, `related <file>` and `eval`, and record a first eval baseline.

**M2: The v0 app, pull plus shadow (~3 weeks).**

- Run the design exploration.
- Build the app and the engine split: menu bar item, hotkey, context reader, ranker, panel, feedback, journal, exclusions, onboarding and settings.
- Turn on shadow logging.

**M3: Dogfood (2 weeks, Colin only).**

- Tune the ranker from the journal.
- Fix capture gaps.
- Check the ambient gate.

**M4: Earn push (~2 weeks).** Add the calibration model, the glyph's "something's here" state and the budgets, then dogfood for another week.

**M5: Ship.**

- Finish the brand and the site.
- Configure signing and notarization credentials, verify Sparkle across two signed releases, and add the Homebrew cask.
- Make the README GIF.
- Open the repo and launch.

**v1 backlog:**

- **Voice Memos and audio:** read the `.m4a` files in `group.com.apple.VoiceMemos.shared` (Full Disk Access). Each memo already carries Apple's transcript in a `tsrp` atom; SpeechAnalyzer covers other audio. Native audio embeddings (EmbeddingGemma 2's audio tower, about 600 MB more) only if they find what transcripts miss.
- **More sources:** Mail (emlx, Full Disk Access), Photos (PhotoKit), video (frames and audio).
- **Messages:** built early on 2026-10-15 as a direct source, including local photos; never shares whosaid's index.
- **screenpipe:** read its SQLite file, never its local HTTP API, which would need the network.
- **Calendar as context:** "you're about to meet Dana" is a context too. Built early, on 2026-10-15 (see README.md's "Meetings").

## Risks

1. **Precision is the product.** At 60% precision, people stop looking within a week. Mitigations: pull and shadow mode during development, the dogfooding gate before ambient ships on by default, calibration, and negative eval scenarios.
2. **Trust.** "An app that reads your screen" is what sparked the Recall backlash, and the screen reader can't be sandboxed. Mitigations:
   - the split, with each part's enforcement stated plainly;
   - nothing stored about context;
   - open source;
   - exclusions and pause.
3. **Capture gaps.** Canvas apps, Electron apps without AX and Safari's private windows need OCR or exclusion. OCR brings monthly Screen Recording prompts.
4. **Apple goes proactive.** Siri in macOS 27 already has on-screen awareness and personal context. Appears' edges: it's open, local, cross-modal, works on your own files, and is careful about interrupting.
5. **An always-on model is heavy.** Mitigations: only the text encoder stays resident, the other towers load on demand, and Matryoshka vectors.
6. **iCloud placeholders** can trigger downloads by accident.
7. **The model port is new:** v0.1.0, released 2026-10-06. It's vendored and checked against Google's reference vectors, as in whosaid.

## Decisions (Colin, 2026-10-15)

1. **Process split:** an unsandboxed app with no networking code (it can't deny itself the network; see Permissions), plus a sandboxed engine with no network entitlement. The fallback, if M0 finds a problem, is a sandboxed app plus a tiny unsandboxed Accessibility helper.
2. **DigUp:** Appears builds its own index and borrows ideas from DigUp as needed. DigUp's index won't be a source.
3. **Code from whosaid:** copy in whatever's useful, no provenance note and no shared package. Engineering only; never its UX or design.
4. **Voice memos:** not in v0. They're in the v1 backlog.
5. **Ambient:** on by default at launch, once the dogfooding gate is met.
6. **Site:** static Astro plus the small hand-written negotiation Worker.
7. **Repo:** private for now.
8. **Name:** "Appears", capitalized.
9. **Browsers:** Arc and Dia aren't supported targets.
10. **Sources:** index as much as makes sense by default; Include and Exclude lists give control to anyone who wants it.
11. **Logo:** Orbit, chosen on 2026-10-15. Keep the shadcn zinc/blue direction; use an open ring with a detached dot at the upper right, and monochrome menu bar states. See `brand/README.md` for geometry and regeneration.
12. **Distribution (2026-10-15):** a lightweight DMG at `appea.rs/app.dmg`, built and notarized in GitHub Actions, stored in Cloudflare R2. The model downloads separately in the background on first launch while the user completes onboarding. This supersedes bundling model weights in the engine.
13. **Explicit search (2026-10-15):** a separate Spotlight-style window for semantic search, opened manually or with its own configurable shortcut. Context recall stays available with its existing shortcut and menu bar click.
