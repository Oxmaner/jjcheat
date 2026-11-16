# JJCheat roothide 适配 — 完整交接文档

> 写给接手的 AI / 开发者：这份文档记录了这个项目从「上游原版」到「roothide 上能用 Metal 抓帧」的全部过程、每处改动的理由、踩过的坑、以及当前确切卡点。
> 最后更新：2026-11-16 11:15（构建 run #36，包版本 1.1.36）

---

## 0. 一句话现状

**抓帧已经打通**（Metal 游戏，用 `nextDrawable` + 上一帧 IOSurface 读回，稳定拿到 1284×2778 RGBA 真画面）；
**engine.js 加载已打通**（App 容器优先 + 内嵌兜底）；
**懒加载、版本号递增已完成**；
**卡点只剩「识别精度」**：`verifyDiff=19`，顶行 9 个黑子被判成红子；
**最新包里还带了一个刚修好但未验证的卡死问题**（见 §6）。

---

## 1. 目标与环境

| 项 | 值 |
|---|---|
| 上游项目 | https://github.com/lichengyang51/jjcheat （iOS 越狱 tweak，在 JJ 系象棋 App 上画建议箭头） |
| 工作仓库 | https://github.com/Oxmaner/jjcheat （private） |
| 设备 | iPhone14,3，iOS **15.1**，越狱 **Dopamine-roothide**（procursus(roothide)） |
| 目标 App | bundle id `cn.jj.chinachess`，进程名 **`TKLobby_chess_tuanjie`**（腾讯「中国象棋」） |
| 屏幕 | native **1284×2778**，point **428×926**，@3x |
| 包管理器 | Sileo 2.5.1（**注意：Sileo 的 reinstall 会只卸不装，装机用 `dpkg -i`**） |
| 构建 | GitHub Actions `macos-15` + roothide/theos（云端，不需要本地 Mac） |
| 本地辅助机 | Windows，有 LLVM 23 / iPhoneOS16.5 SDK / 自建 lld（仅用于本地语法编译验证） |

roothide 的关键事实：

- 越狱根（jbroot）每次越狱随机命名：`/var/containers/Bundle/Application/.jbroot-XXXXXXXX/`
- deb 的 `data.tar` 里路径**必须相对 jbroot**，不能带 `/var/jb`，更不能出现 `rootfs`
- `/rootfs` 是 jbroot 内指向 iOS 系统卷的链接，**只读**，往上写会 `Read-only file system`
- 访问 jbroot 内文件要用 `jbroot()`（来自 libroothide），或靠 Mach-O 同目录的 `.jbroot` 符号链接
- App 沙箱对「跨 App 容器目录」读取是拒绝的 → engine.js 放 jbroot 里读不到（这是早期踩的坑）

---

## 2. 仓库文件清单（`ios/tweak/`）

| 文件 | 状态 | 作用 |
|---|---|---|
| `Makefile` | 改 | `THEOS_PACKAGE_SCHEME=roothide`；`ARCHS=arm64 arm64e`；`JJCheat_FILES` 增加 `JJEngineScript.c`、`JJMetalGrabber.m`；`JJCheat_LIBRARIES=roothide` |
| `control` | 改 | Version 由 CI 自动改写为 `1.1.${GITHUB_RUN_NUMBER}` |
| `Tweak.xm` | 改 | ① `EAGLContext` 三个 `presentRenderbuffer` 变体 hook（在 `%orig` **之前**读像素）② `%ctor` 里打 EAGLContext 自检日志 ③ **延迟 1.5s 异步**装 Metal hook（不能在 `%ctor` 同步做） |
| `JJController.m` | **大改** | 懒加载（`start` 只挂球 / 点球 `activate`）；标定按**实际抓帧尺寸**换算；自动微调（纯内存评分，只跑一次） |
| `JJEngineBridge.m` | **大改** | engine.js 候选链（App 容器优先）+ 首次释放到容器 + 内嵌副本兜底 |
| `JJEngineScript.c/.h` | 新增 | `dist/engine.js` 的 C 数组（约 248 KB），编进 dylib |
| `JJMetalGrabber.h/.m` | 新增 | Metal 抓帧：hook `nextDrawable`，延迟一帧读上一帧的 **IOSurface** |
| `JJScreenGrabber.m` | 改 | 抓帧顺序改为 **GL-hook → Metal → CARenderServer → CALayer**；黑帧检测 `JJFrameIsBlack`；来源日志 |
| `JJHUDWindow.m` | 未改 | HUD 窗口、箭头、四点标定 UI |
| `JJConfig.h` | 改 | 增加 `JJ_ENGINE_PATH_MOBILE` 等宏 |
| `JJCheat.plist` | 改 | `Filter.Bundles` 含 `cn.jj.chinachess` 等 5 个 |
| `layout/Library/Application Support/JJCheat/engine.js` | 构建时生成 | 磁盘副本（可选，运行时优先用 App 容器里那份） |
| `layout/DEBIAN/postinst` | 改 | **不再调用 `jjcheat-fix`**（往 .app 塞文件会破坏 App 签名）；只 `killall SpringBoard` |
| `layout/DEBIAN/prerm` | 保留 | 卸载时清理残留的 `.app/engine.js` |
| `layout/usr/bin/jjcheat-fix` | 保留但**不该再跑** | 旧方案（往 .app 复制）的手动脚本 |

