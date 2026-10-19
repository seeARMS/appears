# Contributing to Appears

Appears is an experimental Mac menu bar app. Useful contributions include reproducible bugs, Accessibility coverage fixes, file-reading improvements, accessibility in the UI, and better synthetic retrieval scenarios. Open an issue before starting a large feature or changing when the app suggests something.

Read [README.md](README.md) for setup and [AGENTS.md](AGENTS.md) for the product's constraints. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). The app uses the system font and the tokens in `Theme.swift`; the site follows `brand/README.md`.

## Work with made-up data

Use `demo/files` for tests, screenshots and reproductions. Every person and document there is invented. Do not attach your index, journal, Messages or Notes database, real screen text, or screenshots of private files to an issue or PR. Report privacy and security problems through [SECURITY.md](SECURITY.md).

The app, engine and downloader have different responsibilities. Keep networking in the restricted downloader, screen context in memory, exclusions on, and ambient suggestions behind the existing surface policy. Changes to these boundaries need an explanation and checks that exercise the affected behavior.

Debug builds have an optional setting to keep context snippets for 14 days. It is off by default and absent from Release builds. Use a Release build and demo data when preparing a public reproduction.

## Local checks

Use Xcode 27 with the Metal toolchain, XcodeGen, and Node 24. `mac/scripts/check-app.sh` builds without an Apple developer account, notarization keys, or model weights. It checks the actual app binary, sandbox entitlements and bundled notices. It does not launch the app or request permissions.

From the repository root:

```sh
cd mac/Packages/AppearsKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

```sh
python3 -I -m unittest discover -s mac/scripts/tests -v
python3 -I -m unittest discover -s scripts/tests -v
mac/scripts/check-app.sh
```

For web changes, from `web/`:

```sh
npm ci
npm run check
npm test
npm run build
```

The `Checks` workflow runs on pull requests and pushes to `main`. Web checks always run. Changes confined to `web/`, `docs/`, `brand/` and the top-level contributor documentation skip the two native jobs. Native code, demo fixtures, licenses, workflow changes and unrecognized paths run all checks; manual runs also run everything. The selector compares the full PR merge or push, including deletions and both sides of renames. If selection fails, the native jobs run.

Native jobs cache Swift package builds/sources, the pinned Sparkle build and Xcode's content-addressed compiler results, with toolchain and input hashes in the build cache keys. The app still gets a clean Release build and complete signature, privacy and notice checks; cached compiler results do not restore app/resource bundles. The workflow has read-only repository access and no release secrets. Its required checks keep the names `Core and MCP`, `Web`, and `Mac app`, including when native jobs are skipped.

## Model tests and ranking changes

The regular PR checks build the model code but do not run inference. For inference tests and eval, prepare the model with `mac/scripts/fetch-model.sh` and run:

```sh
mac/scripts/test-model.sh
```

This needs an Apple silicon Mac with Metal. Set `APPEARS_MODEL` to use an existing local model folder. The script fails clearly if the model or CLI is unavailable, rather than counting skipped suites as successful coverage. It runs on the demo and never needs Accessibility, Full Disk Access, or your real files.

The separate `Model tests and eval` workflow can run the same script manually from `main` on a dedicated runner labelled `appears-model`. It needs that runner to be configured first. Never connect a personal daily-use Mac to public PR jobs; this workflow has no PR trigger and accepts only `main`.

For changes to `Recall`, `QueryBuilder`, `DecisionFraming` or the answer model, run `appears eval --verbose` before and after (it needs `mac/Models/h2o-lightning-4b-q4` from `mac/scripts/fetch-decider.sh`). Include the results in the PR and eventual commit message. Add a synthetic scenario for each failure you fix, including negative cases where silence is correct. The current eval is small and was used to check the answer model's framing and threshold; it is not an independent quality benchmark.

## Pull requests

Keep each PR focused. Explain the concrete problem, the resulting behavior, what you tested, and any limitations. For UI changes, include light and dark screenshots made with demo data. For source or permission changes, update the README and the site's shared copy in `web/src/site.ts`.

Preserve upstream license and copyright notices. The app build gathers notices from its exact resolved dependencies. Model packaging carries its own license, provenance and checksums. Include licensing changes when adding or updating a dependency.

Contributions are provided under the repository's MIT license, with existing third-party licenses retained. Maintainers handle signing, releases and deployments; contributing does not require those credentials. No review requests are added automatically.
