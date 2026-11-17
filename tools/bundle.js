'use strict';
/*
 * 打包器：把 src/ 下的 CommonJS 模块打成单个 IIFE，
 * 让 iOS 的 JavaScriptCore 一句 evaluateScript 就能用，无需 require。
 *
 * 输出：dist/engine.js   暴露全局 JJEngine
 * 用法：node tools/bundle.js
 */
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'src');
const OUT_DIR = path.join(__dirname, '..', 'dist');

/* 2.1.0：JS 只做视觉识别与状态机。搜索已迁到 Pikafish
   （2.1.52 起在 dylib 进程内跑，ObjC 侧 JJPikafish），
   cst/eval、cst/search、cst/book 已彻底删除，不再打包。
   cst/position + cst/notation 保留：process 里「检测到走法」的中文记谱
   仍由它们产出（不依赖搜索器）。 */
const ENTRY_FILES = [
  'cst/constants',
  'cst/position',
  'cst/notation',
  'vision/templates',
  'vision/recognizer',
  'vision/tracker'
];

// 模块 id -> 源码
const sources = new Map();

function normId(fromId, reqPath) {
  // 归一化相对路径
  const fromDir = path.posix.dirname(fromId);
  let p = path.posix.normalize(path.posix.join(fromDir, reqPath));
  // 去掉前导 './'
  p = p.replace(/^\.\//, '');
  return p;
}

function readModule(id) {
  if (sources.has(id)) return;
  const file = path.join(SRC, id + '.js');
  if (!fs.existsSync(file)) throw new Error('模块不存在: ' + file);
  const code = fs.readFileSync(file, 'utf8');
  sources.set(id, code);
  // 递归解析依赖
  const re = /require\(\s*['"]([^'"]+)['"]\s*\)/g;
  let m;
  while ((m = re.exec(code)) !== null) {
    const dep = normId(id, m[1]);
    // 允许省略 .js —— 生成器与 recognizer 里的写法都是 './templates.js'
    if (sources.has(dep) || fs.existsSync(path.join(SRC, dep + '.js'))) { readModule(dep); continue; }
    const stripped = dep.replace(/\.js$/, '');
    readModule(stripped);
  }
}

for (const f of ENTRY_FILES) {
  const id = f.replace(/\.js$/, '');
  readModule(id);
}

// 生成模块表
let out = '';
out += '/* ============================================================\n';
out += ' *  JJ象棋 辅助引擎内核 —— 单文件打包\n';
out += ' *  目标运行环境: iOS JavaScriptCore / Node / 浏览器\n';
out += ' *  生成时间: ' + new Date().toISOString() + '\n';
out += ' *  模块数: ' + sources.size + '\n';
out += ' * ============================================================ */\n';
out += '(function (global) {\n';
out += "'use strict';\n";
out += 'var __modules = {};\n';
out += 'var __cache = {};\n';

for (const [id, code] of sources) {
  out += '\n/* ---- ' + id + ' ---- */\n';
  out += '__modules[' + JSON.stringify(id) + '] = function (module, exports, require) {\n';
  out += code;
  out += '\n};\n';
}

out += `
function __require(id) {
  if (__cache[id]) return __cache[id].exports;
  var m = { exports: {} };
  __cache[id] = m;
  var fn = __modules[id];
  if (!fn) throw new Error('模块未找到: ' + id);
  fn(m, m.exports, function (p) { return __require(__resolve(id, p)); });
  return m.exports;
}

function __resolve(fromId, reqPath) {
  var parts = fromId.split('/');
  parts.pop();
  var segs = reqPath.split('/');
  for (var i = 0; i < segs.length; i++) {
    if (segs[i] === '.' || segs[i] === '') continue;
    if (segs[i] === '..') parts.pop();
    else parts.push(segs[i]);
  }
  return parts.join('/');
}

var C = __require('cst/constants');
var POS = __require('cst/position');
var NOTE = __require('cst/notation');
var REC = __require('vision/recognizer');
var TRK = __require('vision/tracker');

/* ============================================================
 *  一站式接口 —— 给 iOS / ObjC 调用
 * ============================================================ */

/* ============================================================
 *  棋盘朝向处理
 *  用户执红时红子在下（标准朝向），执黑时 JJ象棋 会翻转棋盘、黑子在下。
 *  引擎内部统一用「红在下」的标准坐标，所以画面翻转时要翻回来。
 * ============================================================ */

/** 上下翻转一张棋子编码表 */
function flipPieceMap(map) {
  var out = new Array(90).fill(0);
  for (var sq = 0; sq < 90; sq++) {
    var v = map[sq];
    if (!v) continue;
    var r = (sq / 9) | 0, c = sq % 9;
    out[(9 - r) * 9 + c] = v;
  }
  return out;
}

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
 *   - 变化格数过多（>6）或找不到一步棋结构 → 整帧丢弃。
 * 这样每帧落地的 codes 都严格由「锚盘 + 一步棋」生成，模板抖动再也带不偏盘面。
 *
 * @returns {{changed:number, move:object|null, noise:Array}}
 */
function analyzeStepDiff(prev, cur) {
  var changed = [];
  for (var i = 0; i < 90; i++) {
    if ((prev[i] || 0) !== (cur[i] || 0)) changed.push(i);
  }
  if (changed.length === 0) return { changed: 0, move: null, noise: [] };
  var none = { changed: changed.length, move: null, noise: changed };
  if (changed.length > 6) return none;

  var best = null;
  for (var a = 0; a < changed.length; a++) {
    var from = changed[a];
    var piece = prev[from] || 0;
    if (!piece || (cur[from] || 0) !== 0) continue;
    for (var b = 0; b < changed.length; b++) {
      if (b === a) continue;
      var to = changed[b];
      if ((cur[to] || 0) !== piece) continue;
      var captured = prev[to] || 0;
      if (captured === piece) continue;
      // 不能吃己方棋子
      if (captured && ((captured <= 7) === (piece <= 7))) continue;
      var noise = changed.filter(function (x) { return x !== from && x !== to; });
      var cand = { from: from, to: to, piece: piece, captured: captured, noise: noise };
      if (!best || noise.length < best.noise.length) best = cand;
    }
  }
  if (!best) return none;
  return { changed: changed.length, move: best, noise: best.noise };
}

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
var JJ_RESEAT_MIN_DIFF = 8;
/* 连续被丢弃多少帧后，允许一次「大变化 + 双合法」盘面强制重锚，
   防止中途进对局时 3 帧稳定条件永远凑不齐而卡死。 */
var JJ_RESEAT_REJECT_LIMIT = 12;

/* ============================================================
 *  全局会话状态（单例）
 * ============================================================ */
var session = {
  recognizer: null,
  tracker: null,
  corners: null,
  lastFen: '',
  lastResult: null,
  pending: false,
  flipped: false,          // true = 黑在下（用户执黑）
  lastGridHash: 0,
  gridStable: 0,
  lastBoardFen: '',        // 上一帧的棋盘部分（用于判断局面是否变化）
  sideToMoveNow: 'red',    // 当前该谁走
  // 1.1.44 盘面状态锚定：所有落地局面都由「锚盘 + 一步棋」生成
  anchorCodes: null,       // 上一稳定盘面（引擎坐标，红在下）
  anchorFen: '',           // 锚盘棋盘 FEN
  prevAnchorFen: '',       // 走子前盘面（中文记谱用）
  anchorFlipped: false,    // 建锚时的画面朝向
  openingAnchor: null,     // 开局学习成功时记下的标准盘面
  reseatPrev: null,        // 换局候选：上一帧 codes（做帧间差异比较）
  reseatCount: 0,
  anchorRejected: 0,       // 连续被丢弃的噪声帧
  reseatDone: 0,           // 本帧刚完成换局重锚（诊断输出后置 0）
  lastMoveText: '',        // 最近一步的 UCCI，供日志/HUD 诊断
  // 2.0.0 红先黑后：JJ 象棋「由执红棋的一方先走，双方轮流走一步」。
  // movePly = 本局已发生的走子数；偶数轮到红(w)、奇数轮到黑(b)。
  // 我方执黑时开局 ply=0 归对方先走，此时不出建议（用户明确要求）。
  movePly: 0,
  plyGuessed: 0,           // 中途进对局时轮次只能假设，日志可追溯
  newGame: 0               // 本帧识别到「回到标准开局」并已重锚
};

var JJEngine = {
  version: '2.1.0',
  /* 2.1.58：开局匹配滤波对齐（alignGridToOpening）。标记必须变：
     容器里那份 engine.js 只认「缺当前标记 → 覆盖升级」，标记不变 = 2.1.57
     的旧脚本一直被用下去，新对齐逻辑根本跑不到。 */
  featureMark: 'pikafishNative2159',
  C: C,

  /** 初始化 / 更新四点标定  corners = [[x,y],[x,y],[x,y],[x,y]] */
  setCorners: function (corners) {
    session.corners = corners;
    if (!session.recognizer) {
      session.recognizer = new REC.BoardRecognizer({ corners: corners, enableLowConfRefine: true });
    } else {
      session.recognizer.corners = corners.map(function (p) { return [p[0], p[1]]; });
    }
    return true;
  },

  /** 重置到指定局面（默认开局）。keepAnchor=true 用于 process 内部首次建 tracker，
      不能把 learnBoard 刚建立的开局锚盘一起清掉。 */
  reset: function (fen, keepAnchor) {
    session.tracker = new TRK.MoveTracker(fen || C.START_FEN);
    session.lastFen = session.tracker.fen;
    session.lastResult = null;
    session.lastDispatchedFen = '';
    session.lastGridHash = 0;
    session.gridStable = 0;
    if (!keepAnchor) {
      session.anchorCodes = null;
      session.anchorFen = '';
      session.openingAnchor = null;
      session.lastBoardFen = '';
      session.lastRawFen = '';
    }
    // 逐格「上一稳定值」也清掉，否则换局后残留上一局的棋子
    session.stableCodes = null;
    session.lowStreak = null;
    session.lowConfCount = 0;
    // 稳定判定和朝向投票也要清，否则换一局后会被上一局的哈希/投票带偏
    session.lastCodesHash = -1;
    session.codesStable = 0;
    session.legalStreak = 0;
    session.illegalStreak = 0;
    session.orientVote = null;
    session.orientCount = 0;
    session.reseatPrev = null;
    session.reseatCount = 0;
    session.reseatDone = 0;
    session.anchorRejected = 0;
    session.prevAnchorFen = '';
    session.lastMoveText = '';
    if (!keepAnchor) {
      session.lastBoardFen = '';
      session.lastRawFen = '';
      session.movePly = 0;
      session.plyGuessed = 0;
      session.newGame = 0;
    }
    return session.tracker.fen;
  },

  /** 在开局局面状态下学习棋盘背景 */
  learnBoard: function (pixels, w, h) {
    if (!session.recognizer) throw new Error('未标定');

    /* 2.0.1：一次失败的重标定（在中局画面点自动标定 / 四角点歪）不能污染
       已经收敛的会话。16:43 真机日志：verifyDiff 18→50 的失败学习照样改了
       session.flipped 和 recognizer.bgModel，把开局锚定的判据带偏，
       随后 legalNow=0 / skipReason=illegal 无限循环。 */
    var prevFlipped = session.flipped;
    var prevBgModel = session.recognizer.bgModel;
    var prevTemplates = session.recognizer.templates;   // 自举失败要能退回去

    var stats = session.recognizer.sampleAll(pixels, w, h, true);
    session.recognizer.learnBackground(stats, []);
    /* 诊断快照：失败分支会把 bgModel 回滚成 prevBgModel（通常是 null），
       直接读就成了 -1，看不出这一帧到底算出了什么阈值。
       真机日志里 warmTh=-1 就是这么来的，害得「背景模型没学到」看起来像根因。 */
    var bgSnap = session.recognizer.bgModel ? Object.assign({}, session.recognizer.bgModel) : null;

    var startMap = TRK.startPieceMap();

    function compare(a, b) {
      var d = 0;
      for (var i = 0; i < 90; i++) if (a[i] !== b[i]) d++;
      return d;
    }

    // ★ 朝向判定：用「颜色分类」而不是「翻转标签再学一遍」。
    //   为什么不能用模板：模板的红黑是靠标签给的，标签一翻，识别结果也跟着翻，
    //   两边永远打平（实测 diffNormal=0 且 diffFlipped=0，完全分不出来）。
    //   颜色分类只看像素本身（棋子暖色、棋盘冷色；红字发红、黑字不发红），
    //   和标签无关，才是可靠的物理判据。
    var colorCls = null;
    try { colorCls = session.recognizer.classifyByColor(stats); } catch (e) { colorCls = null; }

    var bRed = 0, bBlk = 0, tRed = 0, tBlk = 0;
    if (colorCls) {
      for (var c = 0; c < 9; c++) {
        var vb = colorCls.grid[9 * 9 + c];
        if (vb === 1) bRed++; else if (vb === 2) bBlk++;
        var vt = colorCls.grid[0 * 9 + c];
        if (vt === 1) tRed++; else if (vt === 2) tBlk++;
      }
    }

    // 手机屏幕上「棋盘最下方」永远是自己这边：
    //   下排红多 → 我执红（红在下）
    //   下排黑多 → 我执黑（JJ象棋 会翻转棋盘）
    // 上下都判不出来时，退回「谁在下方看谁」，再不行默认红。
    var flipped = false;
    if (colorCls) {
      if (bBlk > bRed + 2) {
        flipped = true;                    // 下排明显是黑
      } else if (bRed > bBlk + 2) {
        flipped = false;                   // 下排明显是红
      } else {
        // 下排看不清，用上排反推
        flipped = (tRed > tBlk + 2);
      }
    }
    session.flipped = flipped;

    /* ★★ 2.1.57 模板自举：只在这一帧确实是标准开局时才裁模板 ★★
     *
     * 历史包袱：2.1.x 之前试过「用第一帧当标准开局贴标签」，用户中途进中局时
     * 标签全错（车标成马、炮标成兵），于是 FEN 永远是开局 —— 所以后来改成
     * 「模板离线从参考截图生成、内置进引擎，和当前帧无关」。
     * 但这条路的代价是：模板与真机像素不同源（象牙白 (243,203,149) vs 木色棋盘
     * (199,167,112)，抗锯齿/色温/缩放全不同），模板分恒低，整盘棋子被丢空。
     *
     * 参考 64922/xiangqi-advisor 的解法：标准开局恰好含全部 14 种棋子且位置已知，
     * 所以模板完全可以现场裁 —— 同源像素，归一化后自动对齐亮度和色调。
     * 它绕开「标签全错」的办法是加一道闸门：先确认这一帧就是开局。
     *
     * 我们的闸门不依赖兵种，只比「哪些格有子」：用刚算出的亮度模型得到占位图，
     * 和标准开局的 32 个位置逐格比对，差 ≤4 格才贴标签。判错了就什么都不改，
     * 沿用旧模板（宁可不出箭头，也不能乱认）。 */
    var bootTried = 0, bootOccDiff = -1, bootMade = 0;
    if (colorCls && colorCls.grid && session.recognizer.calibrateBoardLevel) {
      bootTried = 1;
      var openingMap = TRK.startPieceMap();
      var pieceAtScreen = new Array(90);
      var occDiff = 0;
      for (var bi = 0; bi < 90; bi++) {
        var stdIdx = flipped ? ((9 - ((bi / 9) | 0)) * 9 + (8 - (bi % 9))) : bi;
        var lbl = openingMap[stdIdx] || 0;
        pieceAtScreen[bi] = lbl;
        var hasOnScreen = (colorCls.grid[bi] !== 0);
        var hasInOpening = (lbl !== 0);
        if (hasOnScreen !== hasInOpening) occDiff++;
      }
      bootOccDiff = occDiff;
      /* 只差 4 格以内才认：允许高亮圈、被手指压住、渲染抖动这类局部误差。
         开局有 32 子 / 58 空，中局占位差一定会远超 4，闸门足够严。 */
      if (occDiff <= 4) {
        try {
          session.recognizer.learnTemplates(stats, pieceAtScreen);
          bootMade = 1;
        } catch (eBoot) { bootMade = 0; }
      }
    }

    // 验证：用（可能刚自举的）模板识别同一帧，和标准开局比（翻转时先翻回标准坐标）
    var clsV = session.recognizer.classify(stats);
    var verifyDiff = 999;
    if (clsV && clsV.codes) {
      var got = flipped ? flipCodes(clsV.codes) : clsV.codes;
      verifyDiff = compare(got, startMap);
    }
    var ok = (verifyDiff <= 8);
    /* 失败时把朝向与背景模型原样还回去：锚盘 / openingAnchor / movePly
       本来就只在 ok 分支里写，这里补上另外两个会被顺手改掉的字段。 */
    var calibRejected = ok ? 0 : 1;
    if (!ok) {
      session.flipped = prevFlipped;
      session.recognizer.bgModel = prevBgModel;
      /* 自举出来的模板同样要退回去：只有「自举完还认不对」说明这次贴的标签
         有问题（占位差 ≤4 但确实不是开局），继续用它只会把后面的帧全带错。 */
      if (bootMade) session.recognizer.templates = prevTemplates;
    }

    // ---- 诊断：verifyDiff 到底错在哪几格 ----
    // 只改 engine.js 就能生效（App 容器里的那份可热替换），不用重新编译 dylib。
    // mismatch 格式 "格号:识别值/开局应有值"，用来区分「判空」「红黑反」「兵种错」。
    var gotCodes = clsV && clsV.codes ? clsV.codes : null;
    var chkCodes = gotCodes ? (flipped ? flipCodes(gotCodes) : gotCodes) : null;
    var mismatch = [];
    if (chkCodes) {
      for (var mi = 0; mi < 90; mi++) {
        if (chkCodes[mi] !== startMap[mi]) mismatch.push(mi + ':' + chkCodes[mi] + '/' + startMap[mi]);
      }
    }
    var gotFen = chkCodes ? codesToBoardFen(chkCodes) : '';
    var redN = 0, blkN = 0;
    if (gotCodes) {
      for (var ci = 0; ci < 90; ci++) {
        var cv = gotCodes[ci];
        if (cv >= 1 && cv <= 7) redN++; else if (cv >= 8) blkN++;
      }
    }
    /** 某一行 9 格的像素特征均值：区分「采样网格偏了」和「颜色判据错」 */
    function rowProbe(row) {
      var sum = { warm: 0, red: 0, dark: 0, ink: 0, redInk: 0, darkInk: 0 };
      for (var c2 = 0; c2 < 9; c2++) {
        var st = stats[row * 9 + c2];
        if (!st) continue;
        sum.warm += st.warmR || 0; sum.red += st.redR || 0; sum.dark += st.darkR || 0;
        sum.ink += st.inkR || 0; sum.redInk += st.redInkR || 0; sum.darkInk += st.darkInkR || 0;
      }
      for (var k in sum) sum[k] = Math.round(sum[k] / 9 * 1000) / 1000;
      return sum;
    }

    var learned = bgSnap ? 1 : 0;
    var warmTh = bgSnap ? bgSnap.warmThreshold : -1;

    /* ---- 2.1.56 诊断：把 90 格的「墨迹 / 暖色 / 模板分 / 识别值」压成一条串 ----
     * 真机 verifyDiff=32 恰好等于开局子数，说明整盘棋子被判空。仅凭这一点
     * 分不清是「没采到墨迹」（阈值问题）还是「网格偏了」（几何问题），
     * 所以这里按格给三码：
     *   i = 墨迹占比 inkR*20（0~9，9 就是 0.45 以上）
     *   w = 暖色占比 warmR*10
     *   s = 模板分 conf*2
     * 再附 90 个识别值（36 进制）。整条 360 字符，一条日志就能定位。
     */
    var ls = session.recognizer.lastStats || {};
    var dConf = (clsV && clsV.conf) ? clsV.conf : null;
    var diagI = '', diagW = '', diagS = '', diagL = '', codes36 = '';
    for (var dq = 0; dq < 90; dq++) {
      var ds = stats[dq];
      var dCode = chkCodes ? chkCodes[dq] : (gotCodes ? gotCodes[dq] : 0);
      codes36 += (dCode || 0).toString(36);
      if (!ds || !ds.n) { diagI += '·'; diagW += '·'; diagS += '·'; diagL += '·'; continue; }
      var vI = Math.min(9, Math.round((ds.inkR || 0) * 20));
      var vW = Math.min(9, Math.round((ds.warmR || 0) * 10));
      var vS = dConf ? Math.min(9, Math.round((dConf[dq] || 0) * 2)) : 0;
      /* 2.1.57：亮度图，一格一字符 = meanL/10（36 进制，0~35 即 L 0~350）。
         判据现在全靠它：暗子约 8~9、木色棋盘约 15~18、亮子约 20~23。
         若棋盘格和棋子挤在同一段数字里，说明这对皮肤对比度不够，得换判据。 */
      var vL = Math.max(0, Math.min(35, Math.round((ds.meanL || 0) / 10)));
      diagL += vL.toString(36);
      diagI += String(vI); diagW += String(vW); diagS += String(vS);
    }
    /* 棋盘外接框的宽高比：标准河盘 8 列 9 行 = 0.889。
       真机自动标定给出过 0.94，说明四角落到了木框上，格点必然整体错位。 */
    var gridAspect = 0;
    try {
      var gc = session.corners || session.recognizer.corners;
      if (gc && gc.length === 4) {
        var gW = ((gc[1][0] - gc[0][0]) + (gc[2][0] - gc[3][0])) / 2;
        var gH = ((gc[3][1] - gc[0][1]) + (gc[2][1] - gc[1][1])) / 2;
        gridAspect = gH > 0.5 ? Math.round(gW / gH * 1000) / 1000 : 0;
      }
    } catch (eA) { gridAspect = 0; }

    // 【1.1.44 开局锚定】学习成功的画面就是标准开局。模板在黑方底线右侧四格
    // 会稳定认错（15:10 日志 mismatch="5:11/9 6:12/10 7:14/11 8:10/12"），
    // 过去只是把 mismatch 记进日志，随后每帧继续拿错误结果重算引擎。
    // 现在直接把标准开局写成基线：后续 process 只允许「锚盘 + 一步棋」，
    // 这四格从此不会被带偏，也不会再触发无意义的重算。
    if (ok) {
      var anchorEng = Array.prototype.slice.call(startMap);   // 引擎坐标（红在下）
      session.anchorCodes = anchorEng;
      session.anchorFen = codesToBoardFen(anchorEng);
      session.anchorFlipped = !!flipped;
      session.openingAnchor = anchorEng.slice();
      session.lastBoardFen = session.anchorFen;
      session.lastRawFen = session.anchorFen;
      session.lastFen = C.START_FEN;
      session.lastResult = null;
      session.lastDispatchedFen = '';
      session.reseatCount = 0;
      session.anchorRejected = 0;
      // 学习成功 = 一局新棋从标准开局开始，红方先走
      session.movePly = 0;
      session.plyGuessed = 0;
      // stableCodes 是屏幕坐标，供「低置信度沿用上一帧」用，也给正确基线
      session.stableCodes = flipped
        ? Array.prototype.slice.call(flipCodes(anchorEng))
        : anchorEng.slice();
    }

    return {
      learned: learned,
      warmThreshold: warmTh,
      templateCount: session.recognizer.templateCount || 0,
      verifyDiff: verifyDiff,
      ok: ok,
      isOpening: ok,
      calibRejected: calibRejected,
      flipped: session.flipped ? 1 : 0,
      mySide: session.flipped ? 'black' : 'red',
      diffNormal: verifyDiff,
      diffFlipped: flipped ? verifyDiff : -1,
      /* 2.1.56 采样几何与亮度：cell 约 137、radius 约 47 才算正常；
         gain 是 estimateGain 把整帧拉到模板亮度用的增益（0.55~1.9）。 */
      cell: Math.round((ls.cell || 0) * 10) / 10,
      radius: ls.radius || 0,
      gain: Math.round((ls.gain || 0) * 100) / 100,
      meanL: Math.round((function () {
        var t = 0, c = 0;
        for (var q = 0; q < 90; q++) { if (stats[q] && stats[q].n) { t += stats[q].meanL; c++; } }
        return c ? t / c : 0;
      })()),
      gridAspect: gridAspect,
      /* 2.1.57 亮度三峰模型：boardL 是棋盘底色中位亮度，[loTh, hiTh] 之间为空格。
         判读：暗子应 < loTh、亮子应 > hiTh；如果棋子都落在区间内，说明阈值不对。 */
      boardL: bgSnap ? Math.round(bgSnap.boardL) : -1,
      hiTh: bgSnap ? Math.round(bgSnap.hiTh) : -1,
      loTh: bgSnap ? Math.round(bgSnap.loTh) : -1,
      mad: bgSnap && bgSnap.mad ? Math.round(bgSnap.mad * 10) / 10 : -1,
      occludedN: redN + blkN,
      /* 2.1.57 模板自举：bootOccDiff 是与标准开局的占位数差（≤4 才会自举），
         bootMade=1 表示这一帧成功裁出了同源模板。 */
      bootTried: bootTried,
      bootOccDiff: bootOccDiff,
      bootMade: bootMade,
      tplCount: session.recognizer.templateCount || 0,
      diagI: diagI,
      diagW: diagW,
      diagS: diagS,
      diagL: diagL,
      codes36: codes36,
      bottomRed: bRed,
      bottomBlack: bBlk,
      topRed: tRed,
      topBlack: tBlk,
      gotFen: gotFen,
      redN: redN,
      blkN: blkN,
      mismatchCount: mismatch.length,
      mismatch: mismatch.join(' '),
      topProbe: rowProbe(0),
      bottomProbe: rowProbe(9)
    };
  },

  /**
   * 学习 + 四角独立自校准（一次调用完成，供 ObjC 在后台队列里跑）
   *
   * 为什么需要：手动标定的四角带梯形误差，纯平移 dx/dy 修不了。
   * 真机实测底行左 y1967 / 右 y1994，9 行累计差 27px，四角采样直接落到木色上，
   * 模板把残缺字形认成别的兵种（verifyDiff=16），进而被 codesLegal 判死。
   * REC.refineGrid 按双线性（含 u*v 交叉项）对 90 个格点做最小二乘拟合，
   * 能表达梯形，正好修这个。
   *
   * 性能：refineGrid 的邻域搜索量与格距平方成正比，全尺寸 1284x2778 要十几秒。
   * 先在 1/2 降采样图上拟合（约 1/4 耗时）再乘回 2，最后用 verifyDiff 仲裁，
   * 所以即使拟合不精确也不会比现状更差。
   *
   * @returns {object} learnBoard 的全部字段 + refine* 诊断字段
   */
  learnAndRefine: function (pixels, w, h, baseCorners) {
    /** 四角结果体检：位移不超限、四条边不塌缩 */
    function sane(a, b, lim, minEdge) {
      if (!b || b.length !== 4) return false;
      for (var i = 0; i < 4; i++) {
        if (!b[i] || !isFinite(b[i][0]) || !isFinite(b[i][1])) return false;
        if (Math.abs(b[i][0] - a[i][0]) > lim || Math.abs(b[i][1] - a[i][1]) > lim) return false;
      }
      var wt = b[1][0] - b[0][0], wb = b[2][0] - b[3][0];
      var hl = b[3][1] - b[0][1], hr = b[2][1] - b[1][1];
      return wt > minEdge && wb > minEdge && hl > minEdge && hr > minEdge;
    }
    function copy(src) {
      var o = {};
      for (var k in src) if (Object.prototype.hasOwnProperty.call(src, k)) o[k] = src[k];
      return o;
    }
    /** 2x 最近邻降采样：棋盘是大色块，最近邻足够，比 2x2 平均快一倍 */
    function halfPixels(px, w0, h0) {
      var nw = w0 >> 1, nh = h0 >> 1;
      var out = new Uint8ClampedArray(nw * nh * 4);
      for (var y = 0; y < nh; y++) {
        for (var x = 0; x < nw; x++) {
          var s = ((y * 2) * w0 + x * 2) * 4, d = (y * nw + x) * 4;
          out[d] = px[s]; out[d + 1] = px[s + 1]; out[d + 2] = px[s + 2]; out[d + 3] = 255;
        }
      }
      return { data: out, w: nw, h: nh };
    }

    var base = (baseCorners && baseCorners.length === 4) ? baseCorners : null;
    if (base) JJEngine.setCorners(base);

    /* ★ 2.1.58 开局匹配滤波对齐：先用「已知开局 32 个位置」对整帧像素反解真实网格，
       再进入 refineGrid / learnBoard。
       根因（真机 2.1.57 日志实锤）：手动四角天生 ±30px 手指误差，采样窗中心
       偏 20px+ 后 patch 只擦到棋子边缘，亮度只被拉低 20~30、仍落在空格区间内
       → 32 个子全判空（亮度图 90 格全 150~195、判有子=0）。
       对齐用开局 32 位偏离棋盘中位的总量做匹配滤波，红黑两个朝向取大；
       凑不出这套分布（中局/大厅）就什么都不改。 */
    var alignR = null;
    if (base && REC.alignGridToOpening) {
      try {
        var spmAl = TRK.startPieceMap();
        var opAl = [], emAl = [];
        for (var ai = 0; ai < 90; ai++) (spmAl[ai] ? opAl : emAl).push(ai);
        alignR = REC.alignGridToOpening(pixels, w, h, base, opAl, emAl);
        if (alignR && alignR.accepted && alignR.corners) {
          base = alignR.corners.map(function (p) { return [p[0], p[1]]; });
          JJEngine.setCorners(base);
        }
      } catch (eAl) { alignR = null; }
    }
    /** 把对齐诊断挂到返回值上（fast 路径与主路径共用） */
    function alignFields(o) {
      o.alignAccepted = alignR ? (alignR.accepted ? 1 : 0) : -1;
      o.alignAlready = (alignR && alignR.already) ? 1 : 0;
      o.alignOccHit = alignR ? alignR.occHit : -1;
      o.alignEmptyHit = alignR ? alignR.emptyHit : -1;
      o.alignIdOccHit = alignR ? alignR.idOccHit : -1;
      o.alignIdEmptyHit = alignR ? alignR.idEmptyHit : -1;
      o.alignShiftX = alignR ? Math.round(alignR.shiftX || 0) : 0;
      o.alignShiftY = alignR ? Math.round(alignR.shiftY || 0) : 0;
      o.alignScaleX = alignR ? Math.round((alignR.scaleX || 1) * 1000) / 1000 : 1;
      o.alignScaleY = alignR ? Math.round((alignR.scaleY || 1) * 1000) / 1000 : 1;
      return o;
    }

    var refined = null, err = '', tried = 0;
    /* ★ 2.1.59：对齐已采纳就不再跑 refineGrid。
       真机 2.1.57/58 日志实锤：refineGrid 的暖亮掩码在木色棋盘上整块命中，
       无先验拟合等于对噪声对齐（把格点从棋子上拖走几十像素）；而
       alignGridToOpening 有「开局 32 子」物理先验 + 严格闸门，可信度远高。
       两条路二选一，对齐赢的时候不能再让拟合把格点拖回去。 */
    if (base && !(alignR && alignR.accepted)) {
      tried = 1;
      try {
        var sm = halfPixels(pixels, w, h);
        var bs = base.map(function (p) { return [p[0] * 0.5, p[1] * 0.5]; });
        var rs = REC.refineGrid(sm.data, sm.w, sm.h, bs, 2);
        if (rs && sane(bs, rs, 30, 50)) {
          /* 真机采样点证明 x 方向本来就是准的：左边 99→95、右边 1194→1193，
             两条边几乎垂直；梯形误差全在 y（底行左 1967 / 右 1994）。
             而 refineGrid 会被棋盘外的暖色木框把 x 拉歪几十像素，
             所以 x 只采纳一个整体平移，y 才让四角独立。 */
          var shiftX = 0;
          for (var qi = 0; qi < 4; qi++) shiftX += rs[qi][0] * 2 - base[qi][0];
          shiftX = Math.max(-30, Math.min(30, shiftX / 4));
          var back = rs.map(function (p2, i2) {
            /* 顶边也有证据：#0 y797 / #8 y794，只差 3px，本来就是准的。
               拟合偶尔会被木框把顶边整体拉走几十像素，所以顶边只给 ±20，
               底边才允许 ±60（梯形误差集中在底行，右下角要修 ~27px）。 */
            var limY = (i2 < 2) ? 20 : 60;
            var dy = Math.max(-limY, Math.min(limY, p2[1] * 2 - base[i2][1]));
            return [base[i2][0] + shiftX, base[i2][1] + dy];
          });
          if (sane(base, back, 60, 100)) refined = back;
        }
      } catch (e2) { err = String(e2 && e2.message || e2); refined = null; }
    }

    var rRef = null, dRef = 999, rBase = null, dBase = null;
    if (refined) {
      JJEngine.setCorners(refined);
      try { rRef = JJEngine.learnBoard(pixels, w, h); dRef = rRef.verifyDiff; }
      catch (e3) { rRef = null; dRef = 999; }
      /* 拟合后已经收敛（ok 的阈值就是 8），直接用，省掉基准帧那次全量学习 */
      if (rRef && dRef <= 8) {
        var fast = copy(rRef);
        fast.refineTried = tried;
        fast.refineAccepted = 1;
        fast.diffBase = null;
        fast.diffRefined = dRef;
        fast.diffBefore = null;
        fast.diffAfter = dRef;
        fast.refineCorners = refined;
        fast.finalCorners = refined;
        fast.refineError = err;
        return alignFields(fast);
      }
    }

    if (base) JJEngine.setCorners(base);
    try { rBase = JJEngine.learnBoard(pixels, w, h); dBase = rBase.verifyDiff; }
    catch (e4) {
      return { verifyDiff: 999, ok: 0, templateCount: 0,
               finalCorners: base || session.corners || [], refineError: String(e4 && e4.message || e4) };
    }

    var accepted = (rRef && dRef < dBase) ? 1 : 0;
    if (accepted) {
      /* bgModel 已在 refined 那一帧学过，只需把 corners 切回去 */
      JJEngine.setCorners(refined);
    }
    var out = copy(accepted ? rRef : rBase);
    out.refineTried = tried;
    out.refineAccepted = accepted;
    out.diffBase = dBase;
    out.diffRefined = rRef ? dRef : null;
    out.diffBefore = dBase;
    out.diffAfter = accepted ? dRef : dBase;
    out.refineCorners = refined || null;
    out.finalCorners = accepted ? refined : (base || session.corners || []);
    out.refineError = err;
    return alignFields(out);
  },

  /** 清空学习结果，退回默认阈值模式（画面不是开局时的兜底） */
  skipLearning: function () {
    if (session.recognizer) {
      session.recognizer.bgModel = null;
      // 模板不能清空 —— 内置模板是离线从已知正确盘面生成的，
      // 清空后就只剩「纯颜色判断」，识别率会掉一大截。
      // 这里只是「重新装回内置模板」，等价于丢弃任何运行时学出来的模板。
      try {
        session.recognizer.templates = session.recognizer._buildBuiltinTemplates();
      } catch (e) { /* 保持原样 */ }
    }
    return { skipped: true };
  },

  /**
   * 自动检测棋盘四角
   * 棋盘是严格等间距的 9 竖 10 横网格，用边缘投影 + 等距约束就能定位，
   * 完全不需要用户手点。
   * @returns {Array<[number,number]>|null} [[左上],[右上],[右下],[左下]]，检测失败返回 null
   */
  autoDetectBoard: function (pixels, w, h) {
    try {
      var r = REC.autoDetectBoard(pixels, w, h);
      if (!r) return null;
      return [
        [r[0][0], r[0][1]],
        [r[1][0], r[1][1]],
        [r[2][0], r[2][1]],
        [r[3][0], r[3][1]]
      ];
    } catch (e) {
      return null;
    }
  },

  /**
   * 自动检测 + 用棋子实测校验，校验不过就明确报不通过。
   *
   * 为什么要校验：边缘投影找到的线间距可能偏小 10~20%（实测格高 59.9 vs 实际 73.3），
   * 这种误差逐行累积，到第 7 行采样点已经偏了整整一格，炮就被采到上面空格去了。
   * 检测本身没法自己发现自己错了，只能用「棋子应该落在交叉点上」来验证。
   *
   * 校验方法：网格算出来后，采 90 个格子，统计「暖色盘面」的格子数
   * 和它们到最近交叉点的偏移。棋子数太少或偏移太大 → 判定网格不可信。
   */
  /**
   * 自动检测的调试信息：初始边缘投影四角 / 棋子反推结果 / 最终走了哪条路
   */
  autoDetectDebug: function (pixels, w, h) {
    var r = null;
    try { r = JJEngine.autoDetectBoard(pixels, w, h); } catch (e) { return { error: String(e && e.message || e) }; }
    return { corners: r, debug: REC.autoDetectBoard.lastDebug || null };
  },

  autoDetectBoardChecked: function (pixels, w, h) {
    var corners = JJEngine.autoDetectBoard(pixels, w, h);
    if (!corners) return { ok: false, reason: 'no_grid' };

    // 用这组角采样，看有多少格是「有棋子盘面」
    JJEngine.setCorners(corners);
    if (!session.recognizer) return { ok: false, reason: 'no_recognizer' };
    var stats;
    try { stats = session.recognizer.sampleAll(pixels, w, h, false); } catch (e) { return { ok: false, reason: 'sample_fail' }; }

    var pieceCells = 0;
    var warmSum = 0;
    for (var i = 0; i < 90; i++) {
      var s = stats[i];
      if (!s) continue;
      var warmR = s.warmR || 0;
      if (warmR >= 0.30) { pieceCells++; warmSum += warmR; }
    }
    return {
      ok: true,
      corners: corners,
      pieceCells: pieceCells,
      avgWarm: pieceCells ? (warmSum / pieceCells) : 0,
      // 中局一般 20~32 个子，低于 8 个基本就是网格歪了
      plausible: pieceCells >= 8
    };
  },

  /** 自动检测并直接应用（一步到位） */
  autoCalibrate: function (pixels, w, h) {
    var r = JJEngine.autoDetectBoard(pixels, w, h);
    if (!r) return { ok: false };
    /* ★ 2.1.58 自动检测四角必须先过「开局匹配滤波」确认再落地。
       refineByPieces 的暖亮圆盘掩码在木色皮肤上整块棋盘都命中
       （R-B=87、L=189 全过），等于对噪声对齐 —— 以前直接 set + 持久化，
       一组被木纹带歪的网格点会一直用到下次手动标定。
       现在用已知开局 32 个位置复核：对不齐（或画面根本不是开局棋盘）
       就拒绝，宁可让用户重试，也不落一组错点。 */
    if (REC.alignGridToOpening) {
      var spmAc = TRK.startPieceMap();
      var opAc = [], emAc = [];
      for (var ai = 0; ai < 90; ai++) (spmAc[ai] ? opAc : emAc).push(ai);
      var alignAc = null;
      try { alignAc = REC.alignGridToOpening(pixels, w, h, r, opAc, emAc); } catch (eAc) {}
      if (alignAc) {
        if (alignAc.accepted && alignAc.corners) {
          JJEngine.setCorners(alignAc.corners);
          return { ok: true, corners: alignAc.corners, align: alignAc };
        }
        if (alignAc.already) {
          JJEngine.setCorners(r);
          return { ok: true, corners: r, align: alignAc };
        }
        return { ok: false, reason: 'no_pieces', align: alignAc, corners: r };
      }
    }
    JJEngine.setCorners(r);
    return { ok: true, corners: r };
  },

  /** 调试：直接输出单帧的兵种识别结果（不走稳定性门槛、不写 session） */
  classifyBoard: function (pixels, w, h) {
    if (!session.recognizer) return null;
    var stats = session.recognizer.sampleAll(pixels, w, h, true);
    var cls = null;
    try { cls = session.recognizer.classify(stats); } catch (e) { return { error: String(e && e.message || e) }; }
    if (!cls || !cls.codes) return { error: 'no_codes' };
    var codes = Array.prototype.slice.call(cls.codes);
    var redN = 0, blkN = 0, details = [];
    for (var i = 0; i < 90; i++) {
      var v = codes[i];
      if (!v) continue;
      if (v >= 1 && v <= 7) redN++; else blkN++;
      details.push([i, v]);
    }
    return {
      codes: codes,
      fen: codesToBoardFen(codes),
      redN: redN,
      blkN: blkN,
      valid: validateCodes(codes),
      usable: codesUsable(codes),
      occupied: details.length,
      details: details,
      conf: session.recognizer.lastConf ? Array.prototype.slice.call(session.recognizer.lastConf) : null,
      ranked: session.recognizer.lastRanked || null
    };
  },

  /**
   * 调试：对单格做半径/偏移扫描，看「换个采样窗口这一格会变成什么」
   * @param {number} sq 格子序号 0..89
   * @param {number} scale 半径倍率（相对默认 radius）
   * @param {number} dxF cell 单位的水平偏移
   * @param {number} dyF cell 单位的垂直偏移
   */
  debugCell: function (pixels, w, h, sq, scale, dxF, dyF) {
    var rec = session.recognizer;
    if (!rec) return null;
    var pts = rec.gridPoints();
    var cell = rec.cellSize(pts);
    var radius = Math.max(3, Math.round(cell * rec.cellRadiusRatio * (scale || 1)));
    var gain = rec.estimateGain(pixels, w, h, pts);
    var cx = pts[sq * 2] + (dxF || 0) * cell;
    var cy = pts[sq * 2 + 1] + (dyF || 0) * cell;
    var s = rec.sampleCell(pixels, w, h, cx, cy, radius, true, gain);
    var m = rec.matchCell(s);
    return {
      key: m.key, score: m.score, warmRatio: m.warmRatio,
      alts: (m.alts || []).map(function (a) { return [a.key, Math.round(a.score * 1000) / 1000]; }),
      inkR: Math.round((s.inkR || 0) * 1000) / 1000,
      warmR: Math.round((s.warmR || 0) * 1000) / 1000,
      skipped: s.skipped || 0,
      cell: cell, radius: radius
    };
  },

  /**
   * 把一步 UCCI 着法翻译成中文着法 + 起止格
   * （2.1.0：检测到的走法用它出中文记谱；引擎建议的中文记谱由
   *  ObjC 侧 JJMoveCodec 原生产出，不经过这里）
   */
  moveInfo: function (fen, ucci) {
    try {
      var pos = new POS.Position(fen);
      var mv = C.ucciToMv(ucci);
      if (!mv) return { chinese: '', from: -1, to: -1 };
      return {
        chinese: NOTE.mvToChinese(pos.board, mv, pos.side),
        from: C.mvFrom(mv),
        to: C.mvTo(mv)
      };
    } catch (e) {
      return { chinese: '', from: -1, to: -1 };
    }
  },

  /** 调试：切换兵种打分方式 'dot' | 'f1' | 'mass' | 'mass:0.5'（后者同时设惩罚系数） */
  setScoreMode: function (mode) {
    if (!session.recognizer) return false;
    var parts = String(mode).split(':');
    session.recognizer.scoreMode = parts[0];
    if (parts.length > 1) session.recognizer.massK = parseFloat(parts[1]);
    return session.recognizer.scoreMode === parts[0];
  },

  /** 调试：输出 90 个格子的原始特征，用来定位「哪一格为什么判错」 */
  debugSample: function (pixels, w, h) {
    if (!session.recognizer) return null;
    var stats = session.recognizer.sampleAll(pixels, w, h, true);
    var out = [];
    for (var i = 0; i < 90; i++) {
      var s = stats[i] || {};
      out.push([
        i,
        Math.round((s.inkR || 0) * 1000) / 1000,
        Math.round((s.warmR || 0) * 1000) / 1000,
        Math.round((s.redInkR || 0) * 1000) / 1000,
        Math.round((s.darkInkR || 0) * 1000) / 1000,
        Math.round((s.redR || 0) * 1000) / 1000,
        s.skipped || 0
      ]);
    }
    return out;
  },

  /**
   * 主流程：喂一帧 RGBA 像素，返回识别结果（2.1.0 起只识别、不搜索）
   *
   * 契约变化：suggest/scoreText/depth 等搜索字段全部移除。轮到我方且盘面
   * 可信时输出 needSearch=1 + searchFen（引擎坐标 FEN，红在下 + w/b 走子方），
   * 由 ObjC 侧 JJPikafish 拿去问独立进程 Pikafish；局面没变就输出 needSearch=0，
   * 上层沿用上一次的引擎结论（原生缓存）。
   * @param {Uint8ClampedArray|Uint8Array} pixels RGBA
   * @param {number} w
   * @param {number} h
   * @param {object} opts { live }
   * @returns {object}
   */
  process: function (pixels, w, h, opts) {
    opts = opts || {};
    if (!session.recognizer) throw new Error('未标定');
    // 首次建 tracker 时保留 learnBoard 刚建立的开局锚盘
    if (!session.tracker) JJEngine.reset(null, true);

    // 模板匹配需要 patch，所以这里必须采
    var stats = session.recognizer.sampleAll(pixels, w, h, true);
    var cls = session.recognizer.classify(stats);

    // ★ 逐格置信度 + 保留上一稳定值
    //
    // 为什么需要：JJ象棋 在落子瞬间会把刚走的棋子放大 1.25 倍并偏移十几像素
    // （还有红圈/白圈/绿点），那一两帧的模板分数会掉到 0.2 左右（正常 1.3~2.7），
    // 于是红仕被判成红兵。这些效果「只在特定时候出现」，是瞬时干扰。
    //
    // 做法：分数够高的格子直接采信；分数太低的格子沿用上一帧的稳定值，
    // 连续多帧都低才认这一次的结果（避免被一个动画帧永久带偏）。
    var LOWCONF = 0.55;
    // 实时模式（录屏 + 浮窗）：本帧结果直接采信。
    //
    //   为什么要单独一条：稳定值机制本来是为了挡落子动画的一两帧干扰，
    //   但实时模式下棋盘会一直停在「对方刚走完」的状态里 ——
    //   那几格刚好因为放大/高亮圈分数偏低，就一直沿用旧值，
    //   表现就是「对方走了，浮窗里没变」。所以在实时模式下不搞保留。
    var liveMode = !!(opts && opts.live);
    var prevCodes = session.stableCodes;
    var mergedCodes = new Array(90);
    var lowConfCount = 0;
    for (var sm = 0; sm < 90; sm++) {
      // ★ 被浮窗盖住的格子：整格作废，保留上一帧的值
      //
      //   浮窗会一起被截进截图里，那几格采到的其实是浮窗画面（我们自己的小棋盘），
      //   拿去识别就会凭空多出棋子、还把网格拉偏 —— 历史上这就是「浮窗挡棋盘」翻车的根源。
      //   现在浮窗自带一圈洋红边框（App 端画的），引擎按边框精确算出盖住了哪几格，
      //   这几格保留上一帧的值；没有上一帧就留空（宁可少一个子，也不要凭空多一个）。
      if (session.recognizer && session.recognizer.occluded && session.recognizer.occluded[sm]) {
        mergedCodes[sm] = (prevCodes && prevCodes[sm] !== undefined && prevCodes[sm] !== null)
          ? prevCodes[sm] : 0;
        session.lowStreak = session.lowStreak || new Array(90).fill(0);
        session.lowStreak[sm] = 0;
        continue;
      }
      var raw = cls.codes ? cls.codes[sm] : 0;
      var conf = cls.conf ? (cls.conf[sm] || 0) : 1;
      if (liveMode) { mergedCodes[sm] = raw; continue; }
      var st = stats[sm];
      var warm = st ? (st.warmR || 0) : 0;
      var okCell;
      if (!raw) {
        // 【1.1.44】判空原来要求 warm<0.12，但木色棋盘空格的 warmR 本来就有
        // 0.3~0.5，这条几乎永远不成立 → 走子的起点被「沿用上一帧」填回旧棋子，
        // 一步棋永远凑不出来（离线回归第 4 帧复现）。改成看模板分数：
        // 分数低 = 这格真的没字形，判空可信；分数高却判空才是矛盾帧。
        okCell = (conf < 0.10) || (warm < 0.12);
      } else {
        okCell = (conf >= LOWCONF);
      }
      if (!okCell) lowConfCount++;
      if (okCell || !prevCodes || prevCodes[sm] === undefined || prevCodes[sm] === null) {
        mergedCodes[sm] = raw;
        session.lowStreak = session.lowStreak || new Array(90).fill(0);
        session.lowStreak[sm] = 0;
      } else if ((session.lowStreak[sm] = (session.lowStreak[sm] || 0) + 1) >= 8) {
        // 连续 8 帧都不确定，就接受新值，免得永远卡在旧局面上
        mergedCodes[sm] = raw;
        session.lowStreak[sm] = 0;
      } else {
        mergedCodes[sm] = prevCodes[sm];
      }
    }
    if (cls.codes) cls.codes = mergedCodes;
    session.lowConfCount = lowConfCount;

    // 1.1.43：裁掉超额的兵种，避免「一个兵种错 → 整盘判非法 → 永不出着法」。
    // 必须在 detectOrientation / codesHash / rawFen 之前，让全链路用同一份 codes。
    var quotaFix = { repaired: 0, replaced: 0, dropped: 0 };
    if (cls.codes) {
      var rankedNow = session.recognizer ? session.recognizer.lastRanked : null;
      quotaFix = repairCodesQuota(cls.codes, cls.conf, rankedNow);
      cls.codes = quotaFix.codes;
      mergedCodes = Array.prototype.slice.call(cls.codes);
      if (cls.grid) {
        for (var qz = 0; qz < 90; qz++) if (!cls.codes[qz]) cls.grid[qz] = 0;
      }
    }

    // 画面翻转时（用户执黑）翻回标准坐标，引擎内部一律「红在下」
    //
    // ★ 朝向改成每帧重判，不再只信 learnBoard 那一帧的结论。
    //   之前 session.flipped 只在 learnBoard 时定一次，之后永不更新：
    //   learnBoard 那一帧如果刚好没读准，或者你换了执红/执黑，
    //   朝向就一直错着，着法自然全是乱的（浮窗还会把「你执黑」写成「你执红」）。
    //   判据：看底部两行（第 8、9 行）以哪一方棋子为主 —— 玩家自己永远在下方。
    //   只有双方数量差 ≥3 才投票，且要连续 2 帧一致才改，避免中途抖动。
    (function detectOrientation(codes) {
      // ★ 朝向改用「走不出自己半场」的棋子投票，不再数底两行的颜色
      //
      // 老判据是「屏幕底两行哪种颜色多，哪种就是玩家」。这在开局没问题，
      // 但残局会直接反掉：「雨打芭蕉 编号:19」里黑方 5 个子已经压到红方底线，
      // 底两行黑 6 红 2，于是被判成「玩家执黑」——
      // 整盘翻面、引擎 FEN 全反，我方得分算出 -29999（自己被将死），着法全废。
      //
      // 帅/将出不了九宫（红帅只可能在下三行、黑将只可能在上三行），
      // 仕/士同样只在九宫，相/象过不了河 —— 这些都是「位置锁定」的棋子，
      // 拿它们投票，对方冲到哪都不会干扰。
      var s = 0;
      for (var i = 0; i < 90; i++) {
        var c = codes[i];
        if (!c) continue;
        var row = (i / 9) | 0;
        if (c === 1) s += (row >= 5 ? 6 : -6);          // 红帅在下方 → 画面正常
        else if (c === 8) s += (row <= 4 ? 6 : -6);     // 黑将在上方 → 画面正常
        else if (c === 2) s += (row >= 5 ? 2 : -2);     // 红仕只能在下方九宫
        else if (c === 9) s += (row <= 4 ? 2 : -2);
        else if (c === 3) s += (row >= 5 ? 1 : -1);     // 红相过不了河
        else if (c === 10) s += (row <= 4 ? 1 : -1);
      }
      var vote = null;
      if (s >= 3) vote = 'red';        // 红在下 → 我执红
      else if (s <= -3) vote = 'black'; // 红在上 → 我执黑
      if (!vote) {
        // 将帅都没认出来时，退回老办法（底两行颜色），聊胜于无
        var r2 = 0, b2 = 0;
        for (var rr = 8; rr <= 9; rr++) {
          for (var cc = 0; cc < 9; cc++) {
            var code2 = codes[rr * 9 + cc];
            if (code2 >= 1 && code2 <= 7) r2++; else if (code2 >= 8) b2++;
          }
        }
        if (b2 >= r2 + 3) vote = 'black';
        else if (r2 >= b2 + 3) vote = 'red';
        if (!vote) return;
      }
      if (vote === session.orientVote) {
        session.orientCount = (session.orientCount || 0) + 1;
      } else {
        session.orientVote = vote;
        session.orientCount = 1;
      }
      if (!session.orientSeen || (session.orientCount || 0) >= 2) {
        session.orientSeen = true;
        session.flipped = (vote === 'black');
      }
    })(cls.codes);

    var grid = session.flipped ? flipGrid(cls.grid) : cls.grid;

    // ============================================================
    // 【1.1.44 盘面状态锚定】乱指挥 + 卡顿的共同根因
    // ============================================================
    // 15:10 真机日志：模板在同一静态局面每帧给出 3~8 个不同格，FEN 从开局一路
    // 漂成「红车在黑方底线 / 黑卒在自己底线 / 炮变兵 / 红炮跑到黑方阵地」，于是
    //   ① 每帧 moveDetected=true → 每帧重跑 ENG.analyze → JS 线程满载 → 游戏卡顿；
    //   ② 引擎拿着垃圾盘面算 → 建议全是乱的。
    // 象棋每步只动一枚棋子。这里把本帧 codes 与锚盘比较，只接受「一步棋」：
    // 噪声帧整帧丢弃；合法一步则把其余抖动格用锚盘覆盖，再推进锚盘。
    // 落地 codes 永远是一盘真棋，盘面不变时引擎命中缓存、一次都不重算。
    var engCodes = session.flipped ? flipCodes(cls.codes) : cls.codes;
    var stepInfo = { changed: 0, move: null, noise: [] };
    var anchorRejected = 0;
    var anchor = session.anchorCodes;
    session.newGame = 0;

    /* 【2.0.0 新局识别】16:00 真机日志：换一局新棋后 12 分钟没有任何走法日志。
       旧架构只在「与锚盘差一步棋」时推进，新局开局盘面与上一局的中局锚盘
       相差十几格，既不满足一步结构、又因噪声帧锁死换局重锚 → 永久静默。
       学习阶段已把标准开局存进 openingAnchor；这里只要识别结果接近开局，
       且当前锚盘明显不是开局，就直接重置锚盘与轮次，一帧即可恢复。 */
    /* 判据必须看「占位」而不是兵种：开局走两步后与标准开局也只差 4 格，
       用 countCodesDiff<=4 会把正常走子误判成新局（离线回归 A4 实测）。
       真新局的 32 枚棋子位置全对，占位差为 0，只有兵种可能被模板认错。
       2.0.1：还必须同时满足「锚盘已离开开局」且「当前帧相对锚盘明显回退」。
       16:39 回归实测：只走一步（占位差恰好 2）时，旧判据的 movePly>0
       会让之后每一帧静止画面都 hit <=2 → newGame=1、锚盘退回开局、ply 归零，
       表现就是「走第一步后再也不跟着走」。 */
    if (session.openingAnchor && anchor && codesLegal(engCodes) &&
        countOccupancyDiff(session.openingAnchor, engCodes) <= 2 &&
        countOccupancyDiff(anchor, session.openingAnchor) > 0 &&
        countOccupancyDiff(anchor, engCodes) >= 2) {
      session.newGame = 1;
      anchor = session.openingAnchor.slice();
      session.anchorCodes = anchor;
      session.anchorFen = codesToBoardFen(anchor);
      session.anchorFlipped = !!session.flipped;
      session.movePly = 0;
      session.plyGuessed = 0;
      session.lastBoardFen = session.anchorFen;
      session.lastRawFen = session.anchorFen;
      session.lastFen = '';
      session.lastResult = null;
      session.lastDispatchedFen = '';
      session.prevAnchorFen = '';
      session.reseatCount = 0;
      session.reseatPrev = null;
      session.anchorRejected = 0;
    }

    if (!anchor) {
      // 没学过开局（中途进对局）：只有数量与位置都合理的盘面才配当锚盘
      if (codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
        anchor = Array.prototype.slice.call(engCodes);
        session.anchorCodes = anchor;
        session.anchorFen = codesToBoardFen(anchor);
        session.anchorFlipped = !!session.flipped;
        session.lastBoardFen = session.anchorFen;
        session.lastRawFen = session.anchorFen;
        session.lastResult = null;
        session.lastDispatchedFen = '';
        /* 没学过开局（中途进对局）：轮次无从得知，假设正好轮到我方，
           让用户立刻能拿到建议；plyGuessed=1 供日志追溯。 */
        session.movePly = session.flipped ? 1 : 0;
        session.plyGuessed = 1;
      }
    } else if (session.anchorFlipped !== !!session.flipped) {
      // 画面朝向变了：旧锚盘坐标失效，按当前盘面重建。
      // 但必须先确认当前盘面本身是一盘真棋 —— 否则一帧朝向抖动就把锚盘
      // 换成垃圾盘面（15:10 日志里 FEN 一路漂成 pnbaknb2 的帮凶之一）。
      // 不合法时只标噪声，本帧仍用旧锚覆盖，等朝向稳定/识别干净再重建。
      if (codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
        anchor = Array.prototype.slice.call(engCodes);
        session.anchorCodes = anchor;
        session.anchorFen = codesToBoardFen(anchor);
        session.anchorFlipped = !!session.flipped;
        session.lastBoardFen = session.anchorFen;
        session.lastResult = null;
        session.lastDispatchedFen = '';
        session.reseatPrev = null;
        session.reseatCount = 0;
        session.movePly = session.flipped ? 1 : 0;
        session.plyGuessed = 1;
      } else {
        anchorRejected = 1;
      }
    }

    if (anchor) {
      stepInfo = analyzeStepDiff(anchor, engCodes);
      var reseat = false;
      if (!stepInfo.move && stepInfo.changed >= JJ_RESEAT_MIN_DIFF) {
        // 2.0.0：只有「大变化」才可能是换局 / 中途进对局。
        // 1.1.44 只要 changed>0 就进换局候选，真机首帧 diff=4 的模板噪声
        // 连着 3 帧（旧帧缓存）就把学习刚锚定的标准开局 reseat 成错误盘面。
        var frameDiff = session.reseatPrev
          ? countCodesDiff(session.reseatPrev, engCodes) : 999;
        session.reseatCount = (frameDiff <= 6)
          ? (session.reseatCount || 0) + 1 : 1;
        session.reseatPrev = Array.prototype.slice.call(engCodes);
        var plausibleNow = codesLegal(engCodes) && codesPositionPlausible(engCodes);
        // 超时兜底：连续被丢弃 >=12 帧说明「3 帧稳定」在真机抖动下凑不齐，
        // 只要当前盘面是一盘真棋就强制重锚一次，避免中途进对局永久静默。
        var forced = (session.anchorRejected || 0) >= JJ_RESEAT_REJECT_LIMIT;
        if (plausibleNow && (session.reseatCount >= 3 || forced)) {
          reseat = true;
          anchor = Array.prototype.slice.call(engCodes);
          session.anchorCodes = anchor;
          session.anchorFen = codesToBoardFen(anchor);
          session.lastBoardFen = '';
          session.lastRawFen = '';
          session.lastResult = null;
          session.lastFen = '';
          session.lastDispatchedFen = '';
          session.reseatCount = 0;
          session.reseatPrev = null;
          session.reseatDone = 1;   // 供 out 输出诊断（out 此时还没创建）
          // 重锚后若就是标准开局 → 红方先走；否则轮次未知，假设轮到我方
          var backToOpening = session.openingAnchor &&
            countCodesDiff(session.openingAnchor, engCodes) <= 4;
          session.movePly = backToOpening ? 0 : (session.flipped ? 1 : 0);
          session.plyGuessed = backToOpening ? 0 : 1;
        } else {
          anchorRejected = 1;
        }
      } else if (!stepInfo.move && stepInfo.changed > 0) {
        // 小幅抖动且不构成一步棋 = 纯噪声：整帧丢弃，且不累计换局候选
        anchorRejected = 1;
        session.reseatCount = 0;
        session.reseatPrev = null;
      } else {
        // 盘面没变、或已找到一步棋结构：清空换局候选
        session.reseatCount = 0;
        session.reseatPrev = null;
      }

      if (!reseat) {
        var nextAnchor = anchor.slice();
        if (stepInfo.move) {
          nextAnchor[stepInfo.move.from] = 0;
          nextAnchor[stepInfo.move.to] = stepInfo.move.piece;
          // 一步棋不该把相/兵/将推到规则外，否则宁可当作噪声丢弃
          if (codesLegal(nextAnchor) && codesPositionPlausible(nextAnchor)) {
            session.prevAnchorFen = session.anchorFen;   // 走子前盘面，供中文记谱
            anchor = nextAnchor;
            session.anchorCodes = nextAnchor;
            session.anchorFen = codesToBoardFen(nextAnchor);
            session.lastMoveText = C.sqToUcci(stepInfo.move.from) +
                                   C.sqToUcci(stepInfo.move.to);
            /* 红先黑后：每落地一步走子，轮次翻面。这也是「我执黑要等对面
               先手」的依据 —— 开局 ply=0 归红方，对面走完 ply=1 才轮到我。 */
            session.movePly = (session.movePly || 0) + 1;
            session.plyGuessed = 0;
          } else {
            stepInfo = { changed: stepInfo.changed, move: null, noise: stepInfo.noise };
            anchorRejected = 1;
          }
        }
        // 用锚盘（可能已推进一步）覆盖本帧 codes/grid，噪声格一律不落地
        var screenCodes = session.flipped ? flipCodes(anchor) : anchor;
        for (var bc = 0; bc < 90; bc++) {
          cls.codes[bc] = screenCodes[bc];
          if (cls.grid) cls.grid[bc] = screenCodes[bc]
            ? (screenCodes[bc] <= 7 ? 1 : 2) : 0;
        }
        mergedCodes = Array.prototype.slice.call(cls.codes);
        grid = session.flipped ? flipGrid(cls.grid) : cls.grid;
      }
    }
    session.anchorRejected = anchorRejected ? (session.anchorRejected || 0) + 1 : 0;

    // ★ 我执红还是执黑：由画面朝向决定（黑在下 = 我执黑，红在下 = 我执红）
    var mySideDetected = session.flipped ? 'black' : 'red';
    var bottomRed = mySideDetected === 'red' ? 1 : 0;
    var bottomBlack = mySideDetected === 'black' ? 1 : 0;

    /* 【2.0.0 红先黑后】JJ 象棋规则：由执红棋的一方先走，双方轮流走一步。
       旧版把 FEN 的走子方写死成「永远我方」，于是我执黑时开局第一手明明
       归对方，插件却照样给我出着法。现在按 movePly 奇偶推真实轮次；
       轮到对方就完全不调引擎、不画箭头，顺带省掉一半的搜索开销。 */
    var turnChar = (session.movePly % 2 === 0) ? 'w' : 'b';
    var myTurnChar = mySideDetected === 'red' ? 'w' : 'b';
    var waitingOpponent = (turnChar !== myTurnChar);
    var prevTurnChar = ((session.movePly - 1) % 2 === 0) ? 'w' : 'b';

    // 1) 尝试推进一步棋
    // ★ 画面稳定性检测
    //   落子动画、高亮圈闪烁会让同一局面在相邻帧里识别出不同结果，
    //   如果每帧都拿去匹配走法，tracker 会被误判推着往前跑（而且退不回来），
    //   表现就是「一会这样一会那样，一会又等对方走」。
    //   所以要求连续 2 帧识别结果完全一致，才认为画面稳定、才做走法判定。
    var gridHash = 0;
    for (var gi = 0; gi < 90; gi++) {
      gridHash = ((gridHash * 31) + grid[gi]) | 0;
    }
    if (session.lastGridHash === gridHash) {
      session.gridStable = (session.gridStable || 0) + 1;
    } else {
      session.gridStable = 0;
      session.lastGridHash = gridHash;
    }
    var isStable = (session.gridStable >= 1);

    var out = {
      grid: Array.prototype.slice.call(grid),
      fen: session.tracker.fen,
      moveDetected: false,
      mySide: mySideDetected,
      bottomRed: bottomRed,
      bottomBlack: bottomBlack,
      stable: isStable ? 1 : 0,
      // 浮窗盖住了几格（浮窗自带洋红边框，引擎按边框算出来的，不是猜颜色）
      pipOverlap: (session.recognizer && session.recognizer.occludedCount) || 0,
      pipRect: (session.recognizer && session.recognizer.pipRect) || null,
      hiddenCells: (session.recognizer && session.recognizer.occludedCount) || 0,
      anchorRejected: anchorRejected ? 1 : 0,
      diffChanged: stepInfo.changed,
      reseat: session.reseatDone ? 1 : 0,
      newGame: session.newGame ? 1 : 0,
      ply: session.movePly || 0,
      plyGuessed: session.plyGuessed ? 1 : 0,
      turn: turnChar,
      waitingOpponent: waitingOpponent ? 1 : 0,
      repairedCount: quotaFix.repaired,
      replacedCount: quotaFix.replaced || 0,
      droppedCount: quotaFix.dropped || 0
    };
    session.reseatDone = 0;
    // 日志里 15:11 起一直打「检测到走法 (null) (null)」：旧代码只在
    // tracker.tryAdvance 分支填 move，主路径从来没填过。现在由锚定状态机直接给出。
    if (stepInfo.move) {
      out.move = session.lastMoveText ||
                 (C.sqToUcci(stepInfo.move.from) + C.sqToUcci(stepInfo.move.to));
      var mvTxt = JJEngine.moveInfo(
        (session.prevAnchorFen || session.anchorFen) + ' ' +
        prevTurnChar + ' - - 0 1',
        out.move);
      out.moveChinese = mvTxt.chinese || out.move;
      out.moveFromSq = stepInfo.move.from;
      out.moveToSq = stepInfo.move.to;
    }

    // ★ 主路径：直接把识别出的兵种组回 FEN
    //   这才是象棋软件该有的做法 —— 不依赖「从开局一步步跟踪」，
    //   所以哪怕你中途进对局，也能立刻认出当前局面并给出下一步。
    //
    //   关键：识别结果必须先稳定下来才更新局面。
    //   采样点只要偏几像素，相邻帧可能把同一个棋子识别成不同兵种，
    //   FEN 每帧都不一样，着法就会乱跳（实测同一开局给出过相三进五/兵四进一/兵三进一三个答案）。
    var directFen = null;
    var codesOk = false;
    var codesHash = 0;
    if (cls.codes) {
      for (var ci = 0; ci < 90; ci++) {
        codesHash = ((codesHash * 31) + cls.codes[ci]) | 0;
      }
    }
    if (session.lastCodesHash === codesHash) {
      session.codesStable = (session.codesStable || 0) + 1;
    } else {
      session.codesStable = 0;
      session.lastCodesHash = codesHash;
    }
    // 要求连续 3 帧识别结果完全一致才认为局面定下来了。
    // 2 帧门槛太低：一次落子动画 + 高亮圈切换就能凑够两帧抖动。
    var codesSettled = liveMode ? true : (session.codesStable >= 1);

    // 第一帧只要认出来就直接落地，不再等「3 帧完全一致」。
    //   之前一律要求 3 帧一致才更新，结果中途进对局时识别在两组结果之间抖
    //   （几个高亮格来回翻），永远凑不出 3 帧一致，浮窗就一直是开局的棋盘。
    //   现在：第一次落地无条件（限流照旧），之后才要求稳定，抖动照样挡得住。
    var firstLatch = !session.lastBoardFen;
    // ★ 合法性闸门
    //   真机抓屏偶尔会出几帧垃圾识别（满盘车、红帅变黑将之类）。
    //   与其把垃圾显示出去，不如继续显示上一帧合法盘面 ——
    //   你看到的永远是「一盘真棋」，不会是乱码盘。
    // 1.1.44：数量上限之外再加「位置合理性」，拦住 pnbaknb2 这类数量合法、
    // 但黑卒蹲在自己底线 / 红相过河的荒谬盘面
    var engForLegal = session.flipped ? flipCodes(cls.codes) : cls.codes;
    var legalNow = cls.codes && codesLegal(engForLegal) && codesPositionPlausible(engForLegal);
    if (!legalNow) {
      session.legalStreak = 0;
      session.illegalStreak = (session.illegalStreak || 0) + 1;
      // 连续 12 帧都不合法 → 清掉旧局面，让下一帧合法识别重新落地（别卡死在一个错盘面上）
      if (session.illegalStreak > 12) {
        session.lastBoardFen = '';
        session.lastRawFen = '';
        session.lastResult = null;
        session.lastDispatchedFen = '';
        session.illegalStreak = 0;
      }
    } else {
      session.illegalStreak = 0;
      session.legalStreak = (session.legalStreak || 0) + 1;
    }

    // 1.1.43：真机每帧间隔 7~9 秒（Metal 1s 节流 + process 0.8s + 未收敛退避 2.5s），
    // 落子动画/计时器/高亮每帧都不同，「连续 N 帧完全一致」几乎凑不出来，
    // 旧版因此让 codesOk 恒为 false、skipAnalyze 恒为 1，形成死锁。
    // 对「距上次成功落地超过 2.5 秒的合法帧」无条件放行一次。
    var latchNow = Date.now();
    var latchTimeout = !session.lastFenUpdateTime ||
                       (latchNow - session.lastFenUpdateTime > 2500);
    if (!codesSettled && legalNow && latchTimeout) codesSettled = true;

    if (legalNow && (firstLatch || codesSettled) && cls.codes && codesUsable(cls.codes)) {
      // 两套 FEN，别再混用：
      //   rawFen = 屏幕原样（给浮窗显示，必须跟你眼睛看到的一模一样）
      //   engFen = 引擎内部坐标（红永远在下，给算棋用）
      // 你执黑时这两套是上下相反的。之前只存了一套、还按屏幕方向去算棋，
      // 引擎会把黑方当红方，着法自然全错。
      var rawFen = codesToBoardFen(cls.codes);
      var engCodes = session.flipped ? flipCodes(cls.codes) : cls.codes;
      var boardFen = codesToBoardFen(engCodes);
      // 局面更新限流：最多每 700ms 换一次。
      // 识别偶尔抖动时，靠这道闸门挡住「一秒内连换五个着法」的情况。
      var nowMs = Date.now();
      // 实时模式（录屏浮窗）不限流：棋盘一变就要立刻反映出来。
      // 照片模式保留 700ms 限流，防止识别抖动时界面乱换。
      var canUpdate = liveMode || (!session.lastFenUpdateTime) || (nowMs - session.lastFenUpdateTime > 700);

      session.lastRawFen = rawFen;

      if (boardFen !== session.lastBoardFen && canUpdate) {
        session.lastBoardFen = boardFen;
        session.lastFenUpdateTime = nowMs;
        out.moveDetected = true;
        session.lastResult = null;    // 强制重算
        session.lastDispatchedFen = '';
        session.stableCodes = mergedCodes.slice();
      } else if (!session.lastBoardFen) {
        // 第一次进来先落地，不占用限流
        session.lastBoardFen = boardFen;
        session.lastFenUpdateTime = nowMs;
        out.moveDetected = true;
        session.lastResult = null;
        session.stableCodes = mergedCodes.slice();
      }
      // 局面没变也要更新「上一稳定值」，这样高置信度的格子能持续收敛
      if (!session.stableCodes) session.stableCodes = mergedCodes.slice();
      codesOk = true;

      // 2.0.0：走子方按真实轮次（红先黑后），不再写死「永远我方」。
      // 轮到对方时下面会整段跳过引擎搜索，HUD 显示「等待对方先走」。
      directFen = session.lastBoardFen + ' ' + turnChar + ' - - 0 1';
      // 浮窗显示用「屏幕原样」的 FEN：你执黑时它就是黑在下，
      // 跟你眼睛看到的完全一致。算棋用的是 directFen（内部坐标，红永远在下）。
      out.fen = (session.lastRawFen || session.lastBoardFen) + ' ' +
        turnChar + ' - - 0 1';
      out.recognized = 1;
      out.conf90 = session.recognizer.lastConf || null;
      out.tops90 = session.recognizer.lastRanked || null;
      out.engineFen = directFen;
      out.sideToMove = mySideDetected;
      try { session.tracker.pos.setFen(directFen); } catch (e) {}
    } else {
      // 还在等识别稳定，沿用上一次的结论
      // 【别再拿「开局盘面」冒充识别结果】
      //   以前这里兜底成 session.tracker.fen（= 开局 FEN），
      //   于是识别彻底失败时界面会显示一盘完整的开局、还说「识别完成 · 32 个子」。
      //   现在没有识别结果就返回空串，让上层明确报「没认出来」。
      out.fen = session.lastRawFen || session.lastBoardFen || '';
      out.recognized = out.fen ? 1 : 0;
      // 1.1.44：走法已由锚定状态机统一判定，不再让 tracker.tryAdvance 用
      // 颜色网格另推一步 —— 它会绕过锚盘、把噪声帧误判成走子并重算引擎。
    }
    out.codesValid = codesOk ? 1 : 0;
    out.codesSettled = codesSettled ? 1 : 0;
    // 诊断：合法性闸门为什么没放行。1.1.42 只打印 illegalStreak / codesStable，
    // 看不出 legalNow 到底是不是 0，14:51 日志因此误导了好几轮。
    out.legalNow = legalNow ? 1 : 0;
    out.illegalStreak = session.illegalStreak || 0;
    out.codesStableCount = session.codesStable || 0;
    out.repairedCount = quotaFix.repaired;
    out.replacedCount = quotaFix.replaced || 0;
    out.droppedCount = quotaFix.dropped || 0;
    out.anchorRejected = anchorRejected ? 1 : 0;
    out.anchorRejectedStreak = session.anchorRejected || 0;
    out.diffChanged = stepInfo.changed;
    out.anchorFen = session.anchorFen || '';
    out.flipped = session.flipped ? 1 : 0;
    out.skipReason = 'none';

    // 2) 到了我方走 → 算棋
    // 【1.1.42 卡顿根因】识别没收敛时，旧逻辑仍会拿 session.tracker.fen（开局 FEN）
    // 跑一次 ENG.analyze；而 illegalStreak>12 又清掉 lastResult 强制重算，于是
    // 盘面全空 / 满盘乱码时引擎队列永远满载。
    // 【1.1.43 死锁根因】旧短路条件 (!legalNow || !codesOk) 把「只是等稳定」也
    // 算进去：短路后 stableCodes / lastBoardFen 都不更新，识别永远收敛不了，
    // 真机就表现为每帧 skipAnalyze=1、一条着法都不给。现在只有真正乱码
    // （裁剪后仍非法 / 一子未认出）才短路；合法但等稳定时沿用上一合法局面算棋。
    if (!legalNow || !cls.codes || !codesUsable(cls.codes)) {
      out.skipAnalyze = 1;
      out.skipReason = !legalNow ? 'illegal' : 'empty';
      out.needSearch = 0;
      out.searchFen = '';
      return out;
    }
    /* 2.0.0：轮到对方（典型是我方执黑的开局第一手）时整段跳过搜索。
       不是 skipAnalyze：上层不会因此退避，对方一落子下一帧就能立刻出建议。 */
    if (waitingOpponent) {
      session.lastResult = null;
      session.lastFen = '';
      session.lastDispatchedFen = '';
      out.skipReason = 'waitingOpponent';
      out.sideToMove = turnChar === 'w' ? 'red' : 'black';
      out.needSearch = 0;
      out.searchFen = '';
      return out;
    }
    /* 2.1.0：搜索已迁出 JS。这里只把「该问引擎的局面」交给 ObjC：
       - 轮到我方 + 盘面合法 → searchFen（引擎坐标，红在下 + w/b 走子方）
       - 同一局面只发一次（lastDispatchedFen 去重），上层原生缓存结论；
         换局 / 等待对方 / 重锚都会清 lastDispatchedFen，保证必发新请求。 */
    var analyzeFen = directFen ||
        ((session.lastBoardFen || session.tracker.fen.split(' ')[0]) + ' ' +
         turnChar + ' - - 0 1');
    out.searchFen = analyzeFen;
    out.needSearch = (analyzeFen !== session.lastDispatchedFen) ? 1 : 0;
    if (out.needSearch) session.lastDispatchedFen = analyzeFen;

    return out;
  },

  /** 当前局面 */
  currentFen: function () { return session.tracker ? session.tracker.fen : C.START_FEN; },

  /** 手动修正局面（识别错了的时候用） */
  forceSetFen: function (fen) {
    session.tracker = new TRK.MoveTracker(fen);
    session.lastFen = fen;
    session.lastResult = null;
    return session.tracker.fen;
  },

  /** 调试：把一个 FEN 渲染成 90 格三分类（验证追踪逻辑） */
  fenToGrid: function (fen) {
    var pos = new POS.Position(fen);
    return Array.prototype.slice.call(TRK.boardToGrid(pos.board));
  },

  /** 棋盘 → 每个交叉点在该帧中的像素坐标，给 UI 画箭头用 */
  gridPoints: function () {
    if (!session.recognizer) return [];
    var pts = session.recognizer.gridPoints();
    var out = [];
    for (var i = 0; i < 90; i++) out.push([pts[i * 2], pts[i * 2 + 1]]);
    return out;
  }
};

global.JJEngine = JJEngine;
/* 仅离线回归用：宿主注入钩子时暴露识别器与开局表（生产环境不设置，零开销） */
if (typeof global.__JJ_TEST_HOOK__ === 'function') global.__JJ_TEST_HOOK__(REC, TRK);
if (typeof module !== 'undefined' && module.exports) module.exports = JJEngine;

})(typeof globalThis !== 'undefined' ? globalThis : this);
`;

fs.mkdirSync(OUT_DIR, { recursive: true });
const outFile = path.join(OUT_DIR, 'engine.js');
fs.writeFileSync(outFile, out, 'utf8');

const stat = fs.statSync(outFile);
console.log('打包完成');
console.log('  模块数 :', sources.size);
console.log('  输出   :', outFile);
console.log('  体积   :', (stat.size / 1024).toFixed(1), 'KB');
console.log('  模块列表:');
for (const id of sources.keys()) console.log('    -', id);
