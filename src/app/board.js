'use strict';
/*
 * 棋盘纯函数层 —— 从 tools/bundle.js 抽出（2.1.79）
 *
 * 为什么抽出来：这些函数全都只依赖「90 格编码 + 规则」，不碰 session、
 * 不碰识别器实例、不碰引擎，是纯粹的输入→输出。以前它们和打包器、
 * JJEngine 主流程混在 tools/bundle.js 一个文件里（1500 行），
 * 想单独验证任何一个都得先跑整个打包器。
 *
 * 现在：
 *   - 本文件 = 棋盘编码 / 朝向 / FEN 互转 / 合法性闸门 / 走子比对
 *   - tools/bundle.js = 打包器 + JJEngine 主流程（只做拆装与状态机）
 * 行为零变化：迁移是逐字搬运，回归（24+ 断言）覆盖了这里的每一条分支。
 */

const C = require('../cst/constants');
const POS = require('../cst/position');

/* ============================================================
 *  棋盘朝向处理
 *  用户执红时红子在下（标准朝向），执黑时 JJ象棋 会翻转棋盘、黑子在下。
 *  引擎内部统一用「红在下」的标准坐标，所以画面翻转时要翻回来。
 * ============================================================ */

/** 上下翻转一张三分类网格（返回新数组，不改原数组） */
function flipGrid(grid) {
  var out = new Int8Array(90);
  for (var sq = 0; sq < 90; sq++) {
    var r = (sq / 9) | 0, c = sq % 9;
    // ★ 必须是「旋转 180 度」，不是「上下翻转」
    //
    //   你执黑时，看盘的视角是从对面看过来 —— 相当于把棋盘在桌面里转了 180 度，
    //   行和列同时反向。原来只翻了行、列没翻，得到的是一张「左右镜像」的假局面：
    //   帅/将恰好还在九宫里（九宫左右对称），所以合法性检查也发现不了，
    //   但整盘棋子全在错的列上，引擎算出来的着法自然全废。
    out[(9 - r) * 9 + (8 - c)] = grid[sq];
  }
  return out;
}

/** 屏幕坐标 ↔ 引擎坐标（红在下）：旋转 180 度 */
function flipCodes(codes) {
  var out = new Int8Array(90);
  for (var sq = 0; sq < 90; sq++) {
    var r = (sq / 9) | 0, c = sq % 9;
    out[(9 - r) * 9 + (8 - c)] = codes[sq];
  }
  return out;
}

/* ============================================================
 *  直接把识别出的兵种编码组回 FEN
 *
 *  这才是象棋软件该有的架构：识别整盘棋子 → 组局面 → 引擎算。
 *  不依赖「从开局一步步跟踪」，所以随时中途进去也能用。
 * ============================================================ */

var PC2FEN_TABLE = ['', 'K', 'A', 'B', 'N', 'R', 'C', 'P', 'k', 'a', 'b', 'n', 'r', 'c', 'p'];

/** 只拼棋盘部分（不带走子方） */
function codesToBoardFen(codes) {
  var rows = [];
  for (var r = 0; r < 10; r++) {
    var s = '', empty = 0;
    for (var c = 0; c < 9; c++) {
      var v = codes[r * 9 + c];
      if (!v) { empty++; continue; }
      if (empty) { s += empty; empty = 0; }
      s += PC2FEN_TABLE[v] || '1';
    }
    if (empty) s += empty;
    rows.push(s);
  }
  return rows.join('/');
}

/**
 * 局面合法性校验
 *
 * 只拦「明显不合理」的情况，不做严格将帅计数校验。
 * 之前要求 redK===1 && blkK===1，结果红帅被高亮圈/绿点遮住一帧就整盘作废，
 * 浮窗直接冻住不动。宁可容忍个别格识别错，也不要让程序彻底停止工作。
 */
