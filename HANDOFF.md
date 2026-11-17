# JJCheat 交接文档（roothide / 2026-11-17 版）

> 接手前先读 **§0 与 §2**。§2 是当前唯一真正的阻塞点，在它解决之前，任何抓帧/引擎改动都是盲改。

---

## §0 状态速览（2026-11-17 15:45）

| 项 | 状态 |
|---|---|
| 仓库 | `Oxmaner/jjcheat`（private），head `276c05e`，包版本 **2.1.67** |
| 架构 | 2.1.x 已重构：`Capture/` `Core/` `Engine/` `Game/` `UI/` `Vision/`，引擎换成**进程内 Pikafish**（不是 1.x 的 JS 引擎） |
| 设备安装 | `com.fujiang.jjcheat` **2.1.67** 完整包已装（50 MB，md5 `57d57d52…` 与本地一致） |
| dylib | `…/DynamicLibraries/JJCheat.dylib` 2545504 B, md5 `615701a5…8caa592c` = **诊断版**（`nextDrawable` hook 体为 `return %orig`） |
| **阻塞** | **tweak 没有被注入进游戏进程**：重启多次、`[JJCheat]` 日志一条都没有（详见 §2） |
| 崩溃 | 14:31 那份 `.ips` 分析完 → **主线程渲染循环的 0x0，与 2.1.61/62/63 修的引擎线程无关**（详见 §3） |
| 未验证 | 诊断包「摘掉 Metal hook 后是否还崩」——因为 §2 阻塞，这个实验始终没拿到数据 |

---

## §1 环境

| 项 | 值 |
|---|---|
| 设备 | iPhone14,3 / iOS **15.1** / **Dopamine-roothide**（procursus(roothide)） |
| jbroot | `/var/containers/Bundle/Application/.jbroot-DB287DC7EB4CA44A/` |
| 目标 App | bundle `cn.jj.chinachess`，进程名 `TKLobby_chess_tuanjie` |
| App 路径 | `/var/containers/Bundle/Application/22C9D37B-DB99-4573-95BE-62B17741E8D2/TKLobby_chess_tuanjie.app` |
| App 二进制时间 | **Nov 10 15:26**（这之后注入行为发生了变化，见 §2） |
| App 数据容器 | `/var/mobile/Containers/Data/Application/141CCCF6-0FE0-4492-8E22-5EDFAC205EF5/` |
| engine.js | `…/Library/Application Support/JJCheat/engine.js`（288538 B） |
| NNUE 权重 | `…/Library/Application Support/JJCheat/Pikafish/pikafish.nnue`（50308806 B） |
| 屏幕 | native 1284×2778 / point 428×926 / @3x |
| 包管理器 | Sileo 2.5.1 —— **reinstall 只卸不装，装机用 dpkg** |
| 构建 | GitHub Actions `macos-15` + roothide/theos，产物只上传 artifact（不发 Release） |

roothide 硬规则：

- `data.tar` 内路径必须相对 jbroot，**不能**出现 `/var/jb`，更不能出现 `rootfs`
- `/rootfs` 是只读系统卷
- dylib 的 install_name 是 `@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/JJCheat.dylib`，依赖 `@loader_path/.jbroot/usr/lib/libroothide.dylib` 与 `libsubstrate.dylib`（→ `libellekit.dylib`）；该目录下 `.jbroot -> //` 符号链接负责把路径展开
- 设备上 `/usr/lib/libroothide.dylib`（168576 B）与 `/usr/lib/libsubstrate.dylib -> libellekit.dylib`（787088 B）**存在**，依赖不是问题

---

## §2 当前阻塞：tweak 未被注入（最高优先级）

### 现象

重启游戏多次（`kill_app` + `launch_app`，pid 每次变），用 `get_syslog` 抓 12～25 秒窗口：

```
JJCheat hits: 0
```

`TKLobby_chess_tuanjie` 自己的日志有（28 条，全是 `com.apple.network` 的 `tcp_input`），但**没有任何 `[JJCheat]` 输出**，也没有 ElleKit/dyld 的加载痕迹（syslog 里两条 `category: Injection` 属于系统 `com.apple.BoardServices`，与本项目无关）。