仓库根：

| 文件 | 作用 |
|---|---|
| `dist/engine.js` | 象棋引擎 + 视觉识别（约 248 KB JS） |
| `tools/gen-engine-c.py` | 把 `dist/engine.js` 转成 `ios/tweak/JJEngineScript.c`，CI 每次构建自动跑 |
| `.github/workflows/build-roothide-deb.yml` | 唯一流水线：版本号递增 → 生成 engine.js 与内嵌副本 → `make package` → 校验 → 上传 artifact |

---

## 3. 构建与安装

### 云端构建（唯一推荐方式）

```bash
# 触发（需要 token）
curl -X POST -H "Authorization: token <TOKEN>" \
  https://api.github.com/repos/Oxmaner/jjcheat/actions/workflows/build-roothide-deb.yml/dispatches \
  -d '{"ref":"main"}'
```

产出：artifact **`JJCheat-roothide-deb`**（内含 `com.fujiang.jjcheat_<ver>_iphoneos-arm64e.deb`）。
流水线**不再发 Release**（已删 `softprops/action-gh-release` 步骤）。

下载 artifact：

```powershell
$h = @{ Authorization = "token <TOKEN>"; 'User-Agent'='dsh'; Accept='application/vnd.github+json' }
$a = Invoke-RestMethod "https://api.github.com/repos/Oxmaner/jjcheat/actions/runs/<RUN_ID>/artifacts" -Headers $h
$deb = $a.artifacts | ? { $_.name -eq 'JJCheat-roothide-deb' }
Invoke-WebRequest $deb.archive_download_url -Headers $h -OutFile deb.zip
```

流水线各步（共 11 步，约 4–6 分钟）：取代码 → 打印工具链 → 装 roothide/theos → 装 ldid/dpkg → 补 iPhoneOS16.5 SDK → **版本号递增** → 打包 engine.js + 生成内嵌副本 → `make package` → 校验产物（含 `_JJEngineScript` 符号、libroothide 依赖、install_name）→ 上传 artifact ×2。

### 本地语法验证（Windows，可选）

```powershell
$CLANG='C:\Program Files\LLVM\bin\clang.exe'
$SDK='F:\MacLin\Documents\theos-sdks\iPhoneOS16.5.sdk'
$SHIM='F:\MacLin\Documents\jjcheat-build\shim'   # JavaScriptCore 头 + IOSurface umbrella
& $CLANG -target arm64-apple-ios14.0 -isysroot $SDK -fobjc-arc -O1 -c -I. -I $SHIM -Wno-everything JJController.m -o $env:TEMP\a.o
```

注意：`-I $SHIM` 必须写成两个数组元素，写成 `-I$SHIM` 在 PowerShell 里会不生效。

### 设备安装

```sh
dpkg -i /var/root/com.fujiang.jjcheat_1.1.36_iphoneos-arm64e.deb
killall -9 TKLobby_chess_tuanjie     # 必须真退出，dylib 只在进程启动时加载
```

**不要用 Sileo 的 reinstall**：实测它执行 `apt-get install --reinstall --no-download`，结果是「卸载旧版但没装新版」。

---

## 4. 已完成的工作（按主题）

### 4.1 注入与 roothide 打包

- Theos 用 **roothide/theos**，`THEOS_PACKAGE_SCHEME=roothide`：dylib 的 install_name 变成 `@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/JJCheat.dylib`，依赖 `@loader_path/.jbroot/usr/lib/libroothide.dylib`，包 `Architecture: iphoneos-arm64e`
- 注入本身一直没问题（日志有 `tweak 已加载`）

