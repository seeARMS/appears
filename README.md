# Appears

A Mac menu bar app that notices what you're looking at (the email you're replying to, the doc you're editing, the page you're reading) and quietly shows related things you already have and probably forgot: an old screenshot, a photo of a quote, a PDF from two years ago. You never type a query. Everything runs on the Mac.

Site: [appea.rs](https://appea.rs) (in `web/`). MIT licensed. The plan and the reasoning behind it are in [PLAN.md](PLAN.md).

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
- **Confidence:** each result gets a 0–1 score built from how far it stands above the context's other candidates. A clear match counts for more when what you're writing asks for something you had ("what was the wifi password again?"). `appears eval` measures it.
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
- **`appears mcp`,** the CLI's server for agents, has no networking code either and runs only when an agent you set up starts it. What that agent does with the results is up to the agent; see [For agents](#for-agents).
- **Nothing about what was on screen is stored,** and the same goes for calendar events, which are read through EventKit in memory and never logged. Password managers, Keychain Access, System Settings, secure text fields and private browser windows (Chrome incognito, Firefox private) are never read. Safari can't say whether a window is private, so ambient mode skips Safari unless you turn it on; asking still works there. You can exclude more apps, or pause.
- **The model download** runs in `AppearsDownloader.xpc`, a separate sandbox with network.client only and no access to your files or screen. On first launch it downloads about 914 MB of pinned model files while you go through onboarding. Every file must match its bundled size and SHA-256 before an atomic install makes the model available to the engine. Completed files and resume data survive download failures; Retry continues setup. Once installed, the app works offline. The app and engine never download anything themselves.

## Repository

```
mac/
  App/                      the menu bar app (AppKit + SwiftUI): status item, panel, settings, onboarding
  Engine/                   the sandboxed XPC service
  Downloader/               the sandboxed first-run model downloader, no user-file access
  Packages/AppearsKit/      builds and tests with the Command Line Tools
    AppearsCore/            sources, extractors, Notes reader, index, ranking, journal, surface policy
    AppearsContext/         Accessibility reader, browser URLs, exclusions, OCR fallback
    AppearsMCP/             `appears mcp`: the MCP server for agents (stdio), read-only on the index
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

1. Build the lightweight app (Release is much faster than Debug: MLX runs unoptimized in Debug):

   ```bash
   cd mac && xcodegen && xcodebuild -project Appears.xcodeproj -scheme Appears -configuration Release -derivedDataPath build/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
   ```

2. For local development before the model is hosted, prepare and seed the verified cache once, from the repo root. `mac/Models/` is git-ignored. This isn't needed by people downloading the released app:

   ```bash
   mac/scripts/fetch-model.sh
   python3 -I mac/scripts/install-local-model.py
   ```

3. Run it from a stable place, so permissions stick:

   ```bash
   cp -R mac/build/DerivedData/Build/Products/Release/Appears.app /Applications/ && open /Applications/Appears.app
   ```

Setup asks for Accessibility (required), then optionally Full Disk Access (Notes, and no prompts for Desktop/Documents/Downloads), Calendar (looking ahead to meetings) and Screen Recording (OCR on ask). Builds are ad-hoc signed by default. macOS ties Accessibility and Full Disk Access to the exact signature, and an ad-hoc signature changes on every build, so each rebuild silently loses both permissions. To keep them, create `mac/Config/Local.xcconfig` (git-ignored) with a stable identity, then run `xcodegen` and rebuild. Either your team (`DEVELOPMENT_TEAM = …` and `CODE_SIGN_IDENTITY = Apple Development`) or a self-signed code-signing certificate from Keychain Access (`CODE_SIGN_IDENTITY = Appears Dev`) works. Without one, remove Appears from both lists in System Settings and add it again after each rebuild.

The first index takes a while and pauses in Low Power Mode; the menu bar orbit has a wider gap while it's working. Measured on 2026-10-15 on Colin's Mac (about 11,000 files after the skip rules):

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

The model's tests, and `appears mcp` run as its own process with the model on the demo (they skip without the model):

```bash
cd mac/Packages/AppearsModel && xcodebuild test -scheme AppearsModel-Package -destination 'platform=macOS' -derivedDataPath ../../build/ModelDerivedData
```

```bash
cd mac/Packages/AppearsModel && xcodebuild -scheme appears -destination 'platform=macOS' -derivedDataPath ../../build/ModelDerivedData -configuration Release build
```

```bash
mac/build/ModelDerivedData/Build/Products/Release/appears eval --verbose
```

`appears eval` indexes `demo/files` in a temporary folder and scores `demo/scenarios.json`. It reports recall@3, MRR, ambient hits (right and confident), false surfaces on negative scenarios (contexts where the right answer is silence), and whether anything recent was shown. Baseline on 2026-10-15, with the meeting and asking scenarios (20 + 19): recall@3 0.98, MRR 1.00, ambient hits 20/20, false surfaces 0/19, matched lines 3/3 with none unexpected, median 181 ms (noisy: measured while other builds ran). Scenarios whose app is "Calendar" are made into a context the way the app reads an event. The confidence weights were fitted to these same scenarios, so add scenarios before trusting the numbers.

Other commands:

- `appears related "<text>"` and `appears index [--root DIR]` work on the CLI's own index in `~/Library/Application Support/rs.appea.appears.cli` (or `--data DIR`), not the app's; the terminal needs Full Disk Access for Notes.
- `appears mcp` lets local agents ask the app's index; see [For agents](#for-agents).
- `appears stats --data <engine data folder>` prints the journal's numbers.
- `appears-context` (scheme `appears-context`) prints what Accessibility reads from the frontmost window every 3 seconds, for checking coverage app by app. The terminal needs Accessibility.
- `appears-snapshots` (scheme `appears-snapshots`, run from the repo root) renders the panel and onboarding, light and dark, to `mac/build/snapshots`.

## For agents

`appears mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server on stdin and stdout. Agents on your Mac (Claude Code, Claude desktop, Codex) can ask it what you already have about something: "what do I have about the Lisbon trip", "find the wifi card from the cabin". The menu bar never asks you for a query; an agent can.

- **It does nothing unless you set it up.** Neither the app nor the engine starts it. An agent you configure starts it, and it runs only while that agent does.
- **Appears sends nothing anywhere, but the agent you connect may.** `appears mcp` has no networking code: it answers on the pipes the agent opened, reads the index read-only, and stores nothing. Agent questions aren't journaled, so they never count toward the pull, shadow or ambient numbers, and neither questions nor results are logged. But what it answers becomes part of the agent's conversation, and the agent may send that to its model provider: paths, why each matched, and the matching text, which can be the password on a photo of a wifi card. Connect only agents you'd show those files to.
- **Tools,** both read-only:
  - `related`: `text` (required), `limit` (default 5, at most 20) and `prefer_forgotten` (default off). Each result has its path, title and kind, the one-line reason, the matching snippet, when it was last opened and modified, the page for PDFs, and a 0–1 confidence. They come back as structured content and as a short text.
  - `related_to_file`: `path`, with the same options. It searches with that file's own stored vectors, so it needs no model call.
- **Ranking:** the app's relevance, name matches and variety, without the "forgotten" weighting, because an agent asking outright should get yesterday's file as readily as last year's. `prefer_forgotten: true` ranks as the menu bar does. Excluded folders and kinds, Notes switched off, and "Never show this" apply exactly as in the app. Results under 0.15 confidence are marked "less likely", as the panel does.
- **The index:** by default the app's own, opened read-only beside the running engine (SQLite's WAL lets it read while the engine writes), so answers keep up as the app indexes. `--demo` reads the index of the app's `-demo` mode, and `--data DIR` any index made with `appears index --data DIR`. The model loads on the first question (a couple of seconds) and stays loaded; connecting is instant. After that a question takes about 50 ms on the demo.
- **Protocol:** stdio only. It speaks MCP 2026-07-28 (stateless, with `server/discover`) and the `initialize` handshake of 2025-11-25 back to 2024-11-05, as heade.rs's server does. Claude Code 2.1 uses 2026-07-28.

