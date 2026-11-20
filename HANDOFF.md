# JJCheat 交接文档

> 最后更新：2026-11-20　当前版本：**2.0.0r18**（已构建、已装机验证过一次）
> 读者：接手的 AI / 开发者。本文档目标是让你**不读全部代码也能安全改动**。

---

## 0. 一句话说清这是什么

iOS 越狱插件（roothide 方案）。注入「JJ 象棋」（`cn.jj.chinachess` / 进程名 `TKLobby_chess_tuanjie`），做三件事：

1. 从 Metal 渲染帧里**读出棋盘**（90 格模板匹配，无机器学习）
2. 把局面喂给**同进程的 Pikafish**（中国象棋 NNUE 引擎）算一步
3. 用**浮窗 + 箭头**标出建议着法

不支持模拟器、不支持未越狱设备、**只支持游戏原始皮肤**。

---

## 1. 五分钟上手

### 1.1 本地自检（改完代码必须先跑）

```bash
cd jjcheat-patch

# ① JS 主逻辑打包（会生成 dist/engine.js）
node tools/bundle.js
# 正常输出：打包完成 / 模块数 7 / 体积 xxx KB

# ② 回归测试（10 组、158 条断言）
node tools/regression.js
# 正常输出：全部通过 OK  engine.js = xxx 字节

# ③ 原生侧语法检查（15 个目标）
export PATH="/c/Program Files/LLVM/bin:$PATH"
SDK="/f/MacLin/Documents/theos-sdks/iPhoneOS16.5.sdk"
bash tools/check-syntax.sh
# 正常输出：通过 15 个，失败 0 个
```

**三个都绿才算改完。** `check-syntax.sh` 还包含「菜单 action 与 switch 一致性」检查——加菜单项必须同步它。

### 1.2 出包（不能本地编译 deb，只能走 CI）

本地没有 Theos 环境，**必须推 GitHub 触发 Actions**：

```bash
# 用 patch_repo.ps1 里的 token；仓库 Oxmaner/jjcheat
# ① 用 Git Trees API 提交（base_tree = 当前 head 的 tree，只放改动的文件）
# ② POST /actions/workflows/build-roothide-deb.yml/dispatches  body: {"ref":"main"}
# ③ 轮询 /actions/runs/{id} 直到 conclusion=success
# ④ 产物在 run 页面底部 Artifacts：JJCheat-roothide-deb（约 48.5 MB）
```

**推送铁律**：推完必须用 `GET /contents/<path>?ref=main` 把文件拉回来比对 md5。
r15 那次构建失败就是因为漏推了 `JJVisionBridge.m`（只推了 .h，报「方法未实现」）。

### 1.3 装机

- 用户自己从 GitHub Actions 下载 deb 安装（他手上有 MCP 时也可以直接推）
- 包内 48MB 里 **47MB 是 NNUE 权重**（`pikafish.nnue`，50308806 字节），只有 dylib（约 2MB）和 engine.js（约 350KB）会变
- 装机后看日志确认 `engine.js 字节数: xxxxxx` 与本地 `dist/engine.js` 一致

---

## 2. 目录与文件职责

