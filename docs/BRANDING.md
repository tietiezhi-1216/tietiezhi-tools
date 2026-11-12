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

为保留身份与数据，Bundle ID `com.tietiezhi.tools`、module / Xcode scheme `TietiezhiTools`、Application Support、Keychain、插件 ID 及既有音频驱动标识继续沿用。新默认导出目录为 `~/Pictures/Untitled`；旧 `~/Pictures/Tietiezhi Tools` 已存在时继续使用，自定义路径不变。历史目录保留原 Release 下载 URL 与 SHA-256，不重写旧包。