function validateCodes(codes) {
  var redN = 0, blkN = 0;
  for (var i = 0; i < 90; i++) {
    var v = codes[i];
    if (!v) continue;
    if (v >= 1 && v <= 7) redN++;
    else if (v >= 8 && v <= 14) blkN++;
  }
  // 棋子数不可能超过初始布局
  if (redN > 16 || blkN > 16) return false;
  // 全是空 / 只剩两三个子，说明识别彻底失败
  if (redN + blkN < 6) return false;
  return true;
}

/** 宽松版：只要不是全空就接受，用于「让程序继续工作」 */
/**
 * 有没有认出东西来。
 *
 * 只要认出至少 1 个棋子就算有结果 —— 象棋可以有只剩两个王的盘面，
 * 任何「至少 N 个子」的门槛都是瞎猜，会误杀合法残局（实测 6 子、4 子残局都栽在这上面）。
 * 真正意义上「什么都没认出来」是 0 个棋子，那种情况才不该覆盖上一局面。
 */
function codesUsable(codes) {
  for (var i = 0; i < 90; i++) if (codes[i]) return true;
  return false;
}

/**
 * 严格合法性校验：这一帧识别出来的盘面「有没有可能是一盘真棋」。
 *
 * 为什么要这道闸：真机抓屏和离线截图不完全一致，偶尔会出几帧垃圾识别。
 * 垃圾盘面一旦被显示出去，用户看到的就是「满盘车」「红帅变黑将」这种乱象，
 * 而真正该做的是：宁可继续显示上一帧合法盘面，也不要把垃圾推给用户。
 *
 * 判据（象棋规则里不可能出现的组合）：
 *   每方最多 1 个将帅、2 仕、2 相、2 马、2 车、2 炮、5 兵
 *   双方棋子总数都不能超过 16，且不能少到 5 个以下（那是识别崩了）
 *   必须有一方有将帅（至少红黑各 1 个里的一个，允许另一侧被遮挡漏读）
 */
function codesLegal(codes) {
  var LIM = [0, 1, 2, 2, 2, 2, 2, 5];   // 将 仕 相 马 车 炮 兵
  var cnt = [new Array(8).fill(0), new Array(8).fill(0)];
  var redN = 0, blkN = 0;
  for (var i = 0; i < 90; i++) {
    var v = codes[i];
    if (!v) continue;
    if (v >= 1 && v <= 7) { redN++; cnt[0][v]++; }
    else if (v >= 8 && v <= 14) { blkN++; cnt[1][v - 7]++; }
  }
  // 只拦「规则上不可能」的情况，一律是上限：
  //   每方最多 16 子（象棋不能升变，子只会少不会多）
  //   每类子不超过初始数量（将1 仕2 相2 马2 车2 炮2 兵5）
  // 【没有任何下限】
  //   只剩两个王、只剩一个车，都是合法局面；任何「至少 N 个子」的门槛
  //   都会误杀残局（实测 6 子和 4 子的残局全被误杀过）。
  if (redN > 16 || blkN > 16) return false;
  for (var s = 0; s < 2; s++) {
    for (var t = 1; t <= 7; t++) {
      if (cnt[s][t] > LIM[t]) return false;
    }
  }
  return true;
}

/**
 * 位置合理性校验（1.1.44）
 *
 * codesLegal 只管「数量不超限」，拦不住「黑卒出现在自己底线」「红相过了河」
 * 这类规则上不可能的盘面。15:10 真机 FEN 一路漂成 pnbaknb2 / 3k1rbp1 /
 * 1RRaknbp1，全部数量合法但位置荒谬，引擎拿着这种盘面给的着法自然是乱的。
 * 这里只写象棋硬规则（将帅仕士不出九宫、相象不过河、兵卒不后退），
 * 不会误杀任何合法残局。
 *
 * @param {Array|Int8Array} codes 引擎坐标（红在下，row0=黑底线，row9=红底线）
 */