```
jjcheat-patch/
├── ios/tweak/                  原生插件（Theos，约 7.9k 行 .m+.h）
│   ├── Tweak.x                 入口：Logos 钩子，冷启动注入
│   ├── control                 包版本（改版本改这里 + JJConfig.h 两处）
│   ├── Makefile                roothide 打包配置
│   ├── Core/
│   │   ├── JJConfig.h          ★ 所有原生侧常量（版本号也在这）
│   │   ├── JJCopy.h/.m         HUD/提示文案集中处
│   ├── Capture/
│   │   ├── JJMetalGrabber.m    ★ Metal 钩子：摘要轮询 + 真读帧 + BGRA→RGBA
│   │   ├── JJScreenGrabber.m   兜底抓帧（Metal 不可用时）
│   ├── Vision/
│   │   ├── JJVisionBridge.m    ★ OC ↔ JS 桥（JavaScriptCore）
│   │   ├── JJEngineScript.c    engine.js 的字节数组（由 CI 生成）
│   ├── Engine/
│   │   ├── JJPikafish.m        ★ 引擎调度：UCI 收发、看门狗、保活
│   │   ├── JJPikafishInstaller.m  权重查找与安装（jbroot 多路径）
│   │   ├── JJEngineOptions.m   参数持久化（NSUserDefaults）
│   │   ├── JJMoveCodec.m       UCCI ↔ 中文记谱
│   ├── Game/
│   │   ├── JJGameController.m  ★★ 主控制器（1955 行，最难改的文件）
│   │   ├── JJCalibrator.m      四角预设 + 学习 + 采纳画面反解的四角
│   ├── UI/
│   │   ├── JJHUDWindow.m       浮窗（纯显示层，hitTest 恒返回 nil）
│   │   ├── JJBallWindow.m      悬浮球 + 菜单 + 二级面板
│   │   ├── JJMenuSheet.m       二级面板控件（步进器/开关/动作行）
├── src/                        JS 源码（约 4.2k 行，模块化）
│   ├── cst/constants.js        sq 编码、走法编码 C.mv
│   ├── cst/position.js         走法生成/合法性（引擎级）
│   ├── cst/notation.js         FEN 解析
│   ├── vision/recognizer.js    ★★ 识别核心（2700 行）：模板学习、90 格分类
│   ├── vision/templates.js     模板存取
│   ├── vision/tracker.js       朝向判定
│   ├── app/board.js            ★ 规则校验 + analyzeStepDiff
├── tools/
│   ├── bundle.js               ★★ 构建脚本 + 主流程（2523 行，含 JJEngine 对象）
│   ├── regression.js           ★★ 回归测试（1116 行）
│   ├── check-syntax.sh         原生语法 + 菜单一致性检查
├── engine/
│   ├── patch-engine.py         ★ Pikafish 源码打补丁（4 处，见 §7.3）
├── dist/engine.js              构建产物（不要手改）
└── .github/workflows/build-roothide-deb.yml   CI
```

**代码规模**：原生 7.9k 行（.m+.h）/ JS 4.2k 行（src）+ `bundle.js` 2523 行（构建脚本兼主流程）+ `regression.js` 1116 行（测试）。

---

## 3. 一帧的完整生命周期

```
① Metal 钩子 presentDrawable
   ├─ 摘要轮询：每 0.15s（等对方时 0.35s）读 90 个角点比对
   └─ 摘要变了才拷 14MB（低优先级队列，不在渲染线程）
        ↓
② JJGameController.tick（250ms 一次）
   ├─ 帧指纹没变 → 整帧跳过（静态零开销）
   ├─ 没学过棋盘 → learnAndRefine（异步，主线程不等）
   └─ 学过 → processPixels（异步）
        ↓
③ engine.js JJEngine.process
   ├─ 90 格模板匹配 → codes[90]（0=空,1~7红,8~14黑）
   ├─ 锚盘比对 → stepInfo{changed, move, noise}
   ├─ 白点白圈（标记法）→ 走法
   ├─ 锚盘推进 / 轮次翻面
   └─ 输出：fen / needSearch / searchFen / 各类诊断
        ↓
④ handleProcessResult
   ├─ 清 HUD 旧箭头、显示文案
   ├─ needSearch → JJPikafish analyzeFen:movetime:
   └─ 写 moves.log / engine.log
        ↓
⑤ 引擎回调 → engineDisplayDictFrom → HUD 画箭头
```

---

## 4. 走子确认：白点白圈（**本项目最核心的机制**）

### 4.1 游戏给的标记

JJ 象棋在**上一步**上画两个东西：

| 标记 | 位置 | 外观 |
|---|---|---|
| **白点** | 起点格（此时已空）中心 | 直径约 12pt 的实心小圆点 |
| **白圈** | 落点格（有子）外围 | 外径约 58pt（半径 29pt）的环，环宽 4~6pt |

**红黑两方画得完全一样**，判哪一方只能看落点那颗子的字色。

### 4.2 判据（真机实测值，2026-11-20 用户手动走 10 轮验证 10/10）

```js
K.RING_MIN = 0.06   // 环带与环外的「中性色差」，有圈 0.084、普通格 ≤0.039
K.DOT_MIN  = 10     // 中心 9×9 采样窗口的白像素个数，起点 53、普通空位 0
```

**关键约束**（都是真机踩出来的）：

