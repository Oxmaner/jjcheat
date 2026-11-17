/**
 * JJCheat engine.js 离线回归（2.0 起常驻，每次出包前必跑）
 *
 * 用法：node tools/regression.js
 * 依赖：先执行 node tools/bundle.js 生成 dist/engine.js
 *
 * 2.1.0 契约：JS 只识别不搜索。process 输出 needSearch/searchFen，
 * 建议着法由 ObjC 侧 JJPikafish 独立进程产出 —— 本回归专测识别状态机：
 *   A 执红：红先手 / 走子轮次 / 噪声门槛 / 派出去重 / 新局重锚
 *   B 执黑：开局必须等红方先走，对方落子后才需要搜索
 *   C 中途进对局：连续 3 帧稳定后换局重锚
 *   D 中局误点自动标定：失败的学习不得污染已收敛锚盘（16:43 真机日志）
 *   E 坐标契约：searchFen 必须是引擎坐标（红在下）且与识别盘面一致
 *
 * 这些场景全部来自真机日志里踩过的坑，改状态机时务必保持全绿。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const ENGINE = path.join(ROOT, 'dist', 'engine.js');

/** 把 engine.js 的内部状态暴露出来，便于断言（仅测试环境） */
function loadEngineSource() {
  let src = fs.readFileSync(ENGINE, 'utf8');
  const probe = 'global.JJEngine = JJEngine;';
  if (src.indexOf(probe) < 0) throw new Error('engine.js 缺少导出锚点');
  return src.replace(probe,
    probe + ' global.__S = session; global.__C = C; global.__flip = flipCodes;');
}

const P2C = ['', 'K', 'A', 'B', 'N', 'R', 'C', 'P', 'k', 'a', 'b', 'n', 'r', 'c', 'p'];

/** FEN 棋盘部分 -> 90 格兵种编码 */
function fenToCodes(fen) {
  const out = new Array(90).fill(0);
  fen.split(' ')[0].split('/').forEach((line, r) => {
    let c = 0;
    for (const ch of line) {
      if (ch >= '1' && ch <= '9') { c += +ch; continue; }
      out[r * 9 + c] = P2C.indexOf(ch);
      c++;
    }
  });
  return out;
}

/**
 * 构造一份干净的引擎夹具。
 * @param {boolean} blackBottom true = 画面黑子在下（我执黑）
 */
function makeFixture(src, blackBottom) {
  delete global.JJEngine;
  delete global.__S;
  delete global.__C;
  delete global.__flip;
  vm.runInThisContext(src);

  const JJ = global.JJEngine;
  const S = global.__S;
  const C = global.__C;
  const flip = global.__flip;
  const START = C.START_FEN.split(' ')[0];
  const S0 = fenToCodes(START);
  let engCodes = S0.slice();

  /** 把引擎坐标 codes 包成 recognizer.classify 的返回结构 */
  function classifyResult(codes) {
    const grid = new Int8Array(90);
    const conf = new Float32Array(90);
    for (let i = 0; i < 90; i++) {
      grid[i] = codes[i] ? (codes[i] <= 7 ? 1 : 2) : 0;
      conf[i] = codes[i] ? 1.5 : 0.02;
    }
    return { grid, conf, codes: Int8Array.from(codes) };
  }

  S.recognizer = {
    occluded: null,
    occludedCount: 0,
    lastRanked: [],
    lastConf: [],
    sampleAll: () => Array.from({ length: 90 },
      () => ({ warmR: 0.4, inkR: 0.2, redInkR: 0, darkInkR: 0.2 })),
    classify: () => classifyResult(blackBottom ? flip(engCodes) : engCodes),
    learnBackground: () => {},
    classifyByColor: () => ({ grid: (() => {
      const g = new Int8Array(90);
      for (let c = 0; c < 9; c++) {
        g[81 + c] = blackBottom ? 2 : 1;   // 底行颜色决定执红 / 执黑
        g[c] = blackBottom ? 1 : 2;
      }
      return g;
    })() }),
    gridPoints: () => new Array(180).fill(0),
    templateCount: 86
  };

  const px = new Uint8ClampedArray(4);

  /** 喂一帧并打印关键诊断字段 */
  function frame(label, codes, expect) {
    engCodes = codes;
    const r = JJ.process(px, 1, 1, { live: true });
    console.log('%s | turn=%s ply=%s wait=%s newGame=%s rejected=%s reseat=%s diff=%s | search=%s fen=%s',
      label, r.turn, r.ply, r.waitingOpponent, r.newGame, r.anchorRejected,
      r.reseat, r.diffChanged,
      r.needSearch, (r.searchFen || '').split(' ')[0]);
    /* 2.1.0 硬约束：JS 不得再输出任何搜索结论字段 */
    for (const k of ['suggest', 'suggestChinese', 'scoreText', 'winrate', 'depth', 'pv', 'nodes', 'elapsed']) {
      if (k in r) throw new Error('process 输出残留搜索字段: ' + k);
    }
    if (r.needSearch === undefined) throw new Error('process 缺少 needSearch 字段');
    if (r.needSearch && !r.searchFen) throw new Error('needSearch=1 但 searchFen 为空');
    if (expect) expect(r);
    return r;
  }

  /** 学习开局（noisy 模仿真机 4 格兵种认错；custom 可指定任意盘面） */
  function learn(noisy, custom) {
    const c = custom ? custom.slice() : S0.slice();
    if (noisy && !custom) { c[5] = 11; c[6] = 12; c[7] = 14; c[8] = 10; }
    engCodes = c;
    return JJ.learnBoard(new Uint8ClampedArray(4), 1, 1);
  }
  /** 成功学习开局后打印基线（供 A/B/C 用） */
  function learnOpening(noisy) {
    const r = learn(noisy);
    console.log('学习: ok=%s verifyDiff=%s %s 锚盘=标准开局:%s ply=%s',
      r.ok, r.verifyDiff, S.flipped ? '执黑' : '执红',
      S.anchorFen === START ? 'YES' : 'NO', S.movePly);
    if (!r.ok || S.anchorFen !== START) throw new Error('学习未锚定标准开局');
  }

  return { JJ, S, C, START, S0, frame, learn, learnOpening,
           setCodes: c => { engCodes = c.slice(); } };
}

