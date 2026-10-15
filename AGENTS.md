# Notes for agents working on Appears

Appears is a Mac menu bar app that shows related things you already have, without a query, plus its site at appea.rs. Read `README.md` (how it works, building, testing) and `PLAN.md` (why, and Colin's decisions). Read `../AGENTS.md` too: it covers how Colin's sites handle Markdown versions, llms.txt, structured data and deploys, and appea.rs follows it.

Never push, deploy, publish a release or commit unless Colin asks. The repo is private for now.

## Rules that protect the product's promise

- **The engine never gets the network.** `mac/project.yml` gives `AppearsEngine` the App Sandbox with no `com.apple.security.network.client` or `network.server`. Never add them, and never add networking code, analytics or crash reporting anywhere in `mac/`.
- **The app has no networking code.** It can't be sandboxed (Accessibility isn't allowed in the sandbox), and it can't sandbox itself: any self-applied `sandbox_init` profile makes macOS refuse it Accessibility (found 2026-10-15). So `mac/scripts/check-no-network.sh` is the guard: run it on every build you hand over, and keep it passing. Don't link Network.framework, URLSession or sockets into the app or `AppearsContext`.
- **Nothing about the screen is stored.** Context text lives in memory only, and calendar events are context too. The journal keeps item ids, scores, outcomes and a salted fingerprint. The one exception is `debugContext`, behind a Debug-build setting that dogfooding uses, kept for 14 days. Don't log context text, even with `NSLog`.
- **Silence is the default.** No notifications, sounds or pop-ups. Ambient suggestions only change the menu bar glyph, behind `SurfacePolicy` (dwell, confidence, budget, backoff). Don't loosen these without checking `appears eval`'s false-surface rate.
- **Exclusions stay on:** password managers and secure fields (`Exclusions.swift`), private windows, Safari in ambient mode unless the setting allows.
- **No real data** in the repo, tests, screenshots or the site. Use `demo/` (made by `demo/make-demo.py`; phone numbers in 555-01xx).
- **The model ships in the engine's bundle.** Neither process downloads it.

## Design

- **Direction:** "E · shadcn", chosen by Colin on 2026-10-15 from five explored on a design canvas. `brand/README.md` has the tokens. In short: shadcn/ui's zinc scale, hairline borders, 8 px card and 6 px control radii, a black primary, muted secondary text, a ⌘K-style results list, and one blue accent (`#2563EB`) used sparingly.
- **Retired looks:** the first warm-paper, serif and vermilion look was rejected as "yellowy and archaic"; don't bring it back. Don't borrow whosaid's or heade.rs's UX, layouts, Liquid Glass capsule, or Geist.
- **Code:** `Theme.swift` holds the app's tokens, button styles, `Kbd`, `Badge` and `Mark`; the web uses the same values in `web/src/styles`.
- **Type:** the system font in the app, Inter on the site.
- **The panel:** it hangs from the menu bar ring and never activates the app, so focus stays where it was.
  - **Header:** one line: "Related", then the front app's icon and the window's title, muted (for a meeting, a calendar glyph and "2:00 PM · title"). No count badge.
  - **Rows:** each has a thumbnail, a name, and a reason whose "why" is in the foreground colour, with when and where muted.
  - **Selection:** the selected row gets the muted background and its snippet, or the quoted line that answers. Pictures show no snippet: OCR text reads as noise.
  - **Footer:** at most three keys on one line (↩ open, ␣ preview or ⌥⌘C copy, ⌫ hide at the far end), and gone when there's no list.
- **Wordmark:** the mark (a zinc tile, a white ring, a blue dot) plus lowercase "appears" in a bold weight. In sentences the name is "Appears", capitalized. The domain is appea.rs.

## Layout

- **`mac/Packages/AppearsKit`:** builds and tests with the Command Line Tools. Running `swift test` with `DEVELOPER_DIR` set to Xcode avoids a Testing-macro plugin error with the CLT toolchain.
  - `AppearsCore`:
    - `Sources` (`FileScanner`, skip rules), `Extractors`, `NotesReader` (gzipped protobuf);
    - `IndexStore` (GRDB, FTS5, float16 vectors), `VectorIndex` (brute force), `Indexer`;
    - `QueryBuilder`, `Recall` (ranking and `Confidence`), `Journal`, `SurfacePolicy`;
    - `Engine` (the engine's logic and XPC protocol, also used in-process by the CLI);
    - `CalendarEvent` (an upcoming meeting as a context, conferencing boilerplate stripped) and `CalendarSchedule` (when to look).
  - `AppearsContext`: `ContextReader` (AX), `Browsers`, `Exclusions`, `ScreenText` (OCR fallback).
  - `AppearsMCP`: `appears mcp`, an MCP server over stdio (`MCPServer`, `Tools`) and `AgentIndex`, which reads an index read-only. It never journals, and its stderr log never gets query text, results or file content.
- **`mac/Packages/AppearsModel`:** needs Xcode, since MLX compiles Metal shaders.
  - `EmbeddingGemma2`: copied unmodified from whosaid, which copied it from Obscyra-app/EmbeddingGemma2Swift.
  - `GemmaEmbedder`: loads the vision tower lazily and unloads it after indexing.
  - `AppearsCLI`: the `appears` command.
- **`mac/Engine/main.swift`:** the XPC service. It loads the model once and keeps a separate index for `-demo`.
- **`mac/App`:** `AppModel` (the context loop, pull, ambient, meetings, feedback), `CalendarWatcher` (EventKit, one timer for the next meeting), `StatusController` (the menu bar item and the non-activating panel), `PanelView`, `SettingsView`, `OnboardingView`, `Glyph`.

## Embedding prompts

EmbeddingGemma 2 expects:

- Queries: `task: search result | query: …`.
- Documents: `title: … | text: …`.
- Images: no prefix.

`EmbeddingGemmaPrompt` in `Embedder.swift` is the only place these strings live. Changing the embedder's `modelID` makes every index re-embed from scratch.

## Ranking changes

Run `appears eval --verbose` before and after any change to `Recall`, `QueryBuilder` or `Confidence`, and record the numbers in the commit message. Add a scenario to `demo/scenarios.json` (and files to `make-demo.py`) for each new failure you fix. Add negative scenarios as often as positive ones.