- 白点只在「**锚盘有子 且 当前识别为空**」的格里找（那才是棋子离开的地方）
- 一圈多点时取**分数最高**的白点
- 一圈多圈时（走子快，旧圈没淡出）**按分数从高到低遍历，取第一个没在去重窗口内的**

### 4.3 三条提交路径（优先级从高到低）

| 路径 | 条件 | 记录 src |
|---|---|---|
| **① 白点+白圈齐全** | 两点都有 + 规则合法 + 帧洁净 | `marker` |
| **② 只有白圈** | 在锚盘里反查「唯一能走到该格」的起点 | `marker-ring` |
| **③ 差分兜底** | 前两条都不成 + 稳定 3 帧 + 超 1.5s + **零噪声** | `diff` |

**③ 的门槛极高**，因为 r17 之前吃过血亏：标记一丢，差分连着提交 10 步带噪声的帧，盘面从 diff=3 漂到 32，整盘崩掉。现在要求 `noise.length === 0`（变动恰好一进一出两格）。

### 4.4 帧洁净度闸门（r17 新增）

```js
K.MAX_MOVE_CHANGE = 6   // 一手真棋最多动 2 格，加 4 格抖动容限
```

- 标记齐全但整帧与锚盘差 > 6 格 → **整帧作废**
- 连续 2 秒被挡 → 放宽到 12 格（否则差分要求 ≤3 格，两条路都不通会死锁）

---

## 5. 轮次判定

```js
lastMoverSide   // 'red' | 'black' | null，最近一次「确认」，是唯一真源
```

- 每提交一手：`lastMoverSide = 走这手的颜色`
- 显示轮次时：`turn = (lastMoverSide === mySide) ? 对方 : 我方`
- **不要用 `movePly % 2` 推轮次** —— 漏识别一步就永久卡死（2.1.84 之前的坑）

**对称轮次翻转（2.1.91）**：白点白圈都读不到时，只要「盘面变了」且连续 2 帧，就翻轮次。
**r17 起：只翻轮次，绝不重锚锚盘。** 原来这里会「连续两帧一致就把当前帧当新锚盘」，而噪声帧偏得很稳定，导致盘面一路漂。

---

## 6. 锚盘（anchor）：唯一真相

```js
session.anchorCodes   // 90 格兵种编码，程序认定的「当前局面」
session.anchorFen     // 上面的 FEN 形式
```

**铁律**：只有走子确认（①/②/③ 任一）通过后才推进锚盘，且只改 `from`/`to` 两格（`anchor.slice()` 后改两点）。

锚盘的建立与自愈：

| 场景 | 触发 | 条件 |
|---|---|---|
| 无锚盘 | `if (!anchor)` | **连续 2 帧**识别盘面完全一致 + `codesLegal` + `codesPositionPlausible` |
| 朝向变了 | `anchorFlipped !== flipped` | 当前盘面合法 |
| 中等漂移 | `changed` 在 4~9 格 | 连续 **3 帧**同一盘面 |
| 换局/中途进对局 | `changed >= 8` | 连续 3 帧（相邻差 **≤2 格**）+ 合法 |

> 漂移自愈只接管 4~9 格，≥8 格交给 reseat，两者不能抢（回归 C2 守着这条）。

---

## 7. 引擎集成（Pikafish）

### 7.1 为什么是同进程静态库

iOS 沙盒**禁止 exec**，越狱环境也绕不过签名。所以 Pikafish 编成 `libpikafish.a`（arm64 + arm64e）链进 `JJCheat.dylib`，通过 C 接口 `jjpika_start/send/recv/stop/running` 收发 UCI。

**代价**：引擎里任何 `exit()` 会连带杀掉 JJ 象棋。

### 7.2 UCI 时序（**必须严格遵守**）

```
Ready      --position/--go-->  Searching
Searching  --stop(pending)-->  ← 新请求只进 pendingFen，不发 position
Searching  --bestmove-->       Ready → 先补发 ucinewgame（若有），再 flushPending
```

- 搜索中绝不发新 `position`（有状态守卫 + 串行队列 + `engineGen` 代号三道保险）
- 搜索中收到「新局」只设 `pendingNewGame=YES` 并发 `stop`，等 `bestmove` 回来再发 `ucinewgame`
- **关插件只 stop 搜索、保活引擎**（`stopSearch`），并清掉 `pendingFen/pendingCb`，否则引擎会在关掉之后又搜一次

