# Repository and release setup

`python3 -I scripts/configure-github.py` shows the intended GitHub settings. Add `--apply` to apply them to `seeARMS/appears`. The script never changes visibility, commits, pushes, releases or deploys. It reports rejected settings and exits with status 2 when setup is incomplete. Re-running updates this project's named rulesets instead of creating duplicates, and preserves unrelated rulesets.

The settings require PRs and the `Core and MCP`, `Web`, and `Mac app` checks on `main`, block force pushes and deletion, and limit `v*` tag creation and changes to repository administrators. Maintainers may bypass main's rules through a PR. No approving review or automatically assigned reviewer is required.

The public Actions policy allows GitHub-owned Actions pinned to full commit SHAs, keeps tokens read-only, and requires approval before running workflows from external contributors. Dependabot checks Actions, Swift packages and web dependencies weekly, with no assigned reviewers.

## Before the repository becomes public

Merge the pinned workflows and contributor docs first. Then run the settings script again once GitHub makes the public security features and rulesets available. Turning public is a separate owner decision; this script does not do it.

As of the readiness work, GitHub accepted a GitHub-owned Actions allowlist with SHA pinning required, read-only Actions tokens, Dependabot alerts and security fixes, and a `release` environment with a `v*` tag policy. It rejected branch/tag rules, private vulnerability reporting, and secret scanning/push protection under the private repository's current feature access. Those settings are prepared, not enforced yet. Fork approval policy is available after publication. All workflows must retain full commit SHAs under the enforced Actions policy. No existing release run or configured signing credentials were present at setup.

After applying the settings, read them back in Settings or through the API. Confirm all three check names have run successfully on the merged workflow before relying on them. Do not infer enforcement from the checked-in JSON alone. Review Actions history and existing issues/PRs before changing visibility.

## Release secrets

Use the `release` environment for `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `NOTARY_KEY_P8`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `SPARKLE_PRIVATE_KEY`. An optional `HF_TOKEN` also belongs there. Keep long-term copies in 1Password. Existing repository-wide copies must be removed after moving them; creating an environment does not move secrets. There were no repository secrets or variables at setup time.

The public IDs `DEVELOPER_ID`, `APPLE_TEAM_ID`, `NOTARY_KEY_ID`, `SPARKLE_PUBLIC_ED_KEY`, and optional `NOTARY_ISSUER` can be environment variables. The workflow uses a temporary keychain and removes signing material when the job ends. No PR or model-eval job references release secrets.

Publishing a stable GitHub release starts the release workflow. Its tag must match `VERSION` and point to a commit reachable from `main`. For a manual rerun, select the existing version tag as the workflow ref and supply the same tag input; dispatching from `main` cannot enter the tag-only release environment. The workflow builds and verifies notices before signing, then verifies uploads before promoting the download. Never overwrite an immutable model or version prefix.

The manual model workflow needs a dedicated Apple silicon runner with Metal, Xcode 27 and the `appears-model` label. It accepts only `main`, runs synthetic data, and has no release secrets. Without that runner, use `mac/scripts/test-model.sh` locally; the regular PR checks do not claim inference coverage.