function main() {
  const src = loadEngineSource();

  /* F 段要直接调识别器的 alignGridToOpening：bundle 模板里有
     __JJ_TEST_HOOK__ 钩子，engine.js 装载时把 REC/TRK 模块递出来 */
  global.__JJ_TEST_HOOK__ = function (RECm, TRKm) {
    global.__REC = RECm;
    global.__TRK = TRKm;
  };

  console.log('========== A. 执红：红先手 + 走子轮次 + 噪声门槛 + 派出去重 ==========');
  const A = makeFixture(src, false);
  A.learnOpening(true);
  A.frame('A1 开局静止', A.S0.slice(), r => {
    if (r.waitingOpponent) throw new Error('执红开局应轮到我');
    if (!r.needSearch) throw new Error('执红开局应派发搜索（needSearch=1）');
    if (r.reseat) throw new Error('开局帧不该 reseat');
  });
  const noise = A.S0.slice();
  [5, 6, 7, 8].forEach(i => { noise[i] = noise[i] === 14 ? 11 : 14; });
  A.frame('A2 4 格噪声', noise, r => {
    if (!r.anchorRejected) throw new Error('噪声帧未丢弃');
    if (r.reseat) throw new Error('小噪声不该触发换局重锚');
    if (r.needSearch) throw new Error('同一局面不该重复派发搜索');
  });
  const step1 = A.S0.slice(); step1[54] = 0; step1[45] = 7;   // 红兵进一
  A.frame('A3 我方走子', step1, r => {
    if (!r.moveDetected || !r.move) throw new Error('走子没检测到');
    if (r.ply !== 1) throw new Error('ply 未推进');
    if (!r.waitingOpponent) throw new Error('我方走完应轮到对方');
    if (r.needSearch) throw new Error('轮到对方不该派发搜索');
    if (r.skipReason !== 'waitingOpponent') throw new Error('skipReason 应为 waitingOpponent');
  });
  A.frame('A3b 走一步后静止', step1.slice(), r => {
    if (r.newGame) throw new Error('走一步后的静止帧不该被判成新局');
    if (r.ply !== 1) throw new Error('静止帧轮次被重置');
  });
  const step2 = step1.slice(); step2[27] = 0; step2[36] = 14;  // 黑卒进一
  A.frame('A4 对方走子', step2, r => {
    if (r.ply !== 2) throw new Error('ply 未推进到 2');
    if (r.waitingOpponent) throw new Error('对方走完应轮到我');
    if (!r.needSearch) throw new Error('轮到我应派发搜索');
    if (r.newGame) throw new Error('开局走两步不该被误判成新局');
  });
  A.frame('A5 静止帧', step2.slice(), r => {
    if (r.needSearch) throw new Error('静止帧重复派发搜索');
  });
  A.frame('A6 回到新局开局', A.S0.slice(), r => {
    if (r.newGame !== 1) throw new Error('新局没被识别');
    if (r.ply !== 0) throw new Error('新局轮次没归零');
    if (r.waitingOpponent) throw new Error('新局执红应轮到我');
    if (!r.needSearch) throw new Error('新局应立刻派发搜索');
  });

  console.log('');
  console.log('========== B. 执黑：必须等对方（红）先走 ==========');
  const B = makeFixture(src, true);
  B.learnOpening(false);
  B.frame('B1 执黑开局', B.S0.slice(), r => {
    if (!r.waitingOpponent) throw new Error('执黑开局必须等红方先走');
    if (r.needSearch) throw new Error('执黑开局不该派发搜索');
    if (r.turn !== 'w') throw new Error('开局走子方应为红 w');
  });
  const bstep = B.S0.slice(); bstep[54] = 0; bstep[45] = 7;
  B.frame('B2 对方先手后', bstep, r => {
    if (!r.moveDetected) throw new Error('没检测到对方先手');
    if (r.waitingOpponent) throw new Error('对方走完应轮到我');
    if (!r.needSearch) throw new Error('轮到我应派发搜索');
  });

  console.log('');
  console.log('========== C. 中途进对局：3 帧稳定换局重锚 ==========');
  const D = makeFixture(src, false);
  D.learnOpening(false);
  const mid = D.S0.slice();
  for (let c = 0; c < 9; c += 2) { mid[27 + c] = 0; mid[36 + c] = 14; }
  let last;
  for (let k = 1; k <= 3; k++) {
    last = D.frame('C' + k + ' 新局面帧', mid.slice(), r => {
      if (k < 3 && r.reseat) throw new Error('单帧不该 reseat');
      if (k === 3 && !r.reseat) throw new Error('连续 3 帧稳定未重锚');
    });
  }
  if (!last.moveDetected) throw new Error('重锚后没落地新局面');

  console.log('');
  console.log('========== D. 中局误点自动标定：失败学习不污染锚盘 ==========');
  const E = makeFixture(src, false);
  E.learnOpening(true);
  const openingSnapshot = E.S.openingAnchor.slice();
  const flippedBefore = E.S.flipped;
  const s1 = E.S0.slice(); s1[54] = 0; s1[45] = 7;   // 红兵进一
  E.frame('D1 红兵进一', s1, r => {
    if (!r.moveDetected) throw new Error('走子丢失');
  });
  const anchorAfterMove = E.S.anchorFen;
  const plyAfterMove = E.S.movePly;
  /* 模仿真机 16:43：在已经走过棋的中局画面点「自动标定棋盘」，
     学习校验必然失败（真机 verifyDiff=18~50）。 */
  const midCodes = E.S0.slice();
  for (let c = 0; c < 9; c += 2) { midCodes[27 + c] = 0; midCodes[36 + c] = 14; }
  E.setCodes(midCodes);
  const bad = E.JJ.learnBoard(new Uint8ClampedArray(4), 1, 1);
  console.log('中局重标定: ok=%s verifyDiff=%s calibRejected=%s',
    bad.ok, bad.verifyDiff, bad.calibRejected);
  if (bad.ok) throw new Error('中局画面不该被判成开局');
  if (bad.calibRejected !== 1) throw new Error('缺少 calibRejected 诊断字段');
  if (E.S.anchorFen !== anchorAfterMove) throw new Error('失败的重标定改掉了锚盘');
  if (E.S.movePly !== plyAfterMove) throw new Error('失败的重标定改掉了轮次');
  if (E.S.flipped !== flippedBefore) throw new Error('失败的重标定改掉了朝向');
  if (E.S.openingAnchor.join(',') !== openingSnapshot.join(','))
    throw new Error('openingAnchor 被污染');
  E.frame('D2 回到真实局面（静止）', s1, r => {
    if (r.newGame) throw new Error('静止帧被误判成新局');
    if (r.ply !== plyAfterMove) throw new Error('静止帧轮次被重置');
    if (r.skipAnalyze) throw new Error('失败重标定不该导致 skipAnalyze');
  });
  const s2 = s1.slice(); s2[27] = 0; s2[36] = 14;   // 对方黑卒进一
  E.frame('D3 对方走子', s2, r => {
    if (!r.needSearch) throw new Error('失败重标定后应能继续派发搜索');
    if (r.skipAnalyze) throw new Error('失败重标定不该导致 skipAnalyze');
    if (r.ply !== 2) throw new Error('失败重标定后轮次未推进');
  });

  console.log('');
  console.log('========== E. 坐标契约：searchFen 必须是引擎坐标（红在下） ==========');
  const F = makeFixture(src, false);
  F.learnOpening(false);
  F.frame('E1 开局待搜', F.S0.slice(), r => {
    if (!r.searchFen) throw new Error('应有 searchFen');
    const rows = r.searchFen.split(' ')[0].split('/');
    if (rows[9] !== 'RNBAKABNR') throw new Error('引擎坐标红方必须在 FEN 第10行: ' + rows[9]);
    if (r.searchFen.split(' ')[1] !== 'w') throw new Error('开局走子方应为红 w');
  });
  const mv1 = F.S0.slice(); mv1[54] = 0; mv1[45] = 7;   // 我红兵进一
  F.frame('E2 我走完（不派发）', mv1, r => {
    if (r.needSearch) throw new Error('轮到对方不该派发');
  });
  const mv2 = mv1.slice(); mv2[27] = 0; mv2[36] = 14;   // 对方黑卒进一
  F.frame('E3 对方走完（派发）', mv2, r => {
    if (!r.needSearch) throw new Error('轮到我应派发搜索');
    const rows = r.searchFen.split(' ')[0].split('/');
    if (rows[9] !== 'RNBAKABNR') throw new Error('红方仍应在最下: ' + rows[9]);
    if (r.searchFen.split(' ')[1] !== 'w') throw new Error('轮到红方，走子方应为 w');
    /* 黑卒 row3col0 → row4col0：FEN 第 5 行(row4) 首列应为 p，第 4 行(row3) 首列为空 */
    if (rows[4][0] !== 'p') throw new Error('黑卒应落在 row4: ' + rows[4]);
  });
  /* 执黑视角：searchFen 仍必须是「红在下」的引擎坐标（识别层已把画面翻回） */
  const G = makeFixture(src, true);
  G.learnOpening(false);
  const gstep = G.S0.slice(); gstep[54] = 0; gstep[45] = 7;   // 对方红兵先手
  G.frame('E4 执黑·对方先手后', gstep, r => {
    if (!r.needSearch) throw new Error('轮到我应派发搜索');
    if (!r.searchFen) throw new Error('应有 searchFen');
    const rows = r.searchFen.split(' ')[0].split('/');
    if (rows[9][0] !== 'R') throw new Error('引擎坐标红方必须在 FEN 最下（第10行）');
    if (rows[9] !== 'RNBAKABNR') throw new Error('执黑时红方仍应原样在底: ' + rows[9]);
    if (r.searchFen.split(' ')[1] !== 'b') throw new Error('红走完应轮到黑 b');
  });

  console.log('');
  console.log('========== F. 格点对齐（2.1.59 盘均值口径）：偏移修复 / 空盘拒绝 / 已对齐不动 ==========');
  {
    /* 2.1.58 真机教训：2×2 点采样把棋盘线 / 兵卒位定位标记当棋子，空盘也
       能凑出「命中」造成假对齐。断言换成盘均值口径后的三种关键行为。 */
    const RECM = global.__REC;
    const TRKM = global.__TRK;
    if (!RECM || !TRKM) throw new Error('测试钩子未注入（bundle 模板缺 __JJ_TEST_HOOK__？）');
    const spm = TRKM.startPieceMap();
    const opIdx = [], emIdx = [];
    for (let i = 0; i < 90; i++) (spm[i] ? opIdx : emIdx).push(i);

    const W = 600, H = 660;
    const CS = [[60, 60], [540, 60], [540, 600], [60, 600]];
    const ptOf = (cs, r, c) => {
      const u = c / 8, v = r / 9;
      return [
        (1-u)*(1-v)*cs[0][0] + u*(1-v)*cs[1][0] + u*v*cs[2][0] + (1-u)*v*cs[3][0],
        (1-u)*(1-v)*cs[0][1] + u*(1-v)*cs[1][1] + u*v*cs[2][1] + (1-u)*v*cs[3][1]
      ];
    };
    /** 合成帧：木色底 + 2px 深色网格线 + 兵卒/炮位十字标记 + 可选 32 子 */
    function synthFrame(withPieces, offX, offY) {
      const px = new Uint8ClampedArray(W * H * 4);
      for (let i = 0; i < W * H; i++) {
        px[i * 4] = 190; px[i * 4 + 1] = 150; px[i * 4 + 2] = 100; px[i * 4 + 3] = 255;
      }
      const put = (x, y, r, g, b) => {
        const xi = x | 0, yi = y | 0;
        if (xi < 0 || yi < 0 || xi >= W || yi >= H) return;
        const i = (yi * W + xi) * 4;
        px[i] = r; px[i + 1] = g; px[i + 2] = b;
      };
      const sCS = CS.map(p => [p[0] + offX, p[1] + offY]);
      const line = (a, b) => {
        const n = Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]));
        for (let t = 0; t <= n; t++) {
          const x = a[0] + (b[0] - a[0]) * t / n, y = a[1] + (b[1] - a[1]) * t / n;
          /* 1px 细线：真机帧里空格墨迹基线 0.02~0.07 正是这种细线贡献的
             （2px 会把基线推到 0.10+，adaptive 阈值被抬高，反而测不出真机行为） */
          put(x, y, 90, 70, 55);
        }
      };
      for (let r = 0; r < 10; r++) for (let c = 0; c < 8; c++) line(ptOf(sCS, r, c), ptOf(sCS, r, c + 1));
      for (let c = 0; c < 9; c++) for (let r = 0; r < 9; r++) line(ptOf(sCS, r, c), ptOf(sCS, r + 1, c));
      const marks = [];
      for (const r of [2, 7]) for (const c of [0, 2, 4, 6, 8]) marks.push([r, c]);
      for (const [r, c] of [[1, 1], [1, 7], [8, 1], [8, 7]]) marks.push([r, c]);
      for (const [r, c] of marks) {
        const p = ptOf(sCS, r, c);
        for (let d = -2; d <= 2; d++) { put(p[0] + d, p[1], 70, 55, 45); put(p[0], p[1] + d, 70, 55, 45); }
      }
      if (withPieces) {
        for (let i = 0; i < 90; i++) {
          if (!spm[i]) continue;
          const r = (i / 9) | 0, c = i % 9;
          const p = ptOf(sCS, r, c);
          /* 2.1.60 真机皮肤（2.1.59 失败帧实锤）：黑子 = 浅木色盘面 + 黑字黑边、
             红子 = 象牙盘面 + 红字红边 —— 盘面亮度与棋盘底色几乎重合（L≈150
             vs 木色 170），只有「墨迹」能把有无子分开。所以这里必须画出字和边，
             否则合成帧对墨迹判据就是一批「光板棋子」，测不出真机场景。 */
          const isBlack = r <= 4;
          const face = isBlack ? [176, 142, 108] : [236, 196, 140];
          const ink = isBlack ? [40, 34, 30] : [150, 30, 24];
          for (let dy = -25; dy <= 25; dy++) {
            for (let dx = -25; dx <= 25; dx++) {
              const d2 = dx * dx + dy * dy;
              if (d2 > 625) continue;
              if (d2 >= 484) { put(p[0] + dx, p[1] + dy, ink[0], ink[1], ink[2]); continue; }
              put(p[0] + dx, p[1] + dy, face[0], face[1], face[2]);
            }
          }
          /* 字：内圈 + 按兵种码点的 4×4 点阵笔画（每个 code 图案唯一）。
             真机上 14 种棋子各有不同的字，模板才分得出兵种 —— 合成帧若全画同一个
             字，模板比对必然认错（G2 就是被这个坑住的：占位对、兵种全错）。 */
          const code = spm[i] || 0;
          for (let dy = -12; dy <= 12; dy++) {
            for (let dx = -12; dx <= 12; dx++) {
              const d2 = dx * dx + dy * dy;
              if (d2 >= 81 && d2 <= 144) { put(p[0] + dx, p[1] + dy, ink[0], ink[1], ink[2]); }
            }
          }
          for (let k = 0; k < 16; k++) {
            if (!((code >> (k % 4)) & 1)) continue;
            const gx = -8 + (k % 4) * 4, gy = -8 + ((k / 4) | 0) * 4;
            for (let dy = 0; dy < 3; dy++) {
              for (let dx = 0; dx < 3; dx++) {
                put(p[0] + gx + dx, p[1] + gy + dy, ink[0], ink[1], ink[2]);
              }
            }
          }
        }
      }
      return px;
    }

    /* F1：整盘偏移 (40,-30)（超出棋子+采样盘的覆盖范围，恒等网格打不到子）
       → 必须被修复采纳，命中 ≥28，平移量收敛到真实偏移 ±6px */
    const r1 = RECM.alignGridToOpening(synthFrame(true, 40, -30), W, H, CS, opIdx, emIdx);
    if (!r1 || !r1.accepted) {
      throw new Error('F1 偏移 40,-30 应被采纳修复: occ=' + (r1 && r1.occHit) + ' id=' + (r1 && r1.idOccHit));
    }
    if (r1.occHit < 28) throw new Error('F1 修复后命中应 ≥28: ' + r1.occHit);
    if (Math.abs(r1.shiftX - 40) > 6 || Math.abs(r1.shiftY + 30) > 6) {
      throw new Error('F1 平移量不符: ' + r1.shiftX + ',' + r1.shiftY);
    }

    /* F2：空棋盘（只有网格线与定位标记，2.1.58 真机就是这种画面骗过了点采样）
       → 必须拒绝，且命中 <10（HUD 才能提示「画面里没看到棋子」） */
    const r2 = RECM.alignGridToOpening(synthFrame(false, 0, 0), W, H, CS, opIdx, emIdx);
    if (!r2 || r2.accepted) throw new Error('F2 空盘必须拒绝（2.1.58 被线/标记骗过一次）');
    if (r2.occHit >= 10) throw new Error('F2 空盘命中应 <10: ' + r2.occHit);

    /* F3：已对齐（恒等网格 32/32 全命中）→ already，四角一个像素都不动 */
    const r3 = RECM.alignGridToOpening(synthFrame(true, 0, 0), W, H, CS, opIdx, emIdx);
    if (!r3 || r3.already !== true || r3.accepted) throw new Error('F3 已对齐应走 already 分支');
    if (r3.occHit < 22) throw new Error('F3 恒等网格应 ≥22 命中: ' + r3.occHit);

    /* G：浅木皮肤（2.1.59 真机皮肤 —— 黑子=浅木盘面+黑字、红子=象牙盘面+红字）。
       棋子盘面亮度与棋盘底色几乎重合，亮度三峰模型会整盘判空 → 自举闸门不过 →
       verifyDiff=32。这条断言守的是「墨迹判据 + 无墨才判空」这条修复链：
       判有子必须 ≈32，且现场自举的模板认同一帧必须与标准开局一致。 */
    const recG = new RECM.BoardRecognizer({ corners: CS, enableLowConfRefine: true });
    const stG = recG.sampleAll(synthFrame(true, 0, 0), W, H, true);
    recG.learnBackground(stG, []);
    const ccG = recG.classifyByColor(stG);
    let occG = 0;
    for (let i = 0; i < 90; i++) if (ccG.grid[i] !== 0) occG++;
    if (occG < 30) throw new Error('G1 浅木皮肤判有子应 ≈32: ' + occG);
    recG.learnTemplates(stG, spm);
    const clsG = recG.classify(stG);
    let diffG = 0;
    for (let i = 0; i < 90; i++) if ((clsG.codes[i] || 0) !== (spm[i] || 0)) diffG++;
    if (diffG > 4) throw new Error('G2 自举后与标准开局差应 ≤4: ' + diffG);

    console.log('F1 偏移修复: 命中=%d/32 平移=%d,%d | F2 空盘拒绝: 命中=%d | F3 already: 命中=%d',
      r1.occHit, r1.shiftX, r1.shiftY, r2.occHit, r3.occHit);
    console.log('G 浅木皮肤: 判有子=%d/32 | 自举后与标准开局差=%d 格', occG, diffG);
  }

  console.log('');
  console.log('全部通过 OK  engine.js = %d 字节, mark=%s',
    fs.statSync(ENGINE).size, /pikafishNative/.test(src) ? 'pikafishNative OK' : 'MISSING');
}

main();
