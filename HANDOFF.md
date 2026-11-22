# JJCheat 交接（2026-11-23 00:20）

## 一句话现状

**代码已经等于「上游逻辑 + Pikafish 引擎」。** 锚盘/枚举/轮次那一整套 fork 自造的
状态机已全部删除（r55，−753 行），盘面只由识别定盘，走子方永远写我方 —— 与
上游 `lichengyang51/jjcheat` 逐行一致。

**r55 还没上过真机。** 设备上是这一版，但只有台架验证（见下）。

## 设备/仓库

| 项 | 值 |
|---|---|
| 设备 deb | `2.0.0r43+b130`（dylib 未变，仍是 r43） |
| 设备 engine.js | **r55**：321 KB / 1752 行（`engine.js.pre-purge.bak` = 删前 368 KB） |
| 仓库 HEAD | `80831cc`（r55），全部本地提交，**未推送** |
| 回滚 | `git tag backup-before-purge-2488`、`E:\work\bundle-2488-backup.js`、`E:\work\engine-before-purge.js`、设备 `engine.js.pre-purge.bak` |

## 架构（r51~r55 四刀）

1. **r51 走子方永远写我方**
   上游原文（`tools/bundle.js:885`）：「FEN 的走子方一律取「我方」……引擎永远站在
   我方算。」我们曾改成"按真实轮次"，于是必须维护 `movePly / lastMoverSide /
   waitingOpponent` 三套状态去猜"轮到谁"——真机上全部失步。
   现在：`turnChar = myTurnChar`，`waitingOpponent` 恒 false。
   代价（上游同款）：对手回合也会给箭头。

2. **r52 盘面只由识别定盘**
   锚盘/重锚/悔棋/新局共 6 处 `session.lastBoardFen = session.anchorFen` 全部中和。
   唯一来源：`settled（连续一致）+ legalNow（合法）+ 700ms 限流 + illegalStreak>12 清盘`。

3. **r53 停用「低置信度格子 > 6 就不出建议」**
   上游没有这道闸（只看合法）。它在真机上反复变成死锁：
   `legalNow=1 codesValid=1 skipReason=lowconf` 卡到死。

4. **r54 king 安全闸改成检查「真正要喂引擎的盘面」**
   原来查 `session.anchorCodes`（可能陈旧），而实际喂的是 `analyzeFen`。
   漏拦 → Pikafish 拿到非法 FEN；误拦 → 合法棋被判 `king` 不出箭头。

5. **r55 删除锚盘/枚举整层**（1176~1946 行）
   含：锚盘状态机、枚举走子（单步/两步）、重锚、漂移吸收、对称翻转、悔棋检测、
   着法链与对账。只留 6 行兼容桩（`stepInfo / anchorRejected / reseat / anchor`）。

## 已知行为（不是 bug，是模型代价）

- **将军之后**：盘面变成「我方走 + 对方被将」，规则上不存在的局面。
  Pikafish 不容忍 → `codesEngineSafe` 拦下 → `skipReason='king'`，箭头消失
  直到对手应招。上游的 Eleeye 容忍（但它算的也没意义）。**用户决定保持现状。**
- **对手回合也给箭头**（上游同款）。
- **`moves-*.log` 会变空**：那些行由枚举层产出 `out.move` 后写盘，枚举层已删。
  `engine-*.log` 正常。若需要着法记录，可加约 15 行"盘面差分 → from/to + 中文"
  的纯日志实现（不参与判定）。

## 验证状态

**离线（已过）**
- `node --check`：bundle + dist 均通过
- `tools/test-enum.js` 7/0、`test-enum2.js` 13/0（board.js 未动）
- `tools/diag-e2e.js`（新增）：真机截图跑 `learnAndRefine + process ×3`，**无异常抛出**，
  `turn="w"`、`waitingOpponent=0` 正常。注意：台架用的是含插件浮窗的残局截图，
  所以它跑出 `legalNow=0` —— 截图本身的问题，正向路径只能在真机验。

**真机（r53 时代，删除前）**
- 23:56 执黑局：**12 手 n=1..12 连续无跳号，红黑严格交替，记谱全对**
- 23:42 局（r52）：n 跳号（2,3,4,5,6,**8**,9,10,**12**…34）→ 最后手动 resync
  `prevCount=30`。同一对手同一机器，差别就是"走子方永远我方"这条改动。

**待验（r55 本体）**
- 执红 10 手、执黑 10 手
- 重点：残局是否乱指（上游没有识别兜底，这是唯一可能回退的点）

## 下次的入口

1. 先真机跑 r55（执红 + 执黑各一局），看 `engine-*.log` 的 FEN 走子方是否一直是 `w`/`b`（我方）、有没有突然跳盘
2. 若残局乱指 → 把"识别失联兜底"单独加回（约 20 行）：连续 N 帧 `legalNow=0` 就整帧不出建议
3. 若要着法日志 → 加 15 行盘面差分实现
4. 确认稳定后再出 deb（`bundle.js` 改动要 push 到 main 触发 CI，约 5~7 分钟）

## 工具与坑（沿用）

- `tools/diag-e2e.js`：真机截图 → 打包后的 engine.js 端到端台架（本次新增，最能抓运行时 bug）
- `tools/diag-vision.js`：真机截图 → 识别层逐格数值
- 热更新：容器 `engine.js` 在 `.fp` 与内嵌副本一致时被保留 → 改 JS 只需写容器 + 重启 App
- 大文件传输走 base64 分片（单次 MCP 请求体上限约 16KB）
- **bundle.js 正文是模板字符串**：注释里绝对不能出现反引号
- 降级装不上（dpkg 拒绝降版本）→ 回滚要用"版本号前进 + 旧代码"
- Pikafish 缓存键已升 `v3`（缓存里的 .a 是未打补丁的旧产物）
- 手机息屏会让 MCP 服务和 Wi-Fi 一起挂；长任务前先确认亮屏