### 关键矛盾

**今天早上 04:39 的日志是有 `[JJCheat]` 的** —— 当时能打出：

```
棋盘学习完成 { verifyDiff=0, ok=1, ... }
引擎就绪 uciok=1
```

说明那时注入是好的。之后唯一的动作是：**重装了 deb 包**。所以是**注入配置层**的问题，不是代码。

### 已排除

| 假设 | 排除依据 |
|---|---|
| dylib 文件不在位 | 文件在，2545504 B，md5 与构建产物一致 |
| 依赖缺失 | `libroothide.dylib`、`libsubstrate.dylib` 都在 |
| dylib 未签名 | `LC_CODE_SIGNATURE` 存在（两个 slice 都有） |
| plist 过滤不对 | `JJCheat.plist` 的 `Filter.Bundles` 含 `cn.jj.chinachess` |
| trustcache 缺 cdhash | `jbctl trustcache info` 只有 1 行，但**其他能正常工作的 tweak 也不在**（如 Axon/SnowBoard），所以不是判据；且 `jbctl trustcache add` 要 root 而 `mcp-root` 不放行 |
| postinst 有问题 | 完整包 `postinst` 只处理 engine.js / NNUE / 清理 1.x 残留，不碰签名，也不写 `.app` |

### 待做（需要人工介入）

1. 打开 **Bootstrap**（roothide 管理 App）→ **App List** → 确认 **JJ象棋** 的注入开关是开的；已是开的话关掉再打开，让它重新打补丁
2. 恢复后立刻验证，只认这一行：
   ```
   [JJCheat] tweak 已加载 (pid=…, 2.1.x pikafish)
   ```
3. 若仍无日志，下一步在 dylib 的 `%ctor` **第一行**加一条无条件 `NSLog` 并重打包 —— 那是判断「有没有被 dyld 加载」的最小实验

### 一个不能忽略的推论

App 二进制时间是 **Nov 10 15:26**，而 04:39 的日志证明注入当时有效。若 App Store 更新（或 roothide 的补丁副本）在某个时间点被替换，注入就会失效。**接手时先确认注入，再谈崩溃。**

---

## §3 崩溃分析：14:31 的那份 `.ips`

文件：`TKLobby_chess_tuanjie-2026-11-17-143138.ips`（91962 B）

```
exception: EXC_BAD_ACCESS (SIGSEGV)
subtype:   KERN_INVALID_ADDRESS at 0x0000000000000000     ← 空指针
faultingThread = 0   →  com.apple.main-thread             ← 主线程
images:    TuanjieFramework（游戏引擎）, QuartzCore, JJCheat.dylib(uuid 11f986fc-…)

栈（thread 0）：
  TuanjieFramework +9435188 / +9430248 ×2 / +17757552 / +17942824 / +3894208 / +852516
  TuanjieFramework +126957656 / +135702576 / +133828360 / +138857036 / …
  QuartzCore  CA::Display::DisplayLink::dispatch_items
  QuartzCore  CA::Display::DisplayLink::dispatch_deferred_display_links
  UIKitCore   __setupUpdateSequence_block_invoke → _UIUpdateSequenceRun
  CoreFoundation __CFRunLoopRun
```

**这条栈里没有一帧 JJCheat，也没有一帧 JJPikafish。**

> ⚠️ **15:55 更正 —— 上面这个结论只对 thread 0 成立，整体结论是错的。请先读 §11。**
>
> 这份 `.ips` 一共 **100 个线程**（`threads` 数组在 JSON 第 39 行，普通 Read 会被 2000 字符截断，看起来像只有主线程）。其中 **thread 91 就是引擎线程，栈全部带 JJCheat.dylib 符号**，末尾停在 `Network::verify → exit(EXIT_FAILURE)`。
>
> 也就是说：**这次崩溃确实是插件引起的**；主线程的 0x0 是引擎线程调用 `exit()` 拆进程时，撞上正在跑的渲染循环造成的二次伤害。2.1.61/62/63 修的方向（线程栈、SIGSEGV handler、setoption）全部无关。