function codesPositionPlausible(codes) {
  for (var i = 0; i < 90; i++) {
    var v = codes[i];
    if (!v) continue;
    var r = (i / 9) | 0, c = i % 9;
    var palace = (c >= 3 && c <= 5);
    if (v === 1 && !(r >= 7 && palace)) return false;   // 红帅
    if (v === 8 && !(r <= 2 && palace)) return false;   // 黑将
    if (v === 2 && !(r >= 7 && palace)) return false;   // 红仕
    if (v === 9 && !(r <= 2 && palace)) return false;   // 黑士
    if (v === 3 && r < 5) return false;                 // 红相不过河
    if (v === 10 && r > 4) return false;                // 黑象不过河
    if (v === 7 && r > 6) return false;                 // 红兵不后退
    if (v === 14 && r < 3) return false;                // 黑卒不后退
  }
  return true;
}

/**
 * 引擎安全校验（2.1.76）——「这一帧能不能喂给 Pikafish」，与「能不能显示」分开
 *
 * 为什么不直接并进 codesLegal：历史上加过「王必须各 1 个」，结果红帅被高亮圈
 * 遮住一帧就整盘作废、浮窗直接冻住不动（见 validateCodes 的注释）。显示层
 * 必须宽松，否则偶发漏读会让程序看起来死掉了。
 *
 * 但这一层绝对不能宽松 —— Pikafish 的 Position::set() 会拒绝两类盘面：
 *   王数量不为 1        → "Unsupported position. Incorrect number of kings."
 *   走子方正在将军对方  → "Unsupported position. King can be captured."
 * 而 UCIEngine::position() 失败后会走 terminate_on_critical_error：
 * 2.1.75 及之前那里是 std::exit(1)，直接把宿主 App 一起拆掉
 * （真机 .ips thread 73 的证据链，见 HANDOFF §14）；
 * 2.1.76 起补丁改成「打 JJ-FATAL + 拒绝搜索」，虽然不再崩，
 * 但这次搜索必然作废 —— 等于白白浪费一次思考，还让 HUD 抖一下。
 * 所以：宁可这一帧不给建议，也绝不把非法 FEN 发给引擎。
 *
 * @param {Array|Int8Array} codes 引擎坐标（红在下）
 * @param {string} sideToMove 'red' | 'black'
 */
function codesEngineSafe(codes, sideToMove) {
  var rk = 0, bk = 0;
  for (var i = 0; i < 90; i++) {
    if (codes[i] === 1) rk++;
    else if (codes[i] === 8) bk++;
  }
  if (rk !== 1 || bk !== 1) return false;
  try {
    var fen = codesToBoardFen(codes) + ' ' + (sideToMove === 'black' ? 'b' : 'w') + ' - - 0 1';
    var pos = new POS.Position(fen);
    // inCheck(对方) 为真 = 我方正将着对方 = 这盘面不许出现（对方上一手不该走成被将）
    if (pos.inCheck(pos.side ^ 1)) return false;
  } catch (e) {
    return false;    // 连 Position 都建不起来，更不能喂引擎
  }
  return true;
}

/**
 * 这一步棋在规则上真的走得通吗（2.1.76）
 *
 * analyzeStepDiff 只验「代数结构」：from 格变空、to 格出现同一个子、不吃己方。
 * 它**不验走法形状** —— 马别腿、炮没炮架、仕走出九宫、车穿过别的子，全都能过。
 * 整份 bundle.js 里 isLegal / genLegalMoves 从 1.1.44 起一次都没被调用过，
 * 所以网格噪声凑出来的「伪走法」会被当成真走法推进锚盘，之后越错越远，
 * 引擎就对着这张越来越离谱的盘面算 —— 这就是「瞎指挥」的长尾来源。
 *
 * 这里用 Position.genLegalMoves() 严格比对（内部先按形状生成候选，
 * 再用 isLegal 过滤「走完自己被将军」）。命中才算真走法。
 *
 * @param {Array} codes 走子前的盘面（引擎坐标，红在下）
 */
