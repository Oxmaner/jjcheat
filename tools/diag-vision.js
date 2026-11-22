'use strict';
/* 离线台架：用真机截图跑识别层，打印每格墨迹/亮度，定位河带误判 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'src');
const REC = require(path.join(ROOT, 'vision/recognizer.js'));

const file = process.argv[2];
const W = 428, H = 926;
const buf = fs.readFileSync(file);
const px = new Uint8ClampedArray(buf.buffer, buf.byteOffset, buf.length);

// 标定四角（point 坐标，来自 JJCalibrator：左上 右上 右下 左下）
const corners = [[28, 257], [398, 257], [398, 659], [28, 659]];

const rec = new REC.BoardRecognizer({ corners, enableLowConfRefine: false });
const stats = rec.sampleAll(px, W, H, true);
rec.learnBackground(stats, []);
let cls = null;
try { cls = rec.classifyByColor(stats); } catch (e) { console.log('classifyByColor ERR', e.message); }
try { if (rec.calibrateBoardLevel) rec.calibrateBoardLevel(stats); } catch (e) {}

const bg = rec.bgModel || {};
console.log('bg:', JSON.stringify({
  inkThOcc: bg.inkThOcc, boardL: bg.boardL, hiTh: bg.hiTh, loTh: bg.loTh
}));
if (cls && cls.grid) {
  const sym = { 0: '.', 1: 'R', 2: 'B' };
  console.log('\n=== 识别出的三分类盘面（. 空 / R 红 / B 黑）===');
  for (let r = 0; r < 10; r++) {
    let line = '';
    for (let c = 0; c < 9; c++) line += sym[cls.grid[r * 9 + c]] || '?';
    console.log(`  row${r}  ${line}`);
  }
}

function row(r) {
  const out = [];
  for (let c = 0; c < 9; c++) {
    const s = stats[r * 9 + c] || {};
    out.push({
      c,
      ink: +(s.inkR || 0).toFixed(3),
      red: +(s.redInkR || 0).toFixed(3),
      dark: +(s.darkInkR || 0).toFixed(3),
      warm: +(s.warmR || 0).toFixed(3),
      L: +((s.meanL || 0) | 0)
    });
  }
  return out;
}
for (const r of [3, 4, 5, 6]) {
  console.log(`\n--- row${r} ---`);
  for (const o of row(r)) {
    console.log(`  col${o.c}  ink=${o.ink}  red=${o.red}  dark=${o.dark}  warm=${o.warm}  L=${o.L}`);
  }
}