而 2.1.61 / 2.1.62 / 2.1.63 三个 commit 修的分别是「NSThread 栈 512KB→16MB」、「装 SIGSEGV handler 抓 backtrace」、「去掉 `setoption Threads/EvalFile`」—— 全部针对**引擎线程**。SIGSEGV 只影响出错线程，`faultingThread=0` 已经明确是主线程。

结论：**这份崩溃大概率与引擎搜索无关**；若当时 tweak 也没注入成功（§2），那它根本与插件无关，是游戏自身的崩溃。

按可能性排序的主线程嫌疑（在注入恢复后应逐一二分）：

| 顺序 | 嫌疑 | 依据 |
|---|---|---|
| ① | `CAMetalLayer -nextDrawable` hook | Unity 主线程渲染必经此路；当前实现跨帧 `CFRetain` IOSurface |
| ② | HUD 窗口刷新 | 也在 `DisplayLink` 驱动的 UI 更新链上 |
| ③ | 主线程上的 JS 识别 / 状态更新 | 2.0 起已用「帧序号 + 指纹」降频，但仍可能阻塞 |

---

## §4 仓库结构与关键文件

```
ios/tweak/
  Tweak.x                    Logos hook 入口（EAGLContext ×3、CAMetalLayer -nextDrawable）
  Core/JJConfig.h            全部可调参数 + 诊断开关 JJ_DISABLE_METAL_HOOK
  Capture/JJMetalGrabber.m   Metal 抓帧（nextDrawable + 上一帧 IOSurface，专用读帧队列）
  Capture/JJScreenGrabber.m  抓帧调度与黑帧判定
  Vision/JJVisionBridge.m    JS 引擎桥（2.x 里还负责调 Pikafish）
  Vision/JJEngineScript.c    engine.js 内嵌副本（构建时由 tools/gen-engine-c.py 生成）
  Engine/JJPikafish.m        进程内 Pikafish（UCI 握手、搜索、NNUE mmap）
  Engine/JJPikafishInstaller.m  权重落位到 App 容器
  Engine/JJMoveCodec.m       着法编码
  Game/JJGameController.m    状态机 / tick / 学习 / 标定联动（40 KB）
  Game/JJCalibrator.m        四点标定 + 网格对齐
  UI/JJHUDWindow.m           顶部信息条 + 箭头 + 标定 UI
  UI/JJBallWindow.m          悬浮球（懒加载入口）
  layout/DEBIAN/postinst     只处理 engine.js / NNUE / 清理残留，绝不写 .app
```

已废弃、**不要再用**：`layout/usr/bin/jjcheat-fix`（往 `.app` 塞 engine.js 会破坏签名）、`prerm` 里对应的清理逻辑仅作历史残留兜底。

---

## §5 构建流水线

```bash
curl -X POST -H "Authorization: token <TOKEN>" \
  https://api.github.com/repos/Oxmaner/jjcheat/actions/workflows/build-roothide-deb.yml/dispatches \
  -d '{"ref":"main"}'
```

11 步 ≈ 5–7 分钟：取代码 → 工具链 → roothide/theos → ldid+dpkg → 补 iPhoneOS16.5 SDK → **缓存/交叉编译 Pikafish** → **版本号递增** → 打包 engine.js → `make package` → 校验产物 → 上传 artifact（deb / engine.js / Pikafish 静态库）。

版本号规则：`2.1.${GITHUB_RUN_NUMBER}`，即**每次构建自动 +1**。

产物大小 ~50 MB（主要是 Pikafish 二进制 + NNUE）。

---

## §6 设备操作：iOS MCP（重要，本轮新增能力）

