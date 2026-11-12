#!/usr/bin/env python3
"""Check canonical identities, versions, and PR release requirements."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base", help="PR base commit; enforces version bumps for application changes")
args = parser.parse_args()
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
assert info["CFBundleName"] == info["CFBundleDisplayName"] == info["CFBundleExecutable"] == "Untitled"
assert info["CFBundleIdentifier"] == "app.untitled"
host = (root / "Sources/Untitled/Plugins/PluginManifest.swift").read_text()
assert f'static let version = "{version}"' in host
assert 'static let bundleIdentifier = "app.untitled"' in host
previous = info["UntitledIdentityMigration"]
project = json.loads((root / "Sources/Untitled/Resources/Project.json").read_text())
assert info["UntitledRepositoryURL"] == project["repository"]
owner = project["repository"].split("/")[3]
old_prefix = previous["bundleIdentifier"].split(".")[1].lower()
files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
exempt = {"LICENSE", "Plugins/catalog.json", "Resources/Info.plist"}
for name in sorted(set(files) - exempt):
    path = root / name
    if not path.is_file() or name.startswith("design/"):
        continue
    assert old_prefix not in name.lower(), f"Previous identity in filename: {name}"
    try:
        text = path.read_text().replace(owner, "")
    except UnicodeError:
        continue
    assert old_prefix not in text.lower(), f"Previous identity in active source: {name}"
builtin_ids = {value.rsplit(".", 1)[1]: value for value in previous["plugins"].values()}
numeric = lambda value: tuple(map(int, value.split(".")))
for path in (root / "Plugins").glob("*/manifest.json"):
    manifest = json.loads(path.read_text())
    if path.parent.name in builtin_ids:
        assert manifest["id"] == builtin_ids[path.parent.name]
        assert numeric(manifest["minimumHostVersion"]) >= (0, 10, 0)
    assert numeric(manifest["minimumHostVersion"]) <= numeric(version)
driver = plistlib.loads((root / "Tools/SharingMicrophone/Info.plist").read_bytes())
assert driver["CFBundleIdentifier"] == "app.untitled.microphone.driver"
assert driver["CFBundleExecutable"] == "UntitledMicrophone"
# This immutable catalog remains available only to older released clients.
legacy = json.loads((root / "Plugins/catalog.json").read_text())
assert all(entry["id"] in previous["plugins"] for entry in legacy["plugins"])
if args.base:
    base_info = plistlib.loads(subprocess.check_output(["git", "show", f"{args.base}:Resources/Info.plist"], cwd=root))
    changed = subprocess.check_output(["git", "diff", "--name-only", args.base, "HEAD"], cwd=root, text=True).splitlines()
    application_changed = any(p.startswith(("Sources/", "Resources/", "Tools/")) and not p.endswith(".md") and p != "Resources/Brand/ReadmeIcon.svg" for p in changed)
    if application_changed:
        assert numeric(version) > numeric(base_info["CFBundleShortVersionString"]), "Application changes need a new host version"
        assert int(info["CFBundleVersion"]) > int(base_info["CFBundleVersion"]), "Application changes need a new build number"
    changed_plugins = {Path(name).parts[1] for name in changed
                       if name.startswith("Plugins/") and len(Path(name).parts) == 3
                       and Path(name).name in {"manifest.json", "README.md", "LICENSE"}}
    for slug in changed_plugins:
        path = f"Plugins/{slug}/manifest.json"
        old = subprocess.run(["git", "show", f"{args.base}:{path}"], cwd=root, capture_output=True)
        current = root / path
        if old.returncode == 0 and current.is_file():
            before, after = json.loads(old.stdout), json.loads(current.read_text())
            assert numeric(after["version"]) > numeric(before["version"]), f"Packaged plugin changes need a new version: {slug}"
print(f"Untitled {version}: canonical identities and release versions verified.")