### 7.3 引擎源码补丁（`engine/patch-engine.py`，4 处）

| # | 位置 | 改什么 | 为什么 |
|---|---|---|---|
| 1 | `network.h/.cpp` | `verify()` 改 bool | 失败要能返回，不能 `exit` |
| 2 | `engine.cpp go()` | 网络没就绪 → 只跳过搜索 | 原为 `exit(EXIT_FAILURE)` |
| 2b | `engine.cpp go()` | **校验结果缓存**（`static jjNetVerified`） | 原来每步重读 61MB 权重，每步卡 0.3~0.8s |
| 3 | `uci.cpp` | `position` 失败不 `exit` | 非法 FEN 不能杀 App |
| 4 | `tt.cpp` | 分配失败不 `exit` | 内存紧张时不能杀 App |

**CI 会缓存 `engine/.build/src`**，里面已是「上一版补丁」形态，所以 `patch()` 找不到原文会失败。解法：`soft_replace()` 做「旧版补丁 → 新版」迁移。**每次改引擎补丁，必须把上一版文本登记成 V1。**

---

## 8. 菜单与参数面板

菜单 9 项（`JJMenuAction` 枚举 → switch 必须一一对应，`check-syntax.sh` 会校验）：

| action | 作用 |
|---|---|
| `JJMenuActionPlugin` | 开关插件 |
| `JJMenuActionBoardScheme` | 棋盘预设：人机 / 排位（r10 起两套数值相同） |
| `JJMenuActionResync` | **重新同步**（清锚盘 + 清结论 + 清指纹，HUD 立即抹箭头） |
| `JJMenuActionClearLogs` | 点「版本」号触发：清 `moves-*.log` / `engine-*.log` |
| `JJMenuActionManualCalibrate` | 手动四点标定（保留但 UI 已删，正常不用） |
| `JJMenuActionHUD` | HUD 显示开关 |
| `JJMenuActionResetBoard` | 重置到开局 |
| `JJMenuActionThink` | 思考面板（**跟随「按时间/按深度」模式**） |
| `JJMenuActionEngineOptions` | 引擎参数（思考方式 / 资源 / 其它三组） |
| `JJMenuActionEngineStatus` | 引擎状态 |

**思考面板必须跟随模式**：`o.thinkDepth > 0` 时调层数（预设 10/14/18/22），否则调毫秒（350/650/1000/2000）。r15 修过一次——原来写死只改 ms。

**参数是否真的下发**：日志搜 `搜索方式`，会打 `go depth N（按深度）` 或 `go movetime N ms（按时间）`。

---

## 9. 诊断日志速查（**排障第一入口**）

### 9.1 心跳（每 30 秒一行，最有用）

```
盘面心跳 ply=12 turn=w wait=0 newGame=0 engine=引擎就绪 rejected=1 reseat=0
        skip=none ring=0.095/0 dot=53 mk=ok diffReject=4 usedDiff=1
```

| 字段 | 含义 | 正常值 | 异常含义 |
|---|---|---|---|
| `ply` | 已确认步数 | 单调 +1 | 跳 2 → 一手被算两次 |
| `wait` | 是否等对方 | 与 `turn` 互斥 | `wait=0` 但 `skip=waitingOpponent` → 不一致（r17 已修） |
| `reseat` | 本帧是否换局重锚 | 0 | 频繁 1 → 识别整体崩 |
| `ring` | `环分/距上次见圈帧数` | 0.08~0.15 / 0~5 | 前者 <0.06 → 没画圈；后者 >20 → 5 秒没见圈 |
| `dot` | 本帧最大白点分 | 40~60 | <10 → 白点没读到或没画 |
| `mk` | 标记卡在哪一步 | `ok`/`okRing` | 见下表 |
| `diffReject` | 差分因带噪被拒次数 | 少量 | 持续涨 → 识别质量差 |
| `usedDiff` | 差分兜底累计次数 | **长期 0** | >0 → 标记在丢 |

`mk` 取值：