服务地址 `http://192.168.137.11:8090/mcp`，ios-mcp **1.2.8**，共 **46 个工具**。
本项目会话里**没有**把 MCP 挂进原生工具表，是直接用 JSON-RPC 走 HTTP 调用的；辅助脚本在
`F:\MacLin\Documents\jjcheat-local\`：`mcp_call.py`（通用调用）、`grab_shot.py`（截图）、`list_tools.py`。

调用要点：

- `initialize` → 拿 `Mcp-Session-Id` → `tools/call`
- 参数一律用 **base64 传 JSON**（`mcp_call.py <tool> <b64> --b64`），PowerShell 直接传引号会被吃掉，导致 `Missing required parameter`
- 设备锁屏/熄屏时，**交互类与 Shell 类工具会被拦截**，只放行状态查询、截图、`wake_and_home`

### 48 个工具里真正用得上的

| 用途 | 工具 | 备注 |
|---|---|---|
| 跑 shell | `run_command` | **uid=501(mobile)，不是 root**；`timeout` 上限 30s |
| 抓实时日志 | `get_syslog` | 支持 `process` / `last_seconds`(≤60) / `max_lines`(≤5000)。**这是看 `[JJCheat]` 的唯一手段** |
| 崩溃报告 | `get_crash_logs` / `read_crash_log` | 当前只有 `WiFiLQMMetrics*.ips`，游戏自己的没落盘 |
| 装包 | `install_app` | 只认设备上已存在的 `.deb/.ipa`；装 deb 会重启 SpringBoard |
| 写文件 | `write_file` | 支持二进制走 base64；返回 `resolved_path` 会重写进 jbroot，但 shell 里同样可见 |
| 截屏/OCR | `screenshot` / `ocr_screen` / `describe_screen` | 游戏是 Unity，AX 几乎拿不到节点，**用截图或 OCR** |
| 启动 App | `launch_app` | **设备锁屏时会失败**并报成 `LSApplicationWorkspace … returned NO`，误导性极强；先 `wake_and_home` 再启动 |
| 提权 | `mcp-root` | 只放行包内工具、受限 `chmod`/`launchctl`、`dpkg -i\|-r <绝对路径>`。实测 `id`、`dpkg -i` 都被拒（`Command is not permitted`），**不要指望它** |

### 装包的三条路径（按可靠性排序）

1. **`write_file` 分块 + 设备端拼接（最可靠，实测可用）**
   - 单次请求体上限约 128 KB 原始字节（1.2 MB base64 会 `413 Payload Too Large`）
   - 每块 base64 后写成 `p00000.b64 …`，再 `cat jjpart/p0*.b64 | base64 -di > jjfull.deb`
   - **两个坑**：① 每块独立 base64 会在接缝处补 `=`，必须用 `-d` + `-i` 或逐块解码追加；② `probe.b64` 之类的探测文件会被 `p*.b64` 通配符吃进去，导致拼接结果比正常多出整整一块
   - 校验：`md5sum` 必须与本地一致（本次 `57d57d52da3a58d4c299a34e1d9e9f99`）
   - 然后 `install_app` 指向 `/var/mobile/jjfull.deb`
2. **`/upload_file` + `install_app`（小文件可用）**
   - 必须 **直接 POST 原始二进制** + `Content-Type: application/octet-stream` + `X-Filename`
   - multipart 会 415；50 MB 会被服务端掐断（`RemoteDisconnected`）；2.5 MB 的 dylib 能过
   - 返回的 `/var/mobile/Library/Caches/ios-mcp-uploads/…` 路径**在 shell 里看不到**，但 `install_app` 能用
3. **mini deb（只换 dylib，应急用）**
   - 只打包 `JJCheat.dylib`（xz 后约 417 KB），`Version` 改成 `2.1.67+diag1`
   - **副作用**：`Installed-Size` 与实际不符，dpkg 状态不干净。**仅用于应急，事后要补完整包**

已废弃：本机开 TCP/HTTP 让设备用 `/dev/tcp` 拉 —— 当前不是管理员，防火墙全开加不了入站规则，连不通。

---

## §7 编译坑（本轮实际踩到，务必避免重犯）

| # | 坑 | 报错 | 解法 |
|---|---|---|---|
| 1 | **JJConfig.h 带 BOM** | `identifier contains Unicode character <U+FEFF>` + `#endif without #if` | 用 PowerShell `Set-Content -Encoding utf8` 拉的文件会带 BOM，PS 5.1 还会叠加；用 python 循环剥掉所有 `\xef\xbb\xbf` |
| 2 | **用 `#if` 包住整个 `%hook` 块** | `function '_logos_method$…' has internal linkage but is not defined [-Werror,-Wundefined-internal]` | Logos 的 `%init` 会为 `%hook` 内声明的方法生成注册代码。正确做法：**方法保留，方法体内条件编译** |
| 3 | `%ctor` 里同步遍历全类表装 hook | 启动被拖死，日志只到 `tweak 已加载` | 延迟 1.5s 异步装 + `@try/@catch` |
| 4 | `presentDrawable:` 的 orig 只按 `[self class]` 查 | 查不到 → 不调原实现 → **黑屏**；且该游戏压根不走 present 家族 | 沿父类链按「类名#selector」查表，找不到也要走保底 |
| 5 | 相信 `CARenderServer` 的 `usable=1` | 返回全黑且因「非 nil」永不回退 | 必须验帧内容 |
| 6 | 以为 hook `presentRenderbuffer:` 能抓 Metal 游戏 | 永不触发 | 先判渲染后端（`nextDrawable` 计数） |
| 7 | `data.tar` 出现 `/rootfs/...` | dpkg `Read-only file system` | data 内路径一律相对 jbroot |
| 8 | 在 `tick`（主线程 + 2 Hz）里做重活 | 卡死（1.1.35 就是这么把游戏卡死的） | 重活放后台队列，或加「只做一次」的闸 |