function stepIsRuleLegal(codes, from, to) {
  try {
    var piece = codes[from] || 0;
    if (!piece) return false;
    // 红在下坐标系里：红子(1..7) 走 w，黑子(8..14) 走 b
    var side = piece <= 7 ? 'w' : 'b';
    var pos = new POS.Position(codesToBoardFen(codes) + ' ' + side + ' - - 0 1');
    var want = from | (to << 7);
    var legal = pos.genLegalMoves();
    for (var i = 0; i < legal.length; i++) {
      if (legal[i] === want) return true;
    }
  } catch (e) {}
  return false;
}

/** 棋盘 FEN → 90 格 codes（开局锚定用） */
function boardFenToCodes(fen) {
  var out = new Array(90).fill(0);
  var rows = String(fen || '').split(' ')[0].split('/');
  if (rows.length !== 10) return out;
  for (var r = 0; r < 10; r++) {
    var col = 0, line = rows[r];
    for (var k = 0; k < line.length && col < 9; k++) {
      var ch = line[k];
      if (ch >= '1' && ch <= '9') { col += parseInt(ch, 10); continue; }
      var v = PC2FEN_TABLE.indexOf(ch);
      out[r * 9 + col] = v > 0 ? v : 0;
      col++;
    }
  }
  return out;
}

/**
 * 一步棋差分分析（1.1.44 核心）
 *
 * 象棋每步只动一枚棋子。把本帧识别结果与「上一稳定盘面」比较：
 *   - 找「有子→空」的起点 from 和「cur[to] === prev[from]」的终点 to；
 *   - 额外变化格一律视为识别噪声，用锚盘值覆盖；
 *   - 变化格数过多（>3）或找不到一步棋结构 → 整帧丢弃。
 *     一步棋正常只改 to/from 两格，吃子也是两格；出现 4 格以上说明
 *     是拖动动画、选中高亮或噪声，按「识别异常」处理，不拿来推局面。
 * 这样每帧落地的 codes 都严格由「锚盘 + 一步棋」生成，模板抖动再也带不偏盘面。
 *
 * @returns {{changed:number, move:object|null, noise:Array}}
 */
/* ============================================================
 *  枚举式走子检测
 *
 *  移植自原项目 lichengyang51/jjcheat 的 src/vision/tracker.js -> MoveTracker.tryAdvance()。
 *  原项目 README 的原话解释了它为什么可靠：
 *    「它不认字。程序只需要判断每个交叉点是空 / 有红子 / 有黑子三种情况之一，
 *      兵种身份全部由规则反推出来 —— 规则本身就把身份锁死了。」
 *
 *  做法：拿锚盘枚举**全部合法走法**（通常 40 个左右），逐个模拟，
 *        压成三分类图（0 空 / 1 红 / 2 黑）跟本帧对比；
 *        起点与终点是「签名格」，对不上重罚（权重 10 倍），其余格算噪声。
 *        硬门槛：签名格最多错 1 个、噪声格最多错 4 个。
 *
 *  与「差分」的本质区别：
 *    候选空间是**全部合法走法**，不是从「一格变空 + 一格有差异」推出来的**一个**猜测。
 *    所以它自带追赶能力 —— 锚盘落后几步就连续调几次，每次都被规则约束住，
 *    不会像标记法那样「落后一步就永远追不上」。
 *
 *  @param {Array|Int8Array} anchorCodes 锚盘（15 类编码）
 *  @param {Int8Array} gridNow           本帧三分类图（0/1/2）
 *  @param {string} side                 该谁走：'w' 红 / 'b' 黑
 *  @param {number} [maxNoise=4]         噪声格容限
 *  @returns {{noChange:true,diff:number}|{move:number,sig:number,noise:number,candidates:number,diff:number}|null}
 *           null = 没有任何合法走法能匹配（识别不可信）
 * ============================================================ */
