#!/usr/bin/env python3
"""Build reproducible declarative ZIP plugins and their GitHub catalog."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="GitHub release tag, for example v0.2.0")
    parser.add_argument("--write-catalog", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.tag):
        parser.error("invalid release tag")
    root = Path(__file__).resolve().parent.parent
    output = root / "dist" / "plugins"
    output.mkdir(parents=True, exist_ok=True)
    entries = []
    for source in sorted((root / "Plugins").glob("*/manifest.json")):
        manifest = json.loads(source.read_text())
        name = f"{source.parent.name}-{manifest['version']}.zip"
        archive = output / name
        contents = {"manifest.json": source.read_bytes(), "LICENSE": (root / "LICENSE").read_bytes()}
        if (source.parent / "README.md").exists():
            contents["README.md"] = (source.parent / "README.md").read_bytes()
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
            for filename, data in sorted(contents.items()):
                info = zipfile.ZipInfo(filename, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                package.writestr(info, data)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        entries.append({
            key: manifest[key] for key in ("id", "name", "version", "summary", "author")
        } | {
            "downloadURL": f"https://github.com/tietiezhi-1216/tietiezhi-tools/releases/download/{args.tag}/{name}",
            "sha256": checksum,
        })
        print(f"{checksum}  {archive.relative_to(root)}")
    catalog = {"schemaVersion": 1, "plugins": entries}
    text = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    (output / "catalog.json").write_text(text)
    if args.write_catalog:
        (root / "Plugins" / "catalog.json").write_text(text)


if __name__ == "__main__":
    main()