### 4.2 engine.js 加载（已解决 ✅）

**问题**：roothide 下原代码的候选只有 `/Library/...`（rootful）和 `/var/jb/...`（rootless），全落空；
即便加了 `jbroot()`，**App 沙箱也不允许读跨 App 容器目录**（jbroot 在 `/var/containers/Bundle/Application/` 下）。

**最终方案（App 容器优先 + 内嵌兜底）**：

```
① <App沙箱>/Library/Application Support/JJCheat/engine.js   ← 主路径（App 自己的容器，永远可读写）
② jbroot("/Library/Application Support/JJCheat/engine.js")
③ /var/jb/Library/...
④ /Library/...
⑤ <App>.app/engine.js（老方案残留）
⑥ dylib 内嵌副本（JJEngineScript.c）
```

首次载入时若 ① 不存在，就从内嵌副本写一份进去 → 之后一直读文件，**可以热改**（Filza 改容器里的 engine.js，重启 App 生效）。

验证日志：

```
[JJCheat] engine.js 命中: /var/mobile/Containers/Data/Application/141CCCF6-.../Library/Application Support/JJCheat/engine.js
[JJCheat] engine.js 加载成功
```

### 4.3 抓帧链路的四次演进

| 阶段 | 做法 | 结果 |
|---|---|---|
| ① `CARenderServer` | `CARenderServerRenderDisplay` 渲染到 IOSurface | **usable=1 但整帧全黑**（沙箱下静默失败） |
| ② `GL-hook` | hook `EAGLContext presentRenderbuffer:` | **一次都没触发**；补了 `atTime:` / `afterMinimumDuration:` 三个变体依然不触发 |
| ③ `CALayer` | `renderInContext` | 对 GL/Metal 游戏**基本全黑**，偶尔抓到一帧 HUD 层 |
| ④ **Metal（现方案）** | hook `nextDrawable`，**延迟一帧**读上一帧的 IOSurface | ✅ **稳定**，`captured` 持续增长，`frame=14267808 B` |

关键结论：**这个游戏是 Metal 渲染，且不调用 `presentDrawable` 家族**（三个变体都 hook 上了，`present` 计数冻在 65–78 不动，而 `nextDrawable` 涨到几千）。

### 4.4 Metal 抓帧的实现细节（`JJMetalGrabber.m`）

```c
static id JJNextDrawable(id self, SEL _cmd) {
    if (gPendingSurface) {                        /* 先读上一帧（已渲染完，还没被复用） */
        if ((gNextDrawableCount % 8) == 0) JJReadSurface(gPendingSurface, gPendingW, gPendingH);
        CFRelease(gPendingSurface); gPendingSurface = NULL;
    }
    id d = orig(self, _cmd);
    if (d) {
        IOSurfaceRef s = JJDrawableSurface(d);     /* 从 drawable / texture 取 iosurface（私有属性） */
        if (s) { gPendingSurface = CFRetain(s); gPendingW = ...; gPendingH = ...; }
    }
    return d;
}
```

- `JJReadSurface`：`IOSurfaceLock` → 逐行 memcpy（处理 bytesPerRow 不等于 w*4 的情况）→ **BGRA→RGBA** → 写进 `gFrame`
- 每 8 帧读一次（`nextDrawable` 60fps → 7.5fps 抓帧）
- `JJMetalFrameCopy()` 供 `JJScreenGrabber` 取帧，1.5 秒过期
- `presentDrawable` 家族仍保留 hook（`JJMetalCapture` + blit），但本游戏走不到，只作兼容

### 4.5 懒加载（用户要求）

`JJController.start` 只做 `setupBall`：

```objc
- (void)start {
    NSLog(@"[JJCheat] 待机：只挂悬浮球，不抓帧（进对局后点球开始）");
    self.activated = NO;
    self.state = JJCtrlStateIdle;
    [self setupBall];
    [self.ballWindow setActive:NO];
    /* 刻意不做：loadEngine / grabber.start / HUD attach / startTimer */
}
```

点球 → `activate`：`grabber.start` → `loadEngine` → HUD attach → 有标定进 `WaitingBoard` 自动学，没标定进四点标定。
球的视觉：未激活半透明 + 「点我」；激活后实心「象棋」。已激活后再点 = 切换 HUD 显隐。

目的：避免在登录页/大厅/结算页误学棋盘。

### 4.6 版本号自动递增（用户要求）

workflow 里编译前改写 `control`：

