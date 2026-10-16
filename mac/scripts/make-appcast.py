#!/usr/bin/env python3
"""Turn the matching published GitHub release into native, inline Sparkle notes."""
import datetime
import email.utils
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def make_appcast(version, release, info, size, signature):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Expected X.Y.Z")
    if release.get("tag_name") != f"v{version}" or release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("Expected the matching published stable GitHub release")
    notes = release.get("body") or ""
    if not notes.strip():
        raise ValueError("Add a changelog to the GitHub release before building")
    release_url = f"https://github.com/seeARMS/appears/releases/tag/v{version}"
    if release.get("html_url") != release_url:
        raise ValueError("Release must belong to seeARMS/appears")
    if info["CFBundleShortVersionString"] != version or not re.fullmatch(r"[1-9][0-9]*", str(info["CFBundleVersion"])):
        raise ValueError("App and release versions must agree, with a positive build number")
    published = datetime.datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Appears"
    ET.SubElement(channel, "link").text = "https://appea.rs/"
    ET.SubElement(channel, "description").text = "Updates for Appears"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(published)
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(info["CFBundleVersion"])
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}format": "markdown"}).text = f"## Changelog\n\n{notes.strip()}"
    ET.SubElement(item, "enclosure", {
        "url": f"https://appea.rs/downloads/v{version}/Appears.dmg",
        f"{{{SPARKLE}}}edSignature": signature, "length": str(size), "type": "application/octet-stream",
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


if __name__ == "__main__":
    version, release_path, info_path, dmg_path, signer, key_path, output = sys.argv[1:]
    # A key path, never key contents, goes on the command line. Suppress tool
    # diagnostics because upstream may echo malformed key material on failure.
    result = subprocess.run([signer, "--ed-key-file", key_path, "-p", dmg_path], capture_output=True, text=True)
    if result.returncode or not re.fullmatch(r"[A-Za-z0-9+/]{86}==", result.stdout.strip()):
        raise SystemExit("Could not sign the update. Check the Sparkle signing key.")
    payload = make_appcast(version, json.loads(pathlib.Path(release_path).read_text()),
                           plistlib.loads(pathlib.Path(info_path).read_bytes()), pathlib.Path(dmg_path).stat().st_size, result.stdout.strip())
    pathlib.Path(output).write_bytes(payload)