---

## §8 抓帧链路现状（供改 Metal 时参考）

```
JJScreenGrabber.grabRGBAWithWidth:height:
  ① GL-hook（EAGLContext presentRenderbuffer 三变体）—— 对本游戏不触发
  ② Metal（JJMetalGrabber）—— 主路径
  ③ CARenderServer —— roothide 下 usable=1 但全黑，已永久关闭
  ④ CALayer renderInContext —— 基本全黑，偶发抓到一帧
```

Metal 实现（2.0 重构后）：

```c
// %orig 之前：取出上一帧的 surface，交给专用队列读（渲染线程零拷贝）
void JJMetalBeforeNextDrawable(void) {
    gNextDrawableCount++;
    if (!gCaptureEnabled) { JJDropPending(); return; }
    IOSurfaceRef s = JJTakePending(&w, &h);
    if (!s) return;
    if (atomic_compare_exchange_strong(&gReadBusy, &0, 1) && 间隔够) {
        dispatch_async(JJReadQueue(), ^{ JJReadSurface(s, w, h); CFRelease(s); … });
    } else { CFRelease(s); }
}
// %orig 之后：记住本次 drawable 的 surface（CFRetain）
void JJMetalAfterNextDrawable(id drawable) { … JJStorePending(s, …); }
```

实测数据（2.1.63，注入正常时）：`nextDrawable=1351 present=78 captured=178 fail=0 surfaceMiss=0 surfaceMiss=0`、`frame=14267808 B`（=1284×2778×4），画面真实可用。**该游戏不调 `presentDrawable` 家族**（三个变体都 hook 上了，`present` 却停在 78 不动）。

诊断开关：`Core/JJConfig.h` 里 `JJ_DISABLE_METAL_HOOK`，为 1 时 hook 体直接 `return %orig`（不登记 surface、不读 IOSurface）。当前装的 2.1.67 就是这个状态。

---

## §9 下一步建议（按顺序）

1. **恢复注入**（§2）——在此之前一切实验无效
2. 确认日志出现 `[JJCheat] tweak 已加载` 后，**先原样玩一局**，看崩不崩：
   - 崩 → 用 §7-⑧ 的方式继续二分（下一版摘 Pikafish 搜索，再下一版摘 HUD）
   - 不崩 → 把 `JJ_DISABLE_METAL_HOOK` 改回 0，再玩一局：崩 → 锁定 Metal hook，改 ReplayKit 或给读帧加 `IOSurfaceIsInUse` 保护
3. 崩溃若复现，立刻 `get_syslog`（`process: TKLobby`, `last_seconds: 25`）保存发生前的 `[JJCheat]` 上下文，比 `.ips` 有用得多
4. 备选抓帧方案：**ReplayKit**（`RPScreenRecorder -startCaptureWithHandler:` → `CMSampleBuffer` → `CVPixelBuffer`），完全绕开渲染管线，任何后端都能抓；代价是抓帧瞬间要临时隐藏 HUD

---

## §10 已知限制

