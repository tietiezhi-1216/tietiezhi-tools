# 插件仓库

本项目所有插件统一存放在这个仓库的 `Plugins/` 下。首页商店读取 `Plugins/catalog.json`，从同一仓库的 GitHub Releases 下载 ZIP，并校验目录中记录的 SHA-256。

每个插件一个目录，至少提供 `manifest.json`，建议附带 `README.md`。发布包是扁平 ZIP，根目录仅允许 `manifest.json`、`README.md`、`LICENSE`。

## 插件 API v1

参考 [全局快捷键](global-shortcuts/manifest.json)：

| 字段 | 用途 |
| --- | --- |
| `schemaVersion` | 目前固定为 `1` |
| `id` | 唯一标识，小写字母、数字、点和连字符 |
| `name` / `summary` / `author` | 商店和详情页信息 |
| `version` / `minimumHostVersion` | 三段数字版本，例如 `1.0.0` |
| `repository` | 统一仓库 `https://github.com/tietiezhi-1216/tietiezhi-tools` |
| `actions` | 插件贡献的操作类型 |
| `templates` | “添加操作”中的模板；每项包含 `id`、`title`、`action` |

主程序是声明式插件宿主，提供通用的配置界面、动作执行、快捷键注册、安装和存储；不会根据插件 ID 选择特殊业务页面。插件贡献操作模板，用户的具体目标、快捷键和启停状态只保存在本机。

当前支持 `openApplication`、`openURL`、`runShortcut`、`showMainWindow`。新增这些能力范围内的插件无需修改或重新编译主程序；新增原生能力需要先扩展宿主 API。本版不会动态加载 Swift 二进制、JavaScript 或 Shell 脚本。

安装包不提供默认全局快捷键，不会在安装时执行操作。用户配置后才可执行或注册热键。

## 发布插件

```bash
python3 scripts/package-plugins.py --tag v0.2.0 --write-catalog
```

将更新的清单和 `catalog.json` 提交，创建同名 GitHub Release，并上传 `dist/plugins/*.zip`。不要在发布后替换同版本资产，否则 SHA-256 会不匹配；更新插件时应递增版本。源码、商店目录和下载资产必须保持一致。

安装后数据位于 `~/Library/Application Support/com.tietiezhi.tools/Plugins/<id>.json`。每个文件保存插件声明与用户配置，原子写入；升级保留配置，禁用释放快捷键，卸载删除该插件文件。卸载前应自行备份需要保留的配置。
