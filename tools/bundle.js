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
  /* 2.1.85：高亮圈兜底相关状态。
     hiddenDstFrom/Streak：落点被高亮圈盖住读成空时，用连续 2 帧确认「起点确实空了」；
     highlightLostPiece：已经翻过轮次但落点坐标未知的那颗棋子兵种，供后续帧补回。 */
  hiddenDstFrom: -1,
  hiddenDstStreak: 0,
  highlightLostPiece: 0,
  highlightInferred: 0,
  newGame: 0               // 本帧识别到「回到标准开局」并已重锚
};

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
      session.lastMoverSide = null;    // 2.1.84：换局后走子方记录作废
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
        session.lastMoverSide = null;    // 2.1.84：中途进局，未知走子方
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
        session.lastMoverSide = null;    // 2.1.84：朝向变了重锚，走子方记录作废
      } else {
        anchorRejected = 1;
      }
    }

    if (anchor) {
      stepInfo = analyzeStepDiff(anchor, engCodes);
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
      if (!stepInfo.move && !reseat && stepInfo.changed >= 1 && stepInfo.changed <= 4) {
        var fromSq = -1, emptyCnt = 0;
        for (var ei = 0; ei < 90; ei++) {
          if ((anchor[ei] || 0) !== 0 && (engCodes[ei] || 0) === 0) { emptyCnt++; fromSq = ei; }
        }
        if (emptyCnt === 1) {
          var toSq = -1, otherCnt = 0;
          for (var oj = 0; oj < 90; oj++) {
            if (oj === fromSq) continue;
            if ((anchor[oj] || 0) !== (engCodes[oj] || 0)) { otherCnt++; toSq = oj; }
          }
          if (otherCnt === 1 && toSq >= 0) {
            var movedPiece = anchor[fromSq];
            var capturedPiece = anchor[toSq] || 0;
            /* 不能吃己方棋子（与 analyzeStepDiff 同判据） */
            var okCapture = !capturedPiece ||
                            ((capturedPiece <= 7) !== (movedPiece <= 7));
            if (okCapture && stepIsRuleLegal(anchor, fromSq, toSq)) {
              stepInfo = {
                changed: stepInfo.changed,
                noise: [],
                move: { from: fromSq, to: toSq, piece: movedPiece, captured: capturedPiece }
              };
              session.highlightInferred = (session.highlightInferred || 0) + 1;
              session.hiddenDstFrom = -1;
              session.hiddenDstStreak = 0;
            }
          } else {
            /* 落点读不出来：高亮圈把它整格读成空，或读成超编兵种被配额修复丢掉，
               或读数抖动导致 otherCnt 多于 1。共同点都是**配不出合法一步**，
               但「恰好一枚棋子离开了某格」这个事实是清楚的（那一半不被圈遮住）。
               此时落点坐标不可知，轮次却必须翻，否则永远卡在「等待对方」。
               用连续 2 帧一致来排除单帧噪声（噪声下一帧就恢复，真走子不会）。 */
            if (session.hiddenDstFrom === fromSq) {
              session.hiddenDstStreak = (session.hiddenDstStreak || 0) + 1;
            } else {
              session.hiddenDstFrom = fromSq;
              session.hiddenDstStreak = 1;
            }
            if (session.hiddenDstStreak >= 2) {
              var leftPiece = anchor[fromSq];
              session.lastMoverSide = (leftPiece <= 7) ? 'red' : 'black';
              session.movePly = (session.movePly || 0) + 1;
              session.plyGuessed = 1;      // 落点未知，轮次是推的，日志可追溯
              session.ruleFail = 0;
              /* 锚盘只清掉起点；落点留空，等后续帧识别出来再补
                 （下面有「补回丢失棋子」逻辑，见 anchor 覆盖之前）。 */
              var naHidden = anchor.slice();
              naHidden[fromSq] = 0;
              anchor = naHidden;
              session.anchorCodes = anchor;
              session.anchorFen = codesToBoardFen(anchor);
              session.prevAnchorFen = '';
              session.lastBoardFen = session.anchorFen;
              session.lastResult = null;
              session.lastDispatchedFen = '';
              session.highlightLostPiece = leftPiece;   // 供后续帧补回
              session.highlightInferred = (session.highlightInferred || 0) + 1;
              session.hiddenDstFrom = -1;
              session.hiddenDstStreak = 0;
            }
          }
        }
      }

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
        if (stepInfo.move) {
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
            session.movePly = (session.movePly || 0) + 1;
            session.plyGuessed = 0;
            session.ruleFail = 0;
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
            stepInfo = { changed: stepInfo.changed, move: null, noise: stepInfo.noise };
            anchorRejected = 1;
            if (session.ruleFail >= 5 &&
                codesLegal(engCodes) && codesPositionPlausible(engCodes)) {
              anchor = Array.prototype.slice.call(engCodes);
              session.anchorCodes = anchor;
              session.anchorFen = codesToBoardFen(anchor);
              session.prevAnchorFen = '';
              session.lastBoardFen = session.anchorFen;
              session.lastResult = null;
              session.lastDispatchedFen = '';
              session.ruleFail = 0;
              session.reseatDone = 1;
              // 重锚后轮次无从得知，假设轮到我方，plyGuessed 供日志追溯
              session.movePly = session.flipped ? 1 : 0;
              session.plyGuessed = 1;
              session.lastMoverSide = null;   // 2.1.84：规则连败重锚，走子方记录作废
            }
          }
        }
        /* 2.1.85：补回上一帧因高亮圈读不到落点而「消失」的那颗棋子。
         条件：锚盘里该兵种比当前帧多一个，且当前帧恰好多出一个同兵种的格，
         拼起来是一盘合法棋 —— 才算找回来，避免把噪声格当落点。 */
      if (session.highlightLostPiece) {
        var lp = session.highlightLostPiece;
        var lostCnt = 0, curCnt = 0, candSq = -1, candCnt = 0;
        for (var li = 0; li < 90; li++) {
          if ((anchor[li] || 0) === lp) lostCnt++;
          if ((engCodes[li] || 0) === lp) curCnt++;
        }
        if (curCnt > lostCnt) {
          for (var lj = 0; lj < 90; lj++) {
            if ((engCodes[lj] || 0) === lp && (anchor[lj] || 0) !== lp) {
              candCnt++; candSq = lj;
            }
          }
        }
        if (candCnt === 1 && candSq >= 0) {
          var trial = anchor.slice();
          trial[candSq] = lp;
          if (codesLegal(trial) && codesPositionPlausible(trial)) {
            anchor = trial;
            session.anchorCodes = anchor;
            session.anchorFen = codesToBoardFen(anchor);
            session.lastBoardFen = '';
            session.lastResult = null;
            session.lastDispatchedFen = '';
          }
        }
        session.highlightLostPiece = 0;   // 只尝试一次，避免长期挂着乱补
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
    /* 2.1.85 诊断：真机没有 log 命令，把定位轮次判定所需的三个关键量
       直接透到 HUD 第二行，肉眼就能判断「是没认出变化」还是「认错了走子方」。 */
    out.dbgMover = session.lastMoverSide || '-';
    out.dbgInferred = session.highlightInferred || 0;
    out.dbgStep = stepInfo.move ? 1 : 0;
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
    if (out.needSearch) session.lastDispatchedFen = analyzeFen;

    return out;
  },

  /** 当前局面 */
  currentFen: function () { return session.tracker ? session.tracker.fen : C.START_FEN; },

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
