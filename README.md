# Appears

A Mac menu bar app that notices what you're looking at (the email you're replying to, the doc you're editing, the page you're reading) and quietly shows related things you already have and probably forgot: an old screenshot, a photo of a quote, a PDF from two years ago. You never type a query. Everything runs on the Mac.

Site: [appea.rs](https://appea.rs) (in `web/`). MIT licensed. In private testing. The plan and the reasoning behind it are in [PLAN.md](PLAN.md).

## How it works

- **Context:** the app reads the frontmost window through the Accessibility API: title, the document it shows, the field you're typing in, the selection, the visible text. It reads only when something changes, in memory, and drops it. Browser URLs come from Apple Events (Safari, Chrome) or Accessibility (Firefox). When a window has no readable text and you ask, it can OCR just that window (Screen Recording permission, optional).
- **Index:** the engine indexes everything sensible in your home folder (documents, PDFs, images and screenshots) plus Apple Notes. It skips:
  - `~/Library`, code checkouts (any folder with `.git`), package and build folders (`node_modules`, `dist`, `vendor`, `obj`…), caches;
  - coding agents' workspaces (`~/conductor`, `~/Documents/Codex`…);
  - data dumps: a folder with more than 150 plain-text files directly in it;
  - plain text over 2 MB, and boilerplate (LICENSE, CHANGELOG…);
  - text that is mostly numbers, which is indexed by name only. Text, PDF pages and images are embedded by Google's EmbeddingGemma 2 on MLX, in one vector space, next to an FTS5 full-text index. Settings has Include and Exclude lists.
- **Ranking:** vector search (text and images) and full-text search on the names, numbers and rare words in the context are fused by rank. Then:
  - **Forgotten:** results are weighted toward what you haven't touched in months. Anything open or touched in the last 3 days is never shown.
  - **New:** what's in the same folder or repeats the window title counts less.
  - **Varied:** results are diversified, so you don't get three near-copies.
- **Confidence:** each result gets a 0–1 score built from how far it stands above the context's other candidates. `appears eval` measures it.
- **Meetings:** with Calendar access (optional), Appears also looks once before each meeting, 10 minutes ahead by default. The event stands in for a window: its title, the people invited, and its location and notes, minus the join links, dial-ins and passcodes. All-day events, ones you declined, and blocks with nobody else and nothing written in them are skipped. One timer waits for the next meeting; nothing polls. The lead time replaces the dwell, everything else below applies as is, and the panel says which meeting it's for ("For Kitchen walkthrough at 2:00 PM").
- **When to show something:** you can always ask, with ⇧⌘Space or a click on the menu bar ring. On its own, Appears looks only after you've stayed in one context for 15 seconds. It changes the ring (a dot appears) only when a result is confident and the budget allows: a few per hour, with backoff after each ignored or dismissed suggestion. It never sends notifications or makes sounds. "Log only" mode records what it would have shown, without showing it.
- **Measuring:** a journal records each suggestion and what you did with it (opened, previewed, dragged out, dismissed, ignored). It holds item ids and scores, and a salted fingerprint of the context, never its text. Settings → Stats and `appears stats` turn it into precision numbers.

## Privacy, and how each part is enforced

- **The engine** (`AppearsEngine.xpc`: file reading, the model, the index, the journal) runs in the App Sandbox with no network entitlement, so macOS blocks every connection. It has read-only access to your home folder and `/Volumes`. Check it:

  ```bash
  codesign -d --entitlements - mac/build/DerivedData/Build/Products/Release/Appears.app/Contents/XPCServices/AppearsEngine.xpc
  ```

- **The app** reads the screen through the Accessibility API, which Apple doesn't allow in the sandbox, so it isn't sandboxed, and nothing in macOS stops it from connecting. It has no networking code, and `mac/scripts/check-no-network.sh` fails if its binary imports any networking API (sockets, URLSession, Network.framework, CFNetwork streams):

  ```bash
  mac/scripts/check-no-network.sh mac/build/DerivedData/Build/Products/Release/Appears.app
  ```

  It can't sandbox itself either. A self-applied `sandbox_init` profile, even one that allows everything except IP networking, makes macOS refuse the process Accessibility, and on macOS 27 the built-in named `no-network` profile kills the process outright. Both found 2026-10-15.
- **Nothing about what was on screen is stored,** and the same goes for calendar events, which are read through EventKit in memory and never logged. Password managers, Keychain Access, System Settings, secure text fields and private browser windows (Chrome incognito, Firefox private) are never read. Safari can't say whether a window is private, so ambient mode skips Safari unless you turn it on; asking still works there. You can exclude more apps, or pause.

## Repository

```
mac/
  App/                      the menu bar app (AppKit + SwiftUI): status item, panel, settings, onboarding
  Engine/                   the sandboxed XPC service
  Packages/AppearsKit/      builds and tests with the Command Line Tools
    AppearsCore/            sources, extractors, Notes reader, index, ranking, journal, surface policy
    AppearsContext/         Accessibility reader, browser URLs, exclusions, OCR fallback
  Packages/AppearsModel/    EmbeddingGemma 2 on MLX (copied from whosaid), the `appears` CLI
  Tools/                    ContextProbe (`appears-context`), Snapshots (`appears-snapshots`)
  scripts/                  model download and preparation, reference vectors, check-no-network
  project.yml               XcodeGen spec (Appears.xcodeproj is generated, not committed)
web/                        appea.rs (Astro, static, plus a small Markdown-negotiation Worker)
demo/                       a made-up home folder and eval scenarios; never real data
brand/                      the mark and app icon
```

## Building and running

You need Xcode 27 (with its Metal toolchain), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [uv](https://docs.astral.sh/uv/). If `xcode-select -p` points at the Command Line Tools, prefix Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

1. The model (about 1.5 GB down, 870 MB bundled). `mac/Models/` is git-ignored; on this Mac it was copied from whosaid's prepared model. Otherwise:

   ```bash
   mac/scripts/fetch-model.sh
   ```

2. Build the app (Release is much faster than Debug: MLX runs unoptimized in Debug):

   ```bash
   cd mac && xcodegen && xcodebuild -project Appears.xcodeproj -scheme Appears -configuration Release -derivedDataPath build/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
   ```

3. Run it from a stable place, so permissions stick:

   ```bash
   cp -R mac/build/DerivedData/Build/Products/Release/Appears.app /Applications/ && open /Applications/Appears.app
   ```

Setup asks for Accessibility (required), then optionally Full Disk Access (Notes, and no prompts for Desktop/Documents/Downloads), Calendar (looking ahead to meetings) and Screen Recording (OCR on ask). Builds are ad-hoc signed by default. macOS ties Accessibility and Full Disk Access to the exact signature, and an ad-hoc signature changes on every build, so each rebuild silently loses both permissions. To keep them, create `mac/Config/Local.xcconfig` (git-ignored) with a stable identity, then run `xcodegen` and rebuild. Either your team (`DEVELOPMENT_TEAM = …` and `CODE_SIGN_IDENTITY = Apple Development`) or a self-signed code-signing certificate from Keychain Access (`CODE_SIGN_IDENTITY = Appears Dev`) works. Without one, remove Appears from both lists in System Settings and add it again after each rebuild.

The first index takes a while and pauses in Low Power Mode; the menu bar ring is open while it's working. Measured on 2026-10-15 on Colin's Mac (about 11,000 files after the skip rules):

- documents and PDFs run at about 2.7 a second;
- scanned PDFs take 10–17 seconds each, for OCR;
- images run at about 13 a second.

Watch it with:

```bash
log stream --level info --predicate 'subsystem == "rs.appea.appears"'
```

The log shows the scan, a rate line every 100 files, slow files (over 10 seconds), and files that failed or timed out (after 120 seconds). Paths are redacted.

### Try it without your files

The demo is a made-up home folder: a kitchen remodel with a contractor, a dental claim, a Lisbon trip, a cabin's wifi card, and about 120 distractors.

```bash
python3 -I demo/set-ages.py
```

```bash
open -n /Applications/Appears.app --args -demo "$PWD/demo/files"
```

`-demo` keeps a separate index. Add `-ask "<text>"` to run one ask with scripted text once indexing finishes, which also works without the Accessibility permission. Then open, say, a text file in TextEdit containing "Hi Dana, can you confirm the quote covers moving the outlet?" and press ⇧⌘Space.

`-event "<title>"` stands in a made-up meeting for your calendar, which is then never read (nor is it with `-demo`). It starts 30 seconds after the lead time, so the ring gets its dot about half a minute after launch if the result is confident. Add `-event-with "Name <email>; …"`, `-event-location`, `-event-notes` and `-event-in <seconds>`:

```bash
open -n /Applications/Appears.app --args -demo "$PWD/demo/files" -event "Kitchen walkthrough with Dana Ruiz" -event-with "Dana Ruiz <dana@ruizdaughters.example>"
```

## Tests and the eval

```bash
cd mac/Packages/AppearsKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

```bash
cd mac/Packages/AppearsModel && xcodebuild -scheme appears -destination 'platform=macOS' -derivedDataPath ../../build/ModelDerivedData -configuration Release build
```

```bash
mac/build/ModelDerivedData/Build/Products/Release/appears eval --verbose
```

`appears eval` indexes `demo/files` in a temporary folder and scores `demo/scenarios.json`. It reports recall@3, MRR, ambient hits (right and confident), false surfaces on negative scenarios (contexts where the right answer is silence), and whether anything recent was shown. Baseline on 2026-10-15, with the meeting scenarios: recall@3 0.98, MRR 1.00, ambient hits 14/14, false surfaces 0/11, median 50 ms. Scenarios whose app is "Calendar" are made into a context the way the app reads an event. The confidence weights were fitted to these same scenarios, so add scenarios before trusting the numbers.

Other commands:

- `appears related "<text>"` and `appears index [--root DIR]` work on the real index (the terminal needs Full Disk Access for Notes).
- `appears stats --data <engine data folder>` prints the journal's numbers.
- `appears-context` (scheme `appears-context`) prints what Accessibility reads from the frontmost window every 3 seconds, for checking coverage app by app. The terminal needs Accessibility.
- `appears-snapshots` (scheme `appears-snapshots`, run from the repo root) renders the panel and onboarding, light and dark, to `mac/build/snapshots`.

## Not done yet

- **Calibration:** not learned yet. The confidence weights are hand-set from the eval; fitting them to the journal is next.
- **Notes attachments** (scans, photos in notes) aren't indexed; note text is.
- **Folders added under Include** are scanned, but not watched for changes until the next full rescan (every 6 hours) or a relaunch.
- **Releases:**
  - signing with a team, notarization;
  - Sparkle (`web/public/appcast.xml` is ready and empty; the app must use Sparkle's Downloader XPC service, since it can't reach the network itself);
  - `release.sh` with its entitlement checks;
  - the Homebrew cask.
- **Not in v0:** voice memos and audio, video, Mail, Photos (see PLAN.md).
