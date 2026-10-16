# Releasing to appea.rs

This is for maintainers. Contributors never need release credentials.

`.github/workflows/release.yml` runs when a stable GitHub release is published for a `vX.Y.Z` tag (which must match `VERSION`), or manually against an existing tag with a published release. Give the GitHub release a nonempty changelog. The workflow:

1. reads that exact release using its read-only GitHub token;
2. tests the core and web routes;
3. prepares the separately hosted model;
4. builds the isolated Sparkle framework and the arm64 app;
5. checks the privacy boundaries;
6. signs with Developer ID, then notarizes and staples the app and DMG;
7. uploads to the private `appears-downloads` R2 bucket.

`mac/scripts/release.sh` only builds; the upload steps are separate.

## How downloads are served

The site Worker exposes `https://appea.rs/app.dmg`, an uncached redirect to an immutable `/downloads/vX.Y.Z/Appears.dmg`. The landing page, its Markdown and `llms.txt` share that link. The upload script reads back and hashes the R2 files before switching `latest.json`. Previous version URLs keep working, including paused downloads. The thin app is eligible for the Worker's edge cache; model files above Cloudflare's 512 MB standard limit stream from R2.

The release build signs both the DMG and an appcast containing the GitHub release's Markdown notes. `/appcast.xml` serves those signed bytes from R2 with a five-minute cache. The uploader promotes the feed only after reading back and verifying the immutable DMG.

## One-time setup

1. In `web/`, create the private bucket: `npm run cf -- r2 bucket create appears-downloads`. Keep public bucket access disabled; the Worker reads it through an R2 binding. Deploy the site Worker once so `/downloads/*` and `/models/*` are served.
2. Run `python3 -I scripts/configure-github.py --apply` to configure repository protections and the `release` environment, then check its output for settings GitHub couldn't apply. See [.github/MAINTAINERS.md](../.github/MAINTAINERS.md).
3. Add secrets to the `release` environment:
   - `APPLE_CERTIFICATE_BASE64`: the exported Developer ID Application `.p12`, base64 encoded;
   - `APPLE_CERTIFICATE_PASSWORD`;
   - `NOTARY_KEY_P8`: the App Store Connect private key;
   - `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`: Object Read & Write, scoped to this bucket;
   - optionally `HF_TOKEN`, used only to prepare the upstream model.

   Keep long-term copies in a password manager. Never put values in the repo, shell history or chat.
4. Create a dedicated Ed25519 update-signing key. Add its base64 private seed as the `SPARKLE_PRIVATE_KEY` environment secret, and its base64 public key as the `SPARKLE_PUBLIC_ED_KEY` environment variable. Release builds verify that they match. Never regenerate this key for an ordinary release. To test a development build against the real feed, provide the public key through `mac/Config/Local.xcconfig`.
5. Add environment variables: `DEVELOPER_ID` (the full Developer ID Application identity), `APPLE_TEAM_ID` and `NOTARY_KEY_ID`. Set `NOTARY_ISSUER` for a Team API key; leave it unset for an Individual key.

## Cutting a release

Update `VERSION`, merge the intended release to `main`, push its `vX.Y.Z` tag, and publish a stable GitHub release with its changelog. Pushing a tag alone doesn't publish a download. Signing credentials live only in a temporary runner keychain or private runner files and are removed when the job ends.

Release tags must point to a commit reachable from `main`. For a manual rerun, select the version tag as the workflow ref and supply the same tag input; dispatching from `main` can't enter the tag-only release environment. Validation runs before the job that can access the release environment.

Local release builds also need `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_PRIVATE_KEY_PATH` and `GITHUB_RELEASE_PATH` (the matching GitHub release JSON).

## Rollback

Put a previously verified version and its SHA-256 back into the bucket's `latest.json`. Don't overwrite immutable version or model files. A failed upload never promotes an unverified DMG, and a version that was already uploaded isn't overwritten on rerun.

## History

The first release, `v0.1.0`, was built, signed, notarized and uploaded by GitHub Actions on 2026-10-15. First-run model setup was verified the same day with a Developer ID build: the restricted downloader installed all 12 pinned files from appea.rs, then the sandboxed engine indexed the 142-item demo and semantic search returned the kitchen quote photo.
