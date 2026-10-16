#!/usr/bin/env python3
"""Apply Appears' GitHub protections without changing visibility or publishing code."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def api(path, method="GET", data=None):
    command = ["gh", "api", path, "--method", method]
    if data is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        try:
            message = json.loads(result.stdout)["message"]
        except (ValueError, KeyError):
            message = result.stderr.strip()
        raise RuntimeError(message)
    return json.loads(result.stdout) if result.stdout.strip() else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Apply settings; otherwise only show the plan")
    args = parser.parse_args()
    repo = "seeARMS/appears"
    base = f"repos/{repo}"
    state = api(base)
    plan = [
        ("Pinned, GitHub-owned Actions only", f"{base}/actions/permissions", "PUT",
         {"enabled": True, "allowed_actions": "selected", "sha_pinning_required": True}),
        ("Allowed Actions", f"{base}/actions/permissions/selected-actions", "PUT",
         {"github_owned_allowed": True, "verified_allowed": False, "patterns_allowed": []}),
        ("Read-only Actions tokens", f"{base}/actions/permissions/workflow", "PUT",
         {"default_workflow_permissions": "read", "can_approve_pull_request_reviews": False}),
        ("Dependabot vulnerability alerts", f"{base}/vulnerability-alerts", "PUT", None),
        ("Dependabot security fixes", f"{base}/automated-security-fixes", "PUT", None),
    ]
    public = state["visibility"] == "public"
    if public:
        plan += [
            ("Fork workflow approval", f"{base}/actions/permissions/fork-pr-contributor-approval", "PUT",
             {"approval_policy": "all_external_contributors"}),
        ]
    plan += [
        ("Private vulnerability reporting", f"{base}/private-vulnerability-reporting", "PUT", None),
        ("Secret scanning and push protection", base, "PATCH", {"security_and_analysis": {
            "secret_scanning": {"status": "enabled"},
            "secret_scanning_push_protection": {"status": "enabled"}}}),
        ("Release environment", f"{base}/environments/release", "PUT", {
            "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}),
    ]
    print(f"Repository: {repo} ({state['visibility']}); visibility will stay unchanged.")
    if not args.apply:
        for label, _, _, _ in plan:
            print(label)
        print("Main/tag rules and a v* tag policy for the release environment will also be applied.")
        return
    failures = []
    environment_ready = False
    for label, path, method, data in plan:
        try:
            api(path, method, data)
            print(f"Applied: {label}")
            if label == "Release environment":
                environment_ready = True
        except RuntimeError as error:
            failures.append(f"{label}: {error}")
    if environment_ready:
        path = f"{base}/environments/release/deployment-branch-policies"
        policies = api(path)["branch_policies"]
        if not any(p["name"] == "v*" and p["type"] == "tag" for p in policies):
            api(path, "POST", {"name": "v*", "type": "tag"})
        print("Applied: release environment accepts v* tags")
    try:
        existing = api(f"{base}/rulesets")
        for filename in ["main.json", "release-tags.json"]:
            rules = json.loads((ROOT / ".github/rulesets" / filename).read_text())
            current = next((r for r in existing if r["name"] == rules["name"]), None)
            path = f"{base}/rulesets" + (f"/{current['id']}" if current else "")
            api(path, "PUT" if current else "POST", rules)
            print(f"Applied: {rules['name']}")
    except RuntimeError as error:
        failures.append(f"Branch/tag rules: {error}")
    if not public:
        failures.append("Fork workflow approval policy: available after publication")
    if failures:
        print("\nNot applied:")
        for failure in failures:
            print(f"- {failure}")
        raise SystemExit(2)


if __name__ == "__main__":
    main()
