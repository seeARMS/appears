---
name: release-appears
description: Cut a stable Appears Mac release, or prepare a release draft. Summarize changes since the last shipped release, write friendly release notes and a release commit message, prepare and merge the version bump, publish through GitHub Actions, and verify Cloudflare downloads and Sparkle updates. Use for requests to ship or prepare an Appears release, not ordinary app builds or release-process questions.
---

# Release Appears

Run this workflow from the repository root. Use the existing release pipeline;
keep signing and R2 uploads in GitHub Actions.

Read [AGENTS.md](../../../AGENTS.md), [CONTRIBUTING.md](../../../CONTRIBUTING.md),
[docs/releasing.md](../../../docs/releasing.md), `.github/workflows/release.yml`,
`mac/scripts/make-appcast.py`, and `mac/scripts/upload-release.sh` before acting.
These files define the current release contract; recheck them rather than relying
on a version or workflow remembered from another run.

## Scope and authorization

- A request to **cut, ship, or publish a release** authorizes the normal version
  commit, branch push, release PR, checked merge, tag, GitHub release, and resulting
  Actions publication. Carry it through verification without asking again at
  each step. Announce the chosen version and show the notes before publishing.
- **Prepare, draft, plan, or dry-run** means gather evidence and write local
  drafts only. Do not commit, push, create a PR, tag, dispatch, or publish. Creating
  or editing this skill does not authorize running a release.
- Preserve unrelated work. Use a suitable clean checkout or an isolated worktree
  from `origin/main`; do not reset, stash, or commit someone else's changes.
- Reuse existing credentials and the existing Sparkle key pair. Missing access
  is a blocker to report, not permission to create credentials or broaden access.
  Follow the applicable persistent-PTY instructions if 1Password is needed.
- Website deployment and replacing the maintainer's installed app are separate
  tasks. Neither is needed to publish an app through the existing Worker.

## 1. Establish the release range

Confirm `origin` is `seeARMS/appears`, GitHub access works, and the checkout state
is understood. Fetch `origin/main` and tags without changing tracked files.
Record the intended source SHA; default to the fetched `origin/main`.

Reconcile these live sources:

- Published stable GitHub releases (`gh release list/view --repo seeARMS/appears`).
- `https://appea.rs/app.dmg`'s redirect and `https://appea.rs/appcast.xml`'s version.
- Recent `release.yml` runs, including pending or failed runs.
- `VERSION` and existing local and remote tags.

Use the last **successfully shipped stable release**, with a tag reachable from
the intended source SHA, as the comparison baseline. Do not choose an arbitrary
nearest tag or assume GitHub publication means the upload succeeded. If GitHub,
the download, and the feed disagree, inspect the relevant run and resolve or
report the incomplete release before starting another. Allow the feed's existing
five-minute cache time. An API/authentication failure is not an absent release.

Read every commit in `BASE_TAG..SOURCE_SHA`, its aggregate diff, and the relevant
PR descriptions/diffs. Use `git log --reverse` and `git diff --stat` to inventory
the range, then inspect the implementation for user-facing claims. Group related
commits; account for reverts and later changes. PR titles alone are not enough.
Keep a local mapping from each proposed release-note bullet to supporting commits
or PRs. Do not include unmerged changes or unrelated local files.

Use a requested stable `X.Y.Z` version. Otherwise reuse an appropriate unreleased
`VERSION` greater than the shipped version, or choose a patch for fixes and a
minor version for substantial additions. State the choice and reason. Do not
infer a major compatibility change without evidence. Check numeric version order
and tag uniqueness; skip an empty release unless explicitly requested.

## 2. Write the release packet

Save drafts in the ignored `mac/build/release-plan/vX.Y.Z/` directory, reading any
existing packet first. Include the base tag/SHA, intended source SHA, version,
commit-to-bullet evidence, `release-notes.md`, `commit-message.txt`, and
`pr-body.md`. Keep credentials out of these files. Report absolute draft paths.

Write the public notes for someone using Appears:

- Start with one short sentence about the most useful changes. Use plain,
  friendly language and concrete actions such as “Search stays responsive while
  your photos are indexing.” Include only claims supported by the final diff.
- Group related improvements and fixes into a short, scannable list. Avoid a
  commit dump, internal class names, CI chores, generic “performance improvements,”
  invented measurements, or claims that locally tested behavior shipped earlier.
- Mention compatibility, permission changes, reindexing, model downloads, or
  user action only when the release actually changes them. Check the model pin
  and `modelID` when assessing index/download impact.
- Keep website-only changes out of the Mac feature list. Add a GitHub comparison
  link for technical detail if useful. Don't expose private data or local paths.
- Use simple Markdown paragraphs and bullets. Do not add a `Changelog` heading:
  `make-appcast.py` adds it. Avoid images, raw HTML, and external content embeds.