```bash
VER="1.1.${GITHUB_RUN_NUMBER}"
/usr/bin/sed -i '' -E "s/^Version: .*/Version: ${VER}/" ios/tweak/control
```

所以版本 = `1.1.<构建序号>`，当前 **1.1.36**。

---

## 5. 当前卡点：识别精度

### 现象（1.1.34 实测日志）

```
Metal 状态 nextDrawable=1351 present=78 captured=178 fail=0 surfaceMiss=0 origMissing=0 (frame=14267808 B)
抓帧来源=Metal 1284x2778 中心像素=(185,185,166)
抓帧 1284x2778（point 428x926 / native 1284x2778）→ 标定缩放 3.000/3.000
棋盘学习完成 {
    bottomBlack = 0; bottomRed = 9;
    topBlack = 0;   topRed = 9;
    diffNormal = 19; diffFlipped = -1;
    flipped = 0;     mySide = red;
    learned = 1;     ok = 0;   verifyDiff = 19;
    templateCount = 86; warmThreshold = 0.1587;
}
采样点颜色(RGB) w=1284 h=2778
  #0(99,797)=(237,193,136)     ← 木色（左上角车位置，采到背景）
  #4(647,796)=(14,13,13)       ← 黑色（顶行第 5 列，采到黑子）
  #8(1194,794)=(56,52,51)      ← 深灰（顶行右角，采到黑子）
  #40(645,1322)=(184,187,164)
  #81(95,1967)=(156,34,35)     ← 红（底行左角，红车 ✓）
  #85(644,1981)=(118,14,17)    ← 深红（底行 ✓）
  #89(1193,1994)=(251,211,150) ← 木色（底行右角，采到背景）
  #13(646,927)=(170,172,150)
  #76(644,1849)=(98,108,90)
```

### 判读

- **抓帧是真的**：底行 `#81/#85` 红子、顶行 `#4/#8` 黑子都在，颜色正常
- **执红、不翻转正确**（`flipped=0, mySide=red`，底行是红子）
- **错在两处**：
  1. **顶行 9 个黑子被判成红子**（`topRed=9, topBlack=0`）→ `engine.js` 的 `classifyByColor` 对这套皮肤的判据不准（黑子可能是深灰/深褐，被判成暖色）
  2. **四角采到背景**（`#0`、`#89` 是木色）→ 采样网格与棋盘有约 **0.2 格（26px）** 偏移

`verifyDiff=19` ≈ 顶行 9 个错 + 其他位置约 10 个错。

### 已经做了但未验证的修复

`JJController.m` 里新增的自动微调（见 §6 的说明），目标是解决「0.2 格偏移」。**若微调后 verifyDiff 仍 > 8，就说明主因是颜色判据，需要动 `dist/engine.js` 的 `recognizer.classifyByColor`**（搜 `redTh` / `darkTh` / `warmThreshold`）。

---

## 6. 刚修好但未验证：游戏卡死（重要）

### 现象

装上 1.1.35 后**进游戏直接卡死**。

### 根因（已定位）

`learnWithAutoRefine` 第一版是这样写的：对 74 组候选偏移，每组都调一次
`[[JJEngineBridge shared] learnBoardWithPixels:...]`，而这个方法是 **`dispatch_sync` 到引擎队列**、由主线程上的 `NSTimer tick`（每 125ms）调用的。于是：

- 单轮 74 次同步阻塞 → 主线程卡 1–3 秒
- 学习不成功时 `learnedBoard` 仍是 NO → **下一个 tick 又来一轮 74 次** → 主线程彻底堵死 → 看门狗杀进程/界面冻结

### 修复（1.1.36，已提交、**未在设备验证**）

1. 把评分改成**纯内存计算** `JJOffsetScore()`：双线性插值取 90 点颜色，与「中宫附近 4 点」的背景色比差，算「32 个开局有子位置的平均差异 − 58 个空位的平均差异」。不调引擎、不跨线程，74 组候选是毫秒级。
2. 加 `refineDone` 闸：**只搜一次**，之后固定用 `refineDx/refineDy`。
3. 重标定时（`handleCalibration`）复位 `refineDone/Dx/Dy`。

预期日志：

```
[JJCheat] 标定微调：dx=-6 dy=26 score=12.3
[JJCheat] 棋盘学习完成 { verifyDiff = ... }
```

**验证要点**：装 1.1.36 后游戏不能卡；看 `标定微调` 的 dx/dy 是否贴边（±30）、`verifyDiff` 是否下降。