- 这台 Windows 机器上**没有真机验证能力**，所有本地验证都是结构性的（fat header、slices、符号、ad-hoc 签名、deb ar/control/data 布局）
- 自动标定只做两件事：判断哪方在下（底线颜色）+ 学习背景阈值（`warmThreshold`）；**四个角点仍需手点**
- `JJ_LEARN_MAX_DIFF = 8`，学习校验超过就拒绝，避免把已收敛的锚盘冲成乱码
- 历史遗留：仓库 Releases 里还有 `roothide-build-19/21/22/23/24`，可删（未确认）

---

## §11 更正 §3：14:31 崩溃的真因是引擎线程调用了 `exit()`

> 本节由前一轮会话在拿到 `.ips` 全文后补充。**请连同 §3 一起读，§3 的结论以此节为准。**

### 11.1 先把全部线程打印出来（`.ips` 的 `threads` 数组有 100 条）

`threads` 在 JSON 第 39 行、是一整行，任何按行截断的查看方式都会丢掉后面 99 个线程。用这段脚本还原（`imageIndex` 会被映射成模块名，dylib 内的帧自带符号）：

```bash
node -e "
const fs=require('fs');
const p='<路径>/TKLobby_chess_tuanjie-2026-11-17-143138.ips';
const raw=fs.readFileSync(p,'utf8');const i=raw.indexOf('\n');
const body=JSON.parse(raw.slice(i+1));
const imgs=body.usedImages||[];
body.threads.forEach((t,ix)=>{
  const fr=t.frames||[];
  if(!fr.some(f=>imgs[f.imageIndex]&&imgs[f.imageIndex].name==='JJCheat.dylib')) return;
  console.log('=== thread',ix,t.name||t.queue||'');
  fr.forEach((f,k)=>{const im=imgs[f.imageIndex]||{name:'?'};
    console.log(' #'+k,im.name,f.symbol||('0x'+f.imageOffset.toString(16)));});
});
"
```

### 11.2 thread 91 = 引擎线程，栈是完整带符号的

```
#0  libsystem_kernel   __psynch_cvwait
#1  libsystem_pthread  _pthread_cond_wait
#2  libc++             std::__1::condition_variable::wait(unique_lock<mutex>&)
#3  TKLobby            0xf38e74
#4  TKLobby            0xf37ea4
#5  TKLobby            0xf157cc
#6  TKLobby            0x102a204
#7  libsystem_c        __cxa_finalize_ranges
#8  libsystem_c        exit                                  ← 关键
#9  JJCheat.dylib      Stockfish::Eval::NNUE::Network::verify(function<void(string_view)> const&, EvalFile const&, __fs::filesystem::path) const   (+2456)
#10 JJCheat.dylib      Stockfish::Engine::verify_network() const                     (+224)
#11 JJCheat.dylib      Stockfish::Engine::go(Search::LimitsType&)                    (+40)
#12 JJCheat.dylib      Stockfish::UCIEngine::loop()                                  (+3816)
#13 JJCheat.dylib      jjpika_start                                                  (+1036)
#14 JJCheat.dylib      0x79578
#15 Foundation         __NSThread__start__ → _pthread_start → thread_start
```

读法：帧号越小越内层。`exit` 的返回地址落在 `Network::verify+2456`，即 **`Network::verify` 调用了 `exit`**；`exit` 再跑 `__cxa_finalize_ranges`（全局析构），析构链里某个 `TKLobby` 静态析构函数在等条件变量。

### 11.3 源码依据（Pikafish-2026-09-06，与我们 `engine/build-ios.sh` 的 `PIKA_TAG` 一致）

```cpp
void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);
    verify_network();                       // ← go 的第一件事就是校验网络
    threads.start_thinking(pos, states, limits);
}

void Engine::verify_network() const {
    const auto file = path_from_utf8(std::string(options["EvalFile"]));
    network->verify(onVerifyNetwork, networkFile, file);
    ...
}

void Network::verify(const std::function<void(std::string_view)>& f,
                     const EvalFile& evalFile, fs::path evalfilePath) const {
    if (evalfilePath.empty()) evalfilePath = evalFile.defaultName;
    if (evalFile.current != evalfilePath) {          // ← 网络没加载成功
        if (f) { /* 打印 5 行 ERROR: ... The engine will be terminated now. */ }
        exit(EXIT_FAILURE);                          // ← 唯一出口，直接杀进程
    }
    if (f) { f("NNUE evaluation using ..."); }
}
```

