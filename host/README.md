# 宿主侧工具（Windows / PowerShell）

这些脚本**不在手机上跑**，是开发机用来驱动 iPhone MCP 服务和热更新的。
原项目把它们放在仓库外（`E:\work\`），换电脑时会丢，所以收进仓库。

> 没有 token、没有密码。唯一需要按你的环境改的是**设备 IP** 和**容器 UUID**。

## 一次性配置

### 1. 设备 IP

`mcp.ps1:2`：

```powershell
$script:MCP_EP = 'http://192.168.50.210:8090/mcp'    # ← 改成你的 iPhone IP
```

iPhone 上装 `ios-mcp`（1.2.8 已验证）后监听 8090。查 IP：`设置 → 无线局域网 → ⓘ`。

**手机必须保持亮屏**：息屏会让 MCP 服务和 Wi-Fi 一起挂（实测 ping 都不通）。

### 2. 容器路径

`transfer.ps1:6`：

```powershell
$D = '/var/mobile/Containers/Data/Application/141CCCF6-.../Library/Application Support/JJCheat'
```

UUID 每台设备不同。在设备上查：

```sh
ls -d /var/mobile/Containers/Data/Application/*/Library/Application\ Support/JJCheat
```

## 脚本说明

| 文件 | 用途 |
|---|---|
| `mcp.ps1` | MCP JSON-RPC 封装：`Connect-Mcp` / `Invoke-McpTool` / `Get-McpText` / `Show-McpTool`。UTF-8 原始解码（避免中文日志被 PowerShell 的 ANSI 解码弄乱） |
| `transfer.ps1` | **热更新 engine.js**：读 `dist/engine.js` → base64 分片（单次 MCP 请求体上限约 16KB）→ `write_file` 逐片 → 设备上 `base64 -d` 合并 → `mv` 覆盖 |
| `sampler2.ps1` | 边下棋边采样：OCR 抓 HUD 文本 + `get_syslog` 过滤 `[JJCheat]`，落 `E:\work\diag\run-*.log` |
| `capture.ps1` | 单次截图 + OCR，存 `E:\work\diag\` |
| `sampler.ps1` | 旧版采样器（保留备用） |

## 典型工作流

```powershell
# 1) 连设备
Invoke-Expression (Get-Content host\mcp.ps1 -Raw -Encoding UTF8)

# 2) 改完 JS 后热更新（不用重新出包）
node tools/bundle.js                                  # 重新打包 dist/engine.js
Invoke-Expression (Get-Content host\transfer.ps1 -Raw -Encoding UTF8)

# 3) 让插件重新加载
#    在设备上：杀进程重开 App，然后点鲸鱼球开启
```

改 `src/**` 或 `ios/tweak/**`（dylib、配置常量）**必须出包**：
push 到 `main` → GitHub Actions `build-roothide-deb.yml`（约 5~7 分钟）→
artifact `JJCheat-roothide-deb` → `install_app` 装到设备。

## 坑

- **PowerShell 5.1**：`-Encoding UTF8` 写文件会带 BOM，`dpkg-deb` 会报 `missing 'Package' field`。
  用 `[System.IO.File]::WriteAllText(path, text, (New-Object System.Text.UTF8Encoding($false)))`。
- 读含中文的文件要用 `-Encoding UTF8`，否则乱码。
- 执行策略会拦 dot-source `.ps1`，用 `Invoke-Expression (Get-Content ... -Raw -Encoding UTF8)`。
- 本机 `curl.exe` / `Invoke-WebRequest` 访问 GitHub 会 TLS 失败（`SEC_E_NO_CREDENTIALS`）；
  但 **Node 的 fetch 可以用**。拉 artifact、查 CI 状态都用 node。
  `git` 要加 `-c http.sslBackend=openssl`。
- `get_syslog` 窗口只有 ~55 秒，抓长流程要边跑边抓（见 `sampler2.ps1`）。