| 值 | 含义 | 下一步 |
|---|---|---|
| `ok` | 白点+白圈提交 | 正常 |
| `okRing` | 只有白圈，反查成功 | 正常（白点丢了） |
| `noRing` | 没有圈 | 看 `ring`，可能没画/换了皮肤 |
| `ringDedup` | 有圈但全被去重/残留过滤 | 可能一直是上一手的圈 |
| `ringOnly` | 有圈但白点和反查都不成 | 看 `dot` |
| `dirty` | 帧太脏（>6 格）被洁净度闸门挡 | 识别漂移 |
| `ruleReject` | 白点读到了但走法规则不合法 | 白点点错格了 |

### 9.2 其它关键行

```
着法链 #3 h9g7  dirty=0 usedDiff=0      ← 每提交一手
检测到走法 b7e7 炮二平五 → FEN ...       ← 附带 FEN 与锚盘
引擎调度 ply=.. turn=.. skip=..          ← 为什么跳过搜索
搜索方式: go movetime 650ms（按时间）    ← 参数是否真下发
读不到走子标记 · 请点菜单「重新同步」      ← markerLost 提示
```

### 9.3 日志文件（沙箱内）

```
Library/Application Support/JJCheat/moves-<yyyyMMdd-HHmmss>.log   每局一个
Library/Application Support/JJCheat/engine-<yyyyMMdd-HHmmss>.log  每局一个
```

- `moves.log` 每行：`{n, uci, zh, fen, src, gain, ts}`；`event` 行标记 `newgame`/`resync`/`undo`
- `engine.log` 每行：`{fen, bestmove, score, depth, nodes, winrate, ts}`
- 点菜单里的「版本」号可一键清理（带文件数与体积提示）

---

## 10. 常量总表（改阈值只改这两处）

### JS 侧：`tools/bundle.js` 里的 `K` 对象

| 键 | 值 | 作用 |
|---|---|---|
| `RING_MIN` | 0.06 | 白圈判据 |
| `DOT_MIN` | 10 | 白点判据（9×9 白像素数） |
| `SETTLE_FRAMES` / `SETTLE_MS` | 3 / 1500 | 差分兜底的定格门槛 |
| `OPT_HIT` / `OPT_WINDOW` | 2 / 15 | 乐观轮次 |
| `MARKER_DEDUP` | 12 | 同一落点去重窗口（帧） |
| `SKIN_HI/LO`、`SKIN_OK_HI/LO` | 1.45/0.75、1.30/0.85 | 皮肤提示（带滞回） |
| `UNDO_STABLE` | 2 | 悔棋连续帧数 |
| `MAX_MOVE_CHANGE` | 6 | 帧洁净度 |

### 原生侧：`ios/tweak/Core/JJConfig.h`

| 宏 | 值 | 说明 |
|---|---|---|
| `JJ_CHEAT_VERSION` | `2.0.0r18` | 与 `control` 必须一致 |
| `JJ_THINK_MS_DEFAULT/MIN/MAX` | 650 / 100 / 3000 | 思考时间 |
| `JJ_PROCESS_MIN_GAP` | 0.25 | tick 最小间隔（≈4 fps） |
| `JJ_METAL_PEEK_INTERVAL` | 0.15 | 摘要轮询（我方） |
| `JJ_PEEK_WAIT_OPPONENT/OUR_TURN` | 0.35 / 0.15 | 抓帧分档 |
| `JJ_FRAME_DIFF_THRESHOLD` / `JJ_FP_POINT_DELTA` | 260 / 45 | 帧指纹阈值 |
| `JJ_LEARN_MAX_FAIL` | 6 | 学习连败后降频 |
| `JJ_PRESET_AI_*` / `JJ_PRESET_RANK_*` | 28/257/398/659 | 棋盘四角（两套相同） |

---

## 11. 踩坑清单（**最值钱的部分，改代码前先看完**）

### 11.1 构建 / 推送类

