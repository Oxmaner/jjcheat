# JJCheat 交接（r36）

## 当前状态

| 项 | 值 |
|---|---|
| 包 | `com.maclin.jjcheat_2.0.0r36+b125_iphoneos-arm64e.deb` |
| MD5 | `49a9046c52e1563ff5d4b23e772c72e9` |
| 仓库 | `Oxmaner/jjcheat`（私有） |
| 设备 | 已装 r36+b125，真机验证通过 |
| 引擎 | 纯枚举法（移植原项目 `MoveTracker.tryAdvance`），`src=enum` 已验证 |

已删除：白点白圈标记整层、`analyzeStepDiff`、`logo-dark` 变黑逻辑、HUD 死文案、菜单精简至 8 项。

---

## 唯一待办：对手的走子没被识别

### 症状（真机实测，用户执红）

1. 用户按箭头走 `马八进七` → `ply` 0→1，**识别成功**
2. 对手走中炮（`炮8平5`）→ **没识别**，`ply` 停在 **1**（应为 2）
3. HUD 一直显示「等待对方走子」，**永不给 bestmove**

### 为什么卡住

`tools/bundle.js:1842-1852`：

```js
var myTurnChar = mySideDetected === 'red' ? 'w' : 'b';
var lastMoverChar = session.lastMoverSide === 'red' ? 'w' : (…'black' ? 'b' : '');
if (lastMoverChar) turnChar = (lastMoverChar === 'w') ? 'b' : 'w';
var waitingOpponent = (turnChar !== myTurnChar);
```

`lastMoverSide` 停在 `'red'` → `turnChar='b'` → `waitingOpponent=1` → 跳过搜索、不出箭头。
对手明明走了，但 `lastMoverSide` 没更新成 `'black'`。

### 排查入口

**日志**（设备上）：
```
/var/mobile/Containers/Data/Application/141CCCF6-0FE0-4492-8E22-5EDFAC205EF5/
  Library/Application Support/JJCheat/
    moves-*.log     ← n / uci / zh / src / fen
    engine-*.log    ← 引擎搜索记录
```

**要看的字段**（心跳 + 枚举诊断）：
- `enumSig` / `enumNoise` / `enumHits` —— 黑炮那几步的匹配得分
- `skipReason` —— 是否被 `stepIsLegal` / `codesLegal` 拦下
- `lastMoverSide` 的变化轨迹
- **`flipped` 是否中途翻转**（若锚盘坐标系与画面朝向不一致，枚举会全盘匹配失败）

### 初步怀疑

中炮是「炮8平5」，横移 **3 格**。签名格只有起点 + 落点两格，中间 2 个空格的采样差异可能把 `noise` 推过硬门槛（`noise ≤ 4`）；也可能 3 帧确认没凑满。

**需要真实数值确认，不要盲改阈值。**

### 相关代码

| 位置 | 作用 |
|---|---|
| `src/app/board.js` → `enumerateAdvance` | 枚举全部合法走法 + 三分类比对 |
| `tools/bundle.js` ~1526 起 | 集成块：`enumHits >= 3` 才提交 |
| `tools/bundle.js:1842-1852` | 轮次推导（上面的代码） |
| 硬门槛 | `sig ≤ 1 && noise ≤ 4`，签名格权重 ×10 |

---

## 次要待办：HUD 显示歧义

`sideToMove` 一个字段两种语义：

```js
// bundle.js:2066（正常分支）= 我执哪方
out.sideToMove = mySideDetected;                     // 'red'
// bundle.js:2221（waitingOpponent 分支）= 轮到谁走  ← 语义变了
out.sideToMove = turnChar === 'w' ? 'red' : 'black'; // 'black'
```

HUD 统一当「我执哪方」显示（`JJHUDWindow.m:357`）→ 等对方时看到「黑方」会误以为自己是黑方。

**修法**：HUD 改用 `mySide`（`bundle.js:1901` 已有），轮次由 `waitingOpponent` 单独表达。

---

## 改完必须全绿

```
node --check tools/bundle.js
node tools/test-enum.js       → 7 通过 / 0 失败
node tools/test-catchup.js    → 连续追上 3/3 步
bash tools/check-syntax.sh    → 15/15
```

改完 `bundle.js` 后记得同步：
```
node tools/bundle.js
Copy-Item dist\engine.js 'ios\tweak\layout\Library\Application Support\JJCheat\engine.js'
```

---

## 关键坐标链（不要重新推导）

- `corners[0]` = 屏幕左上（`JJCalibrator.m:147`「左上 → 右上 → 右下 → 左下」）
- `gridPoints` / `cls.codes` / `anchor` / `JJSqFromICCS` / `JJPieceAtFen`
  **全部 row0 = 屏幕顶部 = FEN 首行 = 黑方底线**
- `JJSqFromICCS('h2') = 70`
- `Position.board` 与 `codes` 同序（`this.board[r*9+c]`，r = FEN 行号）
- 执红不翻转；执黑时 `JJSqRotate180`
- `C.RED=0` `C.BLACK=1` `C.EMPTY=0`；RK=1…RP=7、BK=8…BP=14
- `BOARD_PRIOR = { x0:0.0666, cw:0.1078, y0:0.2773, ch:0.0484 }`（原项目反解值，
  `refineByPieces` 三级搜索会收敛到本机真实位置）

---

## 出包

push 到 main 自动触发 `build-roothide-deb.yml`，约 4 分钟。
下载：`python download_deb.py`（需在脚本里填 PAT）。

**注意**：不要往仓库里写明文 token —— GitHub Secret Scanning 会拦（422）。

### 装机（iOS MCP）

```
① POST http://<手机IP>:8090/upload_file     原始二进制 + X-Filename
② tools/call install_app { path, file_type: "deb" }   ← 会重启 SpringBoard，连接必然断
③ 等 20s → curl http://<手机IP>:8090/health
```

**装机后必查**（deb 更新但容器副本可能还是旧的）：
```bash
C="/var/mobile/Containers/Data/Application/141CCCF6-.../Library/Application Support/JJCheat"
ls -l "$C/engine.js"          # r36 应为 346149 B
rm -f "$C/engine.js" "$C/engine.js.fp"   # 不对就删，重启 App 会重新释放
```

**MCP 调用坑**：
- 结果在 `result.content[0].text`（JSON 字符串），不是 `structuredContent`
- PowerShell 函数参数**不能叫 `$args`**（自动变量会被覆盖成空）
- 游戏 bundle id = **`cn.jj.chinachess`**（`TKLobby_chess_tuanjie` 是进程名）
- 手机必须**保持亮屏**，息屏会让 MCP 服务挂起

---

## 用户长期约束（必须遵守）

- **帧数不改**（用户自己设定）
- **不能靠猜** —— 差分、环反推、高亮推断、补子全部已删除
- **只留原项目的算法**
- **UI / 箭头保持原样**（改版预览方案全部被否）
- **不要擅自推送**，推送前等用户确认
- 准确度 > 数据一致性 > 稳定性 > 速度
- 可接受的最坏结果是「暂时没有箭头」，**绝不能是错误箭头**
