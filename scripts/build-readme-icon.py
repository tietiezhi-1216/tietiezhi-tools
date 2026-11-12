#!/usr/bin/env python3
"""Wrap the approved artwork in a rounded SVG for GitHub's README renderer."""

import base64
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parent.parent
source = root / "Resources/Brand/AppIcon.png"
output = root / "Resources/Brand/ReadmeIcon.svg"

with tempfile.TemporaryDirectory(prefix="untitled-readme-icon-") as directory:
    thumbnail = Path(directory) / "icon.png"
    subprocess.run(
        ["/usr/bin/sips", "-z", "512", "512", str(source), "--out", str(thumbnail)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    encoded = base64.b64encode(thumbnail.read_bytes()).decode("ascii")

output.write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" '
    'viewBox="0 0 512 512" role="img" aria-labelledby="title">\n'
    '  <title id="title">Untitled · 裂变</title>\n'
    '  <defs><clipPath id="corners"><rect width="512" height="512" '
    'rx="112"/></clipPath></defs>\n'
    '  <image width="512" height="512" clip-path="url(#corners)" '
    f'href="data:image/png;base64,{encoded}"/>\n'
    '</svg>\n',
    encoding="utf-8",
)
print(f"已生成：{output.relative_to(root)}")