---

## 7. 踩过的坑（务必不要重犯）

| # | 坑 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | `Tweak.xm` 经 Logos 预处理按 **ObjC++** 编译 | 头文件里的 C 函数声明找不到符号（`Undefined symbols __Z19JJMetalInstallHooksv`） | 头文件里包 `extern "C" { }` |
| 2 | 在 `%ctor` 里同步遍历全类表 hook `presentDrawable:` | App 启动被拖死，日志只到 `tweak 已加载` | 延迟 1.5s 异步装 + 全程 `@try/@catch` |
| 3 | `presentDrawable:` hook 只按 `[self class]` 查 orig | 子类查不到 → 原 present 不调用 → **黑屏** | 沿父类链按 `类名#selector` 查 hook 表；找不到也要走保底 |
| 4 | 相信 `CARenderServer` 的 `usable=1` | 返回全黑，且因为「非 nil」永远不回退 | 必须**验帧内容**（`JJFrameIsBlack` 抽样 48 点） |
| 5 | 以为 hook `presentRenderbuffer:` 就能抓 GL | 对 Metal 游戏**永不触发** | 先判渲染后端（`nextDrawable` 计数） |
| 6 | 在 `tick`（主线程 + 125ms）里做重活 | 卡死 | 重活放一次性的启动阶段或后台队列 |
| 7 | deb 的 `data.tar` 里写 `/rootfs/...` | dpkg 报 `Read-only file system`，包装一半 | data 内路径一律相对 jbroot；`build_deb.py` 里已有断言 |
| 8 | 往 `JJ象棋.app` 里塞 `engine.js`（`jjcheat-fix` 的做法） | 破坏 App 代码签名，iOS 15 可能启动被拒 | 用 App 容器 + 内嵌副本，别碰 .app |
| 9 | 用 Sileo 的 reinstall 装本地 deb | 只卸不装 | `dpkg -i` |
| 10 | 以为标定精度够（手点四点） | 偏 1/5 格就整盘采样错位 | 用自动微调（纯内存评分） |
| 11 | PowerShell 里写 `-I$SHIM` | clang 收不到 include 路径 | `-I $SHIM`（数组两个元素） |

---

## 8. 日志判读手册

`Console.app` / iMazing Console / 3uTools 实时日志，过滤 `[JJCheat]`。

正常顺序：

```
[JJCheat] tweak 已加载 (pid=…)
[JJCheat] EAGLContext=0x… presentRenderbuffer:=有
[JJCheat] Metal hook: CAMetalLayer=有 nextDrawable=已 hook present 家族=1/1/1（抓帧走 nextDrawable 的 IOSurface）
[JJCheat] CAMetalLayer nextDrawable 命中 → 这游戏是 Metal 渲染
[JJCheat] 待机：只挂悬浮球，不抓帧（进对局后点球开始）
        ← 用户点球
[JJCheat] 用户点球 → 开始抓帧与识别
[JJCheat] 启动
[JJCheat] CARenderServer: render=… port=… usable=1
[JJCheat] engine.js 命中: /var/mobile/Containers/Data/Application/<UUID>/Library/Application Support/JJCheat/engine.js
[JJCheat] engine.js 加载成功
[JJCheat] Metal 状态 nextDrawable=… present=… captured=… fail=0 surfaceMiss=0 origMissing=0 (frame=14267808 B)
[JJCheat] 抓帧来源=Metal 1284x2778 中心像素=(R,G,B)
[JJCheat] 抓帧 1284x2778（point 428x926 / native 1284x2778）→ 标定缩放 3.000/3.000
[JJCheat] 标定微调：dx=… dy=… score=…
[JJCheat] 棋盘学习完成 { … verifyDiff=… }
```

| 现象 | 含义 |
|---|---|
| 只有 `tweak 已加载` | `%ctor` 里崩了（典型：同步装了重 hook） |
| `present 家族=0/0/0` | present hook 没装上（`class_copyMethodList` 没扫到），但不影响现在的抓帧 |
| `captured` 不涨、`surfaceMiss` 涨 | drawable 上没有 `iosurface` 属性 |
| `frame=0 B` | 帧过期（1.5s）或没抓到 |
| `抓帧来源=CALayer` | Metal 和 GL 都没拿到 |
| `采样点颜色` 全 `(0,0,0)` | 抓的是黑帧 |
| `verifyDiff` 卡在 19 左右 + `topRed=9 topBlack=0` | 颜色判据把黑子判成红子（当前卡点） |

