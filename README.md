# cpa-update（update-cliproxyapi.ps1）

本仓库提供一个 PowerShell 脚本，用于在 Windows 上自动下载并更新 CLIProxyAPI 的最新 stable 版本，并在更新后按 `config.patch.yaml` 对 `CLIProxyAPI/config.yaml` 做必要的补丁修改。

## 1. 使用方式

在你想安装/更新 CLIProxyAPI 的目录里打开 PowerShell，`cd` 到目标目录后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\update-cliproxyapi.ps1
```

## 2. 脚本会做什么

- 调用 GitHub Releases API 获取 CLIProxyAPI 最新 stable 版本
- 下载 `*_windows_amd64.zip` 到当前目录（`.partial` 为下载中临时文件）
- 解压并把文件放到：`./CLIProxyAPI/`（目录层级更浅）
  - 如果 zip 里只有一层顶级目录，会自动去掉这一层
- 确保存在 `config.yaml`
  - 如果没有 `config.yaml` 且有 `config.example.yaml`，则复制生成
  - 然后会自动补齐/更新必要配置（见下）

## 3. GitHub API 403 / Rate limit（常见）

如果你看到类似 `API rate limit exceeded` 或 403，说明你的网络出口 IP 触发了 GitHub API 匿名限流。

解决方法：配置 GitHub Token（推荐）

- 在 https://github.com/settings/tokens 生成一个 token（只需要 public repo 访问即可）
- 永久设置环境变量：

```powershell
setx GITHUB_TOKEN "你的token"
```

重新打开 PowerShell 后再运行脚本。

或仅对当前窗口生效：

```powershell
$env:GITHUB_TOKEN="你的token"
```

然后再运行脚本。

## 4. 参数（可选）

- `-Owner` / `-Repo`：默认 `router-for-me / CLIProxyAPI`
- `-AssetPattern`：默认 `*_windows_amd64.zip`
- `-InstallRoot`：默认当前目录下的 `./CLIProxyAPI`
- `-CleanBeforeUpdate`：更新前清理旧下载的 zip / `.partial`，并删除解压目录 `InstallRoot`（默认开启）
- `-NoClean`：不执行更新前清理（覆盖 `-CleanBeforeUpdate`）
- `-Force`：强制重新下载/解压（注意：可能会覆盖安装目录里的文件；`config.yaml` 默认保留）
- `-PatchConfigPath`：补丁配置文件路径（默认当前目录下 `./config.patch.yaml`）

示例：

```powershell
# 默认会在更新前清理旧 zip / 解压目录
powershell -NoProfile -ExecutionPolicy Bypass -File .\update-cliproxyapi.ps1 -Force -Verbose

# 如需保留现有 zip / 解压目录，不做清理：
powershell -NoProfile -ExecutionPolicy Bypass -File .\update-cliproxyapi.ps1 -NoClean -Force -Verbose
```

## 5. 补丁配置文件（config.patch.yaml）

先把仓库里的 `config.patch.example.yaml` 复制为 `config.patch.yaml`，然后按需修改。

脚本会从 `config.patch.yaml` 读取：

- `secret-key`
  - 仅当目标 `config.yaml` 的 `remote-management.secret-key` 为空时才写入
  - 写入位置是 `remote-management.secret-key`（不是顶层 `secret-key`）
- `api-keys`
  - 在已有列表基础上追加去重
- `proxy-url`（顶层）
  - **只修改目标 `config.yaml` 顶层的 `proxy-url`**（即这行注释 `# Proxy URL. Supports socks5/http/https protocols...` 下面的那一行）
  - 仅当 `config.patch.yaml` 里提供了**顶层** `proxy-url` 时才会写入；不写则保持目标 `config.yaml` 原值不变
  - 允许写成 `""` 来清空目标值
  - 注意：不会处理/修改 `codex-api-key-block` 内部出现的那些 `proxy-url`
- `codex-api-key` / `codex-api-key-block`
  - 推荐直接在 `config.patch.yaml` 里写 `codex-api-key:`（标准 YAML）
  - 兼容 `codex-api-key-block: |` 这种“字符串 block”写法：脚本会先把 block 解析成 YAML，再合并进配置

### 5.1 proxy-url 示例

保持原值（不改）：

```yaml
# 不写 proxy-url 这一项
```

设置为某个代理：

```yaml
proxy-url: "http://127.0.0.1:7897"
```

清空代理：

```yaml
proxy-url: ""
```