function enumerateAdvance(anchorCodes, gridNow, side, maxNoise) {
  const tol = (typeof maxNoise === 'number') ? maxNoise : 4;

  /* ★ 坐标系（2.0.0r32 实测确认，别再动）：
     POS.Position 的 setFen 是 `this.board[r * 9 + c]`，r 直接就是 FEN 的行号，
     所以 **pos.board 与 codes / boardFenToCodes 完全同序**（row0 = FEN 第一行 = 黑方底线）。
     实测：开局时两者 90 格零差异。
     genLegalMoves 也一样——开局（'w' 红先）第一条是 row6→row5 的红兵进一，完全正确。
     结论：这里**不需要任何翻转**，三分类图直接用原下标跟 pos.board 比。 */
  const cur = new Int8Array(90);
  for (let i = 0; i < 90; i++) {
    const v = anchorCodes[i] || 0;
    cur[i] = v ? (v <= 7 ? 1 : 2) : 0;
  }

  // ① 结构分类：没有「有子→空 且 空→有子」的移动结构，就不是走子
  let emptied = 0, filled = 0, chg = 0;
  for (let sq = 0; sq < 90; sq++) {
    const a = cur[sq], b = gridNow[sq];
    if (a === b) continue;
    if (a === 0) filled++;
    else if (b === 0) emptied++;
    else chg++;
  }
  const totalDiff = emptied + filled + chg;
  if (totalDiff === 0) return { noChange: true, diff: 0 };
  if (emptied === 0 && filled === 0) return { noChange: true, diff: totalDiff };

  // ② 枚举全部合法走法，逐个模拟比对
  let pos, moves;
  try {
    pos = new POS.Position(codesToBoardFen(anchorCodes) + ' ' + (side || 'w') + ' - - 0 1');
    moves = pos.genLegalMoves();
  } catch (e) {
    return null;
  }
  if (!moves || !moves.length) return null;

  let best = 0, bestScore = 1e9, bestSig = 99, bestNoise = 99, bestCount = 0;
  const g2 = new Int8Array(90);
  for (let mi = 0; mi < moves.length; mi++) {
    const m = moves[mi];
    const from = C.mvFrom(m), to = C.mvTo(m);
    const cap = pos.makeMove(m);
    const bd = pos.board;
    for (let q = 0; q < 90; q++) {
      const pv = bd[q] || 0;
      g2[q] = pv ? (pv <= 7 ? 1 : 2) : 0;
    }
    pos.unmakeMove(m, cap);

    let sig = 0, noise = 0;
    for (let sq2 = 0; sq2 < 90; sq2++) {
      if (g2[sq2] === gridNow[sq2]) continue;
      if (sq2 === from || sq2 === to) sig++;
      else noise++;
    }
    if (sig > 1 || noise > tol) continue;      // 硬门槛
    const score = sig * 10 + noise;            // 签名格权重 10 倍
    if (score < bestScore) {
      bestScore = score; best = m;
      bestSig = sig; bestNoise = noise; bestCount = 1;
    } else if (score === bestScore) {
      bestCount++;
    }
  }
  if (!best) return null;
  return { move: best, sig: bestSig, noise: bestNoise, candidates: bestCount, diff: totalDiff };
}

/* 2.0.0r34：analyzeStepDiff 已删除。走子判定只认 enumerateAdvance；
   帧差异统计改用 countCodesDiff，不再需要「配对出一手棋」这套副作用。 */
/**
 * 两帧 codes 的差异格数（换局重锚用）。
 * 真机模板每帧抖 3~8 格，逐格签名「完全相同」几乎不可能凑齐连续 3 帧；
 * 改用差异格数阈值，既能让稳定局面收敛，又不会把单帧垃圾当新局。
 * @param {Array|Int8Array} a 上一帧
 * @param {Array|Int8Array} b 本帧
 * @returns {number} 不同格数
 */
function countCodesDiff(a, b) {
  var n = 0;
  for (var i = 0; i < 90; i++) if ((a[i] || 0) !== (b[i] || 0)) n++;
  return n;
}

