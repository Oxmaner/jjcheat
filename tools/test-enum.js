'use strict';
/* 验证 enumerateAdvance —— 用「真实 move 编码」而不是手写 UCCI，
   因为项目里 C.sqToUcci 的 rank 是反的（见测试末尾的专项检查）。 */
const path = require('path');
const ROOT = 'F:/MacLin/Documents/jjcheat-patch/src';
const B = require(path.join(ROOT, 'app/board.js'));
const C = require(path.join(ROOT, 'cst/constants.js'));
const POS = require(path.join(ROOT, 'cst/position.js'));

const START = 'rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR';

function toGrid(codes) {
  const g = new Int8Array(90);
  for (let i = 0; i < 90; i++) g[i] = codes[i] ? (codes[i] <= 7 ? 1 : 2) : 0;
  return g;
}
function playFen(fen, m) {
  const p = new POS.Position(fen);
  p.makeMove(m);
  return p.getFen();
}
let pass = 0, fail = 0;
function check(label, got, want) {
  const ok = String(got) === String(want);
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}   got=${got} want=${want}`);
  ok ? pass++ : fail++;
}

// 取开局第一个合法走法当作"真实走法"
const p0 = new POS.Position(START + ' w - - 0 1');
const moves0 = p0.genLegalMoves();
const realMove = moves0[0];
console.log('真实走法 move =', realMove, ' from=', C.mvFrom(realMove), ' to=', C.mvTo(realMove));

console.log('\n=== 1. 锚盘=开局，本帧=走完这一步，应原样认回 ===');
{
  const startCodes = B.boardFenToCodes(START);
  const afterFen = playFen(START + ' w - - 0 1', realMove);
  const r = B.enumerateAdvance(startCodes, toGrid(B.boardFenToCodes(afterFen)), 'w');
  console.log('   result:', JSON.stringify(r));
  check('认回同一步', r && r.move, realMove);
  check('签名格零误差', r && r.sig, 0);
  check('噪声格零误差', r && r.noise, 0);
}

console.log('\n=== 2. 加 3 格噪声仍应认对 ===');
{
  const startCodes = B.boardFenToCodes(START);
  const afterFen = playFen(START + ' w - - 0 1', realMove);
  const grid = toGrid(B.boardFenToCodes(afterFen));
  for (const s of [20, 50, 70]) grid[s] = grid[s] ? 0 : 1;
  const r = B.enumerateAdvance(startCodes, grid, 'w');
  console.log('   result:', JSON.stringify(r));
  check('噪声下认对', r && r.move, realMove);
}

console.log('\n=== 3. 局面没变 → noChange ===');
{
  const startCodes = B.boardFenToCodes(START);
  const r = B.enumerateAdvance(startCodes, toGrid(startCodes), 'w');
  check('noChange', r && r.noChange, true);
}

console.log('\n=== 4. 黑方走子（side=b），锚盘=红方走完 ===');
{
  const fen1 = playFen(START + ' w - - 0 1', realMove);
  const codes1 = B.boardFenToCodes(fen1);
  const pb = new POS.Position(fen1);
  const bmoves = pb.genLegalMoves();
  const bMove = bmoves[0];
  const fen2 = playFen(fen1, bMove);
  const r = B.enumerateAdvance(codes1, toGrid(B.boardFenToCodes(fen2)), 'b');
  console.log('   黑方真实走法 =', bMove, ' result:', JSON.stringify(r));
  check('认回黑方走法', r && r.move, bMove);
}

console.log('\n=== 5. 专项：sqToUcci 与 JJSqFromICCS 是否一致 ===');
{
  // 原生 JJSqFromICCS('h2') = (9-2)*9+7 = 70
  const expected = (9 - 2) * 9 + 7;
  const back = C.sqToUcci(expected);
  console.log(`   JJSqFromICCS('h2') = ${expected}, C.sqToUcci(${expected}) = '${back}'  (应为 'h2')`);
  check('UCCI 往返一致', back, 'h2');
}

console.log(`\n===== ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail ? 1 : 0);
