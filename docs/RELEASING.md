# Pull Request、CI/CD 与发布

所有开发使用功能分支和 Pull Request，main 不接受直接推送或本地合并后的推送。维护者在必需的 `verify` 检查通过、分支同步且讨论解决后，通过 GitHub 合并 PR。agents 默认交付 PR，不自行合并；用户明确要求仅本地时不推送。

## CI 与交付

`.github/workflows/ci.yml` 在面向 main 的 PR 和合并后的 main 上运行：

1. 检查包名、模块、Bundle ID、版本与 PR 的版本递增要求。
2. 串行运行 Swift 自动测试，构建 Release 应用、音频驱动 / WebP helper 和完整 Xcode target。
3. 生成应用 ZIP、插件 ZIP、目录、构建信息与 SHA-256；使用宿主实际的清单、UI 和权限校验器验证所有插件包。
4. 上传可下载的 CI 审查产物。PR 产物使用临时签名，不能宣称通过 Developer ID 或 Apple 公证。

PR 作业只有 `contents: read`，不获取发布密钥，不使用 `pull_request_target` 执行贡献者代码。Actions 固定到经确认的提交。贡献者可 fork、推送自己的分支并向 main 发 PR。

应用源码、资源或驱动变更递增 `Resources/Info.plist` 的版本与 build number，同步 `HostInfo.version`。自带插件清单变更递增插件版本，当前最低宿主为 0.10.0。文档修改无需重发应用。已公开的同版本资产不可替换；CI 遇到已发布版本会保留它。

## 合并后自动部署

只有受保护 main 的 `push`，或针对 main 的手动重试，才能在 `release` environment 中执行部署。部署依赖同一工作流的 `verify` 成功；写权限只授予部署 job。

新版本自动构建最终应用，按模式签名 / 公证，再生成最终 ZIP。CI 先上传 GitHub Release 草稿并下载核验，随后公开 Release，核验匿名下载，最后把目录部署到专用 `plugin-catalog` 分支。标签指向实际构建提交。部署不向 main 写入生成文件。

0.10.0+ 的应用从 `plugin-catalog/catalog.json` 读取商店目录。main 的 `Plugins/catalog.json` 是供旧客户端使用的冻结目录，不再更新。发布失败不会提前部署新目录；草稿可重试，已公开的资产不改写。若公开 Release 后目录部署中断，重跑会下载既有资产修复目录，不重新打包覆盖它们。版本较旧的重试不能覆盖较新的目录。

独立插件在 `Plugins/catalog-external.json` 中提交标准目录记录：ID、名称、版本、摘要、作者、真实 GitHub Release 下载 URL 与 SHA-256。CI 限制下载大小、检查归档和清单身份，并通过宿主实际的校验器验证包；目录引用原作者的发行资产，不复制发布到宿主 Release。许可和人工验证要求见 [贡献规范](../CONTRIBUTING.md)。

## 签名模式

仓库变量 `UNTITLED_RELEASE_MODE`：

| 值 | 行为 |
| --- | --- |
| `preview`（默认） | 自动发布预览版。有 Developer ID 凭据时使用该签名；没有时使用 ad-hoc 临时签名。发布说明及 BUILD-INFO 明确标注签名和未公证状态，不标记为稳定最新版。 |
| `notarized` | 必须具备 Developer ID 与 App Store Connect 认证；Apple 接受、公证票据 staple 和验证均成功后才发布稳定版本。缺少凭据或任一步失败直接停止，不降级发布。 |

在 GitHub 仓库 Settings → Environments → release 配置以下 secrets；不要提交文件或把值写进日志：

| Secret | 内容 |
| --- | --- |
| `UNTITLED_CERTIFICATE_P12` | 包含 Developer ID Application 证书和私钥的 P12，以 Base64 保存 |
| `UNTITLED_CERTIFICATE_PASSWORD` | 该 P12 的导出密码 |
| `UNTITLED_NOTARY_KEY` | App Store Connect API 私钥 P8，以 Base64 保存 |
| `UNTITLED_NOTARY_KEY_ID` | API Key ID |
| `UNTITLED_NOTARY_ISSUER` | Team API Key 的 Issuer ID；Individual API Key 留空 |

本机钥匙串里的证书不会自动成为 GitHub secret。CI 只导入维护者提供的密钥，不从开发者电脑导出私钥。认证材料仅写入 runner 临时目录和独立钥匙串，完成或失败后清理。当前仓库未配置这些 secrets 时，默认只能自动发布临时签名的预览版。

Apple 认证与公证流程参考 [Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)；PR token、job 权限和 environment 语义参考 [GitHub 工作流语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)。

## main 保护

仓库实际开启 main 保护，配置留在 [main-protection.json](../.github/main-protection.json)：必须经 PR、`verify` 成功且与 main 同步、讨论解决，禁止强推和删除，管理员同样受约束。当前不强制第二位维护者批准，便于单维护者项目接收贡献；代码仍由维护者决定是否合并。

保护配置不是由普通 CI 自动修改。仓库管理员需要恢复配置时使用 GitHub Settings → Branches，或显式使用 GitHub API 应用该文件。不要为绕过失败检查暂时取消保护。

## 本地验证

```bash
python3 scripts/check-project.py
swift test --no-parallel
./scripts/build-app.sh release
python3 scripts/prepare-release.py --app dist/release/Untitled.app \
  --repository OWNER/REPOSITORY --output dist/local-release
UNTITLED_PACKAGE_CANDIDATES_FILE=dist/.local-release-validation/packages.json \
  swift test --no-parallel --filter validateReleasePackages
```

使用新的空输出目录。上述操作只生成本地可审查产物。发布脚本只允许在 GitHub Actions 的 main 部署上下文运行，agents 不手工创建标签或上传 Release。
