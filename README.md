# Appears

A Mac menu bar app that notices what you're looking at (the email you're replying to, the doc you're editing, the page you're reading) and quietly shows related things you already have and probably forgot: an old screenshot, a photo of a quote, a PDF from two years ago. You can also search by describing what you remember. Everything runs on the Mac.

Site: [appea.rs](https://appea.rs) (in `web/`). MIT licensed. The plan and the reasoning behind it are in [PLAN.md](PLAN.md).

## How it works

- **Context:** the app reads the frontmost window through the Accessibility API: title, the document it shows, the field you're typing in, the selection, the visible text. It reads only when something changes, in memory, and drops it. Browser URLs come from Apple Events (Safari, Chrome) or Accessibility (Firefox). When a window has no readable text and you ask, it can OCR just that window (Screen Recording permission, optional).
- **Index:** the engine indexes everything sensible in your home folder (documents, PDFs, images and screenshots) plus Apple Notes and Messages, including photos already downloaded on this Mac. Messages are read directly from `~/Library/Messages/chat.db` into Appears' own index, independently of whosaid. Each message is embedded with nearby conversation, and photos use the image model plus on-device OCR. It skips:
  - `~/Library`, code checkouts (any folder with `.git`), package and build folders (`node_modules`, `dist`, `vendor`, `obj`…), caches;
  - coding agents' workspaces (`~/conductor`, `~/Documents/Codex`…);
  - data dumps: a folder with more than 150 plain-text files directly in it;
  - plain text over 2 MB, and boilerplate (LICENSE, CHANGELOG…);
  - text that is mostly numbers, which is indexed by name only. Text, PDF pages and images are embedded by Google's EmbeddingGemma 2 on MLX, in one vector space, next to an FTS5 full-text index. Settings has Include and Exclude lists. Sources → Include Messages and photos is on by default; switching it off removes both from the index. New and edited messages are checked each minute; deletions, unsends and newly downloaded photos are reconciled at least every ten minutes, or immediately with “Look for new items now”.
- **Ranking:** vector search (text and images) and full-text search on the names, numbers and rare words in the context are fused by rank. Then:
  - **Forgotten:** results are weighted toward what you haven't touched in months. Recent files rank lower. Messages have only a small age penalty (up to 15% in ranking), so a conversation from yesterday can still answer today's question. The open document is excluded.
  - **New:** what's in the same folder or repeats the window title counts less.
  - **Varied:** results are diversified, so you don't get three near-copies.
- **Photos:** when the window shows a picture (a photo open in Preview), the picture itself is the query: the engine uses the vector it indexed for that file, or embeds it then if it isn't indexed yet, keeping that vector in memory only. It finds other photos of the same thing and notes and messages about it. Any words in the window are blended in, except a title that is just the file's name.
- **Confidence:** each result gets a 0–1 score built from how far it stands above the context's other candidates. A clear match counts for more when what you're writing asks for something you had ("what was the wifi password again?"). `appears eval` measures it.
- **Meetings:** with Calendar access (optional), Appears also looks once before each meeting, 10 minutes ahead by default. The event stands in for a window: its title, the people invited, and its location and notes, minus the join links, dial-ins and passcodes. All-day events, ones you declined, and blocks with nobody else and nothing written in them are skipped. One timer waits for the next meeting; nothing polls. The lead time replaces the dwell, everything else below applies as is, and the panel says which meeting it's for ("For Kitchen walkthrough at 2:00 PM").
- **When to show something:** you can always ask, with ⇧⌘Space or a click on the menu bar ring. On its own, Appears first looks after you've stayed in one context for 15 seconds. Editing in the same conversation or document can trigger another lookup after a 1.5-second typing pause, at most once every 10 seconds. Unchanged text isn't searched again, and answers for an earlier draft are discarded. It changes the ring (a dot appears) only when a result is confident and the budget allows: a few per hour, with backoff after each ignored or dismissed suggestion. It never sends notifications or makes sounds. "Log only" mode records what it would have shown, without showing it.
- **Search:** press ⌃⇧Space, choose “Search Appears…” from the ring's right-click menu, or reopen Appears from Finder or Spotlight. A centered search window finds up to 20 results by meaning using the same text and image embeddings, with full-text matching for names and numbers. All enabled sources participate, including recent files, Notes and Messages. Include/Exclude settings and “Never show this” apply. Type to search, use ↑/↓ to select, Return to open, ⌘Return to reveal in Finder, ⌘Y to preview, and Escape or a click away to close. Spaces and standard text-editing shortcuts work in the query. Settings → General has separate configurable shortcuts for context recall and search. Search needs no Accessibility or Screen Recording permission. Queries and results live only in memory and never enter the suggestion journal or its precision metrics; closing clears them.
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
- **App updates** use Sparkle's separate sandboxed Downloader, with network.client only and no user-file access. The pinned Sparkle source build removes its in-process downloader and web views; the privacy check inspects the framework as well as the app. Update feeds and DMGs must have valid Ed25519 signatures. No analytics or system profiling is sent.

## Updates

Settings → Updates has **Automatically check for updates**, on by default. Sparkle checks once a day while the app is running and catches up after relaunch when a check is overdue. Turning it off stops scheduled update checks; **Check for Updates…** in Settings or the menu still works. First-run model setup is independent of this preference.

Scheduled checks never open a window or steal focus. An available version appears in Settings and the menu. Choose **View Changelog and Update…** to see the available version, your installed version, and the GitHub release's changelog, then choose whether to download and install. Release notes are copied from the matching published GitHub release into the signed feed during the release build. The app needs no GitHub token and renders Markdown as native text, without loading remote images or web content.

Models stay pinned to compatible app releases. Installing an app with a new model pin automatically downloads and verifies that model on the next launch; it does not independently chase upstream model versions. Existing model files are reused when the pin is unchanged.

## Repository

```
mac/
  App/                      the menu bar app (AppKit + SwiftUI): status item, panel, settings, onboarding
  Engine/                   the sandboxed XPC service
  Downloader/               the sandboxed first-run model downloader, no user-file access
  Packages/AppearsKit/      builds and tests with the Command Line Tools
    AppearsCore/            sources, extractors, Notes and Messages readers, index, ranking, journal, surface policy
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

For contributions and local checks, see [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities and private-data exposure through [SECURITY.md](SECURITY.md).

## Building and running

You need Xcode 27 (with its Metal toolchain), [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an existing Apple code-signing identity. The convenience command below also needs npm; [uv](https://docs.astral.sh/uv/) is only needed to prepare a model manually. If `xcode-select -p` points at the Command Line Tools, prefix manual Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

For everyday local use, from the repository root:

```bash
npm run rebuild
```

No `npm install` is needed. This builds the current checkout (including uncommitted changes) in Release, verifies signatures, privacy boundaries and bundled licenses, quits Appears, replaces `/Applications/Appears.app`, and checks that it launches. The previous app is restored if installation or launch fails. It uses incremental builds and reuses the installed app's Apple signing certificate from your keychain to help permissions stick. Settings, the index and downloaded model stay in their existing locations. The first build also fetches and builds the pinned Sparkle dependency; later runs reuse its checkout and build cache. The script selects `/Applications/Xcode.app` by default, even if `xcode-select` points at the Command Line Tools.

The command builds local source; it does not pull Git changes. Update your normal checkout with `git pull --ff-only` first when you want the latest `main`, or run it in a feature checkout to try that work.

Use `npm run rebuild -- --build-only` to build and verify without installing or launching. For a per-user install, create `~/Applications` and run `APPEARS_INSTALL_DIR="$HOME/Applications" npm run rebuild`. To choose an existing signing certificate explicitly, set `APPEARS_SIGN_IDENTITY` to its full name or SHA-1 from `security find-identity -v -p codesigning`. Without an installed Apple-signed app, the script selects a single Developer ID Application identity, then Apple Development if none is available. It never creates certificates. Self-signed certificates such as the old `Appears Dev` have no Apple Team ID and fail hardened runtime's library validation when loading Sparkle, so the command requires an Apple-issued identity. Switching identities can require granting permissions again. Local builds without a configured Sparkle public key leave update checks unavailable.

To build and install manually instead:

1. Build the isolated Sparkle framework once, then the lightweight app (Release is much faster than Debug: MLX runs unoptimized in Debug):

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer mac/scripts/build-sparkle.sh
   cd mac && xcodegen && xcodebuild -project Appears.xcodeproj -scheme Appears -configuration Release -derivedDataPath build/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
   ```

2. The app downloads its pinned model on first launch. For local development or offline testing, you can also prepare and seed the verified cache once, from the repo root. `mac/Models/` is git-ignored. This isn't needed by people downloading the released app:

   ```bash
   mac/scripts/fetch-model.sh
   python3 -I mac/scripts/install-local-model.py
   ```

3. Run it from a stable place, so permissions stick:

   ```bash
   cp -R mac/build/DerivedData/Build/Products/Release/Appears.app /Applications/ && open /Applications/Appears.app
   ```

Setup asks for Accessibility (required), then optionally Full Disk Access (Notes, Messages and their photos, and no prompts for Desktop/Documents/Downloads), Calendar (looking ahead to meetings) and Screen Recording (OCR on ask). Manual builds are ad-hoc signed by default, which is useful for build checks but changes the permission identity on every rebuild. For a runnable app, use an Apple-issued identity with a Team ID, so hardened runtime can validate the embedded frameworks. For manual builds, put your team (`DEVELOPMENT_TEAM = …`) and identity (`CODE_SIGN_IDENTITY = Apple Development`, or your full Developer ID Application identity) in `mac/Config/Local.xcconfig` (git-ignored), then run `xcodegen` and rebuild. Keep that identity and the install path stable across rebuilds to preserve permissions.

First-run model setup was verified on 2026-10-15 with a Developer ID build: the restricted downloader installed all 12 pinned files from appea.rs, then the sandboxed engine indexed the 142-item demo and semantic search returned the kitchen quote photo. Moving from the old self-signed identity to Developer ID triggered macOS prompts to reuse the existing app-data containers. No sandbox restrictions were changed.

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

Add `-search "the quote for the kitchen"` instead to open semantic search on the demo, without reading a window or requiring Accessibility.

`-event "<title>"` stands in a made-up meeting for your calendar, which is then never read (nor is it with `-demo`). It starts 30 seconds after the lead time, so the ring gets its dot about half a minute after launch if the result is confident. Add `-event-with "Name <email>; …"`, `-event-location`, `-event-notes` and `-event-in <seconds>`:

```bash
open -n /Applications/Appears.app --args -demo "$PWD/demo/files" -event "Kitchen walkthrough with Dana Ruiz" -event-with "Dana Ruiz <dana@ruizdaughters.example>"
```

## Tests and the eval

After building Sparkle and the app, `mac/scripts/test-updates.sh` checks preference persistence, quiet discoveries and release validation in a separate fixture app, and renders the update settings and changelog in light and dark. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -I -m unittest discover -s mac/scripts/tests` verifies GitHub release metadata and real signatures, including tampering and mismatched keys. Both use made-up data and ephemeral test keys.

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

`appears eval` indexes `demo/files` in a temporary folder and scores `demo/scenarios.json`. It reports recall@3, MRR, ambient hits (right and confident), false surfaces on negative scenarios (contexts where the right answer is silence), and whether anything recent was shown. Baseline on 2026-10-16, with the meeting, asking and photo scenarios (22 + 21): recall@3 0.98, MRR 1.00, ambient hits 22/22, false surfaces 0/21, matched lines 3/3 with none unexpected, median 84 ms. A scenario with a `document` that is a picture (a photo open in Preview) is matched by the picture itself. Scenarios whose app is "Calendar" are made into a context the way the app reads an event. The confidence weights were fitted to these same scenarios, so add scenarios before trusting the numbers.

Other commands:

- `appears related "<text>"` and `appears index [--root DIR]` work on the CLI's own index in `~/Library/Application Support/rs.appea.appears.cli` (or `--data DIR`), not the app's; the terminal needs Full Disk Access for Notes and Messages. `--no-messages` skips conversations and their photos.
- `appears mcp` lets local agents ask the app's index; see [For agents](#for-agents).
- `appears stats --data <engine data folder>` prints the journal's numbers.
- `appears-context` (scheme `appears-context`) prints what Accessibility reads from the frontmost window every 3 seconds, for checking coverage app by app. The terminal needs Accessibility.
- `appears-snapshots` (scheme `appears-snapshots`, run from the repo root) renders the panel and onboarding, light and dark, to `mac/build/snapshots`.

## For agents

`appears mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server on stdin and stdout. Agents on your Mac (Claude Code, Claude desktop, Codex) can ask it what you already have about something: "what do I have about the Lisbon trip", "find the wifi card from the cabin". The app's separate Search window also accepts typed questions.

- **It does nothing unless you set it up.** Neither the app nor the engine starts it. An agent you configure starts it, and it runs only while that agent does.
- **Appears sends nothing anywhere, but the agent you connect may.** `appears mcp` has no networking code: it answers on the pipes the agent opened, reads the index read-only, and stores nothing. Agent questions aren't journaled, so they never count toward the pull, shadow or ambient numbers, and neither questions nor results are logged. But what it answers becomes part of the agent's conversation, and the agent may send that to its model provider: paths, why each matched, and the matching text, which can be the password on a photo of a wifi card. Connect only agents you'd show those files to.
- **Tools,** both read-only:
  - `related`: `text` (required), `limit` (default 5, at most 20) and `prefer_forgotten` (default off). Each result has its path, title and kind, the one-line reason, the matching snippet, when it was last opened and modified, the page for PDFs, and a 0–1 confidence. They come back as structured content and as a short text.
  - `related_to_file`: `path`, with the same options. It searches with that file's own stored vectors, so it needs no model call.
- **Ranking:** the app's relevance, name matches and variety, without the "forgotten" weighting, because an agent asking outright should get yesterday's file as readily as last year's. `prefer_forgotten: true` ranks as the menu bar does. Excluded folders and kinds, Notes or Messages switched off, and "Never show this" apply exactly as in the app. Results under 0.15 confidence are marked "less likely", as the panel does.
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

`.github/workflows/release.yml` runs when a stable GitHub release is published for a `vX.Y.Z` tag (which must match `VERSION`), or manually against an existing tag with a published release. Give the GitHub release a nonempty changelog. The workflow reads that exact release using its read-only GitHub token, tests the core and web routes, prepares the separately hosted model, builds the isolated Sparkle framework and arm64 app, checks the privacy boundaries, signs with Developer ID, notarizes and staples the app and DMG, then uploads to the private `appears-downloads` R2 bucket in the personal Cloudflare account. `mac/scripts/release.sh` only builds; the upload steps are separate.

The site Worker exposes `https://appea.rs/app.dmg`, an uncached redirect to an immutable `/downloads/vX.Y.Z/Appears.dmg`. The landing page, Markdown and llms.txt share that link. The upload script reads back and hashes the R2 files before switching `latest.json`. Previous version URLs keep working, including paused downloads. The thin app is eligible for the Worker's edge cache; model files above Cloudflare's 512 MB standard limit stream from R2. Nothing private from the source repository is published.

One-time setup, before the first release:

1. In `web/`, use the personal profile to create the private bucket: `npm run cf -- r2 bucket create appears-downloads`. Keep public bucket access disabled; the Worker has an R2 binding. Deploy the updated site Worker once so `/downloads/*` and `/models/*` are served.
2. Run `python3 -I scripts/configure-github.py --apply` to configure repository protections and the `release` environment, then check its output for settings GitHub could not apply. See [.github/MAINTAINERS.md](.github/MAINTAINERS.md). Add secrets to that environment: `APPLE_CERTIFICATE_BASE64` (exported Developer ID Application `.p12`, base64 encoded), `APPLE_CERTIFICATE_PASSWORD`, `NOTARY_KEY_P8` (App Store Connect private key), `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` (Object Read & Write, scoped to this bucket). Optional `HF_TOKEN` is used only to prepare the upstream model. Keep long-term credential copies in 1Password; never put values in the repo, shell history or chat.
3. Create a dedicated Ed25519 update-signing key, keep its long-term copy in 1Password, add its base64 private seed as the `SPARKLE_PRIVATE_KEY` environment secret, and its base64 public key as the `SPARKLE_PUBLIC_ED_KEY` environment variable. Release builds verify that they match. Never regenerate this key for an ordinary release. Local builds without a public key show that update checks are unavailable; they do not contact the feed. To test a development build against the real feed, provide the public key through `mac/Config/Local.xcconfig`.
4. Add environment variables: `DEVELOPER_ID` (full Developer ID Application identity), `APPLE_TEAM_ID`, and `NOTARY_KEY_ID`. Set `NOTARY_ISSUER` for a Team API key; leave it unset for an Individual key.
5. When ready to release, update `VERSION`, commit the intended release, push its `vX.Y.Z` tag, and publish a stable GitHub release with its changelog. Tag pushes alone do not publish a download. Signing credentials live only in a temporary runner keychain or private runner files and are removed after the job.

The release build signs both the DMG and an appcast containing GitHub's Markdown notes. `/appcast.xml` serves those signed bytes from R2 with a five-minute cache. The uploader promotes the feed only after reading back and verifying the immutable DMG. Publishing a private repository's release notes this way makes that changelog public, but never exposes the private source or GitHub credentials. Local release builds also need `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_PRIVATE_KEY_PATH`, and `GITHUB_RELEASE_PATH` (the matching GitHub release JSON).

No R2 bucket, credentials, deployment or first release is created by adding these files. For rollback, put a previously verified version and its SHA-256 back into the bucket's `latest.json`; don't overwrite immutable version or model files. A failed upload never promotes an unverified DMG. A version that was already uploaded is not overwritten on rerun.

Release tags must point to a commit reachable from `main`. For manual runs, select the version tag as the workflow ref and supply the same tag input. Validation runs before the job that can access the tag-only release environment.

The first release, `v0.1.0`, was built, signed, notarized and uploaded by GitHub Actions on 2026-10-15. The model package is hosted at its pinned R2 prefix; `https://appea.rs/app.dmg` redirects to the immutable version download, and `https://appea.rs/appcast.xml` serves the signed update feed. Release credentials are configured in the `release` environment and backed up in 1Password.

## Licenses in distributions

Appears' code is MIT licensed. Upstream code and model files retain their own licenses. Before Xcode signs the app, `mac/scripts/bundle-licenses.py` copies this project's license, the vendored model runtime's notices, Sparkle's license, and license/notice files from the exact resolved Swift dependency checkouts into `Appears.app/Contents/Resources/Licenses`. A manifest records revisions and checksums; CI and the release script verify it.

The separately downloaded model includes `LICENSE.txt` (Apache-2.0), `NOTICE.txt` (source revision and the text/vision extraction), and `appears-model.json` (provenance and checksums). The app verifies these files along with the weights. The license-bearing package uses a new immutable model prefix so earlier downloads remain unchanged. Updating notices requires updating their bundled size/SHA-256 pins too.

## Not done yet

- **Calibration:** not learned yet. The confidence weights are hand-set from the eval; fitting them to the journal is next.
- **Notes attachments** (scans, photos in notes) aren't indexed; note text is.
- **Folders added under Include** are scanned, but not watched for changes until the next full rescan (every 6 hours) or a relaunch.
- **Releases:**
  - verify an installed signed release updating to the next release, including the isolated downloader and any changed model pin;
  - the Homebrew cask.
- **`appears mcp` without a checkout or Full Disk Access:** the CLI isn't in the app or the Homebrew cask yet. Reading the app's index needs Full Disk Access for the agent's app. Tested 2026-10-15 on macOS 27: nothing signed with the self-signed dev certificate gets into the engine's container, even with the engine's exact identifier. Apple lets apps with the same Team ID read each other's containers, so shipping the CLI inside Appears.app under the release Team ID should work, but that packaging and access remain untested. Moving the index out of the container would let any process read Notes and Documents text, so it stays where it is.
- **Not in v0:** voice memos and audio, video, Mail, Photos (see PLAN.md).