The **GitHub release body is the in-app changelog**. It is copied into the signed
feed at build time, not fetched live from GitHub. Editing the GitHub body later
does not republish the feed. The feed currently contains only the latest release;
it does not assemble a history for people skipping versions.

Write a separate friendly release commit message: a short subject such as
`Release Appears X.Y.Z`, followed by a brief summary of the release's user-facing
changes and the version preparation. Do not claim publication or validation that
hasn't happened. Include evidence-backed validation in the PR body. Preserve any
ranking-eval numbers required by `AGENTS.md` if this release work changes ranking.

Show the version, release notes, commit message, and planned source range. In
draft mode, stop here with the remaining steps and any blockers. In release mode,
continue under the user's existing authorization.

## 3. Prepare and merge the version bump

Check that the `release` environment has the secret and variable **names** required
by the current workflow, using GitHub metadata. Do not retrieve secret values.
Metadata presence is only a preflight; the run proves the credentials work.
Report missing settings before publishing. Ordinary releases require no new keys.

Create or reuse a task-owned `codex/release-X.Y.Z` branch from the intended main
commit. Update `VERSION`, the default `MARKETING_VERSION` in `mac/project.yml`,
and `MCPServer.version` in
`mac/Packages/AppearsKit/Sources/AppearsMCP/MCPServer.swift` together. Search for
other runtime copies of the old version, leaving historical release references
and unrelated dependency/protocol versions alone. The release script supplies the actual version and
derives the build number from Git history; do not hand-edit generated Xcode files
or reset the build number. If the correct bump is already merged, inspect and
reuse it instead of making an empty commit.

Review the exact diff and stage only the intended release files. Use
`git commit -F` with the prepared message, push the branch, and open a PR to
`main` with `--body-file`. Don't request reviewers. Attach the PR to the chat when
the host provides an attachment tool.

Follow `CONTRIBUTING.md`. For a version-only change, the PR's `Core and MCP`,
`Web`, and `Mac app` jobs provide the full test/build/privacy checks. Require all
current required checks and these three named checks to succeed on the exact PR
head; absent, skipped, pending, or failed checks are not success. Fix attributable
release problems within scope; don't make unrelated product changes to get green.

Merge with `gh pr merge --squash --match-head-commit HEAD_SHA`, explicitly supplying
the prepared subject and body via `--subject` and `--body-file` so the friendly
message survives the squash. Never bypass checks with `--admin`. Fetch and record
the actual merged commit; require it to be reachable from `origin/main`, contain
the chosen `VERSION`, and pass the post-merge `Checks` workflow at that exact SHA.
Reconcile the final release range and notes if main changed during preparation.
Tag the verified merge SHA, not whichever commit happens to be at main later.

## 4. Publish and follow the run

Immediately before publication, recheck the remote tag, GitHub release, active
release runs, and shipped version. Do not publish an older version over a newer
one or race another release. Set `TAG`, `VERSION`, `RELEASE_SHA`, and `NOTES_FILE`
from the reviewed packet; keep paths absolute.

For a new version, create an annotated tag on `RELEASE_SHA`, push that exact tag,
and verify the remote tag resolves to that commit. Then publish:

```sh
gh release create "$TAG" --repo seeARMS/appears --verify-tag \
  --title "Appears $VERSION" --notes-file "$NOTES_FILE" --latest
```

Publishing the stable release triggers `.github/workflows/release.yml`; pushing
the tag alone does not. The job tests, signs and notarizes the app and DMG,
verifies the separately hosted model, uploads the immutable DMG to R2, reads it
back for checksum verification, then promotes `latest.json` and `appcast.xml`.
No manual Cloudflare copy or site redeploy is needed. The DMG is hosted in R2;
an empty GitHub release assets list is expected.

Find the run by workflow, tag, exact release SHA, and event/time. Follow that run
to completion with bounded waits and progress updates. A published GitHub release
or queued run is not a successful app release. If a call times out, reconcile
remote state before repeating it; do not create a second release or dispatch a
duplicate run.

For failures, read [recovery and verification](references/verification.md). Fix
only an understood, authorized failure, and stop if recovery would overwrite an
immutable artifact, move a tag, rotate keys, broaden access, or change unrelated
code. Explain the specific blocker and the next action required.

## 5. Verify and report

Follow [recovery and verification](references/verification.md) for the production
download, checksum, signing, model pin, and changelog checks. Do not call a release
complete merely because Actions is green. Keep publication evidence separate
from any optional real-device upgrade test.

Report the version, friendly change summary, release and workflow links, public
download, exact source SHA/build, and verification results or remaining failures.
Keep draft paths and PR links available. Never describe a local rebuild as the
public release, or claim a real in-app upgrade was tested without doing one.
