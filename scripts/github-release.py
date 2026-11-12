#!/usr/bin/env python3
"""Publish verified releases and the catalog from trusted main CI only."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("operation", choices=["state", "publish", "repair"])
parser.add_argument("--assets", type=Path)
parser.add_argument("--mode", choices=["preview", "notarized"], default="preview")
args = parser.parse_args()
assert os.environ.get("GITHUB_ACTIONS") == "true", "Publishing is only supported by GitHub Actions"
assert os.environ.get("GITHUB_REF") == "refs/heads/main", "Only protected main may deploy"
assert os.environ.get("GITHUB_EVENT_NAME") in {"push", "workflow_dispatch"}
repository = os.environ["GITHUB_REPOSITORY"]
source = os.environ["GITHUB_SHA"]
assert re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repository)
assert re.fullmatch(r"[a-f0-9]{40}", source)
root = Path(__file__).resolve().parent.parent
import plistlib
version = plistlib.loads((root / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
tag = "v" + version
api_root = f"repos/{repository}"

def api(method, path, payload=None, missing=False):
    command = ["gh", "api", "--method", method, path]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        if missing and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout) if result.stdout.strip() else None

release = api("GET", f"{api_root}/releases/tags/{tag}", missing=True)
if args.operation == "state":
    publish = release is None or release["draft"]
    deployed = api("GET", f"{api_root}/contents/deployment.json?ref=plugin-catalog", missing=True)
    deployed_version = json.loads(base64.b64decode(deployed["content"]))["version"] if deployed else None
    numeric = lambda text: tuple(map(int, text.split(".")))
    newer = deployed_version is not None and numeric(deployed_version) > numeric(version)
    publish = publish and not newer
    repair = not publish and not newer and (deployed_version is None or numeric(deployed_version) < numeric(version))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"publish={str(publish).lower()}\nrepair={str(repair).lower()}\ntag={tag}\n")
    print(f"{tag}: " + ("prepare deployment" if publish else "already published; immutable assets retained"))
    raise SystemExit(0)

assets = args.assets.resolve()
metadata = json.loads((assets / "BUILD-INFO.json").read_text())
assert metadata["version"] == version
if args.operation == "publish":
    assert metadata["sourceCommit"] == source
else:
    assert release and not release["draft"], "Catalog repair needs an existing public release"
    source = metadata["sourceCommit"]
if args.operation == "publish":
    assert metadata["notarized"] == (args.mode == "notarized")
checksums = {}
for line in (assets / "SHA256SUMS.txt").read_text().splitlines():
    digest, name = line.split("  ", 1)
    assert Path(name).name == name and re.fullmatch(r"[a-f0-9]{64}", digest)
    assert hashlib.sha256((assets / name).read_bytes()).hexdigest() == digest
    checksums[name] = digest
payloads = [assets / name for name in sorted(checksums)] + [assets / "SHA256SUMS.txt"]
assert all(path.is_file() for path in payloads)
url = f"https://github.com/{repository}/releases/tag/{tag}"
tag_ref = api("GET", f"{api_root}/git/ref/tags/{tag}", missing=True)
if tag_ref:
    tagged = tag_ref["object"]
    if tagged["type"] == "tag":
        tagged = api("GET", f"{api_root}/git/tags/{tagged['sha']}")["object"]
    assert tagged["sha"] == source, "Existing tag points to a different source commit"
if release and not release["draft"]:
    assert release["tag_name"] == tag
    # An existing public release may only repair catalog deployment, never assets.
    existing = api("GET", f"{api_root}/git/ref/tags/{tag}")["object"]
    if existing["type"] == "tag":
        existing = api("GET", f"{api_root}/git/tags/{existing['sha']}")["object"]
    assert existing["sha"] == source, "Published tag points to a different source commit"
    remote_assets = {asset["name"]: asset for asset in release["assets"]}
    for path in payloads:
        assert remote_assets[path.name]["digest"] == "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
else:
    if release:
        assert release["target_commitish"] == source, "Draft belongs to another build"
    else:
        notes = assets.parent / "RELEASE-NOTES.md"
        status = ("Developer ID 签名且已完成 Apple 公证。" if metadata["notarized"] else
                  f"预览版：签名方式为 {metadata['signing']}，未完成 Apple 公证，不保证通过 Gatekeeper。")
        notes.write_text(
            f"Untitled {tag} · 仅支持 macOS\n\n{status}\n\n"
            f"架构：{metadata['architecture']}；最低 macOS {metadata['minimumMacOS']}。\n\n"
            "下载应用 ZIP，解压后放入应用程序目录；插件 ZIP 可独立安装。SHA-256 和构建信息随包提供。\n\n"
            "功能、权限、迁移、真机和性能验收范围见各插件 README 与开发文档。"
            f"\n\n源码：{source}\n\n[CI 验证]({metadata['ci']})\n", encoding="utf-8")
        subprocess.run(["gh", "release", "create", tag, "--repo", repository, "--target", source,
                        "--draft", "--title", f"{tag} · Untitled" + (" 预览版" if args.mode == "preview" else ""),
                        "--notes-file", str(notes)], check=True)
    subprocess.run(["gh", "release", "upload", tag, "--repo", repository, "--clobber",
                    *map(str, payloads)], check=True)  # Clobber is restricted to verified drafts above.
    with tempfile.TemporaryDirectory(prefix="untitled-release-verify-") as directory:
        subprocess.run(["gh", "release", "download", tag, "--repo", repository, "--dir", directory], check=True)
        for path in payloads:
            assert (Path(directory) / path.name).read_bytes() == path.read_bytes(), path.name
    subprocess.run(["gh", "release", "edit", tag, "--repo", repository, "--draft=false",
                    f"--prerelease={str(args.mode == 'preview').lower()}",
                    f"--latest={str(args.mode == 'notarized').lower()}"], check=True)

# Confirm anonymous public downloads before making this catalog visible to the app.
with tempfile.TemporaryDirectory(prefix="untitled-public-verify-") as directory:
    for path in payloads:
        public = Path(directory) / path.name
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
            "--retry-all-errors", "--max-time", "90", "--output", str(public),
            f"https://github.com/{repository}/releases/download/{tag}/{path.name}"], check=True)
        assert hashlib.sha256(public.read_bytes()).digest() == hashlib.sha256(path.read_bytes()).digest()

# Deploy metadata to a dedicated branch. No workflow ever commits to main.
ref = api("GET", f"{api_root}/git/ref/heads/plugin-catalog", missing=True)
parent = ref["object"]["sha"] if ref else None
base_tree = api("GET", f"{api_root}/git/commits/{parent}")["tree"]["sha"] if parent else None
current = api("GET", f"{api_root}/contents/deployment.json?ref=plugin-catalog", missing=True) if ref else None
if current:
    deployed = json.loads(base64.b64decode(current["content"]))
    assert tuple(map(int, version.split("."))) >= tuple(map(int, deployed["version"].split("."))), "Refusing catalog downgrade"
entries = []
for name, content in {
    "catalog.json": (assets / "catalog.json").read_bytes(),
    "deployment.json": json.dumps({"version": version, "source": source, "release": url}, indent=2).encode(),
}.items():
    blob = api("POST", f"{api_root}/git/blobs", {"content": base64.b64encode(content).decode(), "encoding": "base64"})
    entries.append({"path": name, "mode": "100644", "type": "blob", "sha": blob["sha"]})
tree = api("POST", f"{api_root}/git/trees", {"tree": entries, **({"base_tree": base_tree} if base_tree else {})})
commit = api("POST", f"{api_root}/git/commits", {"message": f"Deploy plugin catalog for {tag}",
    "tree": tree["sha"], "parents": [parent] if parent else []})
if ref:
    api("PATCH", f"{api_root}/git/refs/heads/plugin-catalog", {"sha": commit["sha"], "force": False})
else:
    api("POST", f"{api_root}/git/refs", {"ref": "refs/heads/plugin-catalog", "sha": commit["sha"]})
print(f"Published {url}; plugin catalog deployed by CI.")