`evalFile.current` 只在 `Network::load_external` 里、且 `load(stream)` 解析成功时才被赋值。所以 **`exit` 只有一种触发条件：NNUE 网络没被成功加载**。

### 11.4 为什么崩的是主线程（解释所有旧现象）

`exit()` 跑在引擎线程上，会执行 atexit + 全部全局析构（**包括 TuanjieFramework 的静态对象**）。此时主线程还活着，正在 `CA::Display::DisplayLink::dispatch_items` 里逐帧渲染。渲染代码踩到已被析构的状态 → 主线程 `EXC_BAD_ACCESS at 0x0`，栈里全是 TuanjieFramework 的帧。这就同时解释了：

- 为什么「HUD 显示 `engine=思考中`，马上闪退」——`思考中` 就是 `go` 发出去的那一刻；
- 为什么 thread 0 的栈里没有任何 JJCheat 帧——真正的元凶在另一个线程；
- 为什么 2.1.62 的进程内 SIGSEGV handler 从来没落盘——它挂在**主线程**上，但 `exit` 走的是正常退出流程，不是我们的 handler 路径；
- 为什么越狱机的 CrashReporter 之前拿不到 `.ips`——这是 `bug_type 309` / `isCorpse:1`，属于「进程自己走了」而不是标准崩溃上报路径。

**结论：`0x0 SIGSEGV` 不是搜索里的空指针，是 `exit()` 拆进程时的二次伤害。** 2.1.61（16MB 栈）、2.1.62（signal handler）、2.1.63（去掉 `setoption Threads/EvalFile`）全都打在症状上。

### 11.5 一个必须接受的重构性事实

`verify_network()` 是 `go` 的必经路径，而它在网络没加载时**直接 `exit`**。这意味着：**2.1.5x 至今没有任何一个版本在真机上真正搜过一步棋**。所有「引擎就绪 / uciok=1 / 引擎自报 Pikafish」都只说明构造与握手成功，和网络加载是两件事；而 `verifyDiff=0 ok=1` 是**棋盘识别**的判据，跟引擎完全无关。之前把这些读成「引擎 OK、建议要出来了」，是本轮最大的误导源。

### 11.6 为什么这条 ERROR 从来没人看见（我们自己的日志把证据吞了）

`ios/tweak/Engine/JJPikafish.m::handleLineOnQueue:` 的判断顺序是：

```objc
if ([line hasPrefix:@"info "]) { self.lastInfo = ...; return; }      // ← 先命中这里
...
if ([line hasPrefix:@"info string"] || ... || [line rangeOfString:@"NNUE"]...) {
    NSLog(@"%@ 引擎输出: %@", kPikaLog, line);                        // ← 永远到不了
}
```

引擎的错误块是以 `info string ERROR: ...` 输出的（`print_info_string` 会统一加 `info string ` 前缀），**全部被第一个分支吃掉并 return**。所以包括 `NNUE evaluation using ...`、`Network replica 1: ...` 在内的所有引擎自述，一次都没进过日志。修法：把 `info string` 判断挪到 `info ` **之前**。

### 11.7 权重本身是好的（已逐项核对）

| 项 | 值 | 判读 |
|---|---|---|
| 包内文件 | `…/JJCheat/Pikafish/pikafish.nnue`，50,308,806 B | 在 |
| sha256 | `071aefc0730e124876a97609a4a75624d62fa5d3155858c9646a1a8272e9e458` | 记录备查 |
| 文件头 | `28 b5 2f fd` | **zstd 帧 magic**，是压缩网络，`read_compressed_nnue` 负责解压 |
| 解压后 | 64,701,992 B | 解压正常完成 |
| 头部 version | `0x6A448AFA` | == 源码 `constexpr u32 Version = 0x6A448AFAu`，**版本匹配** |
| 头部 desc | `Network trained with the https://github.com/official-pikafish/pikafish-nnue-pytorch trainer.` | 官方网络 |
| 远端 `master-net/pikafish.nnue` | `Content-Length: 50308806` | 与我们这份**同尺寸**，即当前官方 master-net |

