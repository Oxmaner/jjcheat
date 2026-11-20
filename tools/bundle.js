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
  'vision/tracker',
  'app/board'
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
 *  棋盘纯函数层
 *  2.1.79：实现已迁到 src/app/board.js（纯输入→输出，不碰 session/引擎）。
 *  这里只做别名，保持主流程里的裸名调用不变，迁移零行为变化。
 * ============================================================ */

var B = __require('app/board');
var PC2FEN_TABLE = B.PC2FEN_TABLE;
var flipGrid = B.flipGrid;
var flipCodes = B.flipCodes;
var codesToBoardFen = B.codesToBoardFen;
var boardFenToCodes = B.boardFenToCodes;
var validateCodes = B.validateCodes;
var codesUsable = B.codesUsable;
var codesLegal = B.codesLegal;
var codesPositionPlausible = B.codesPositionPlausible;
var codesEngineSafe = B.codesEngineSafe;
var stepIsRuleLegal = B.stepIsRuleLegal;
var analyzeStepDiff = B.analyzeStepDiff;
var countCodesDiff = B.countCodesDiff;
var countOccupancyDiff = B.countOccupancyDiff;
var repairCodesQuota = B.repairCodesQuota;

/* 2.1.79：单帧允许的「待确认格子」上限（低置信度的有子格）。
   超过就不发搜索，HUD 显示「识别待确认 · N 格」。 */
var JJ_MAX_UNSURE_CELLS = 6;

/* 标记确认帧数：由菜单「标记确认帧数」实时修改（1~30），出厂默认取 K.MARKER_CONFIRM_FRAMES。
   真机上白点白圈是持久显示的，所以这个值调大只会更稳，不会因为标记消失而卡住。 */
var markerConfirmFrames = 3;

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
  ruleFail: 0,             // 2.1.77 连续「规则不通过」次数（≥5 强判锚盘错了，重锚）
  reseatDone: 0,           // 本帧刚完成换局重锚（诊断输出后置 0）
  markerConfirmKey: -1,    // 2.0.0r21：正在确认的那一手（from*90+to）
  markerConfirmHits: 0,    // 已连续确认帧数
  lastMoveText: '',        // 最近一步的 UCCI，供日志/HUD 诊断
  // 2.0.0 红先黑后：JJ 象棋「由执红棋的一方先走，双方轮流走一步」。
  // movePly = 本局已发生的走子数；偶数轮到红(w)、奇数轮到黑(b)。
  // 我方执黑时开局 ply=0 归对方先走，此时不出建议（用户明确要求）。
  movePly: 0,
  plyGuessed: 0,           // 中途进对局时轮次只能假设，日志可追溯
  /* 2.1.84：最近一次**实际识别到**的走子方（'red' | 'black' | null）。
     代替「靠 movePly 奇偶猜轮次」——后者只要漏识别一步就永久卡在
     「等待对方走子」，而且我方走完箭头也不消失。这里用真实走子方
     直接推出轮次：谁走的子，下一步就轮到另一方。漏步也能自愈。 */
  lastMoverSide: null,
  /* 2.1.88：通用兜底「等对方时盘面在变」的连续帧计数。 */
  genChgStreak: 0,
  flipCooldown: 0,          // 2.1.91：对称翻转冷却帧数，防连续误翻
  frameSeq: 0,              // 2.1.93：帧序号，给标记去重当指纹（不能用 ply）
  markerDoneSeq: 0,
  newGame: 0               // 本帧识别到「回到标准开局」并已重锚
};

/* ==========================================================================
 * ★ 2.0.0r12：着法记账 + 推演校验（双轨之二）
 *
 * 为什么需要：现在只有「锚盘 vs 当前识别」的差异检查（差 >3 格才自愈）。
 * 中间漏一步（差 2 格）根本发现不了，会一路错下去。这里把每一步都记下来
 * （uci、中文、谁走的、靠什么判出来的），再用「从开局重放」独立推一遍对账：
 *   对得上 → 链正常
 *   对不上 → 中途被重锚/漏记过 → 标记 chainDirty，后续以重锚为准
 *
 * 注意：着法序列**不喂引擎**（引擎只吃当前 FEN）。它只做校验与溯源 ——
 * 一旦某步记错，喂序列会让后面每一步都基于错局面，而喂当前 FEN 只影响这一手。
 * ========================================================================== */
/* ==========================================================================
 * ★ 2.0.0r14：识别/确认链路上的阈值集中在这里
 *
 * 以前这些数字散在各个判断里（0.06 / 10 / 3 / 12 / 15 / 1500 …），
 * 改一个要全文搜，还容易漏掉同名不同义的。现在统一到 K，注释写清来历。
 * 真机实测值都标在注释里，以后校准只改这一处。
 * ========================================================================== */
var K = {
  RING_MIN: 0.06,        /* 白圈：环带与环外中性色差（真机有圈 0.084、普通格 ≤0.039） */
  DOT_MIN: 10,           /* 白点：中心 9×9 白像素个数（起点 53、普通空位 0） */
  /* ★ 2.0.0r23：白点+白圈必须连续这么多帧指向**同一手**才提交。
     真机确认（用户说明）：**标记是持久显示的，不会淡出** ——
     对方走完，标记停在对方那步；直到我方走完才移到我方这步。
     所以「连续 N 帧读到同一手」是天然可靠的，N 可以放心调大。
     该项由菜单「标记确认帧数」控制（1~30），这里只是出厂默认。 */
  /* 仅回归测试用的差分定格门槛（真机差分已禁用，不参与真机行为） */
  SETTLE_FRAMES: 3,
  SETTLE_MS: 1500,
  MARKER_CONFIRM_FRAMES: 3,
  OPT_HIT: 2,            /* 乐观轮次：半区变化连续几帧一致才采纳 */
  OPT_WINDOW: 15,        /* 乐观轮次：采纳后有效多少帧（≈2 秒） */
  MARKER_DEDUP: 12,      /* 同一落点的标记去重窗口（帧） */
  SKIN_HI: 1.45,         /* 亮度增益高于此值 → 疑似非原始皮肤 */
  SKIN_LO: 0.75,         /* 亮度增益低于此值 → 疑似非原始皮肤 */
  SKIN_OK_HI: 1.30,      /* 回到该区间自动解除提示（滞回，防抖） */
  SKIN_OK_LO: 0.85,
  UNDO_STABLE: 2,        /* 悔棋：连续几帧回到旧盘面才认 */
  /* 一手真棋最多动 2 格（吃子也是 2 格），加上识别抖动允许到 6 格。
     超过就说明这一帧识别整体不可信，不能拿它推锚盘。 */
  MAX_MOVE_CHANGE: 6
};

function recordMove(session, from, to, piece, src, uci) {
  if (!session.moves) session.moves = [];
  /* 第一次记账时把「走子之前的盘面」记成推演起点（中途进对局也能重放） */
  if (!session.chainStartFen && session.prevAnchorFen) {
    session.chainStartFen = session.prevAnchorFen;
  }
  session.moves.push({
    from: from,
    to: to,
    piece: piece,
    by: (piece > 0 && piece <= 7) ? 'red' : 'black',
    src: src,                 /* 'marker' | 'marker-ring' | 'diff' */
    uci: uci || '',           /* UCCI 着法；中文记谱由原生 JJMoveChinese 现算 */
    fen: session.prevAnchorFen || '',   /* 走子前的盘面：中文记谱要用 */
    ts: Date.now()
  });
  session.chainLen = session.moves.length;
  return session.chainLen;
}

/** 从本局起点重放着法序列，返回 {ok, fen} 或 null（无法推演时） */
function replayChain(session) {
  if (!session.chainStartFen || !session.moves || !session.moves.length) return null;
  try {
    /* ★ 2.0.0r17：初始走子方必须按链上第一手来定。
       原来这里写死 ' w '，只要链是从「黑方要走的局面」开始重放，
       第一步 isLegal 就返回 false → 判对账失败 → 链被重启。
       真机日志里 #1 反复出现（14:10:48、14:11:22、14:13:00）就是这个原因，
       moves.log 的编号不断从 1 开始，悔棋也会跟着失效。 */
    var firstBy = session.moves[0].by;
    var startSide = (firstBy === 'black') ? 'b' : 'w';
    var p2 = new POS.Position(session.chainStartFen + ' ' + startSide + ' - - 0 1');
    for (var i = 0; i < session.moves.length; i++) {
      var m = C.mv(session.moves[i].from, session.moves[i].to);
      if (!p2.isLegal(m)) return { ok: false, fen: '', at: i };
      p2.makeMove(m);
    }
    return { ok: true, fen: p2.getFen(), at: -1 };
  } catch (e) {
    return null;
  }
}

