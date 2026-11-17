#!/usr/bin/env node
/**
 * frame-probe —— 真机帧离线体检（用打包后的 dist/engine.js，与线上同一份代码）
 *
 * 用途：把手机上下载的失败帧 JPEG 转成 raw RGB，直接在本地跑一遍识别管线，
 * 打印「每格墨迹 / 亮度 / 判据结果 / 对齐结果」，用来定案线上到底死在哪一步。
 *
 * 用法：
 *   node tools/frame-probe.js <frame.raw> <w> <h> [x0 y0 x1 y1 x2 y2 x3 y3]
 *     - frame.raw：RGB 三通道裸数据（PIL: Image.open(jpg).convert('RGB').tobytes()）
 *     - 四角顺序：左上 / 右上 / 右下 / 左下（与 App 里点四角的顺序一致）
 *     - 四角省略时用「画面内缩 6%」的粗估框，只为先看分布
 *
 * 输出解读：
 *   墨迹基线 boardInkMed ≈ 空格 ink；inkThOcc 是自适应阈值；
 *   棋子 ink 应 ≥ inkThOcc 且明显高于星标（0.10 左右）；
 *   判有子 应等于当前盘面棋子数（开局 32）。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ENGINE = path.join(__dirname, '..', 'dist', 'engine.js');

function main() {
  const argv = process.argv.slice(2);
  if (argv.length < 3) {
    console.error('用法: node tools/frame-probe.js <frame.raw> <w> <h> [x0 y0 x1 y1 x2 y2 x3 y3]');
    process.exit(2);
  }
  const rawPath = argv[0];
  const w = parseInt(argv[1], 10);
  const h = parseInt(argv[2], 10);
  const nums = argv.slice(3).map(Number);
  let corners;
  if (nums.length === 8) {
    corners = [[nums[0], nums[1]], [nums[2], nums[3]], [nums[4], nums[5]], [nums[6], nums[7]]];
  } else {
    const padX = Math.round(w * 0.06), padY = Math.round(h * 0.22);
    corners = [[padX, padY], [w - padX, padY], [w - padX, h - padY], [padX, h - padY]];
    console.log('（未给四角，用粗估框：' + JSON.stringify(corners) + '）');
  }

  const src = fs.readFileSync(ENGINE, 'utf8');
  global.__JJ_TEST_HOOK__ = function (RECm, TRKm) { global.__REC = RECm; global.__TRK = TRKm; };
  vm.runInThisContext(src, { filename: 'engine.js' });
  const REC = global.__REC;
  const TRK = global.__TRK;
  if (!REC || !TRK) throw new Error('测试钩子未注入（bundle 缺 __JJ_TEST_HOOK__？）');

  const raw = fs.readFileSync(rawPath);
  if (raw.length !== w * h * 3) throw new Error('raw 长度不符: ' + raw.length + ' ≠ ' + (w * h * 3));
  const rgba = Buffer.alloc(w * h * 4);
  for (let i = 0, j = 0; i < raw.length; i += 3, j += 4) {
    rgba[j] = raw[i]; rgba[j + 1] = raw[i + 1]; rgba[j + 2] = raw[i + 2]; rgba[j + 3] = 255;
  }

  const rec = new REC.BoardRecognizer({ corners: corners, enableLowConfRefine: true });
  const stats = rec.sampleAll(rgba, w, h, true);
  rec.learnBackground(stats, []);
  const bg = rec.bgModel || {};
  console.log('\n== 采样几何 ==');
  console.log('cell=%s radius=%s gain=%s meanL=%s',
    (rec.lastStats && rec.lastStats.cell || 0).toFixed(1),
    rec.lastStats && rec.lastStats.radius,
    (rec.lastStats && rec.lastStats.gain || 0).toFixed(2),
    Math.round(stats.reduce((a, s) => a + (s && s.n ? s.meanL : 0), 0) / 90));

  console.log('\n== 阈值模型 ==');
  console.log('boardL=%s [loTh,hiTh]=[%s,%s] mad=%s',
    Math.round(bg.boardL || 0), Math.round(bg.loTh || 0), Math.round(bg.hiTh || 0),
    bg.mad ? bg.mad.toFixed(1) : '-');
  console.log('boardInkMed=%s inkThOcc=%s',
    bg.boardInkMed !== undefined ? bg.boardInkMed.toFixed(3) : '-',
    bg.inkThOcc !== undefined ? bg.inkThOcc.toFixed(3) : '-');

  const colorCls = rec.classifyByColor(stats);
  const tplCls = rec.classifyByTemplate ? rec.classifyByTemplate(stats) : null;
  const spm = TRK.startPieceMap();

  let occ = 0, red = 0, blk = 0;
  const lines = [];
  for (let r = 0; r < 10; r++) {
    let ln = '';
    for (let c = 0; c < 9; c++) {
      const i = r * 9 + c;
      const s = stats[i] || {};
      const has = colorCls.grid[i] !== 0;
      if (has) occ++;
      if (colorCls.grid[i] === 1) red++; else if (colorCls.grid[i] === 2) blk++;
      const ink = (s.inkR || 0).toFixed(2);
      const L = Math.round(s.meanL || 0);
      ln += (has ? (colorCls.grid[i] === 1 ? 'R' : 'B') : '.') + ' ' +
        ('   ' + ink).slice(-4) + '/' + ('  ' + L).slice(-3) + ' |';
    }
    lines.push('r' + r + ' ' + ln);
  }
  console.log('\n== 每格：占位 / 墨迹 / 亮度 ==');
  console.log(lines.join('\n'));
  console.log('\n判有子(颜色分类) = %d  (红 %d / 黑 %d)    标准开局应为 32', occ, red, blk);

  /* 被判「有子」的格子逐格展开：中心墨迹 inkCoreR 与整体墨迹的比值能区分
     「棋子上的字（字在盘心）」和「棋盘上的定位标记（十字/星形，笔画散在中心外）」。 */
  console.log('\n== 判有子的格子明细 ==');
  for (let r = 0; r < 10; r++) {
    let ln = '';
    for (let c = 0; c < 9; c++) {
      const i = r * 9 + c;
      if (colorCls.grid[i] === 0) { ln += '   ---      '; continue; }
      const s = stats[i] || {};
      ln += (' r' + r + 'c' + c).padEnd(6) +
        ('ink' + (s.inkR || 0).toFixed(2)).padEnd(9) +
        ('core' + (s.inkCoreR || 0).toFixed(2)).padEnd(10) +
        ('red' + (s.redInkR || 0).toFixed(2)).padEnd(9) +
        ('L' + Math.round(s.meanL || 0));
    }
    if (ln.trim()) console.log(ln);
  }

  if (tplCls) {
    let tN = 0;
    for (let i = 0; i < 90; i++) if (tplCls.codes[i]) tN++;
    let diff = 0;
    for (let i = 0; i < 90; i++) if ((tplCls.codes[i] || 0) !== (spm[i] || 0)) diff++;
    console.log('模板识别 = %d 子，与标准开局差 = %d 格（模板数 %d）',
      tN, diff, rec.templateCount || 0);
  }

  /* ---- 复刻线上 learnBoard 的自举 + 验证（bundle.js 600~657 行同逻辑）----
     闸门只看占位（颜色分类），差 ≤4 格才贴标签裁模板；然后用模板重认同一帧比标准开局。
     这一步能回答「学完到底能不能出 FEN」。 */
  console.log('\n== 复刻 learnBoard 自举 ==');
  let occDiff = 0;
  for (let i = 0; i < 90; i++) {
    const hasOnScreen = colorCls.grid[i] !== 0;
    const hasInOpening = spm[i] !== 0;
    if (hasOnScreen !== hasInOpening) occDiff++;
  }
  console.log('占位差 = %d 格（闸门 ≤4）', occDiff);
  if (occDiff <= 4) {
    rec.learnTemplates(stats, spm);
    const c2 = rec.classify(stats);
    let d2 = 0, n2 = 0, bad = [];
    for (let i = 0; i < 90; i++) {
      if (c2.codes[i]) n2++;
      if ((c2.codes[i] || 0) !== (spm[i] || 0)) {
        d2++;
        bad.push('r' + ((i / 9) | 0) + 'c' + (i % 9) + ':' + c2.codes[i] + '/' + spm[i]);
      }
    }
    console.log('自举后模板数 = %d，认出 %d 子，与标准开局差 %d 格（ok 门槛 ≤8）',
      rec.templateCount || 0, n2, d2);
    if (bad.length) console.log('差异格: %s', bad.join(' '));
  } else {
    console.log('闸门未过：不会裁模板（线上就是不学习 → verifyDiff=32）');
  }

  const openingIdx = [], emptyIdx = [];
  for (let i = 0; i < 90; i++) (spm[i] ? openingIdx : emptyIdx).push(i);
  const al = REC.alignGridToOpening(rgba, w, h, corners, openingIdx, emptyIdx);
  console.log('\n== 格点对齐 ==');
  if (!al) {
    console.log('返回 null（guard 拦下：四角退化 / 采样出界）');
  } else {
    console.log('采纳=%s already=%s 命中=%d/32 空格误报=%d 原命中=%d 原误报=%d 平移=%d,%d 缩放=%s,%s evals=%d',
      al.accepted ? 1 : 0, al.already ? 1 : 0, al.occHit, al.emptyHit, al.idOccHit, al.idEmptyHit,
      Math.round(al.shiftX), Math.round(al.shiftY), al.scaleX.toFixed(3), al.scaleY.toFixed(3), al.evals);
    if (al.corners) console.log('新四角 = %s', JSON.stringify(al.corners.map(p => [Math.round(p[0]), Math.round(p[1])])));
  }
}

main();
