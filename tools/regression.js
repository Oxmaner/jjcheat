/**
 * JJCheat engine.js 离线回归（2.0 起常驻，每次出包前必跑）
 *
 * 用法：node tools/regression.js
 * 依赖：先执行 node tools/bundle.js 生成 dist/engine.js
 *
 * 用 stub recognizer 直接喂 90 格 codes，绕开像素与标定，专测识别状态机：
 *   A 执红：红先手 / 走子轮次 / 噪声门槛 / 静止缓存 / 新局重锚
 *   B 执黑：开局必须等红方先走，对方落子后才出建议
 *   C 中途进对局：连续 3 帧稳定后换局重锚
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
    const r = JJ.process(px, 1, 1, { timeMs: 10, live: true });
    console.log('%s | turn=%s ply=%s wait=%s newGame=%s rejected=%s reseat=%s diff=%s | %s | suggest=%s',
      label, r.turn, r.ply, r.waitingOpponent, r.newGame, r.anchorRejected,
      r.reseat, r.diffChanged,
      r.elapsed === undefined ? '缓存/跳过' : '重算', r.suggest || '-');
    if (expect) expect(r);
    return r;
  }

  /** 学习开局（noisy 模仿真机 4 格兵种认错） */
  function learn(noisy) {
    const c = S0.slice();
    if (noisy) { c[5] = 11; c[6] = 12; c[7] = 14; c[8] = 10; }
    engCodes = c;
    const r = JJ.learnBoard(new Uint8ClampedArray(4), 1, 1);
    console.log('学习: ok=%s verifyDiff=%s %s 锚盘=标准开局:%s ply=%s',
      r.ok, r.verifyDiff, S.flipped ? '执黑' : '执红',
      S.anchorFen === START ? 'YES' : 'NO', S.movePly);
    if (!r.ok || S.anchorFen !== START) throw new Error('学习未锚定标准开局');
  }

  return { JJ, S, C, START, S0, frame, learn };
}

function main() {
  const src = loadEngineSource();

  console.log('========== A. 执红：红先手 + 走子轮次 + 噪声门槛 ==========');
  const A = makeFixture(src, false);
  A.learn(true);
  A.frame('A1 开局静止', A.S0.slice(), r => {
    if (r.waitingOpponent) throw new Error('执红开局应轮到我');
    if (!r.suggest) throw new Error('执红开局应出建议');
    if (r.reseat) throw new Error('开局帧不该 reseat');
  });
  const noise = A.S0.slice();
  [5, 6, 7, 8].forEach(i => { noise[i] = noise[i] === 14 ? 11 : 14; });
  A.frame('A2 4 格噪声', noise, r => {
    if (!r.anchorRejected) throw new Error('噪声帧未丢弃');
    if (r.reseat) throw new Error('小噪声不该触发换局重锚');
    if (!r.suggest) throw new Error('噪声帧应沿用上一结论');
  });
  const step1 = A.S0.slice(); step1[54] = 0; step1[45] = 7;   // 红兵进一
  A.frame('A3 我方走子', step1, r => {
    if (!r.moveDetected || !r.move) throw new Error('走子没检测到');
    if (r.ply !== 1) throw new Error('ply 未推进');
    if (!r.waitingOpponent) throw new Error('我方走完应轮到对方');
    if (r.suggest) throw new Error('轮到对方不该出建议');
    if (r.elapsed !== undefined) throw new Error('轮到对方仍在跑引擎搜索');
  });
  const step2 = step1.slice(); step2[27] = 0; step2[36] = 14;  // 黑卒进一
  A.frame('A4 对方走子', step2, r => {
    if (r.ply !== 2) throw new Error('ply 未推进到 2');
    if (r.waitingOpponent) throw new Error('对方走完应轮到我');
    if (!r.suggest) throw new Error('轮到我没出建议');
    if (r.newGame) throw new Error('开局走两步不该被误判成新局');
  });
  A.frame('A5 静止帧', step2.slice(), r => {
    if (r.elapsed !== undefined) throw new Error('静止帧又重算了');
  });
  A.frame('A6 回到新局开局', A.S0.slice(), r => {
    if (r.newGame !== 1) throw new Error('新局没被识别');
    if (r.ply !== 0) throw new Error('新局轮次没归零');
    if (r.waitingOpponent) throw new Error('新局执红应轮到我');
    if (!r.suggest) throw new Error('新局应立刻出建议');
  });

  console.log('');
  console.log('========== B. 执黑：必须等对方（红）先走 ==========');
  const B = makeFixture(src, true);
  B.learn(false);
  B.frame('B1 执黑开局', B.S0.slice(), r => {
    if (!r.waitingOpponent) throw new Error('执黑开局必须等红方先走');
    if (r.suggest) throw new Error('执黑开局不该给建议');
    if (r.elapsed !== undefined) throw new Error('等待时仍在跑引擎');
    if (r.turn !== 'w') throw new Error('开局走子方应为红 w');
  });
  const bstep = B.S0.slice(); bstep[54] = 0; bstep[45] = 7;
  B.frame('B2 对方先手后', bstep, r => {
    if (!r.moveDetected) throw new Error('没检测到对方先手');
    if (r.waitingOpponent) throw new Error('对方走完应轮到我');
    if (!r.suggest) throw new Error('轮到我没出建议');
  });

  console.log('');
  console.log('========== C. 中途进对局：3 帧稳定换局重锚 ==========');
  const D = makeFixture(src, false);
  D.learn(false);
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
  console.log('全部通过 OK  engine.js = %d 字节, mark=%s',
    fs.statSync(ENGINE).size, /waitingOpponent/.test(src) ? 'waitingOpponent OK' : 'MISSING');
}

main();
