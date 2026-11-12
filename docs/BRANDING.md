# Untitled 品牌与图标

产品名 **Untitled**，仓库名 `untitled`。软件用途由用户持续定义。只开发 macOS，视觉采用黑白与不规则的「裂变」图形。

用户已选择 `design/branding/untitled/icon-options-04/i-rupture.png`。它由内置图片模型生成，原始提示词在同目录 `prompts.txt` 的 I 方案。其余方案保留作设计记录。

- `Resources/Brand/AppIcon.png`：所选原图的逐字节副本，不重绘、不重新生成图形。
- `Resources/Brand/ReadmeIcon.svg`：README 专用的圆角展示资源。内嵌原图的 512 像素缩略图，通过 SVG clipPath 裁出圆角，外侧透明；不依赖 GitHub 会过滤的内联 CSS，也不改变应用图标原图。
- `Resources/AppIcon.icns`：`scripts/build-icon.sh` 用 macOS sips / iconutil 缩放封装，包含 16–1024 像素标准尺寸。
- Info.plist 声明 `AppIcon`；命令行打包重新生成 ICNS，Xcode Resources 复制已提交的同一资源。

```bash
python3 scripts/build-readme-icon.py
./scripts/build-icon.sh
./scripts/build-app.sh debug
```

显示名、窗口、应用菜单、构建产物使用 Untitled。菜单栏用原生 `scribble` 符号以保持小尺寸清楚。新仓库链接、Schema 和后续 Release 地址使用 `tietiezhi-1216/untitled`。

包、模块、可执行文件、Xcode 工程 / target / scheme 均使用 `Untitled`，Bundle ID 为 `app.untitled`，环境变量为 `UNTITLED_*`。旧身份只作为迁移元数据和冻结发行目录保留，详见 [身份迁移](MIGRATION.md)。仓库 URL 与许可证作者仍使用真实 GitHub 账户；发布由 [PR 与 CI/CD 流程](RELEASING.md) 管理。
