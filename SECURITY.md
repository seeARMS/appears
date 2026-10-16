# Security and privacy

Appears is experimental. Security fixes target the current `main` branch and the latest release; older versions are not maintained separately.

## Report a problem privately

Use [GitHub's private vulnerability report form](https://github.com/seeARMS/appears/security/advisories/new). If it is unavailable, email [colin@armstr.ng](mailto:colin@armstr.ng). Do not open a public issue for a vulnerability or a private-data exposure.

Describe the affected version or commit, macOS version, expected behavior, actual behavior, and steps to reproduce with invented data. Include the affected permission or process boundary if you know it. Never send passwords, tokens, your index or journal, real Messages or Notes databases, or unredacted screen captures. Start with a short report; a safe way to share further evidence can be arranged if needed.

## What Appears protects

- The engine reads files, Notes and Messages and runs the model inside the App Sandbox, without network entitlements.
- The main app reads the active window. Accessibility prevents sandboxing it; the built binary is checked for networking APIs. This is a build check, not an operating-system network block on the app.
- The model downloader is a separate sandboxed XPC service with network-client access and no user-file access. Its interface accepts no screen text, paths or URLs. The model's URLs, sizes and SHA-256 hashes are pinned in the app, and the complete download is verified before installation.
- App updates use Sparkle's separate sandboxed Downloader XPC service and signed feeds and downloads. The app's copy of the framework has its in-process networking and web views removed. Update checks send no screen text, indexed content or system profile.
- Release builds keep screen and calendar context in memory. The journal stores suggestion IDs, scores, outcomes and a salted context fingerprint. Debug builds have an optional, default-off context-snippet setting with 14-day retention.
- The index contains extracted content from indexed files, Notes and Messages, plus paths and embeddings. It is sensitive local data, protected by the engine's sandbox container and macOS permissions. It is not an encrypted backup. Settings can delete the index and journal.
- Password managers, secure fields and detectable private browser windows are excluded. Safari is skipped in ambient mode by default because it does not expose a reliable private-window signal.
- The optional MCP server answers through local pipes and opens the index read-only. An agent connected to it may send returned paths and excerpts to its model provider. Set it up only for agents you trust with that content.

Potential vulnerabilities include a process gaining access outside these boundaries, a bypass of exclusions, source content entering logs, or model files being accepted without integrity verification.

## Release access

Contributor CI has no signing or upload credentials. Releases use a separate `release` environment restricted to version tags, and the workflow checks that a tag points to a commit on `main`. Keep signing and R2 secrets in that environment; do not add them to PR workflows or repository-wide secrets. See [.github/MAINTAINERS.md](.github/MAINTAINERS.md) for setup and the status of settings that GitHub may restrict while the repository is private.
