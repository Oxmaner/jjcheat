'use strict';
/* 离线端到端台架：把真机截图喂进打包后的 engine.js，跑完整 learn + process，
   直接看输出对象——用来发现「读代码看不出来」的运行时 bug。 */
const fs = require('fs');
const path = require('path');

const enginePath = path.join(__dirname, '..', 'dist', 'engine.js');
const JJEngine = require(enginePath);

const file = process.argv[2];
const W = 428, H = 926;
const buf = fs.readFileSync(file);
const px = new Uint8Array(buf.buffer, buf.byteOffset, buf.length);

const corners = [[28, 257], [398, 257], [398, 659], [28, 659]];

function dump(label, obj) {
  const keys = ['recognized', 'legalNow', 'codesValid', 'flipped', 'sideToMove', 'turn',
                'waitingOpponent', 'ply', 'skipReason', 'skipAnalyze', 'moveDetected',
                'move', 'suggest', 'from', 'to', 'engineFen', 'fen', 'searchFen', 'needSearch',
                'diffChanged', 'anchorRejected', 'unsureCount', 'illegalStreak'];
  const out = {};
  for (const k of keys) if (obj && obj[k] !== undefined) out[k] = obj[k];
  console.log(`\n=== ${label} ===`);
  console.log(JSON.stringify(out, null, 1));
  if (obj && obj.fen) console.log('fen =', obj.fen);
  if (obj && obj.engineFen) console.log('engineFen =', obj.engineFen);
  if (obj && obj.searchFen) console.log('searchFen =', obj.searchFen);
}

try {
  JJEngine.setCorners(corners);
  console.log('setCorners ok');
} catch (e) { console.log('setCorners ERR:', e.message); process.exit(1); }

let learned = null;
try {
  learned = JJEngine.learnAndRefine(px, W, H, corners);
  console.log('learnAndRefine →', JSON.stringify(learned));
} catch (e) {
  console.log('learnAndRefine THREW:', e.message);
  console.log(e.stack.split('\n').slice(0, 4).join('\n'));
}

for (let i = 1; i <= 3; i++) {
  try {
    const r = JJEngine.process(px, W, H, { live: true });
    dump(`process #${i}`, r);
  } catch (e) {
    console.log(`process #${i} THREW:`, e.message);
    console.log(e.stack.split('\n').slice(0, 4).join('\n'));
    break;
  }
}