Build the CLI (see [Tests and the eval](#tests-and-the-eval)), then add it to Claude Code:

```bash
claude mcp add appears -- "$PWD/mac/build/ModelDerivedData/Build/Products/Release/appears" mcp
```

For Claude desktop, add it to `~/Library/Application Support/Claude/claude_desktop_config.json` and restart Claude:

```json
{
  "mcpServers": {
    "appears": {
      "command": "/path/to/appears/mac/build/ModelDerivedData/Build/Products/Release/appears",
      "args": ["mcp"]
    }
  }
}
```

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.appears]
command = "/path/to/appears/mac/build/ModelDerivedData/Build/Products/Release/appears"
args = ["mcp"]
```

The app keeps its index in the engine's sandbox container, and macOS doesn't let other apps read containers. The app that runs the agent (Terminal, iTerm, Claude, Codex) needs Full Disk Access, or `appears mcp` answers every question with an error saying so. The model comes from `mac/Models/appears-model` in the checkout, or from the app's verified downloaded model cache; `--model` picks another.

To try it on the demo without the app, index `demo/files` into a folder of its own and point the server at it:

```bash
mac/build/ModelDerivedData/Build/Products/Release/appears index --root demo/files --data /tmp/appears-demo --no-notes
```

```bash
claude mcp add appears-demo -- "$PWD/mac/build/ModelDerivedData/Build/Products/Release/appears" mcp --data /tmp/appears-demo
```

Or pipe it a question by hand:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"related","arguments":{"text":"what is the wifi password at the cabin"}}}' | mac/build/ModelDerivedData/Build/Products/Release/appears mcp --data /tmp/appears-demo
```

## Releasing to appea.rs

`.github/workflows/release.yml` runs on a pushed `vX.Y.Z` tag (which must match `VERSION`), or manually against an existing tag. It tests the core and web routes, prepares the separately hosted model, builds the arm64 app, checks the privacy boundaries, signs with Developer ID, notarizes and staples the app and DMG, then uploads to the private `appears-downloads` R2 bucket in the personal Cloudflare account. `mac/scripts/release.sh` only builds; the upload steps are separate.

The site Worker exposes `https://appea.rs/app.dmg`, an uncached redirect to an immutable `/downloads/vX.Y.Z/Appears.dmg`. The landing page, Markdown and llms.txt share that link. The upload script reads back and hashes the R2 files before switching `latest.json`. Previous version URLs keep working, including paused downloads. The thin app is eligible for the Worker's edge cache; model files above Cloudflare's 512 MB standard limit stream from R2. Nothing private from the source repository is published.

One-time setup, before the first release:

1. In `web/`, use the personal profile to create the private bucket: `npm run cf -- r2 bucket create appears-downloads`. Keep public bucket access disabled; the Worker has an R2 binding. Deploy the updated site Worker once so `/downloads/*` and `/models/*` are served.
2. Add GitHub repository secrets: `APPLE_CERTIFICATE_BASE64` (exported Developer ID Application `.p12`, base64 encoded), `APPLE_CERTIFICATE_PASSWORD`, `NOTARY_KEY_P8` (App Store Connect private key), `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` (Object Read & Write, scoped to this bucket). Optional `HF_TOKEN` is used only to prepare the upstream model. Keep long-term credential copies in 1Password; never put values in the repo, shell history or chat.
3. Add repository variables: `DEVELOPER_ID` (full Developer ID Application identity), `APPLE_TEAM_ID`, and `NOTARY_KEY_ID`. Set `NOTARY_ISSUER` for a Team API key; leave it unset for an Individual key.
4. When ready to release, update `VERSION`, commit the intended release, and push its `vX.Y.Z` tag. Signing credentials live only in a temporary runner keychain and are removed after the job.

No R2 bucket, credentials, deployment or first release is created by adding these files. For rollback, put a previously verified version and its SHA-256 back into the bucket's `latest.json`; don't overwrite immutable version or model files. A failed upload never promotes an unverified DMG. A version that was already uploaded is not overwritten on rerun.

## Not done yet

- **Calibration:** not learned yet. The confidence weights are hand-set from the eval; fitting them to the journal is next.
- **Notes attachments** (scans, photos in notes) aren't indexed; note text is.
- **Folders added under Include** are scanned, but not watched for changes until the next full rescan (every 6 hours) or a relaunch.
- **Releases:**
  - configure the Apple signing/notarization credentials, R2 bucket and GitHub settings above, then verify the first live workflow and download;
  - Sparkle (`web/public/appcast.xml` is ready and empty; the app must use Sparkle's Downloader XPC service, since it can't reach the network itself);
  - the Homebrew cask.
- **`appears mcp` without a checkout or Full Disk Access:** the CLI isn't in the app or the Homebrew cask yet. Reading the app's index needs Full Disk Access for the agent's app. Tested 2026-10-15 on macOS 27: nothing signed with the self-signed dev certificate gets into the engine's container, even with the engine's exact identifier. Apple lets apps with the same Team ID read each other's containers, so shipping the CLI inside Appears.app under the release Team ID should work, but it's untested until there is a Team ID. Moving the index out of the container would let any process read Notes and Documents text, so it stays where it is.
- **Not in v0:** voice memos and audio, video, Mail, Photos (see PLAN.md).
