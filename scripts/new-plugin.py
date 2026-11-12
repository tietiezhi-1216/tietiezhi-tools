#!/usr/bin/env python3
"""Create a working declarative Untitled plugin with a main-panel action."""

import argparse
import json
from pathlib import Path
import re
import shutil


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slug", help="Directory name, for example my-plugin")
    parser.add_argument("--id", required=True, help="Stable namespaced id, for example dev.alice.my-plugin")
    parser.add_argument("--name", required=True, help="User-visible name")
    parser.add_argument("--author", required=True)
    parser.add_argument("--repository", default="https://github.com/tietiezhi-1216/untitled")
    parser.add_argument("--output", type=Path, default=root / "Plugins", help="Parent directory")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.slug):
        parser.error("slug must contain lowercase letters, digits and single hyphens")
    if len(args.id) > 100 or not re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)+", args.id):
        parser.error("id must use a stable lowercase namespace")
    if not args.name.strip() or len(args.name) > 80 or not args.author.strip():
        parser.error("provide a nonempty author and a name of 1–80 characters")
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*/?", args.repository):
        parser.error("repository must be an HTTPS GitHub repository URL")
    target = args.output.expanduser().resolve() / args.slug
    if target.exists():
        parser.error(f"refusing to overwrite {target}")
    manifest = {
        "schemaVersion": 2, "id": args.id, "name": args.name, "version": "1.0.0",
        "summary": "打开 Untitled 主面板；可在此基础上开发自己的功能。", "author": args.author,
        "repository": args.repository, "minimumHostVersion": "0.9.0",
        "actions": ["showMainWindow"],
        "templates": [{"id": "main-panel", "title": "打开主面板", "action": "showMainWindow"}],
        "permissions": [],
        "ui": {"version": 1, "icon": "puzzlepiece.extension", "slots": {
            "header.leading": [{"id": "identity", "kind": "component", "component": "host.identity"}],
            "header.trailing": [
                {"id": "enabled", "kind": "component", "component": "host.enabled"},
                {"id": "more", "kind": "component", "component": "host.more"}],
            "toolbar.trailing": [{"id": "add", "kind": "component", "component": "host.addCommand"}],
            "content": [{"id": "commands", "kind": "component", "component": "host.commands"}],
            "menuBar": [{"id": "open", "kind": "button", "command": "host.openPlugin"}],
        }},
    }
    target.mkdir(parents=True)
    (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (target / "README.md").write_text(
        f"# {args.name}\n\n"
        f"插件 `{args.id}`，版本 1.0.0，最低宿主 Untitled 0.9.0，macOS 14+。\n\n"
        "当前示例提供“打开主面板”操作，可在插件页面添加并执行。\n\n"
        "系统权限：无。网络请求：无。密钥与额外数据：无。卸载删除本插件操作配置。\n\n"
        "开发时根据实际功能更新动作、界面、权限、平台要求和验证说明。"
        "新增原生能力需注册 PluginUIProvider 并随宿主编译，ZIP 不加载原生代码。\n\n"
        "## 性能与资源\n\n"
        "当前示例只有用户触发的主面板动作，不创建常驻服务、大缓存或工作队列。"
        "CPU / 内存尚未实测，不宣称零开销。开发完成后记录输入与并发上限、"
        "缓存及停止后的清理、测试环境、基线、峰值和反复启停后的趋势；"
        "高开销功能按仓库 docs/PERFORMANCE.md 使用实际负载剖析并填写未测项。\n\n"
        "许可证：随包 MIT；采用其他许可时替换 LICENSE 并更新说明。\n"
    )
    shutil.copyfile(root / "LICENSE", target / "LICENSE")
    print(target)


if __name__ == "__main__":
    main()
