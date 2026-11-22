'use strict';
/* 关键验证：锚盘落后多步时，枚举能不能连续追上来
   —— 这正是白点白圈死锁的那一环（标记一次只能证一手，枚举每步独立可分） */
const path = require('path');
const ROOT = path.join(__dirname, '..', 'src');
const B = require(path.join(ROOT, 'app/board.js'));
const C = require(path.join(ROOT, 'cst/constants.js'));
const POS = require(path.join(ROOT, 'cst/position.js'));

const START = 'rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR';
const toGrid = (codes) => {
  const g = new Int8Array(90);
  for (let i = 0; i < 90; i++) g[i] = codes[i] ? (codes[i] <= 7 ? 1 : 2) : 0;
  return g;
};

// 预先算一条 5 步的棋路（用合法走法引擎自身生成，保证合法）
function pickMove(fen, prefer) {
  const p = new POS.Position(fen);
  const ms = p.genLegalMoves();
  if (!ms.length) return 0;
  for (const m of ms) if (C.mvToUcci(m) === prefer) return m;
  return ms[0];
}

let fen = START + ' w - - 0 1';
const chain = [];               // 每步之后的 FEN
for (let i = 0; i < 5; i++) {
  const m = pickMove(fen, '');
  const p = new POS.Position(fen);
  p.makeMove(m);
  fen = p.getFen() + (i % 2 === 0 ? ' b - - 0 1' : ' w - - 0 1');
  chain.push(fen);
}
console.log('构造了 5 步棋路');

// ===== 场景 A：锚盘 = 开局，一口气看第 3 步后的盘面（落后 3 步）=====
console.log('\n=== A. 锚盘落后 3 步，单次枚举能否直接追上？===');
{
  const startCodes = B.boardFenToCodes(START);
  const farGrid = toGrid(B.boardFenToCodes(chain[2]));
  const r = B.enumerateAdvance(startCodes, farGrid, 'w');
  console.log('   result:', JSON.stringify(r));
  console.log('   → 落后 3 步时单次枚举应返回 null（没有任何单步能对上），这是**正确**行为');
}

// ===== 场景 B：逐帧喂进来，看能否连续追 3 步 =====
console.log('\n=== B. 逐帧追上（模拟真机连续帧）===');
{
  let anchor = B.boardFenToCodes(START);
  let side = 'w';
  let caught = 0;
  for (let k = 0; k < 3; k++) {
    const gridK = toGrid(B.boardFenToCodes(chain[k]));
    const r = B.enumerateAdvance(anchor, gridK, side);
    if (r && r.move) {
      const from = C.mvFrom(r.move), to = C.mvTo(r.move);
      const nf = anchor.slice();
      nf[to] = nf[from];
      nf[from] = 0;
      anchor = nf;
      caught++;
      console.log(`   第${k + 1}步: 认出 ${C.mvToUcci(r.move)}  sig=${r.sig} noise=${r.noise}`);
      side = (side === 'w') ? 'b' : 'w';
    } else {
      console.log(`   第${k + 1}步: 未识别 result=${JSON.stringify(r)}`);
      break;
    }
  }
  console.log(`   连续追上 ${caught}/3 步  ${caught === 3 ? '✓ 追赶能力成立' : '✗'}`);
}

// ===== 场景 C：跳帧后能否追上（锚盘落后 2 步，只有最新一帧）=====
console.log('\n=== C. 锚盘落后 2 步、之后逐帧恢复 ===');
{
  let anchor = B.boardFenToCodes(START);
  // 先跳过前 2 步（模拟那两帧没抓到），从第 3 步开始
  for (let k = 2; k < 5; k++) {
    const gridK = toGrid(B.boardFenToCodes(chain[k]));
    const side = (k % 2 === 0) ? 'w' : 'b';
    const r = B.enumerateAdvance(anchor, gridK, side);
    if (r && r.move) {
      console.log(`   帧${k + 1}: 认出 ${C.mvToUcci(r.move)} (sig=${r.sig}, noise=${r.noise}, diff=${r.diff})`);
      const from = C.mvFrom(r.move), to = C.mvTo(r.move);
      const nf = anchor.slice(); nf[to] = nf[from]; nf[from] = 0;
      anchor = nf;
    } else {
      console.log(`   帧${k + 1}: 未识别（锚盘落后，单步对不上）`);
    }
  }
}