| 坑 | 现象 | 解法 |
|---|---|---|
| **`bundle.js` 里写反引号** | `engine.js` 语法错误、`SyntaxError: Unexpected identifier` | 主流程被包在模板字符串里，注释里出现 `` ` `` 会截断模板。**全文件只允许 2 个反引号（模板首尾）** |
| **只按修改时间筛文件推送** | CI 报「方法声明了但没实现」 | 时间筛选会漏。推完必须逐个 `GET /contents` 比对 md5 |
| **CI 缓存 `engine/.build/src`** | `patch()` 期望原文出现 1 次、实际 0 次 | 用 `soft_replace()` 把上一版补丁迁移成新版 |
| **`open(path,'w')` 参数错** | 文件被截断成 0 字节 | Python `open()` 在参数校验前就截断文件。写文件前先备份 |

### 11.2 识别 / 标记类

| 坑 | 现象 | 根因与解法 |
|---|---|---|
| **旧圈挡住新圈** | `ring` 正常但 `usedDiff=1`（标记失效） | 走子快时上一手圈没淡出且分数更高。r18 改为「按分数遍历取第一个可用」 |
| **标记去重窗口太长** | 连走两步第二步没反应 | 30 帧（4.5s）→ 12 帧（1.8s） |
| **白点找不到** | `mk=ringOnly` + `dot<10` | 起点格被读成「有子」就不在白点搜索范围内；或白点被棋子描边盖住 |
| **整行颜色读反** | reseat 采纳 `pNBAKAB2` 这种盘面 | 规则上合法（黑卒可到底线），`plausible` 拦不住。属识别层，暂时无解 |
| **结算页当棋盘** | `diff=32 repaired=6` 还在搜 | r17 加「骤降检测」：现在 <4 子且上一帧 ≥10 子 → 停止 |

### 11.3 状态机类

| 坑 | 现象 | 根因与解法 |
|---|---|---|
| **锚盘建不起来** | `anchor=` 一直为空、FEN 每帧变、`go` 刷屏 | `if (!anchor)` 那段被误删过一次（r14）。**这段以前零测试覆盖**，r16 补了 W 段 |
| **ply 跳 2** | 日志 3→5、6→8、8→10 | 标记提交后通用路径又处理同一 move → 校验失败 → 走逃逸 → 再 +1（r17 修），以及「对称翻转 + 提交」各 +1（r18 修） |
| **`chainDirty` 永久锁死** | 一次逃逸之后对账再也不跑、`moves.log` 的 src 永远 `resync` | 置 1 后从不清零。r17 改为「链就地重启到当前锚盘」 |
| **`replayChain` 走子方写死 `'w'`** | `#1` 反复出现、编号不断从 1 开始 | 链从「黑方要走的局面」开始重放时第一步 `isLegal` 必失败。r18 按 `moves[0].by` 决定 |
| **换局字段污染** | 新局第一帧翻错轮次、第一步被吞、开局误弹皮肤提示 | 20 个 `session.*` 没清。r17 补齐 |
| **学习连败就停摆** | 大厅停留十几秒后插件死掉，必须手动关开 | `timer invalidate`。r17 改成降频重试（两处） |

### 11.4 引擎类

| 坑 | 现象 | 根因与解法 |
|---|---|---|
| **每步重读 61MB 权重** | 每步卡 0.3~0.8s | `verify_network()` 在 `Engine::go()` 第一句。r9 改为校验一次缓存 |
| **`ucinewgame` 在搜索中发** | 重开后第一手慢半秒 | 引擎 UCI 线程会阻塞在 `wait_for_search_finished()`。r11 改严格时序 |
| **关插件 shutdown 引擎** | 重开要等 15 秒 `readyok` | 改为 `stopSearch` 保活。代价常驻约 110MB |
| **`stopSearch` 不清 pending** | 关插件后引擎还在搜 | r17 补清 `pendingFen/pendingCb` |
| **深度模式太高触发看门狗** | 「偶尔这一手不出建议」 | 22 层可能超过 movetime 估算 → 提前 `stop` 丢结果。降到 16 以下或改时间模式 |

### 11.5 UI 类

| 坑 | 现象 | 解法 |
|---|---|---|
| **HUD 吃触摸** | 挡住游戏点击 | `hitTest` 恒返回 `nil`，HUD 是纯显示层 |
| **`__weak` 捕获未持有对象** | `NSInvalidArgumentException` 崩溃 | 刚创建、还没强引用的对象赋给 `__weak` 会立刻变 nil。用 `row` 参数，别反向捕获 |

---

## 12. 已知未解问题（**接手后要盯着**）

