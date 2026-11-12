#!/usr/bin/env python3
"""Prepare checked macOS release assets locally; never publishes or changes main."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import urllib.request
from urllib.parse import urlsplit
import zipfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--repository", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--notarized", action="store_true")
args = parser.parse_args()
assert re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", args.repository)
app = args.app.resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
expected = plistlib.loads((root / "Resources/Info.plist").read_bytes())
for key in ("CFBundleShortVersionString", "CFBundleVersion", "CFBundleIdentifier", "CFBundleExecutable"):
    assert info[key] == expected[key], key
assert (app / "Contents/Resources/Licenses/Untitled.txt").is_file()
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
details = subprocess.check_output(["codesign", "-dvv", str(app)], stderr=subprocess.STDOUT, text=True)
developer_id = "Authority=Developer ID Application:" in details
if args.notarized:
    assert developer_id, "Notarization requires Developer ID"
    subprocess.run(["xcrun", "stapler", "validate", str(app)], check=True)
version = info["CFBundleShortVersionString"]
tag = "v" + version
binary = app / "Contents/MacOS/Untitled"
architecture = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip().replace(" ", "-")
assert architecture in {"arm64", "x86_64", "x86_64-arm64", "arm64-x86_64"}
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
assert not any(output.iterdir()), "Use an empty output directory; never overwrite release assets"
subprocess.run(["python3", str(root / "scripts/package-plugins.py"), "--tag", tag,
                "--repository", args.repository, "--output", str(output)], check=True)
validation = output.parent / ("." + output.name + "-validation")
validation.mkdir(parents=True, exist_ok=True)
candidates = [str(path) for path in output.glob("*.zip")]
catalog = json.loads((output / "catalog.json").read_text())
external = json.loads((root / "Plugins/catalog-external.json").read_text())
assert external["schemaVersion"] == 1 and len(external["plugins"]) <= 100
ids = {entry["id"] for entry in catalog["plugins"]}
for entry in external["plugins"]:
    assert all(isinstance(entry.get(key), str) for key in
               ("id", "name", "version", "summary", "author", "downloadURL", "sha256"))
    assert re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)+", entry["id"])
    assert entry["id"] not in ids, "Duplicate catalog ID"
    ids.add(entry["id"])
    url = urlsplit(entry["downloadURL"])
    assert url.scheme == "https" and url.hostname == "github.com" and url.port is None
    assert not (url.username or url.password or url.query or url.fragment)
    assert re.fullmatch(r"/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/[A-Za-z0-9._-]+/[^/]+\.zip", url.path)
    assert re.fullmatch(r"[a-f0-9]{64}", entry["sha256"])
    with urllib.request.urlopen(entry["downloadURL"], timeout=60) as response:
        data = response.read(2 * 1024 * 1024 + 1)
    assert len(data) <= 2 * 1024 * 1024
    assert hashlib.sha256(data).hexdigest() == entry["sha256"]
    local = validation / (entry["id"] + ".zip")
    local.write_bytes(data)
    with zipfile.ZipFile(local) as archive_file:
        assert sorted(archive_file.namelist()) == ["LICENSE", "README.md", "manifest.json"]
        assert all(member.file_size <= 2 * 1024 * 1024 for member in archive_file.infolist())
        manifest = json.loads(archive_file.read("manifest.json"))
    assert manifest["id"] == entry["id"] and manifest["version"] == entry["version"]
    catalog["plugins"].append(entry)
    candidates.append(str(local))
(output / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
(validation / "packages.json").write_text(json.dumps({
    "catalog": str(output / "catalog.json"), "packages": candidates
}) + "\n")

archive = output / f"Untitled-macOS-{architecture}-{tag}.zip"
subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
metadata = {
    "product": "Untitled", "version": version, "sourceCommit": source, "architecture": architecture,
    "minimumMacOS": info["LSMinimumSystemVersion"],
    "signing": "Developer ID Application" if developer_id else "ad-hoc",
    "hardenedRuntime": "runtime" in details, "notarized": args.notarized,
    "ci": f"https://github.com/{args.repository}/actions/runs/" + os.environ.get("GITHUB_RUN_ID", ""),
}
(output / "BUILD-INFO.json").write_text(json.dumps(metadata, indent=2) + "\n")
assets = sorted(output.iterdir(), key=lambda path: path.name)
(output / "SHA256SUMS.txt").write_text("".join(
    f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in assets))
print(f"Prepared {tag}: {architecture}, {metadata['signing']}, notarized={args.notarized}")