---

## 9. 下一步建议（按优先级）

### A. 先验证 1.1.36（必做）

```sh
dpkg -i /var/root/com.fujiang.jjcheat_1.1.36_iphoneos-arm64e.deb
killall -9 TKLobby_chess_tuanjie
```

1. 游戏**不能卡**（这是 1.1.36 的唯一目的）
2. 看 `标定微调：dx=… dy=… score=…`
3. 看 `verifyDiff` 是否从 19 降下来

### B. 若 `verifyDiff` 仍 > 8 → 改颜色判据

`dist/engine.js` 里搜 `classifyByColor`，看它对「红子 / 黑子 / 空」的判据（涉及 `redTh`、`darkTh`、`warmThreshold`）。
当前证据：

- 顶行黑子采样值 `(14,13,13)`、`(56,52,51)` —— **深灰/近黑**
- 底行红子 `(156,34,35)`、`(118,14,17)` —— **红**
- 背景木色 `(237,193,136)`、`(251,211,150)`

如果 `classifyByColor` 用「暖/冷」区分红黑，深灰会被判成中性甚至暖色 → 需要改成**用 R 通道显著高于 G/B 判红、三者都很暗判黑、亮度接近木色判空**。

### C. 若微调贴边（dx/dy = ±30）→ 扩大搜索范围

`learnWithAutoRefine` 里把 `±30` 改 `±60`，步长保持 10；细搜范围同步放大。纯内存计算，成本可忽略。

### D. 更强的自动标定（可选，一次性投入）

现在的四点标定靠手点。可以改成**棋盘线检测**：对抓到的帧做边缘检测（或按木色阈值二值化），找 9 条竖线 / 10 条横线的交点，直接算出四角。工程量比现在大，但一劳永逸，且不受皮肤影响（棋盘线颜色总是深色）。

### E. 如果 Metal 路出现不稳定

回退方案是 **ReplayKit**：`RPScreenRecorder -startCaptureWithHandler:` 拿 `CMSampleBuffer` → `CVPixelBuffer`，官方 API，任何渲染后端都能抓。
代价：抓帧瞬间要把 HUD 临时 `hidden = YES`（否则箭头被录进去干扰识别），会有 1–2 帧闪烁。
（`JJMetalGrabber` 的接口 `JJMetalFrameCopy(w,h)` 可以直接换成 ReplayKit 的实现，`JJScreenGrabber` 不用动。）

---

## 10. 已生成的包（本地 `F:\MacLin\Documents\jjcheat-local\`）

| 文件 | 说明 |
|---|---|
| `com.fujiang.jjcheat_1.1.36_iphoneos-arm64e.deb` | **最新**，118,028 B，含卡死修复（未验证） |
| `com.fujiang.jjcheat_1.1.35_...` | 自动微调生效但会卡死（**别用**） |
| `com.fujiang.jjcheat_1.1.34_...` | 微调没生效（patch 打错位置） |
| `com.fujiang.jjcheat_1.1.33_...` | 首次 Metal IOSurface 抓帧成功（`captured` 稳定增长） |

更早的 1.0.2 / 1.1.32 等都已在 `jjcheat-local` 里被覆盖，仓库的 Release 里还残留 `roothide-build-19/21/22/23/24`（可删）。

---

## 11. 快速索引：改哪里解决什么

| 想改 | 文件 | 关键符号 |
|---|---|---|
| 抓帧来源 / 顺序 | `JJScreenGrabber.m` | `grabRGBAWithWidth:height:` |
| Metal 读回 | `JJMetalGrabber.m` | `JJNextDrawable` / `JJReadSurface` / `JJMetalFrameCopy` |
| engine.js 路径 | `JJEngineBridge.m` | `locateEngineScript` / `seedEngineIntoContainer` / `JJContainerEnginePath()` |
| 懒加载 / 标定 / 微调 | `JJController.m` | `start` / `activate` / `handleCalibration:` / `applyCornersForFrameWidth:` / `learnWithAutoRefine:` / `JJOffsetScore` |
| 识别算法 | `dist/engine.js`（源在 `src/vision/*.js`，`node tools/bundle.js` 重新打包） | `recognizer.classifyByColor` / `learnBoard` / `process` |
| 注入入口 | `Tweak.xm` | `%ctor` / `%hook EAGLContext` |
| 打包路径 / 版本 | `build_deb.py`（若用自建流程）/ `ios/tweak/control` + workflow | `Version:` |