| # | 问题 | 现状 | 建议 |
|---|---|---|---|
| 1 | **白点为什么会丢**（`dot<10`） | 只知道走子快时丢，未定位到具体渲染原因 | 靠 `dot`/`mk` 两个诊断继续收数据；若确认是「没画」，考虑用「上一帧锚盘 vs 当前帧」的变化格反推起点 |
| 2 | **引擎偶发自行重启** | 日志 `reader 线程结束` + `uciok=0` 后重握手，触发源不明 | 下次出现时抓完整 5 秒窗口的日志，看是否紧跟 `setoption` |
| 3 | **中等噪声下漂移自愈失效** | 差 4~7 格但每帧抖动 → 「连续 3 帧一致」永不成立 | 可考虑「按格修复」：只把不在本步 from/to 的差异格按当前识别修正（风险：会把误读写进锚盘） |
| 4 | **结算页残余棋子多时漏判** | 骤降判据是「<4 子且上一帧 ≥10」 | 阈值再调会误伤残局，建议先观察 |
| 5 | **悔棋在链重启后失效** | 悔棋判据是「当前盘面 == 链上最后一手的走子前盘面」 | 链被清空时悔棋自动失效，属可接受；若要修，需独立于链记录「上一手盘面」 |
| 6 | **中文记谱仅验证过一局** | `JJMoveChinese(fenWithSide, uci)` 首次接线 | 需要更多对局确认黑方编号（黑方路数从左数）是否正确 |
| 7 | **`autoDetectBoard` 未真机验证** | 只在「学习连败、准备放弃」时触发一次 | 换皮肤场景下应重点测 |

---

## 13. 测试体系（`tools/regression.js`）

**21 组场景、158 条断言**。加任何改动都要先跑它。

| 组 | 守什么 |
|---|---|
| **A** | 执红：红先手、轮次、噪声门槛、派出去重 |
| **B** | 执黑：必须等对方（红）先走，不能抢跑 |
| **C** | 中途进对局：连续 3 帧稳定才换局重锚 |
| **D** | 中局误点自动标定：学习失败不许污染锚盘 |
| **E** | 坐标契约：`searchFen` 必须是引擎坐标（红在下） |
| **F** | 格点对齐（盘均值口径）：偏移修复 / 空盘拒绝 / 已对齐不动 |
| **H** | 引擎安全闸（王=1、王不可被吃）+ 走法规则校验 |
| **I** | 规则校验连败 → 强制重锚（防死锁） |
| **J** | 低置信度闸门（不硬猜） |
| **P** | 坐标旋转公式一致性（防两侧分叉） |
| **Q** | 模块拆分完整性（board.js 生效） |
| **R** | 轮次判定自愈（不靠 movePly 奇偶） |
| **S** | 落点被高亮圈盖住、起点残留、单帧不许抢跑（S3/S4） |
| **V** | 标记优先 + 慢速定格（V0 带标记立即提交 / V1 标记缺失不推进 / V2 超时兜底 / V3 悔棋） |
| **W** | 无锚盘重建（W1 单帧不锚 / W2 两帧一致→锚定） |
| **X** | 乐观翻面不派发搜索 + ply 不许跳号 |
| **Y** | 画面洁净度闸门（差 9 格整帧作废） |
| **Z** | 差分兜底必须零噪声（锚盘不许被污染） |
| **AB** | 连续 6 步 ply 严格 1..6 |
| **AC** | 标记丢失 26 帧：锚盘一格不动 + 报 markerLost |
| **AD** | 旧圈残留（0.14）不挡新圈（0.09） |

**写测试的坑**：

- fixture 用 `makeFixture(src, blackBottom)`，`S.markerSq`/`S.markerFromSq` 是**屏幕坐标**格号
- `S.staleMarkerSq` 可模拟「旧圈残留」（分数 0.14，比新圈 0.09 高）
- 断言要检查 `anchorFen` 是否被污染，不要只看 `ply`（ply 会被对称翻转 +1，是允许的）

---

## 14. 协作规约（用户明确要求过，必须遵守）

### 14.1 铁律

1. **改代码 → 自检 → 汇报 → 等用户确认出包**。不要自作主张推构建。
2. **不生成垃圾脚本**：所有功能塞进现有工具（`bundle.js`/`regression.js`），绝不新建 `xxx_日期.py`。
3. **改完必须三查**：`node --check`（bundle.js 语法）、`bundle`（打包）、`regression`（回归）、`check-syntax.sh`（原生）。
4. **一次只改一件事**，改完立刻验证。多件事混在一起出错最难定位。
5. **不确定就问**，不要脑补需求（尤其涉及识别策略、状态机语义）。

