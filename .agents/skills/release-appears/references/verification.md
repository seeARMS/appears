# Verify or resume an Appears release

Run from a checkout containing the exact release source. Use a temporary directory
outside `mac/build/release` for downloaded verification artifacts: `release.sh`
deletes that build directory. Read current scripts before adapting these checks.

## Production verification

1. Confirm the exact `release.yml` run succeeded for the published tag and commit,
   including privacy/license checks, notarization, upload, and cleanup. Recheck
   the stable GitHub release's version, body, and target commit.
2. Request `https://appea.rs/app.dmg` without following redirects. Expect a `302`
   to `/downloads/vX.Y.Z/Appears.dmg` with `Cache-Control: no-store`. Then download
   that immutable DMG and its `.sha256` file with `curl --fail --show-error --location`
   into files. Compare the actual file's SHA-256 with the published checksum;
   a HEAD response or content length alone is insufficient. Confirm a bounded
   byte-range request returns `206` and the expected `Content-Range`.
3. Fetch `https://appea.rs/appcast.xml` as raw bytes. Parse its single item and
   compare the short version, build number, minimum macOS version, DMG URL, byte
   length, and Markdown format with the release artifact. Compare its description
   exactly with `"## Changelog\n\n" + github_release_body.strip()`. Allow up to
   five minutes for the existing feed cache using bounded waits. Don't edit signed
   XML to correct notes.
4. On macOS, mount the downloaded DMG read-only at a temporary mount point. Do not
   copy it over `/Applications/Appears.app` or launch it against personal data.
   Check the bundle's version/build and the expected Developer ID team, run
   `codesign --verify --deep --strict`, `xcrun stapler validate`, and Gatekeeper
   assessment (`spctl --assess --type execute` for the app;
   `spctl --assess --type open --context context:primary-signature` for the DMG).
   Run `mac/scripts/check-no-network.sh` on the mounted app and verify its bundled
   notices with `mac/scripts/bundle-licenses.py --verify`. Detach in cleanup.
5. Check the app's `SUPublicEDKey` matches the existing `SPARKLE_PUBLIC_ED_KEY`
   release-environment variable and decodes to 32 bytes. Check its feed URL is
   `https://appea.rs/appcast.xml`, signed feeds are required, automatic checks are
   enabled daily, and automatic installation is disabled. Independently verify
   the downloaded DMG's appcast Ed25519 signature with that public key (for example,
   macOS CryptoKit's `Curve25519.Signing.PublicKey.isValidSignature`). Merely seeing
   a signature field is not verification. Also verify the raw production feed's
   own signature using the pinned Sparkle signed-feed format and the same public
   key; don't reserialize XML before verifying. CI verifies the pre-upload feed,
   but the uploader does not read the feed back. If live-feed signature validation
   is unavailable, report that gap rather than claiming updates are verified.
6. Check the release's model manifest and the successful model-upload verification
   step. For a changed model pin, verify each pinned public URL's size and SHA-256
   against `mac/Packages/AppearsKit/Sources/AppearsCore/Resources/model-download.json`;
   stream downloads into files, not tool output. Do not claim a new model's first-run
   setup works based only on hosting. If a new pin lacks synthetic first-run
   validation, disclose that limitation and test in an isolated demo environment
   when available.

If macOS validation is unavailable, finish the platform-independent checks and
report the exact CI evidence and local verification gap. Don't invent a local
Gatekeeper, signature, or UI result.

## Changelog and installed-app testing

The live feed comparison proves which notes the app receives. Native rendering
can be checked with `mac/scripts/test-updates.sh` when its built app plist and
pinned Sparkle framework exist; read its paths first. It uses a separate synthetic
fixture and outputs light/dark screenshots. Inspect those images if claiming UI
verification. This fixture does not prove a production download or installation.

Real upgrade testing is separate and changes the installed app. Perform it only
when requested or already authorized. Use the prior released build and synthetic
data where possible. Confirm discovery, the installed/available versions, the
displayed notes, download, installation, and the running new version.

A local rebuild may omit the public Sparkle key and skip checks, or may have a
build number as new as the release. Check both before diagnosing a feed problem.
Reuse the release's existing public key for an authorized local rebuild; never
generate a new signing key to make a local test work. Do not lower a real app's
build number or tamper with production feeds to force an update.

## Recovery and stopping conditions

Inspect `gh run view RUN_ID --repo seeARMS/appears --log-failed`, the existing tag
and release, the public download/feed, and artifact availability before choosing
a recovery. Protect secret values in logs. Keep the user informed of which stage
succeeded and which did not.

- **Tag exists, release absent:** verify the exact tag commit, intended notes,
  version, checks, and current authorization before continuing publication.
  A 403, timeout, or generic API failure is not evidence the release is absent.
- **Release exists, run active:** follow it; do not publish or dispatch again.
- **Failure before immutable upload:** an understood transient failure can be
  retried after confirming no immutable version object exists. Prefer rerunning
  the failed run. If dispatch is necessary, use the same tag as both workflow ref
  and input, e.g. `gh workflow run release.yml --repo seeARMS/appears --ref "$TAG"
  -f "tag=$TAG"` as one command. Dispatching from `main` fails the tag-only policy.
- **DMG already uploaded:** `upload-release.sh` deliberately refuses that version
  on rerun, even if promotion subsequently failed. A public 404 alone is not
  conclusive proof of absence; use authenticated read-only bucket metadata when
  available. Do not overwrite/delete the object, move the tag, or blindly rerun.
  Preserve evidence and ask for the smallest explicit recovery decision after
  explaining the current partial state. A new patch release or carefully verified
  promotion of existing artifacts requires a concrete recovery plan. Confirm the
  original signed feed still exists before proposing to promote it: the workflow
  currently has no build-artifact retention step, and the runner copy may be gone.
  Rebuilding a signed/notarized DMG can produce different bytes and is not a safe
  way to recreate the existing version or its update signature.
- **Notes edited after publication:** GitHub edits don't update the signed feed,
  and rerunning the whole release collides with the immutable DMG. Explain the
  discrepancy; do not silently rewrite/re-sign/promote a feed.
- **Newer release or another publisher appears:** stop the stale publication,
  reconcile versions and source range, and report the concurrent change.
- **Persistent failure or missing access:** stop after the diagnosed retry fails,
  rather than looping or changing credentials/configuration. Keep the published
  release, run, and draft links so the task can be resumed.

Rollback is not an automatic retry. Changing `latest.json` affects fresh downloads
only; it does not automatically roll back the Sparkle feed or installed apps.
Follow an explicitly authorized recovery plan for all affected surfaces.