/**
 * 占位差异：只比「有子 / 无子」，忽略兵种认错。
 * 2.0.0 新局判据用它区分两种情况：
 *   - 回到的确是标准开局：32 枚棋子都在正确位置，模板最多把兵种认错 → 占位差 0；
 *   - 开局刚走了两步：起点两格变空、终点两格多子 → 占位差 4。
 * 只用 countCodesDiff 会把后者（差 4 格）误判成新局，离线回归 A4 实测踩到。
 * @param {Array|Int8Array} a
 * @param {Array|Int8Array} b
 * @returns {number} 占位不同的格数
 */
function countOccupancyDiff(a, b) {
  var n = 0;
  for (var i = 0; i < 90; i++) {
    if (((a[i] || 0) !== 0) !== ((b[i] || 0) !== 0)) n++;
  }
  return n;
}

/**
 * 兵种配额裁剪（1.1.43 → 1.1.44）
 *
 * 1.1.43 把超额兵种直接清成空格，15:10 日志每帧 repaired=1~4，棋子被一帧帧
 * 凭空删掉，盘面越来越残缺。1.1.44 改为「优先用模板候选替换成同阵营缺额兵种，
 * 实在没有候选才清空格」，且绝不删将帅、单帧最多清 6 格。
 *
 * @param {Array|Int8Array} codes 90 格兵种编码
 * @param {Array} conf 每格模板置信度（低的先动）
 * @param {Array} ranked 每格候选兵种（recognizer.lastRanked）
 * @returns {{codes: Int8Array, repaired: number, replaced: number, dropped: number}}
 */
function repairCodesQuota(codes, conf, ranked) {
  var LIM = [0, 1, 2, 2, 2, 2, 2, 5];   // 将 仕 相 马 车 炮 兵
  var MAX_DROP = 6;
  var out = new Int8Array(90);
  for (var i = 0; i < 90; i++) out[i] = codes[i] || 0;
  var repaired = 0, replaced = 0, dropped = 0;
  for (var side = 0; side < 2; side++) {
    var base = side === 0 ? 1 : 8;
    for (var t = 1; t <= 7; t++) {
      var v = base + t - 1, list = [];
      for (var sq = 0; sq < 90; sq++) {
        if (out[sq] === v) list.push({ sq: sq, conf: conf ? (conf[sq] || 0) : 1 });
      }
      var excess = list.length - LIM[t];
      if (excess <= 0) continue;
      list.sort(function (x, y) { return x.conf - y.conf; });
      for (var k = 0; k < excess; k++) {
        var cell = list[k];
        if (v === 1 || v === 8) continue;              // 将帅绝不删
        var alt = 0;
        var cand = ranked && ranked[cell.sq];
        if (cand) {
          for (var ri = 0; ri < cand.length; ri++) {
            var a2 = cand[ri];
            if (!a2 || a2 === v) continue;
            if ((a2 <= 7) !== (side === 0)) continue; // 阵营必须一致
            var at = a2 <= 7 ? a2 : a2 - 7;
            var n2 = 0;
            for (var z = 0; z < 90; z++) if (out[z] === a2) n2++;
            if (n2 < LIM[at]) { alt = a2; break; }
          }
        }
        if (!alt && dropped >= MAX_DROP) continue;
        out[cell.sq] = alt;
        if (alt) replaced++; else dropped++;
        repaired++;
      }
    }
  }
  return { codes: out, repaired: repaired, replaced: replaced, dropped: dropped };
}

/* 2.0.0 换局重锚门槛：与锚盘差异小于这个数、又不成一步棋结构，
   一律判为模板噪声直接丢弃。16:00 日志里首帧 diff=4 就触发 reseat，
   把学习刚锚定的标准开局换成错误盘面，是「新对局识别不了」的帮凶。 */

module.exports = {
  PC2FEN_TABLE,
  flipGrid,
  flipCodes,
  codesToBoardFen,
  boardFenToCodes,
  validateCodes,
  codesUsable,
  codesLegal,
  codesPositionPlausible,
  codesEngineSafe,
  stepIsRuleLegal,
  enumerateAdvance,
  countCodesDiff,
  countOccupancyDiff,
  repairCodesQuota
};