### 14.2 沟通风格

- 中文、直接、给证据（日志行号、代码行号）
- 用 Markdown 表格对比「改前 / 改后」
- 状态用 ✅ ❌ ⏳ ⚠️
- **不要吹**：明确说「这个不确定」「这个没验证」「这是推测」
- 出错要立刻承认 + 给补救动作，不要解释理由

### 14.3 用户最在意什么

| 排序 | 在意点 |
|---|---|
| 1 | **精准度**（宁可慢，不能错） |
| 2 | **数据一致性**（日志、FEN、锚盘三者对得上） |
| 3 | 稳定性（不崩、不卡死、不用手动关开） |
| 4 | 速度 |

他反复说过：「慢一点无所谓，正常人类是要思考的，只要精准度」。

---

## 15. 常见任务操作手册

### 15.1 改一个阈值

1. 改 `tools/bundle.js` 的 `K` 对象，或 `ios/tweak/Core/JJConfig.h`
2. `node tools/bundle.js && node tools/regression.js`
3. `bash tools/check-syntax.sh`
4. 全绿后按 §1.2 推送

### 15.2 加一个菜单项

1. `JJGameController.m` 的 `JJMenuAction` 枚举加一项
2. `jjMenuEntries` 里加 `JJMenuEntry`，设 `action`
3. `switch` 里加分支 + 实现方法
4. 类扩展里声明方法
5. **同步 `tools/check-syntax.sh` 的 `check_case` 清单**（否则一致性检查会红）
6. 跑自检

### 15.3 改引擎补丁

1. 先看 `engine/patch-engine.py` 现有 4 处
2. 改完后**把上一版文本登记成 `ENGINE_CPP_GO_V1`**（或对应的 V1 常量）
3. 本地用「旧形态源码树」验证 `soft_replace` 迁移生效
4. 推送后看 CI 的 `jj-patch` 日志，确认全部「已替换」

### 15.4 排查「HUD 和棋盘不一致」

按这个顺序看日志：

```
1. mk=？           → 标记法卡在哪一步
2. ring / dot      → 圈和点到底有没有
3. usedDiff        → 有没有掉到差分
4. ply 是否连续    → 有没有重复计算
5. anchor= 是否为空 → 锚盘建起来了没
6. reseat 是否为 1  → 是不是在反复重锚
7. diff 多大        → 6 以内正常，20+ 说明识别整体崩
```

### 15.5 排查「不出建议」

```
1. skip=none 但有 needSearch？→ 看 needSearch 是否为 1
2. skip=waitingOpponent？     → 轮次判定认为在等对方
3. skip=lowconf？             → 待确认格数 > 6
4. skip=illegal？             → 盘面非法
5. skip=king？                → 王缺失或已被吃
6. 搜「搜索方式」             → 引擎参数是否真下发
7. 搜「看门狗」               → 是否被超时 stop 掉了
```

---

## 16. 关键联系人 / 环境信息

| 项 | 值 |
|---|---|
| 仓库 | `github.com/Oxmaner/jjcheat`（PAT 在 `patch_repo.ps1`） |
| 设备 | iPhone（Metal 1284×2778 px / 逻辑 428×926 pt，6.7 吋机型），iOS 16.x，roothide 越狱 |
| 目标 App | JJ 象棋（`cn.jj.chinachess`） |
| 用户 | 定富哥（紫金铜业电解厂，业余做这个） |
| 本地路径 | `F:/MacLin/Documents/jjcheat-patch` |
| Theos SDK | `F:/MacLin/Documents/theos-sdks/iPhoneOS16.5.sdk` |
| MCP（手机） | `192.168.137.123:8090`，只在工位网络可用 |

---

## 17. 最后一句

这个项目最大的教训是：**问题几乎从来不在「识别算法」，而在「状态什么时候被相信」**。

90 格模板匹配本身足够准（10 轮真机实测 10/10）。所有严重故障都出在同一件事上——
**某一帧的脏数据被当成了真相，写进了锚盘，然后一直错下去**。

所以改动前先问自己：

> 这个改动，会让「不确定的帧」有机会污染锚盘吗？

如果会，加闸门；如果不会，放手改，但要补测试。