var JJEngine = {
  version: '2.1.0',
  /* 2.1.58：开局匹配滤波对齐（alignGridToOpening）。标记必须变：
     容器里那份 engine.js 只认「缺当前标记 → 覆盖升级」，标记不变 = 2.1.57
     的旧脚本一直被用下去，新对齐逻辑根本跑不到。 */
  featureMark: 'pikafishNative2179',
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
  /* ------------------------------------------------------------------
   * 2.0.0r11：从画面自己反解棋盘四角（2.1.96 写的 autoDetectBoard，一直没接线）
   *
   * 为什么需要：四角现在是内置预设，一旦换皮肤/换机型/换对局类型就可能偏，
   * 而预设是写死的，没法自适应。这里给上层一个「实在读不出来时问一次画面」的
   * 能力：检测成功就替换四角重学，失败就保持原样。
   * 返回：4 个 [x,y]（像素）或 null。
   * ------------------------------------------------------------------ */
  autoDetect: function (pixels, w, h) {
    if (!REC.autoDetectBoard || !pixels) return null;
    try {
      var r = REC.autoDetectBoard(pixels, w, h);
      if (!r) return null;
      /* 兼容可能出现的两种返回形态：[{x,y}...] 或 [[x,y]...] */
      var out = [];
      for (var i = 0; i < 4; i++) {
        var q = r[i];
        if (!q) return null;
        if (typeof q.x === 'number') out.push([q.x, q.y]);
        else if (q.length >= 2) out.push([q[0], q[1]]);
        else return null;
      }
      return out;
    } catch (e) {
      return null;
    }
  },

  reset: function (fen, keepAnchor) {
    session.tracker = new TRK.MoveTracker(fen || C.START_FEN);
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
    /* 2.0.0r12：着法链与定格计时的初始状态 */
    session.moves = [];
    session.chainLen = 0;
    session.chainStartFen = '';
    session.chainDirty = 0;
    session.stepKey = 0;
    session.stepStable = 0;
    session.pendingSince = 0;
    /* 2.0.0r16：换局要清掉「待锚定」计数，否则可能拿上一局的盘面立刻锚定 */
    session.pendingAnchorKey = 0;
    session.pendingAnchorHits = 0;
    session.usedDiffFallback = 0;
    session.dirtyFrameSkip = 0;
    session.dirtySince = 0;
    session.diffRejected = 0;
    /* ★ 2.0.0r17：这里**不能清成 0**。
       ringAge 的算法是「当前帧号 − 上次见到白圈的帧号」，而帧号是跨局递增的。
       清成 0 会让 ringAge 直接等于几千 → 换局后第一帧就满足
       markerLost（>20 帧）→ 立刻弹出「读不到走子标记」的假警告。
       设成当前帧号 = 把「换局这一刻」当作刚见过，给 20 帧宽限。 */
    session.ringSeenSeq = session.frameSeq || 0;
    session.ringMaxNow = 0;
    session.dotMaxNow = 0;
    session.mkState = '-';
    session.ringDedupSkip = 0;
      session.ringRelaxed = 0;   // 2.0.0r26：帧开始就重置，避免上帧残留
      session.dotRelaxed = 0;
    session.lastOccCount = 0;
    session.anchorRejected = 0;
    session.prevAnchorFen = '';
    session.lastMoveText = '';
    /* ★ 2.0.0r17：换局清零补齐。
       下面这些字段以前没清，会从上一局带过来，逐条都有实际后果：
         optMover*     上一局的乐观翻面状态 → 新局第一帧可能立刻翻到错的一方
         markerDone*   上一局的标记去重窗口 → 新局第一手落在同一格会被吞掉
         genChgStreak  上一局的连续计数   → 新局第一帧就满足「连续 2 帧」
         flipCooldown  上一局的冷却       → 新局前 10 帧不许翻轮次
         drift*        上一局的漂移判定   → 新局可能立刻触发重锚
         skinWarn      结算页设的皮肤警告 → 新局开局误弹「请换回原始皮肤」
         统计量         跨局累计，日志数字会越来越离谱 */
    session.optMoverSide = null;
    session.optMoverHit = 0;
    session.optMoverSeq = 0;
    session.markerDoneSq = -1;
    session.markerDirtyAccepted = 0;
    session.markerDotMiss = 0;
    /* ★ 2.0.0r24：换局/重锚必须复位标记确认计数。
       否则上一局残留的 hits 会带进新局 —— 新局第一手若 from*90+to 恰好
       与上一局未确认的那一手相同，就会少等好几帧直接提交。 */
    session.markerConfirmKey = -1;
    session.markerConfirmHits = 0;
    session.markerDoneSeq = 0;
    session.genChgStreak = 0;
    session.flipCooldown = 0;
    session.driftKey = 0;
    session.driftStable = 0;
    session.skinWarn = 0;
    session.lastGain = 0;
    session.ruleFail = 0;
    session.chainResets = 0;
    session.markerHit = 0;
    session.markerBoth = 0;
    session.undoCount = 0;
    session.prevScreenGrid = null;
    /* markerEverSeen 故意**不清**：它描述的是「这套皮肤会不会画白圈」这个属性，
       跨局依然成立；清掉会让新局头几帧误走差分兜底。 */
    if (!keepAnchor) {
      session.lastBoardFen = '';
      session.lastRawFen = '';
      session.movePly = 0;
      session.plyGuessed = 0;
      session.lastMoverSide = null;    // 2.1.84：换局后走子方记录作废
      session.newGame = 0;
    }
    return session.tracker.fen;
  },

  /** 在开局局面状态下学习棋盘背景 */
  /**
   * ★ 2.0.0r1：把学好的 90 格模板导出成可持久化的普通对象。
   *
   * 背景：每次开插件都强制手动标定，而「学模板」要求标准开局 32 子。
   * 中局开插件就永远学不成、识别起不来。把模板存下来，下次直接读，
   * 中局也能立刻识别。
   *
   * 只导出纯数据（Float32Array → 普通数组），由 OC 侧写成 JSON 文件；
   * 四角校验放在 OC 侧做（它才知道当前标定值）。
   */
  exportTemplates: function () {
    try {
      if (!session.recognizer || !session.recognizer.templates) return null;
      var src = session.recognizer.templates;
      var out = {};
      var total = 0;
      for (var k in src) {
        if (!Object.prototype.hasOwnProperty.call(src, k)) continue;
        var list = src[k];
        if (!list || !list.length) continue;
        var arr = [];
        for (var j = 0; j < list.length; j++) {
          var it = list[j];
          if (!it || !it.w || !it.r) continue;
          /* 降精度到 3 位小数：归一化 patch 的有效范围 ±3 左右，
             0.001 的量化误差对 NCC 匹配完全无感，但 JSON 体积能砍掉一半
             （2.5MB → 1.2MB），写入/解析都更快。 */
          var q = function (fa) {
            var o = new Array(fa.length);
            for (var z = 0; z < fa.length; z++) o[z] = Math.round(fa[z] * 1000) / 1000;
            return o;
          };
          arr.push({
            w: q(it.w),
            r: q(it.r),
            i: it.i ? q(it.i) : null
          });
          total++;
        }
        if (arr.length) out[k] = arr;
      }
      if (!total) return null;
      return {
        v: 1,
        /* 存的是**边长**（PATCH_W=24），不是 patch 长度（576）。
           这里原来是 .w.length，导入侧的 24 校验必然失败，等于白存。 */
        patchW: Math.round(Math.sqrt(session.recognizer.templates[Object.keys(out)[0]][0].w.length)),
        count: total,
        templates: out
      };
    } catch (e) {
      return null;
    }
  },

  /**
   * 导入模板。patchW 必须是 24（PATCH_W），否则说明是别的版本存的，直接丢弃。
   * @returns {number} 导入的模板条数，0 表示失败
   */
  importTemplates: function (data) {
    try {
      if (!data || data.v !== 1 || data.patchW !== 24) return 0;
      if (!session.recognizer) return 0;
      var src = data.templates || {};
      var t = {};
      var count = 0;
      for (var k in src) {
        if (!Object.prototype.hasOwnProperty.call(src, k)) continue;
        var list = src[k];
        if (!list || !list.length) continue;
        var arr = [];
        for (var j = 0; j < list.length; j++) {
          var it = list[j];
          if (!it || !it.w || !it.r) continue;
          if (it.w.length !== 24 * 24) continue;
          arr.push({
            w: new Float32Array(it.w),
            r: new Float32Array(it.r),
            i: (it.i && it.i.length === 24 * 24) ? new Float32Array(it.i) : null
          });
          count++;
        }
        if (arr.length) t[k] = arr;
      }
      if (!count) return 0;
      session.recognizer.templates = t;
      session.recognizer.templateCount = count;
      return count;
    } catch (e) {
      return 0;
    }
  },

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
      session.lastDispatchedFen = '';
      session.reseatCount = 0;
      session.anchorRejected = 0;
      // 学习成功 = 一局新棋从标准开局开始，红方先走
      session.movePly = 0;
      session.plyGuessed = 0;
      session.lastMoverSide = null;    // 2.1.84：新局开局，还没有任何走子记录
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
      /* 2.1.60 墨迹占位模型：inkThOcc=自适应占位阈值、boardInkMed=空格墨迹基线。
         判读：棋子 ink(0.20+) 应 ≥ inkThOcc，空格(0.02~0.07)/星标(0.10) 应 < inkThOcc。 */
      inkThOcc: bgSnap && typeof bgSnap.inkThOcc === 'number'
        ? Math.round(bgSnap.inkThOcc * 1000) / 1000 : -1,
      boardInkMed: bgSnap && typeof bgSnap.boardInkMed === 'number'
        ? Math.round(bgSnap.boardInkMed * 1000) / 1000 : -1,
      /* 簇差 = 棋子簇与空格簇的墨迹均值差。≥0.06 才算真的分出来，
         <0.06 说明整盘墨迹是单峰（空盘 / 画面里没棋子 / 四角完全跑飞）。 */
      inkGap: bgSnap && typeof bgSnap.inkGap === 'number'
        ? Math.round(bgSnap.inkGap * 1000) / 1000 : -1,
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

    /* 2.1.105：自动标定已移除，四角一律来自手动四点标定 */

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
               finalCorners: base || session.corners || [],
               refineError: String(e4 && e4.message || e4) };
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
      if (liveMode) {
        mergedCodes[sm] = raw;
        /* 2.1.79：实时模式仍然不保留旧值（保留会导致「对方走了浮窗里没变」
           那个老 bug），但必须把「认出了子、可模板分数很低」的格子记下来。
           以前 live 直接 continue，置信度机制在生产环境等于不存在 ——
           高亮圈 / 落子放大只要遮住一帧，就按低分硬猜一个兵种，整盘喂给引擎。
           空格不参与计数：判空比判兵种可靠得多，算进去会频繁误报。 */
        if (raw && conf < LOWCONF) lowConfCount++;
        continue;
      }
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

    /* ★ 2.0.0r17：盘面棋子数。<4 且上一帧还有 >=10 → 判定「已离开棋盘」
       （结算页/大厅/切页），见下方骤降检测。 */
    var occCount = 0;
    for (var oc = 0; oc < 90; oc++) if (engCodes[oc]) occCount++;

    /* ------------------------------------------------------------------
     * 2.0.0r10：半区变化（屏幕坐标 row>=5 = 我方半区）
     *
     * 轮次判定靠 lastMoverSide，而它只有「一步棋被完整确认」时才更新。
     * 真机上经常配不出完整一步（落点被高亮圈盖住、起点被压缩读错），于是
     * lastMoverSide 永远停在上一次，表现就是：
     *   我方走完，HUD 还挂着建议（以为还没走）
     *   对方走完，HUD 还在「等待对方走子」
     * 但「哪个半区变了」极好判，一有变化就说明那一方刚动手。所以这里先算
     * 一个乐观信号让轮次翻过去，识别确认在后面兜底（确认结果与它一致）。
     * 两个半区同时变化（长距离子过河、吃子动画）就放弃，交回确认逻辑。
     * ------------------------------------------------------------------ */
    var halfOurs = 0, halfTheirs = 0;
    if (session.prevScreenGrid && cls.grid && cls.grid.length === 90 &&
        session.prevScreenGrid.length === 90) {
      for (var hq = 0; hq < 90; hq++) {
        if (session.prevScreenGrid[hq] === cls.grid[hq]) continue;
        if (((hq / 9) | 0) >= 5) halfOurs++; else halfTheirs++;
      }
    }
    if (cls.grid && cls.grid.length === 90) {
      session.prevScreenGrid = Array.prototype.slice.call(cls.grid);
    }
    var mySideNow = session.flipped ? 'black' : 'red';
    var halfMover = null;
    if (halfOurs > 0 && halfTheirs === 0) halfMover = mySideNow;
    else if (halfTheirs > 0 && halfOurs === 0) halfMover = (mySideNow === 'red' ? 'black' : 'red');
    /* 同一个判断要连着两帧都成立才采纳：落子动画的第一帧经常只变了半格，
       单帧就翻轮次会让 HUD 抖一下（回归 S3 就是守着这条）。两帧≈0.15~0.5s，
       比等「一步棋完整确认」仍然快一个数量级。 */
    /* ★ 2.0.0r17：计数规则修正。
       原来写成「无变化帧把计数清零」，可半区变化只在**跳变那一帧**可见，
       下一帧就检测不到 → 计数被清零 → 永远凑不满 OPT_HIT 次
       → 整个乐观轮次形同废码（r10 加的，从没真正生效过）。
       正确语义是「变化出现 → 下一帧没有被反向覆盖 → 确认」。
       换另一方时必须归 1，否则会接着上一方的计数一帧就凑满。 */
    if (halfMover) {
      if (session.optMoverSide === halfMover) {
        session.optMoverHit = (session.optMoverHit || 0) + 1;
      } else {
        session.optMoverSide = halfMover;
        session.optMoverHit = 1;
      }
      session.optMoverSeq = session.frameSeq;
    } else if (session.optMoverSide &&
               (session.frameSeq - (session.optMoverSeq || 0)) <= K.OPT_WINDOW) {
      /* 没有新变化 = 上一次判断没被推翻，累加一次 */
      session.optMoverHit = (session.optMoverHit || 0) + 1;
    }
    session.turnUpdated = 0;   // 2.1.91：本帧轮次是否已更新（保证一帧只翻一次）
    session.undoApplied = 0;   // 2.0.0r13：本帧是否发生了悔棋回退
    /* 2.1.93：帧序号。**不能拿 ply 当「标记是否已处理」的指纹** ——
       推进本身会改 ply，下一帧指纹立刻对不上，于是又推一次、再改 ply……
       死循环，真机实测 ply 一路涨到 25。用单调递增的帧号才可靠。 */
    session.frameSeq = (session.frameSeq || 0) + 1;
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
      session.lastMoverSide = null;    // 2.1.84：新局重锚，清空走子方记录
      session.lastBoardFen = session.anchorFen;
      session.lastRawFen = session.anchorFen;
      session.lastDispatchedFen = '';
      session.prevAnchorFen = '';
    }

    /* ==================================================================
     * ★ 2.0.0r13：悔棋检测
     *
     * 判据：当前识别盘面，正好等于着法链里「最后一步走子之前的盘面」。
     * 这是最干净的判据 —— 不需要猜，盘面完全回到上一手之前就是悔棋。
     * 要求连续 2 帧同一盘面才动作，避免某一帧偶然读成旧局面就误回退。
     * 悔棋后：链弹出一步、锚盘以当前识别为准、ply-1、走子方回到另一方。
     * 只弹一步；连悔两次会在后续帧里各弹一次。
     * ================================================================== */
    if (anchor && session.moves && session.moves.length &&
        codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
      var undoFen = codesToBoardFen(engCodes);
      var lastMv = session.moves[session.moves.length - 1];
      if (lastMv.fen && lastMv.fen === undoFen) {
        if (session.undoKey === undoFen) {
          session.undoStable = (session.undoStable || 0) + 1;
        } else {
          session.undoKey = undoFen;
          session.undoStable = 1;
        }
        if (session.undoStable >= K.UNDO_STABLE) {
          session.moves.pop();
          session.chainLen = session.moves.length;
          anchor = Array.prototype.slice.call(engCodes);
          session.anchorCodes = anchor;
          session.anchorFen = undoFen;
          session.anchorFlipped = !!session.flipped;
          session.lastBoardFen = undoFen;
          session.lastRawFen = undoFen;
          session.lastDispatchedFen = '';
          session.movePly = Math.max(0, (session.movePly || 0) - 1);
          session.lastMoverSide = (lastMv.by === 'red') ? 'black' : 'red';
          session.plyGuessed = 0;
          session.ruleFail = 0;
          session.undoKey = '';
          session.undoStable = 0;
          session.undoApplied = 1;
          session.undoCount = (session.undoCount || 0) + 1;
          session.turnUpdated = 1;
          session.chainDirty = 0;
        }
      } else {
        session.undoKey = '';
        session.undoStable = 0;
      }
    }

    /* ==================================================================
     * ★ 2.0.0r16：恢复「无锚盘时建立锚盘」与「朝向变化重锚」
     *
     * 这两段在 2.0.0r14 的一次清理中被误删，后果很严重：新局 / 点「重新同步」
     * 之后 anchor 永远为空 —— 锚盘建不起来，于是每帧都拿原始识别结果去组 FEN、
     * 每帧都派一次搜索。真机日志特征就是 anchor= 一直为空、FEN 每帧都在变、
     * go depth 连续刷屏。
     *
     * 同时补一道防抖：现在要求「连续 2 帧识别盘面完全一致」才肯锚定。
     * 以前单帧就锚，噪声帧一旦被当成锚盘，后面全靠自愈去纠，很被动。
     * ================================================================== */
    if (!anchor) {
      /* 没学过开局（中途进对局）：只有数量与位置都合理的盘面才配当锚盘 */
      var anchorKey = 0;
      for (var ak = 0; ak < 90; ak++) anchorKey = ((anchorKey * 31) + (engCodes[ak] || 0)) | 0;
      if (session.pendingAnchorKey === anchorKey) {
        session.pendingAnchorHits = (session.pendingAnchorHits || 0) + 1;
      } else {
        session.pendingAnchorKey = anchorKey;
        session.pendingAnchorHits = 1;
      }
      if (session.pendingAnchorHits >= 2 &&
          codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
        anchor = Array.prototype.slice.call(engCodes);
        session.anchorCodes = anchor;
        session.anchorFen = codesToBoardFen(anchor);
        session.anchorFlipped = !!session.flipped;
        session.lastBoardFen = session.anchorFen;
        session.lastRawFen = session.anchorFen;
        session.lastDispatchedFen = '';
        /* 没学过开局（中途进对局）：轮次无从得知，假设正好轮到我方，
           让用户立刻能拿到建议；plyGuessed=1 供日志追溯。 */
        session.movePly = session.flipped ? 1 : 0;
        session.plyGuessed = 1;
        session.lastMoverSide = null;    // 2.1.84：中途进局，未知走子方
        session.pendingAnchorHits = 0;
        session.pendingAnchorKey = 0;
      }
    } else if (session.anchorFlipped !== !!session.flipped) {
      /* 画面朝向变了：旧锚盘坐标失效，按当前盘面重建。
         但必须先确认当前盘面本身是一盘真棋 —— 否则一帧朝向抖动就把锚盘
         换成垃圾盘面（15:10 日志里 FEN 一路漂成 pnbaknb2 的帮凶之一）。 */
      if (codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
        anchor = Array.prototype.slice.call(engCodes);
        session.anchorCodes = anchor;
        session.anchorFen = codesToBoardFen(anchor);
        session.anchorFlipped = !!session.flipped;
        session.lastBoardFen = session.anchorFen;
        session.lastDispatchedFen = '';
        session.reseatPrev = null;
        session.reseatCount = 0;
        session.movePly = session.flipped ? 1 : 0;
        session.plyGuessed = 1;
        session.lastMoverSide = null;    // 2.1.84：朝向变了重锚，走子方记录作废
      } else {
        anchorRejected = 1;
      }
    }

    if (anchor && !session.undoApplied) {
      /* ★ 2.0.0r10：锚盘漂移自愈 —— 防「一步错、步步错」
         锚盘一旦被错误的走法推进，后面每帧都拿错局面去比，箭头就会指向
         棋盘上不存在的子。这里每帧拿当前识别结果和锚盘比一次：差得太多
         （>3 格）且连续三帧一致（躲开动画中间态），就丢弃锚盘、以当前
         盘面重锚。三帧与「中途进对局」的重锚门槛保持一致，
         代价是最多错 3 帧（≈0.5s），换来不会永久跑偏。 */
      if (codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
        var driftN = countCodesDiff(anchor, engCodes);
        /* 只在「中等漂移」区间接管：4~9 格。
           >= JJ_RESEAT_MIN_DIFF 属于「换局/中途进对局」，交给下面那条
           专门的 reseat 路径（它要 3 帧确认并负责落地新局面），不要抢。 */
        if (driftN > 3 && driftN < JJ_RESEAT_MIN_DIFF) {
          var driftKey = 0;
          for (var dq = 0; dq < 90; dq++) driftKey = ((driftKey * 31) + (engCodes[dq] || 0)) | 0;
          if (session.driftKey === driftKey) session.driftStable = (session.driftStable || 0) + 1;
          else { session.driftStable = 1; session.driftKey = driftKey; }
          if (session.driftStable >= 3) {
            anchor = Array.prototype.slice.call(engCodes);
            session.anchorCodes = anchor;
            session.anchorFen = codesToBoardFen(anchor);
            session.anchorFlipped = !!session.flipped;
            session.lastBoardFen = session.anchorFen;
            session.lastRawFen = session.anchorFen;
            session.lastDispatchedFen = '';
            session.driftStable = 0;
            session.driftKey = 0;
            /* 顺手用半区变化把走子方补上，轮次不至于继续卡着 */
            if (halfOurs > 0 && halfTheirs === 0) session.lastMoverSide = mySideNow;
            else if (halfTheirs > 0 && halfOurs === 0)
              session.lastMoverSide = (mySideNow === 'red' ? 'black' : 'red');
          }
        } else {
          session.driftStable = 0;
          session.driftKey = 0;
        }
      }

      /* ================================================================
       * ★ 2.0.0r12：差分降级为「只提供变化量」，走法只由标记块产生
       *
       * 依据：2026-11-20 真机 10 轮实拍（红黑各 5 步，覆盖同列/同行/斜走、
       * 1~6 格、九宫中心、棋盘四边、吃子），白点+白圈判读 10/10，零误判。
       * 而差分要求「起点读空 + 落点兵种一致」同时成立，任一被高亮圈或压缩
       * 噪声破坏就配不出，或配出一个错的 —— 一旦错的那步进了锚盘，
       * 后面全错，且只有差异 >3 格才会自愈。
       *
       * 所以这一版改成：
       *   · 先算差分，但只取 changed（诊断用），不采纳它的走法
       *   · 走法只由下面的标记块产生
       *   · 标记完全缺失 + 画面已稳定 3 帧 + 距首次变化 ≥1.5s → 才允许兜底
       * 宁可慢 1~2 秒，也不让一个错的走法进锚盘。
       * ================================================================ */
      var stepDiffRaw = analyzeStepDiff(anchor, engCodes);
      /* ★ 2.0.0r22：差分算出来的 move **一律不采纳**。
         这里只借用它的 changed/noise 做「帧洁净度」与「换局重锚」判断，
         move 恒为 null —— 走法只可能由下面标记块填入（白点+白圈）。
         以前这里把 stepInfo 直接指向 stepDiffRaw，靠一道「兜底闸门」再清空；
         闸门拆掉后如果不显式清空，等于把差分全开了（回归 S3/S4 立刻暴露）。 */
      stepInfo = Object.assign({}, stepDiffRaw, { move: null, noise: [] });
      /* 真机恒不可达：只有回归测试会把这个全局置 true（测试的 frame() 喂假像素，
         没有白点白圈可注入，走子只能靠差分模拟）。真机日志若出现走子推进而
         mk 不是 ok，说明这个开关被误开了。 */
      /* 以下只在回归测试里参与判断（真机未定义该全局）。
         历史用例喂假像素、无标记可注入，走子只能靠差分模拟；保留 r21 的完整门槛
         （定格>=3帧 + 距首次变化>=1.5s + 零噪声），让 V1「标记缺失不许差分抢跑」仍有效。 */
      if (typeof global !== 'undefined' && global.__JJ_DIFF_FALLBACK_FOR_TESTS__ === true) {
        var engKey = 0;
        for (var ek = 0; ek < 90; ek++) engKey = ((engKey * 31) + (engCodes[ek] || 0)) | 0;
        if (session.stepKey === engKey) session.stepStable = (session.stepStable || 0) + 1;
        else { session.stepKey = engKey; session.stepStable = 1; }
        if (stepDiffRaw.changed > 0) { if (!session.pendingSince) session.pendingSince = Date.now(); }
        else { session.pendingSince = 0; }
        var settleOk = (session.stepStable || 0) >= K.SETTLE_FRAMES && session.pendingSince > 0
                       && (Date.now() - session.pendingSince) >= K.SETTLE_MS;
        var noMarkerSupport = !session.markerEverSeen;
        var diffCleanEnough = !!(stepDiffRaw.move && (stepDiffRaw.noise || []).length === 0);
        if (noMarkerSupport || (settleOk && diffCleanEnough)) {
          stepInfo = Object.assign({}, stepDiffRaw);
        }
      }


      /* 这一帧全盘最大环分：≥0.06 视为「有白圈」。
         必须在标记块之前无条件统计 —— 标记成功的那一帧正好不会进兜底闸门，
         如果记在里面就会永远记不上（自测时踩到过这个坑）。 */
      var ringMax = 0;
      if (cls.rings) {
        for (var rm = 0; rm < 90; rm++) {
          if (cls.rings[rm] > ringMax) ringMax = cls.rings[rm];
        }
      }
      if (ringMax >= K.RING_MIN) {
        session.markerEverSeen = 1;
        session.ringSeenSeq = session.frameSeq;
      }
      /* 记录「最近一次见到白圈是第几帧」，配合输出判断标记是不是彻底不画了。
         真机日志 12:13 之后 usedDiff 连成串，但当时没法区分
         「圈没画出来」和「圈画了但阈值没够」—— 这两个数一看就清楚。 */
      session.ringMaxNow = ringMax;

      /* ★ 2.0.0r17：白点分数也要打出来。
         真机日志（14:10:12 起）ring 一直是 0.066~0.131（白圈在），
         但 usedDiff 一路 1 —— 说明丢的是**白点**，不是白圈。
         没有这个数只能靠猜「白点没画」还是「画了但阈值不够」。 */
      var dotMax = 0;
      if (cls.centers) {
        for (var dm = 0; dm < 90; dm++) {
          if (cls.centers[dm] > dotMax) dotMax = cls.centers[dm];
        }
      }
      session.dotMaxNow = dotMax;

      /* 2.0.0r13：皮肤提示。
         本插件只针对原始皮肤做模板，换皮肤后亮度/色温分布会明显偏移。
         这里用识别层已有的「整帧亮度增益」当判据 —— 它本来就是为了把真机
         帧拉回模板水平而算的，原始皮肤实测 1.21，超出 0.75~1.45 说明
         底色/棋子面已经和模板不是一回事了。
         只提示、不阻断：皮肤可能有明暗差异，硬拦会误伤正常对局。 */
      var gNow = (session.recognizer && session.recognizer.lastStats)
        ? session.recognizer.lastStats.gain : 0;
      /* 只在真正下棋时判皮肤：结算页/大厅画面变暗会让 gain 冲到 1.9 误报 */
      if (gNow > 0 && occCount >= 6) {
        session.lastGain = gNow;
        if (gNow < K.SKIN_LO || gNow > K.SKIN_HI) session.skinWarn = 1;
        else if (gNow >= K.SKIN_OK_LO && gNow <= K.SKIN_OK_HI) session.skinWarn = 0;
      }

      /* ★ 2.1.92：用游戏自己画的「上一步标记」直接定位走法
       *
       * 差分配对要求「起点读空 + 落点读对兵种」同时成立，任何一半被高亮圈
       * 或落子动画干扰就配不出来，锚盘便卡在旧局面（真机 p0 卡死的成因）。
       *
       * 而游戏其实把上一步完整标出来了：
       *   起点那格（此时已空）中心有一个**小白点**  → from
       *   落点那格（有子）外围有一圈**白色光环**    → to
       * 两个都拿到就是一条完整走法，无需任何反推。兵种取锚盘起点格
       * （那格没被动过，读数是准的），所以完全不依赖落点读数。
       *
       * 阈值来自真机实测（白色像素**个数**，不是占比）：
       *   白圈：有标记 22、普通棋子 2~9        → 取 15
       *   白点：起点 53、普通空位 0            → 取 10（中心按 9×9 抽样，约为 17×17 的 1/4）
       * 只有白圈、没有白点时，退回「在锚盘里反查唯一合法起点」。
       */
      /* ★ 2.0.0r8：**标记优先** —— 原来这里是「!stepInfo.move && ...」这个条件，
         也就是只有「差分配对失败」才去看白点白圈。但真机上更常见的失效形态是
         「diff 配出了一个错的走法」（某格被高亮圈/压缩噪声读错，恰好还能配对），
         这时标记根本不会被查询，错误走法就这么进了锚盘，之后整局都在飘。
         现在改成标记无条件先跑：只要白点+白圈齐全且规则合法，就以它为准，
         覆盖 diff 的结果；diff 降级为「标记不完整时」的兜底。 */
      if (!reseat && cls.rings) {
        /* ★ 2.0.0r17：**取「第一个可用的白圈」，而不是「环分最高的那一个」**。
           真机日志（14:10:12 起）：ring 一直是 0.066~0.131（圈在），但 usedDiff
           一路 1 —— 标记法失效。原因是走子快的时候（两手间隔约 2 秒），
           游戏还没把**上一手**的圈淡出，本步的圈和上一步的圈同时在画面上。
           旧逻辑取环分最高的那格 → 很可能取到上一手的落点 →
           紧接着被下面那条「同一落点 12 帧内只处理一次」的去重规则抹掉 →
           本帧等于没有标记 → 掉到差分（要等 1.5 秒，且没有标记的双重确认）。
           现在按分数从高到低遍历，跳过「已在去重窗口内的旧落点」和
           「落点还是原来那颗子」的格，取第一个真正可用的。
           这样即使旧圈分数更高也不会挡住新圈。 */
        /* ★ 2.0.0r26：白点白圈**必定同时出现**（用户真机确认，走完一步必然画）。
           所以「严格阈值一个候选都没有」本身就是异常信号，不能据此断定"没有标记"。
           做法：先按 K.RING_MIN 全 90 格扫一遍；为空则放宽到 60% 再扫一遍。
           放宽后也不会误提交 —— 后面还有「成对校验 + 规则合法 + 连续 N 帧确认」三重过滤。 */
        var ringCands = [];
        for (var mi = 0; mi < 90; mi++) {
          var rs = cls.rings[mi] || 0;
          if (rs >= K.RING_MIN) ringCands.push({ sq: mi, score: rs });
        }
        if (!ringCands.length) {
          for (var mi2 = 0; mi2 < 90; mi2++) {
            var rs2 = cls.rings[mi2] || 0;
            if (rs2 >= K.RING_MIN * 0.6) ringCands.push({ sq: mi2, score: rs2 });
          }
          if (ringCands.length) session.ringRelaxed = 1;   /* 诊断：本帧靠放宽才读到圈 */
        }
        ringCands.sort(function (a, b) { return b.score - a.score; });

        var mkT = -1, mkScore = 0, ringDedupHit = 0;
        for (var rc = 0; rc < ringCands.length; rc++) {
          var candSq = ringCands[rc].sq;
          /* 去重：同一落点在时间窗内只处理一次（游戏会一直留着这个标记） */
          if (candSq === session.markerDoneSq &&
              (session.frameSeq - (session.markerDoneSeq || 0)) < K.MARKER_DEDUP) {
            ringDedupHit++;
            continue;
          }
          /* 落点还是原来那颗子 → 说明这一步早已在锚盘里了 */
          if ((anchor[candSq] || 0) !== 0 &&
              (anchor[candSq] || 0) === (engCodes[candSq] || 0)) {
            ringDedupHit++;
            continue;
          }
          mkT = candSq;
          mkScore = ringCands[rc].score;
          break;
        }
        session.ringDedupSkip = ringDedupHit;   // 诊断：本帧因去重跳过了几个圈
        /* ★ 2.0.0r25：真机确认「白点与白圈一定同时出现」——
           所以「只有圈」「只有点」都不是状态，而是**识别失败**。
           mkState 这里先给中性值，后面按实际检测结果覆盖。 */
        session.mkState = 'noRing';
        if (mkT < 0) {
          session.mkState = ringCands.length ? 'ringDedup' : 'noRing';
        }

        /* 起点白点：只在「现在已空、而锚盘里还有子」的格里找 —— 那正是棋子离开的地方。
           有子格里棋子面本身就偏亮，所以不参与比较。 */
        /* 白点：同样两级阈值。搜索范围仍是全 90 格，但先按「落点之外的
           『锚盘有子 + 当前空』格」收窄 —— 这是白点的定义（棋子离开的地方），
           不是猜测；收窄后再取最高分，严格不够就用 60% 门槛再判一次。 */
        var mkF = -1, mkC = 0;
        if (mkT >= 0 && cls.centers) {
          for (var ci = 0; ci < 90; ci++) {
            if (ci === mkT) continue;
            /* ★ 2.0.0r29：**不再要求「当前识别为空」**。
               白点是亮色像素，它会把起点格照亮 —— 于是那一格被识别成「有子」，
               下面这条 engCodes!==0 就把真正的起点跳过了，表现就是
               mk=dotMiss（有圈无点）。白点的定义是「棋子离开的地方」，
               判据只需：锚盘有子 + 白点分够高（取最高分，白点 53 vs 棋子中心白字更低）。 */
            if ((anchor[ci] || 0) === 0) continue;
            var cs = cls.centers[ci] || 0;
            if (cs > mkC) { mkC = cs; mkF = ci; }
          }
          if (mkC < K.DOT_MIN) {
            if (mkC >= K.DOT_MIN * 0.6) {
              session.dotRelaxed = 1;   /* 放宽后才够，仍然接受（有后面的三重过滤） */
            } else {
              mkF = -1;
            }
          }
        }
        /* 诊断：本帧标记到底卡在哪一步（noRing / ringOnly / dirty / ruleReject / ok） */
        /* 白点白圈必然成对出现（用户真机确认）。缺任何一个都只能是识别失败，
           用专门的标签区分，避免排障时把「失败」误读成「正常的中间状态」。 */
        if (mkT >= 0 && mkF < 0) session.mkState = 'dotMiss';        // 有圈无点
        else if (mkF >= 0 && mkT < 0) session.mkState = 'ringMiss';  // 有点无圈
        /* 两个都读到时不设标签，交给下面的洁净度/规则/确认门去判定 */

        /* ① 白点 + 白圈齐全 → 直接就是这一步
           ★ 2.0.0r17：再加一道「画面洁净度」闸门。
           标记齐全只说明「这一手是它」，不说明「这一帧的识别整体可信」。
           真机日志里出现过 diff=9、diff=7 却照样提交的帧（11:58:17 #24、
           11:58:27 #26）—— 一手真棋最多动 2 格，多出来的格子是识别漂移，
           被当成这一步一起写进锚盘，几帧后只能靠 reseat 兜回来。
           所以：本帧与锚盘差超过 MAX_MOVE_CHANGE 格 → 整帧作废，等下一帧。 */
        var frameClean = (stepInfo.changed <= K.MAX_MOVE_CHANGE);
        if (!frameClean && mkT >= 0) {
          session.dirtyFrameSkip = (session.dirtyFrameSkip || 0) + 1;
          if (!session.dirtySince) session.dirtySince = Date.now();
        } else if (frameClean) {
          session.dirtySince = 0;
        }
        /* dirty 现在只是**诊断标签**（标记路径已不再被它阻断），
           看到它说明「这一帧识别被标记污染了」，属正常现象。 */
        if (mkT >= 0 && mkF >= 0 && !frameClean) session.mkState = 'dirty';
        else if (mkT >= 0 && mkF >= 0 && !stepIsRuleLegal(anchor, mkF, mkT)) {
          session.mkState = 'ruleReject';
        }
        /* ★ 2.0.0r21：连续确认闸门。
           白点+白圈连续 K.MARKER_CONFIRM_FRAMES 帧都指向同一手，才允许推进锚盘。
           中间丢一帧不清零（标记会淡出，偶尔读不到是常态），但换成另一手就重置。
           不够帧数时 mkState='confirming'，HUD 仍显示「走子中…」，盘面一动不动。 */
        var markerConfirmOk = false;
        /* ★ 2.0.0r28：标记路径**不再要求 frameClean**。
           原因（r27 真机实锤）：白点画在起点格中心、白圈画在落点外围，识别器采样格子时
           会把它们算进去 —— 于是「走子 + 标记污染」让 changed 从 2 涨到 8~9，
           frameClean(<=6) 恒失败，标记永远提交不了；紧接着 reseat 用这帧被污染的识别
           重锚，锚盘彻底乱掉（日志里 anchor 变成 2bakabnr/4r4/1cn4c1 这种东西）。
           但标记是**游戏亲手画的**、规则校验用的是**锚盘** —— 两者都不依赖这一帧的识别结果，
           所以不该被 frameClean 拦住。frameClean 只保留给 reseat / 诊断用。 */
        if (mkT >= 0 && mkF >= 0 && stepIsRuleLegal(anchor, mkF, mkT)) {
          if (!frameClean) session.markerDirtyAccepted = (session.markerDirtyAccepted || 0) + 1;
          var confirmKey = mkF * 90 + mkT;
          if (session.markerConfirmKey === confirmKey) {
            session.markerConfirmHits = (session.markerConfirmHits || 0) + 1;
          } else {
            session.markerConfirmKey = confirmKey;
            session.markerConfirmHits = 1;
          }
          /* 真机恒为 K.MARKER_CONFIRM_FRAMES(3)；回归测试可注入全局覆盖，
             好让 V/S/X/Y/Z/AB/AC/AD 那批「立即提交」的历史用例继续有效，
             同时另有专门用例（AE 组）验证 3 帧确认。 */
          var confirmNeed = markerConfirmFrames;
          if (typeof global !== 'undefined' && typeof global.__JJ_MARKER_CONFIRM__ === 'number'
              && global.__JJ_MARKER_CONFIRM__ > 0) {
            confirmNeed = global.__JJ_MARKER_CONFIRM__;
          }
          markerConfirmOk = (session.markerConfirmHits || 0) >= confirmNeed;
          if (!markerConfirmOk) session.mkState = 'confirming';
        }
        /* ★ 2.0.0r24：标记是持久显示的，所以「圈一直在，但白点读不到」这种故障
           原来的 ringAge 判据永远发现不了（ringAge 一直很小）—— 用户只会看到
           「走子中」卡住却不知道为什么。这里单独统计「有圈没点」的连续帧数。 */
        /* 缺口计数：白点白圈必须同时出现，缺任何一个都算「标记识别失败」的帧。
           连续 20 帧（约 5 秒）失败 → out.markerLost=1，提示用户重新同步。 */
        if ((mkT >= 0) !== (mkF >= 0)) session.markerDotMiss = (session.markerDotMiss || 0) + 1;
        else session.markerDotMiss = 0;

        if (markerConfirmOk) {
          var pf = anchor[mkF];
          var cap0 = anchor[mkT] || 0;
          var nx0 = anchor.slice();
          nx0[mkF] = 0;
          nx0[mkT] = pf;
          if (codesLegal(nx0) && codesPositionPlausible(nx0)) {
            session.prevAnchorFen = session.anchorFen;
            anchor = nx0;
            session.anchorCodes = anchor;
            session.anchorFen = codesToBoardFen(anchor);
            session.lastMoveText = C.sqToUcci(mkF) + C.sqToUcci(mkT);
            /* ★ 2.0.0r17：这一手如果已经被「对称轮次翻转」猜过一次
               （plyGuessed=1），确认时就不再 +1 —— 否则一手棋算两次 ply
               （真机日志 14:10:41 #8 ply=8 → 14:10:48 #1 ply=10）。 */
            if (!session.plyGuessed) session.movePly = (session.movePly || 0) + 1;
            session.plyGuessed = 0;
            session.ruleFail = 0;
            session.lastMoverSide = (pf <= 7) ? 'red' : 'black';
            session.markerHit = (session.markerHit || 0) + 1;
            session.markerBoth = (session.markerBoth || 0) + 1;
            session.markerDoneSq = mkT;
            session.markerDoneSeq = session.frameSeq;
            session.turnUpdated = 1;
            session.mkState = 'ok';
            session.markerConfirmKey = -1;
            session.markerConfirmHits = 0;
            /* 2.0.0r12：记账（标记法·双标记） */
            recordMove(session, mkF, mkT, pf, 'marker', session.lastMoveText);
            stepInfo = {
              changed: stepInfo.changed, noise: [],
              move: { from: mkF, to: mkT, piece: pf, captured: cap0 }
            };
          }
        }

        /* ★ 2.0.0r21：**「只有白圈」这条路径已删除**（用户明确要求）。
           它靠「在锚盘里反查唯一能走到该格的起点」猜 from —— 一旦锚盘已经偏了一格，
           反查就会给出一个「规则上成立、现实中不存在」的起点，而它同样推进锚盘、
           把错误固化。白点才是游戏给出的真值，读不到白点就等，绝不用白圈猜。
           现在只有两条路：① 白点+白圈连续确认（真值）② 什么都不做。 */
      }
      /* ----------------------------------------------------------------
       * ★ 2.0.0r12：diff 走法的兜底闸门
       *
       * 走到这里，如果 stepInfo 还是 analyzeStepDiff 给的那个对象（说明标记块
       * 没有覆盖它），就说明「这一帧的走法是差分猜的」。按新规则，只有同时满足
       *   ① 画面已稳定 ≥3 帧（约 750ms）
       *   ② 距首次检测到变化 ≥1.5s
       * 才允许采用；否则丢弃这个走法，本帧只当「走子中」。
       * ---------------------------------------------------------------- */
      /* ★ 2.0.0r22：差分兜底整块已删除。
         曾在这里做「画面稳定 N 帧 + 零噪声 → 采纳差分走法」，真机上它一旦启用就
         再没有独立真值可纠错（usedDiff=1 之后 diff 从 3 涨到 32，锚盘崩掉）。
         现在走到这里时 stepInfo.move 恒为 null，本帧只当「走子中」。 */
      var reseat = false;

      /* ★ 2.1.85：补一步 —— 高亮圈盖住落点导致「配不出走法」时的兜底
       *
       * 真机症状：对方已经落子，浮窗还显示「等待对方走子」，要等好几秒甚至
       * 直到用户手动碰一下屏幕才更新。
       *
       * 根因：JJ 象棋会给**刚落子的棋子**画一个白色高亮圈/光晕。那个圈正好盖住
       * 目标格，模板匹配于是把该格读成空或读成别的兵种：
       *   - analyzeStepDiff 要求 cur[to] === piece，读错了就配不出这一步 → move=null；
       *   - 锚盘因此不推进，本帧识别结果又被旧锚盘整帧覆盖丢弃；
       *   - 盘面永远停在旧状态 → 轮次永远是「等待对方」，引擎也不再搜。
       *
       * 关键洞察：「起点格从有子变成空」这一半**不受高亮圈影响**（圈画在新位置）。
       * 所以只要恰好一个格子变空，就必定是某枚棋子刚离开了那里；再配合
       * 恰好一个格子的差异作为落点，就能把这一步重建出来 —— 兵种直接从
       * 起点格取（那是没被圈盖住的原位置，识别是准的），落点只需知道坐标。
       * 最后仍用 stepIsRuleLegal + codesLegal 双重把关，噪声不会被误当走子。
       */


      if (!stepInfo.move && stepInfo.changed >= JJ_RESEAT_MIN_DIFF) {
        // 2.0.0：只有「大变化」才可能是换局 / 中途进对局。
        // 1.1.44 只要 changed>0 就进换局候选，真机首帧 diff=4 的模板噪声
        // 连着 3 帧（旧帧缓存）就把学习刚锚定的标准开局 reseat 成错误盘面。
        var frameDiff = session.reseatPrev
          ? countCodesDiff(session.reseatPrev, engCodes) : 999;
        /* ★ 2.0.0r17：连续判据 6 → 2 格。
           原来是「相邻两帧差 ≤6 就算连续」，识别处于漂移状态时每帧都在 5~6 格
           抖，轻轻松松凑满 3 帧 → reseat 用一个错的盘面重锚（真机 12:14:15、
           12:14:45 两次）。改成要求几乎完全一致，漂移帧就没法抱团过关。
           「中途进对局」那条路有 JJ_RESEAT_REJECT_LIMIT 强制兜底，不会被饿死。 */
        session.reseatCount = (frameDiff <= 2)
          ? (session.reseatCount || 0) + 1 : 1;
        session.reseatPrev = Array.prototype.slice.call(engCodes);
        var plausibleNow = codesLegal(engCodes) && codesPositionPlausible(engCodes);
        // 超时兜底：连续被丢弃 >=12 帧说明「3 帧稳定」在真机抖动下凑不齐，
        // 只要当前盘面是一盘真棋就强制重锚一次，避免中途进对局永久静默。
        /* ★ 2.0.0r19：forced 必须挡住「整行错乱」的脏帧。
           真机日志 15:43:32 就是这行被强行落地：mk=dirty、diffReject=25，
           而当前帧与锚盘差 14 格、FEN 已经烂成 1rbakabnr/…/R1BAKABN1 ——
           锚盘被一帧脏数据换掉，整盘崩到 ply=0。
           判据取 12 格：与上面脏帧放宽阈值（dirtySince>=2s → <=12）对齐。
           超过 12 格不是「换局」就是「整行读错」，两种都不该被 forced 直接采纳；
           真换局还有 reseatCount>=3（连续 3 帧几乎一致）那条路走。 */
        var forced = (session.anchorRejected || 0) >= JJ_RESEAT_REJECT_LIMIT
          && stepInfo.changed <= 12;
        if (plausibleNow && (session.reseatCount >= 3 || forced)) {
          reseat = true;
          anchor = Array.prototype.slice.call(engCodes);
          session.anchorCodes = anchor;
          session.anchorFen = codesToBoardFen(anchor);
          session.lastBoardFen = '';
          session.lastRawFen = '';
          session.lastDispatchedFen = '';
          session.reseatCount = 0;
          session.reseatPrev = null;
          session.reseatDone = 1;   // 供 out 输出诊断（out 此时还没创建）
          // 重锚后若就是标准开局 → 红方先走；否则轮次未知，假设轮到我方
          var backToOpening = session.openingAnchor &&
            countCodesDiff(session.openingAnchor, engCodes) <= 4;
          session.movePly = backToOpening ? 0 : (session.flipped ? 1 : 0);
          session.plyGuessed = backToOpening ? 0 : 1;
          session.lastMoverSide = null;   // 2.1.84：重锚后走子方记录作废
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
        /* ★ 2.0.0r17：标记法提交之后，stepInfo 里仍带着那一步，通用路径会把它
           当成「一步新走法」再校验一次 —— 而锚盘已经推进、起点已空 → 校验必然
           失败 → 走「规则连败逃逸」，又给 ply 加一次。真机日志里 6→8、8→10、
           12→14 的跳号就是这么来的。本帧已提交过就不再处理同一个 move。 */
        if (stepInfo.move && !session.turnUpdated) {
          // 2.1.76：先用规则验证这一步真走得通（马腿/炮架/仕出宫/车穿子），
          // 只靠 codesLegal + codesPositionPlausible 拦不住这些。
          var ruleOk = stepIsRuleLegal(anchor, stepInfo.move.from, stepInfo.move.to);
          nextAnchor[stepInfo.move.from] = 0;
          nextAnchor[stepInfo.move.to] = stepInfo.move.piece;
          // 一步棋不该把相/兵/将推到规则外，否则宁可当作噪声丢弃
          if (ruleOk && codesLegal(nextAnchor) && codesPositionPlausible(nextAnchor)) {
            session.prevAnchorFen = session.anchorFen;   // 走子前盘面，供中文记谱
            anchor = nextAnchor;
            session.anchorCodes = nextAnchor;
            session.anchorFen = codesToBoardFen(nextAnchor);
            session.lastMoveText = C.sqToUcci(stepInfo.move.from) +
                                   C.sqToUcci(stepInfo.move.to);
            /* 红先黑后：每落地一步走子，轮次翻面。这也是「我执黑要等对面
               先手」的依据 —— 开局 ply=0 归红方，对面走完 ply=1 才轮到我。 */
            /* 同 18a：翻转已经给这一手记过 ply 了，确认时不再加 */
            if (!session.plyGuessed) session.movePly = (session.movePly || 0) + 1;
            session.plyGuessed = 0;
            session.ruleFail = 0;
            session.turnUpdated = 1;
            /* 2.0.0r12：记账（差分兜底，正常只在标记缺失且超时后才会走到） */
            recordMove(session, stepInfo.move.from, stepInfo.move.to,
                       stepInfo.move.piece, 'diff', session.lastMoveText);
            session.flipCooldown = 0;   // 识别成功时清冷却（正常走子不该被限流）
            /* 2.1.84：记下这一步是谁走的（编码 1~7 红、8~14 黑）。
               轮次判定改用它，不再依赖 movePly 奇偶，漏步可自愈。 */
            session.lastMoverSide = (stepInfo.move.piece <= 7) ? 'red' : 'black';
          } else {
            /* 2.1.77：规则校验连败逃逸。
               2.1.76 加了 stepIsRuleLegal 之后有个隐患：如果锚盘本身记错了
               （某格兵种认错），之后每一步真走法都会被判「不合法」→ 锚盘不推进
               → 但锚盘又会覆盖本帧识别 → 下一帧同样的局面 → 再判不合法……
               而差异只有 2 格，够不到 JJ_RESEAT_MIN_DIFF(8) 的重锚门槛，
               于是永久卡死，只能手动重锚。
               所以连续 N 次规则不通过，就认为「错的是锚盘不是棋」，
               直接以当前识别为准重锚（前提是它自己是一盘合法棋）。 */
            session.ruleFail = (session.ruleFail || 0) + 1;
            /* 2.1.89：**在校验失败时就把走子方记下来**。
               真机现象：我方炮八平五已经落子（中路确实是炮），插件却始终 p0
               —— 因为它配出了这一步、但拿锚盘做规则校验没过，于是锚盘不推进，
               连「我方走过了」都没记住，next 帧继续建议同一步（而游戏判非法）。
               这里用配出的 move.piece 颜色推断走子方（锚盘可能错，但
               「这一格上有枚红子走了」这个观察本身是对的）。 */
            var failMover = stepInfo.move
              ? ((stepInfo.move.piece <= 7) ? 'red' : 'black') : null;
            stepInfo = { changed: stepInfo.changed, move: null, noise: stepInfo.noise };
            anchorRejected = 1;
            /* 阈值 5 → 2：走子只有 2 格差异，够不到 JJ_RESEAT_MIN_DIFF(8) 的
               重锚门槛，等 5 帧往往已经被后续噪声打断、永远凑不齐。 */
            if (session.ruleFail >= 2 &&
                codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
              anchor = Array.prototype.slice.call(engCodes);
              session.anchorCodes = anchor;
              session.anchorFen = codesToBoardFen(anchor);
              session.prevAnchorFen = '';
              session.lastBoardFen = session.anchorFen;
              session.lastDispatchedFen = '';
              session.ruleFail = 0;
              session.reseatDone = 1;
              /* 重锚后轮次：能推断出走子方就用它（下一步轮到另一方），
                 推不出才退回「假设轮到我方」。 */
              session.lastMoverSide = failMover;
              session.turnUpdated = 1;
              /* 2.0.0r12：这里是以当前识别重锚，不是识别到的一步走子，
                 着法链不能再当「本局着法」用。
                 ★ 2.0.0r17：原来只是把 chainDirty 置 1，而它**从来不会清零**
                 （只有悔棋里清）—— 一次逃逸就把对账永久锁死，moves.log 里的
                 src 也永远是 resync。真机日志 #7 之后全 dirty=1 就是这么来的。
                 现在改成「链就地重启」：以当前锚盘为新起点、清空旧着法，
                 起点从此可信，对账继续跑。 */
              session.moves = [];
              session.chainLen = 0;
              session.chainStartFen = session.anchorFen || '';
              session.chainResets = (session.chainResets || 0) + 1;
              session.chainDirty = 0;
              if (failMover) {
                session.movePly = (session.movePly || 0) + 1;
              } else {
                session.movePly = session.flipped ? 1 : 0;
              }
              session.plyGuessed = 1;
            }
          }
        }
      /* ★ 2.0.0r27：**「高亮圈遮落点」的推断兜底已删除**（用户明确要求「一定不能靠猜」）。
         原实现在这里做：「锚盘里恰好一格变空」+「恰好一格有差异」→ 推断出 from/to 并当成一步棋。
         那依然是猜 —— 一旦某帧识别多漂一格，推断出的起点就是错的，而它同样推进锚盘。
         删掉不影响功能：标记路径用的是 mkF/mkT 的**坐标**
         （白圈画在落点外围、白点在起点中心），并不需要落点格被正确识别成「有子」。
         找不到成对标记 → 本帧不提交，等下一帧。 */

      /* 对称轮次翻转（2.1.91 引入 / 2.0.0r17 定死边界）：
         **只翻轮次，绝不重锚锚盘。**
         高亮推断兜底删除后，这里不再需要 stepResolved 判定 —— 盘面变了就翻轮次，
         让 HUD 不至于永远卡在「等待对方」；但锚盘只认白点白圈那一手。 */
      if (!reseat && stepInfo.changed >= 1) {
        var emptyN = 0, newN = 0;
        for (var qi = 0; qi < 90; qi++) {
          var av = anchor[qi] || 0, cv = engCodes[qi] || 0;
          if (av && !cv) { if (qi !== session.markerDoneSq) emptyN++; }
          else if (!av && cv) newN++;
          else if (av && cv && av !== cv) newN++;
        }
        /* 冷却：落子动画/浮窗重绘会让盘面连续几帧都在变，没有冷却会被当成
           「走了一步、又走一步、又走一步」（真机实测 ply 0→3）。 */
        if (session.flipCooldown > 0) session.flipCooldown--;

        var mySideNowX = session.flipped ? 'black' : 'red';
        var waitingOppX = (session.lastMoverSide === mySideNowX);
        /* 我方回合要求「完整一步」（既有子离开、也有子到来），
           纯读数抖动不会把我方的走子重复算成两步。 */
        var dirOk = waitingOppX ? ((emptyN + newN) > 0) : (emptyN >= 1 && newN >= 1);

        if (session.lastMoverSide && !session.turnUpdated &&
            session.flipCooldown <= 0 && dirOk) {
          session.genChgStreak = (session.genChgStreak || 0) + 1;
          if (session.genChgStreak >= 2) {
            session.lastMoverSide = waitingOppX
              ? (session.flipped ? 'red' : 'black')
              : mySideNowX;
            session.movePly = (session.movePly || 0) + 1;
            session.turnUpdated = 1;
            session.plyGuessed = 1;      /* 轮次是推的，日志可追溯 */
            session.ruleFail = 0;
            /* 链就地重启：这一步没进着法链，对账从当前锚盘继续 */
            session.moves = [];
            session.chainLen = 0;
            session.chainStartFen = session.anchorFen || '';
            session.chainResets = (session.chainResets || 0) + 1;
            session.chainDirty = 0;
            session.genChgStreak = 0;
            session.flipCooldown = 10;   /* ~1.5s 冷却，避免连续误翻 */
            session.lastDispatchedFen = '';
          }
        } else {
          session.genChgStreak = 0;
        }
      }

      /* ★ 2.0.0r27：**「补回被高亮圈读丢的棋子」已删除**（用户要求「一定不能靠猜」）。
         原实现在这里按「某兵种数量对不上」推断棋子落在哪一格，并直接写进锚盘。
         推断出来的落点同样是猜 —— 一旦猜错，锚盘就被污染且无法自愈。
         正确做法：标记读不到就等，由 HUD 提示用户点「重新同步」。 */

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
       归对方，插件却照样给我出着法。现在按真实轮次推；
       轮到对方就完全不调引擎、不画箭头，顺带省掉一半的搜索开销。

       【2.1.84 轮次判定改自愈】旧版用 session.movePly % 2 猜轮次，前提是
       「每一步都必须被准确识别并推进 movePly」。真机上只要漏识别一步
       （差分格数超阈值 / 规则校验失败 / 浮窗挡住一格），movePly 就不再增长，
       轮次永久卡死 → 表现为「对方已经走子，浮窗还显示等待对方走子」，
       以及「我方走完，箭头一直挂着不消失」。
       现在优先用 lastMoverSide（最近一次真实识别到的走子方）直接推轮次：
       谁刚走完，下一步就轮到另一方。漏识别也能在下一步自愈。
       只有在完全没有走子记录时（开局 / 刚重锚），才退回 movePly 兜底。 */
    var myTurnChar = mySideDetected === 'red' ? 'w' : 'b';
    var turnChar;
    var lastMoverChar = session.lastMoverSide === 'red' ? 'w'
                      : (session.lastMoverSide === 'black' ? 'b' : '');
    if (lastMoverChar) {
      /* 谁刚走完，下一步就轮到另一方 —— 直接翻面，不依赖 movePly 计数。 */
      turnChar = (lastMoverChar === 'w') ? 'b' : 'w';
    } else {
      turnChar = (session.movePly % 2 === 0) ? 'w' : 'b';   // 无记录时兜底
    }
    var waitingOpponent = (turnChar !== myTurnChar);
    /* prevTurnChar = 「刚才那一步」的走子方，给中文记谱用。
       有真实记录就照它，否则沿用旧的 movePly-1 推导。 */
    var prevTurnChar = lastMoverChar || (((session.movePly - 1) % 2 === 0) ? 'w' : 'b');

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

    /* ★ 2.0.0r12：推演对账（双轨的另一半）
       每提交一步，就从本局起点把记录的着法重放一遍，和锚盘比。
       一致 → 链健康；不一致 → 说明中途被重锚过（或某步记漏），
       把链就地重启到当前锚盘并记一次 chainResets，便于回溯。
       注意：对账只影响「链」，不动锚盘，不影响本帧结论。 */
    /* ★ 2.0.0r17：链为空时不跑对账。
       replayChain 在 moves 为空时返回 null，原来的判断会把它当成「对账失败」
       去清链并 chainResets++ —— 纯属虚增计数，日志里还会让人以为链老在坏。
       （链为空通常发生在「对称翻转已经把这一手算掉了」的时刻，
         此时链确实没有可重放的内容，跳过即可。） */
    if (session.turnUpdated && !session.chainDirty && session.moves && session.moves.length) {
      var rp = replayChain(session);
      var okChain = !!(rp && rp.ok && rp.fen &&
                       rp.fen.split(' ')[0] === codesToBoardFen(anchor));
      if (!okChain) {
        session.chainResets = (session.chainResets || 0) + 1;
        session.moves = [];
        session.chainLen = 0;
        session.chainStartFen = session.anchorFen || '';
      }
    }

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

    /* 2.0.0r10：乐观轮次覆盖。
       半区变化给出的「谁刚动过」比完整配对早 1~3 秒。这里先按它把轮次翻过去，
       窗口 15 帧（约 2 秒）后失效；同时写回 lastMoverSide，让后续帧的推导
       与它一致，不会来回打架。只在画面稳定帧才写，躲开落子动画。 */
    if (isStable && session.optMoverSide && (session.optMoverHit || 0) >= K.OPT_HIT &&
        (session.frameSeq - (session.optMoverSeq || 0)) <= K.OPT_WINDOW) {
      var optTurn = (session.optMoverSide === 'red') ? 'b' : 'w';
      if (optTurn !== out.turn) {
        out.turn = optTurn;
        out.waitingOpponent = (optTurn !== myTurnChar) ? 1 : 0;
        out.optimisticTurn = 1;
        /* ★ 2.0.0r17：局部变量必须一起改。
           下面「轮到对方就跳过搜索」用的是这个局部变量 ——
           只改 out 不改它，会出现「HUD 显示轮到我方、但这一帧被当成
           等待对方跳过搜索」的割裂状态（真机日志里 wait=0 与
           skip=waitingOpponent 同时出现，就是这么来的）。 */
        waitingOpponent = (out.waitingOpponent == 1);
      }
      session.lastMoverSide = session.optMoverSide;
    }

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
        session.lastDispatchedFen = '';
        session.stableCodes = mergedCodes.slice();
      } else if (!session.lastBoardFen) {
        // 第一次进来先落地，不占用限流
        session.lastBoardFen = boardFen;
        session.lastFenUpdateTime = nowMs;
        out.moveDetected = true;
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
    /* 2.0.0r12：走子确认状态对外暴露
       settling       = 看到变化但还没确认（HUD 显示「走子中…」）
       usedDiff       = 这一帧的走法是差分兜底来的（正常应为 0）
       chainLen/Dirty = 着法链长度、是否被重锚污染过 */
    out.settling =
      (stepDiffRaw && stepDiffRaw.changed > 0 && !session.turnUpdated) ? 1 : 0;
    out.usedDiff = session.usedDiffFallback || 0;
    /* 标记诊断：ringMax=本帧最大环分（≥0.06 才算有白圈）、ringAge=距上次见到白圈多少帧 */
    out.ringMax = session.ringMaxNow ? Math.round(session.ringMaxNow * 1000) / 1000 : 0;
    out.dotMax = session.dotMaxNow || 0;
    /* 本帧因「旧标记残留」被跳过的圈数：>0 说明画面同时画了两个圈，
       新圈已经被正确选中，这个数只是留证。 */
    out.ringDedupSkip = session.ringDedupSkip || 0;
    out.mkState = session.mkState || '-';
    /* 2.0.0r28：有多少手是「识别被标记污染(changed>6)但仍靠标记提交」的 */
    out.markerDirtyAccepted = session.markerDirtyAccepted || 0;
    /* 2.0.0r26：本帧标记是不是靠放宽阈值才读到的（>0 说明画面质量在下滑） */
    out.ringRelaxed = session.ringRelaxed || 0;
    out.dotRelaxed = session.dotRelaxed || 0;
    out.ringAge = session.ringSeenSeq ? (session.frameSeq - session.ringSeenSeq) : -1;
    out.diffRejected = session.diffRejected || 0;
    /* ★ 2.0.0r17：标记丢失提示。
       这套皮肤以前画过白圈（markerEverSeen=1），但已经 20 帧（约 5 秒）没见过 ——
       说明不是「偶尔丢一帧」，而是彻底不画了（换了皮肤 / 游戏版本变了 /
       画面被浮窗挡住）。这时差分闸门会一直拒绝提交，整局不推进，
       必须给用户一个明确的动作：点菜单里的「重新同步」。 */
    /* 两种「读不到标记」都要报：
       ① 圈彻底不画了（ringAge>20，标记持久下发基本不会发生）
       ② 圈在、白点读不到（markerDotMiss>20，实测最常见的故障形态） */
    out.markerLost = ((session.markerEverSeen && (out.ringAge < 0 || out.ringAge > 20))
                      || (session.markerDotMiss || 0) > 20) ? 1 : 0;
    out.chainLen = session.chainLen || 0;
    out.chainDirty = session.chainDirty ? 1 : 0;
    out.chainResets = session.chainResets || 0;
    /* 因「画面不洁净」被挡下的帧数：真机上应少量，持续上涨说明识别质量下滑 */
    out.dirtyFrameSkip = session.dirtyFrameSkip || 0;
    /* 0=正常 1=疑似非原始皮肤 */
    out.skinWarn = session.skinWarn ? 1 : 0;
    out.undo = session.undoApplied ? 1 : 0;
    out.undoCount = session.undoCount || 0;
    out.gain = session.lastGain ? Math.round(session.lastGain * 100) / 100 : 0;
    if (session.moves && session.moves.length) {
      var lm = session.moves[session.moves.length - 1];
      out.lastMoveUci = lm.uci || '';
      out.lastMoveFenBefore = lm.fen || '';
      out.lastMoveBy = lm.by || '';      /* red/black：中文记谱要按走子方编号 */
    } else {
      out.lastMoveUci = '';
      out.lastMoveFenBefore = '';
      out.lastMoveBy = '';
    }
    /* 2.0.0r10：看到棋盘变了、却配不出合法一步 —— 这帧的结论不能拿来画箭头，
       否则箭头会指向一个真实棋盘上已经不存在的子。上层据此清掉箭头。 */
    /* 判据改成「看到变化 且 本帧没有提交任何一步」——不再看 stepInfo.move：
       规则校验失败、重锚逃逸等分支也会改写 stepInfo，用 move 判断会漏。 */
    out.boardChangedUnconfirmed =
      (stepDiffRaw && stepDiffRaw.changed > 0 && !session.turnUpdated) ? 1 : 0;
    /* 2.1.85 诊断：真机没有 log 命令，把定位轮次判定所需的三个关键量
       直接透到 HUD 第二行，肉眼就能判断「是没认出变化」还是「认错了走子方」。 */
    out.dbgMover = session.lastMoverSide || '-';
    out.dbgStep = stepInfo.move ? 1 : 0;
    /* 2.1.87 诊断：把识别出的「屏幕原样盘面」透给 HUD。
       真机没有 log 命令，只有把 FEN 摆在眼前才能确认「插件看到的盘面」
       到底和眼睛看到的一致不一致 —— 这是判断「认错子」还是「没跟上」的唯一办法。 */
    out.dbgBoard = session.lastRawFen || session.lastBoardFen || '';
    out.anchorFen = session.anchorFen || '';
    out.flipped = session.flipped ? 1 : 0;
    out.unsureCount = session.lowConfCount || 0;
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

    /* 2.1.79 治理「乱指挥」：待确认格子太多就不硬猜
     *
     * 之前 live 模式完全跳过置信度判断，于是任何一帧只要结构上合法就直接
     * 组 FEN 喂引擎 —— 哪怕里面有六七个格子是低分蒙出来的兵种。引擎会非常
     * 认真地对着错盘面算，建议自然离谱，而用户完全看不出是识别错了。
     *
     * 现在：待确认格子超过阈值就整帧不发搜索，让 HUD 明确显示「识别待确认」。
     * 阈值取 6 是有意的宽松值：
     *   - 真机落子动画一般只影响 1~3 格（起点 / 终点 + 高亮圈）；
     *   - 残局模板少、分数普遍偏低，阈值太紧会一直卡住不给建议；
     *   - 6 格约占 32 枚棋子的 19%，超过这个比例说明整帧整体不可信。
     * 不退避：下一帧正常就立刻恢复，不要像旧的 illegalStreak 那样歇几秒。 */
    var unsureCount = session.lowConfCount || 0;
    if (unsureCount > JJ_MAX_UNSURE_CELLS) {
      out.skipAnalyze = 1;
      out.skipReason = 'lowconf';
      out.unsureCount = unsureCount;
      out.needSearch = 0;
      out.searchFen = '';
      return out;
    }
    /* ★ 2.0.0r17：离开棋盘 / 对局结束检测。
       真机日志（11:52:54 起）：对局结束进结算画面，识别在一个完全不是棋盘的
       画面上硬读，diff=40、repaired=6，还照样派搜索 —— HUD 就会乱跳。
       判据用「骤降」而不是「子少」：正常残局也可能只剩 3~4 子。 */
    var prevOcc = session.lastOccCount || 0;
    if (occCount > 0) session.lastOccCount = occCount;
    if (occCount > 0 && occCount < 4 && prevOcc >= 10) {
      out.skipAnalyze = 1;
      out.skipReason = 'ended';
      out.needSearch = 0;
      out.searchFen = '';
      session.lastDispatchedFen = '';
      return out;
    }

    /* 2.0.0：轮到对方（典型是我方执黑的开局第一手）时整段跳过搜索。
       不是 skipAnalyze：上层不会因此退避，对方一落子下一帧就能立刻出建议。 */
    if (waitingOpponent) {
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

    /* 2.1.76：喂引擎前的最后一道闸。
       王必须各恰好 1 个，且走子方不能已经能吃对方王 —— 这两类盘面 Pikafish
       会直接拒绝（"Incorrect number of kings" / "King can be captured"），
       而 2.1.75 及之前 UCIEngine::position 失败会 std::exit(1)，把整个 App
       带走（真机 .ips thread 73，HANDOFF §14）。
       2.1.76 起引擎侧补丁已改为「不 exit、拒绝搜索」，但那次思考就白费了，
       所以识别侧也要自己拦住：这一帧干脆不发搜索，下一帧再来。
       注意这里只拦「喂引擎」，不影响浮窗继续显示上一帧合法盘面。 */
    var engCheck = session.anchorCodes || null;
    if (engCheck && !codesEngineSafe(engCheck, turnChar === 'b' ? 'black' : 'red')) {
      out.skipReason = 'king';
      out.needSearch = 0;
      out.searchFen = '';
      return out;
    }

    out.searchFen = analyzeFen;
    out.needSearch = (analyzeFen !== session.lastDispatchedFen) ? 1 : 0;

    /* ★ 2.0.0r17：乐观翻面不许派发搜索。
       真机日志（11:40:32 我方 h7e7 提交 → 11:40:35 又 go movetime）：
       那一帧只检测到对方半区有变化、轮次被「乐观」翻了过来，但真实走法还
       没被标记确认，于是拿一帧半成品盘面去搜 —— 结论自然可能指错。
       现在乐观翻面只负责「清箭头 + 显示对方走子中」，
       搜索必须等这一步被标记正式提交（turnUpdated=1）之后才发。 */
    if (out.optimisticTurn && !session.turnUpdated) {
      out.needSearch = 0;
      out.searchFen = '';
    }
    if (out.needSearch) session.lastDispatchedFen = analyzeFen;

    return out;
  },

  /** 当前局面 */
  currentFen: function () { return session.tracker ? session.tracker.fen : C.START_FEN; },

  /** 标记确认帧数：菜单调用。范围 1~30，返回实际生效值。 */
  setMarkerConfirmFrames: function (n) {
    n = n | 0;
    if (n < 1) n = 1;
    if (n > 30) n = 30;
    markerConfirmFrames = n;
    return markerConfirmFrames;
  },

  getMarkerConfirmFrames: function () { return markerConfirmFrames; },

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
if (typeof global.__JJ_TEST_HOOK__ === 'function')
  global.__JJ_TEST_HOOK__(REC, TRK, {
    codesEngineSafe: codesEngineSafe,
    stepIsRuleLegal: stepIsRuleLegal
  });
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