`read_compressed_nnue` 解压失败会返回空 stream，随后 `read_header` 失败 → `current` 不赋值 → `verify` → `exit`。所以链路上还有三种可能，**现有证据无法区分**：

1. 运行时 `std::ifstream` 打不开（`binaryDirectory` 由 `argv[0].parent_path()` 推出，shim 传的是权重文件本身，理论上对）；
2. `hashValue != Network::hash`（架构哈希不符）；
3. `Detail::read_parameters` / `stream.peek()==eof` 不符（参数布局或尾部多余字节）。

`master-net` 是**滚动发布**（`scripts/net.sh` 直接拉这个 tag），源码却钉在 `Pikafish-2026-09-06`。版本号一致只说明粗粒度格式没变，**不能保证 `Network::hash` 与参数布局一致** —— 这是最可疑的一条。

### 11.8 2.1.68 应该怎么做（建议方案，尚未实施）

我们自己在 CI 里编 Pikafish（`engine/build-ios.sh` 里 `git clone --branch $TAG`），所以可以直接打补丁，**让网络校验失败变成可观测的降级，而不是杀掉宿主 App**：

**① 编译期补丁（新增 `engine/patches/0001-no-exit-on-verify.patch`，在 clone 之后 `git apply`）**

- `src/nnue/network.cpp`：`void verify(...)` → `bool verify(...)`；删掉 `exit(EXIT_FAILURE)`，改为 `return false;`（ERROR 文本照旧先打印）；成功分支 `return true;`
- `src/nnue/network.h`：同步改声明
- `src/engine.cpp`：`void verify_network() const` → `bool`（`verify` 结果 && 各 replica 状态）；`go()` 改成
  ```cpp
  if (!verify_network()) { onVerifyNetwork("JJ: 网络校验失败，本次不搜索"); return; }
  threads.start_thinking(pos, states, limits);
  ```
  **必须提前 return**：网络没加载就 `start_thinking` 会在评估里解引用未初始化的权重。

**② 让失败原因自己说清楚（同一补丁里加 3 条 `info string JJ-NNUE:`）**

- `Network::load_external`：打印 `dir/evalfilePath` 与 `read_compressed_nnue` 返回的字节数（0 = 解压/开文件失败）
- `Network::read_parameters`：`read_header` 失败、`hashValue != Network::hash`（打印**文件哈希与引擎哈希的十六进制**）、参数解析失败、尾部多余字节，四种分别打不同文案
- `verify`：成功后打印 `NNUE evaluation using ...`（原本就有，只是被日志过滤器吞了）

**③ OC 侧**：`handleLineOnQueue:` 调整判断顺序（见 §11.6）；`info string` 一律 `NSLog`，并把最后 5 条引擎输出显示到 HUD，这样失败原因在球上一眼可见。

**④ CI 护栏（防再犯）**：在 `macos-15` runner 上编一个 10 行小程序，`#include "nnue/nnue_architecture.h"` + `nnue_feature_transformer.h`，打印
`NetworkArchitecture::get_hash_value() ^ FeatureTransformer::get_hash_value()`，再读权重文件头的 `u32[1]` 比对，不一致就让构建失败；同时把权重 sha256（`071aefc0…`）钉进 workflow，`master-net` 漂移时立刻报警。

### 11.9 对 §2「tweak 未注入」的一条旁证

这份 14:31 的 `.ips` 里 **`usedImages[21]` 就是我们**：

```
name : JJCheat.dylib
path : /private/var/containers/Bundle/Application/.jbroot-DB287DC7EB4CA44A/usr/lib/TweakInject/JJCheat.dylib
uuid : 11f986fc-38c2-3d81-9c8d-218f15b0b588
```

而且 thread 91 正在跑 `jjpika_start`。所以 **14:31 时注入是成功的、引擎线程是活的**。注入失效发生在 **14:31 之后**（时间上最接近的是 2.1.67 诊断包的重装），§2 的排查范围可以据此收窄。
