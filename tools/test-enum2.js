'use strict';
/* 2.0.0r37：验证两步枚举 enumerateAdvance2 + 「单步把对手那步当噪声吞掉」这个缺陷。
   背景：人机 AI 回子比 3 帧确认快，一次比对里常含「我方一步 + 对方一步」。 */
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
const ucciOf = (m) => C.sqToUcci(C.mvFrom(m)) + C.sqToUcci(C.mvTo(m));

let pass = 0, fail = 0;
function check(label, got, want) {
  const ok = String(got) === String(want);
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}   got=${got} want=${want}`);
  ok ? pass++ : fail++;
}

const p1 = new POS.Position(START + ' w - - 0 1');
const redMove = p1.genLegalMoves().find(m => ucciOf(m) === 'c3c4') || p1.genLegalMoves()[0];
p1.makeMove(redMove);
const fenAfterRed = p1.getFen();
const blackMove = p1.genLegalMoves()[0];
p1.makeMove(blackMove);
const fenAfterTwo = p1.getFen();

console.log(`红方第1手 = ${ucciOf(redMove)}   黑方第1手 = ${ucciOf(blackMove)}`);
console.log(`两步后 FEN = ${fenAfterTwo}`);

console.log('\n=== 1. 单步枚举必须拒绝"只解释一半"的盘面 ===');
let d1 = null;
{
  const anchor = B.boardFenToCodes(START);
  d1 = B.enumerateAdvance(anchor, toGrid(B.boardFenToCodes(fenAfterTwo)), 'w');
  console.log('   enumerateAdvance →', JSON.stringify(d1),
              d1 && d1.move ? `(${ucciOf(d1.move)})` : '');
  /* r37 之前它会认下我方那一步、把对手那步当成 2 格噪声——
     结果锚盘缺一手，之后每一步建议都是错的。现在必须拒绝。 */
  check('单步拒绝半个解释（返回 null）', d1 === null, true);
}

console.log('\n=== 2. 两步枚举必须精确认回这两步 ===');
let d2 = null;
{
  const anchor = B.boardFenToCodes(START);
  d2 = B.enumerateAdvance2(anchor, toGrid(B.boardFenToCodes(fenAfterTwo)), 'w');
  console.log('   enumerateAdvance2 →', JSON.stringify(d2));
  check('认回第 1 步', d2 && ucciOf(d2.move1), ucciOf(redMove));
  check('认回第 2 步', d2 && ucciOf(d2.move2), ucciOf(blackMove));
  check('签名格零误差', d2 && d2.sig, 0);
  check('噪声零误差', d2 && d2.noise, 0);
  check('最优解唯一', d2 && d2.candidates, 1);
}

console.log('\n=== 3. 择优规则：单步已被拒，两步是唯一解释 ===');
{
  check('单步为 null', d1 === null, true);
  check('两步可用', !!(d2 && d2.move1 && d2.move2), true);
}

console.log('\n=== 4. 颜色认错（占位不变、颜色反转）仍应认对 ===');
{
  const codes = B.boardFenToCodes(fenAfterTwo);
  const g = toGrid(codes);
  /* 制造「红子被读成黑子」：占位不变、只有颜色错 —— 这是模板抖动的典型形态。
     任何一步棋都不可能解释它（要挪子就得让某格变空 → 触发占位严格性），
     所以它只能落在 noise 里，两步枚举应当照认不误。 */
  let victim = -1;
  const sigSq = [C.mvFrom(redMove), C.mvTo(redMove), C.mvFrom(blackMove), C.mvTo(blackMove)];
  for (let i = 0; i < 90; i++) {
    if (codes[i] >= 1 && codes[i] <= 7 && sigSq.indexOf(i) < 0) { victim = i; break; }
  }
  g[victim] = 2;
  const r = B.enumerateAdvance2(B.boardFenToCodes(START), g, 'w');
  console.log('   enumerateAdvance2 →', JSON.stringify(r));
  check('颜色噪声下仍认回第 2 步', r && ucciOf(r.move2), ucciOf(blackMove));
  check('该噪声被计入 noise', r && r.noise >= 1, true);
}

console.log('\n=== 5. 占位噪声（多出一格有子↔空）时，两步解释必须放弃 ===');
{
  const codes = B.boardFenToCodes(fenAfterTwo);
  const g = toGrid(codes);
  /* 找一格原本为空的，伪造成「凭空多出一枚子」——这不是任何一步棋能解释的 */
  let emptySq = -1;
  for (let i = 40; i < 90; i++) if (codes[i] === 0) { emptySq = i; break; }
  g[emptySq] = 1;
  const r = B.enumerateAdvance2(B.boardFenToCodes(START), g, 'w');
  console.log('   enumerateAdvance2 →', JSON.stringify(r));
  check('多出一枚子 → 拒答', r === null, true);
}

console.log('\n=== 6. 盘面没变 → null ===');
{
  const anchor = B.boardFenToCodes(START);
  check('noChange → null', B.enumerateAdvance2(anchor, toGrid(anchor), 'w') === null, true);
}

console.log('\n=== 7. 只有一步时，两步枚举不许硬凑 ===');
{
  const anchor = B.boardFenToCodes(START);
  const r = B.enumerateAdvance2(anchor, toGrid(B.boardFenToCodes(fenAfterRed)), 'w');
  console.log('   enumerateAdvance2 →', JSON.stringify(r));
  check('一步盘面返回 null', r === null, true);
}

console.log(`\n===== ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail ? 1 : 0);
