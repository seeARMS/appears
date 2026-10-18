#!/usr/bin/env python3
"""Skip native CI only when every changed path is known to be site/documentation.

Diff the tested merge against the PR base, or the entire push against `before`.
Unknown paths, manual runs and unavailable history all keep full coverage.
"""
import json
import os
from pathlib import Path
import re
import subprocess


NON_NATIVE_PREFIXES = ("web/", "docs/", "brand/")
NON_NATIVE_FILES = {
    "README.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "SECURITY.md", "AGENTS.md",
}


def needs_native(paths):
    """Require native checks unless a nonempty diff contains only known safe paths."""
    return not paths or any(
        path not in NON_NATIVE_FILES and not path.startswith(NON_NATIVE_PREFIXES)
        for path in paths
    )


def select_native(event_name, event, head):
    """Check the full event diff, retaining native coverage when comparison fails."""
    if event_name == "pull_request":
        base = event.get("pull_request", {}).get("base", {}).get("sha", "")
    elif event_name == "push":
        base = event.get("before", "")
    else:
        return True
    if any(not re.fullmatch(r"[0-9a-f]{40}", sha) or sha == "0" * 40 for sha in (base, head)):
        return True
    try:
        # Disable rename detection so moving a native file into docs still
        # includes the removed native path. NUL separators handle any filename.
        changed = subprocess.check_output([
            "git", "diff", "--name-only", "--no-renames", "-z", base, head, "--",
        ])
    except subprocess.CalledProcessError:
        print("::warning::Could not compare revisions; running all native checks.")
        return True
    return needs_native([os.fsdecode(path) for path in changed.split(b"\0") if path])


def main():
    """Read the Actions event and publish the native-check decision and reason."""
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    native = select_native(os.environ["GITHUB_EVENT_NAME"], event, os.environ["GITHUB_SHA"])
    value = str(native).lower()
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"native={value}\n")
    reason = "Native/shared inputs changed or a full check was requested." if native else "Only site/documentation paths changed."
    print(f"Native checks: {value}. {reason}")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write(f"Native checks: **{value}**. {reason}\n")


if __name__ == "__main__":
    main()
