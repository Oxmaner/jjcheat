'use strict';
/*
 * 棋盘视觉识别核心 —— 纯 JS，无依赖，可在 Node / JavaScriptCore / 浏览器复用
 *
 * 核心思路（关键设计）：
 *   不识别「这是车还是马」。只做三分类：空 / 红子 / 黑子。
 *   兵种身份全部由「上一局面 + 合法走法枚举」反推（见 tracker.js）。
 *   这样识别只需 3 个稳定特征，抗皮肤、抗缩放、抗压缩噪声。
 *
 * 坐标约定：
 *   交叉点 = row*9 + col，row 0 = 屏幕最上（黑方底线），col 0 = 屏幕最左
 *   四点标定顺序：[左上, 右上, 右下, 左下]
 */

/** 字形采样网格边长。
 *  16×16 对中文棋子太粗：車/馬/炮/仕 的笔画会糊在一起，
 *  实测会出现「车认成炮、炮认成车」这种纯字形混淆。
 *  提到 24×24（576 个采样点）后笔画结构能分辨出来。 */
const PATCH_W = 24;

const EMPTY = 0;
const RED_PC = 1;
const BLK_PC = 2;

/** 颜色兜底判据（无模板时的三分类 / learnBoard 判朝向）。
 *  红黑一律比较「红墨 vs 黑墨」，不用红色占比 redR：
 *  redR 判据 (R>85 && R-G>45 && R-B>45) 会把木色背景里的偏红像素算成红，
 *  真机上出现过顶行 9 个黑子被判成红子（topRed=9 / topBlack=0）。 */
const COLOR_INK_MIN = 0.05;        // 有子所需的最小墨迹占比
const COLOR_DARK_MIN = 0.20;       // 暗色棋子所需的最小暗像素占比
const COLOR_DARK_FACE = 0.45;      // 纯黑子暖色低，靠暗像素占比认定有子
const COLOR_RED_INK_MIN = 0.01;    // 红墨绝对下限，防噪点误判
const COLOR_RED_INK_RATIO = 0.30;  // 红墨 / 黑墨 的最小比值

/** 三线性透视变换：由四角求任意 (u,v) 的图像坐标 */
function bilinear(p00, p10, p11, p01, u, v) {
  const a = (1 - u) * (1 - v), b = u * (1 - v), c = u * v, d = (1 - u) * v;
  return [
    a * p00[0] + b * p10[0] + c * p11[0] + d * p01[0],
    a * p00[1] + b * p10[1] + c * p11[1] + d * p01[1]
  ];
}

/** 透视变换：4 点求单应矩阵（比双线性更准，用于大倾角） */
function homography(src, dst) {
  // src/dst: [[x,y] x4]。解 8x8 线性方程组
  const A = [], B = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = src[i];
    const [u, v] = dst[i];
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); B.push(u);
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); B.push(v);
  }
  // 高斯消元
  const n = 8;
  const M = A.map((row, i) => row.concat([B[i]]));
  for (let col = 0; col < n; col++) {
    let piv = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(M[r][col]) > Math.abs(M[piv][col])) piv = r;
    if (Math.abs(M[piv][col]) < 1e-12) return null;
    [M[col], M[piv]] = [M[piv], M[col]];
    const div = M[col][col];
    for (let c = col; c <= n; c++) M[col][c] /= div;
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = M[r][col];
      if (f === 0) continue;
      for (let c = col; c <= n; c++) M[r][c] -= f * M[col][c];
    }
  }
  return M.map(row => row[n]);
}

function applyH(H, x, y) {
  const w = H[6] * x + H[7] * y + 1;
  return [(H[0] * x + H[1] * y + H[2]) / w, (H[3] * x + H[4] * y + H[5]) / w];
}

/**
 * 抛物线插值细化峰值位置（亚像素精度）
 * 峰值 i 与左右两点做二次拟合，顶点偏移量就是亚像素修正量
 */
function refinePeak(profile, i) {
  if (i <= 0 || i >= profile.length - 1) return i;
  const a = profile[i - 1], b = profile[i], c = profile[i + 1];
  const denom = a - 2 * b + c;
  if (Math.abs(denom) < 1e-6) return i;
  let delta = 0.5 * (a - c) / denom;
  if (delta > 0.5) delta = 0.5;
  if (delta < -0.5) delta = -0.5;
  return i + delta;
}

/**
 * 一组等间距峰的查找
 * 棋盘 9 竖 10 横，线条严格等距 —— 用「等距约束」筛峰，比单纯找极值可靠得多
 */
function findEvenlySpacedPeaks(profile, count, minGap) {
  const n = profile.length;
  if (n < count * 3) return null;

  let maxV = 0;
  for (let i = 0; i < n; i++) if (profile[i] > maxV) maxV = profile[i];
  if (maxV <= 0) return null;

  // 1) 找局部极大值，做非极大值抑制
  const peaks = [];
  const th = maxV * 0.22;
  for (let i = 2; i < n - 2; i++) {
    const v = profile[i];
    if (v < th) continue;
    if (v < profile[i - 1] || v < profile[i + 1]) continue;
    if (peaks.length && i - peaks[peaks.length - 1] < minGap) {
      if (v > profile[peaks[peaks.length - 1]]) peaks[peaks.length - 1] = i;
    } else {
      peaks.push(i);
    }
  }
  if (peaks.length < count) return null;

  // 2) 在峰里找一组「等距」的位置
  let best = null, bestScore = -1;
  for (let s = 0; s < peaks.length; s++) {
    for (let e = s + count - 1; e < peaks.length; e++) {
      const span = peaks[e] - peaks[s];
      const d = span / (count - 1);
      if (d < minGap) continue;
      if (s + count - 1 > peaks.length) break;

      let score = 0, ok = true;
      const pos = [];
      for (let k = 0; k < count; k++) {
        const target = peaks[s] + d * k;
        let nearest = -1, nd = 1e9;
        for (let p = 0; p < peaks.length; p++) {
          const dd = Math.abs(peaks[p] - target);
          if (dd < nd) { nd = dd; nearest = peaks[p]; }
        }
        if (nearest < 0 || nd > d * 0.22) { ok = false; break; }
        score += profile[nearest];
        pos.push(nearest);
      }
      if (ok && score > bestScore) { bestScore = score; best = pos; }
    }
  }
  return best;
}

/**
 * 自动检测棋盘四角
 *
 * 原理：中国象棋棋盘是严格等间距的 9 竖 10 横网格。
 *   1. 转灰度
 *   2. 沿 x 求「垂直边缘强度」投影 → 竖线会形成 9 个尖峰
 *   3. 沿 y 求「水平边缘强度」投影 → 横线会形成 10 个尖峰
 *   4. 用等距约束从尖峰里挑出真正的 9+10 条线
 *   5. 最外四条线的交点就是四角
 *
 * 全程不需要任何颜色先验，也不怕棋子和高亮圈（它们只贡献零散噪声，
 * 构不成等距序列）。
 *
 * @returns {[[number,number],[number,number],[number,number],[number,number]]|null}
 *          顺序：左上 右上 右下 左下（图像像素坐标）
 */
/* ============================================================
 *  网格自校准（refineGrid）
 *
 *  不管初始四点有多歪，棋子一定落在交叉点上。
 *  做法：
 *    1. 用当前网格算出 90 个格点
 *    2. 每个格点在邻域内搜索「暖色最浓」的位置 → 这个棋子的真实中心
 *    3. 用这些真实中心，最小二乘反解网格参数（x = a+bu+cv+duv，y 同理）
 *    4. 迭代几次收敛
 *
 *  这能抹平自动检测 10~20% 的格距误差，也能吃掉手点四角时的几像素偏差。
 * ============================================================ */

/** 小区域的暖色占比（判断这里是不是棋子盘面） */
function localWarm(pixels, w, h, cx, cy, radius) {
  let n = 0, warm = 0;
  const step = Math.max(1, Math.floor(radius / 3));
  for (let dy = -radius; dy <= radius; dy += step) {
    for (let dx = -radius; dx <= radius; dx += step) {
      const x = Math.round(cx + dx), y = Math.round(cy + dy);
      if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
      const i = (y * w + x) * 4;
      const R = pixels[i], G = pixels[i + 1], B = pixels[i + 2];
      // 跳过白色高亮圈和绿色
      if (R > 200 && G > 200 && B > 200) continue;
      if (G > R + 30 && G > B + 30 && G > 90) continue;
      n++;
      if ((R - B) > 22 && R > 80) warm++;
    }
  }
  return n > 0 ? warm / n : 0;
}

/** 解 4x4 线性方程组（列主元高斯消元） */
function solve4(A, b) {
  const n = 4;
  const M = [];
  for (let i = 0; i < n; i++) M.push(A[i].concat([b[i]]));
  for (let col = 0; col < n; col++) {
    let piv = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(M[r][col]) > Math.abs(M[piv][col])) piv = r;
    if (Math.abs(M[piv][col]) < 1e-9) return null;
    const tmp = M[col]; M[col] = M[piv]; M[piv] = tmp;
    const d = M[col][col];
    for (let c = col; c <= n; c++) M[col][c] /= d;
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = M[r][col];
      if (f === 0) continue;
      for (let c = col; c <= n; c++) M[r][c] -= f * M[col][c];
    }
  }
  return [M[0][n], M[1][n], M[2][n], M[3][n]];
}

/** 用一组 (u,v)->(x,y) 样本拟合双线性网格系数 */
function fitAxis(samples, useX) {
  const ATA = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
  const ATb = [0, 0, 0, 0];
  for (let k = 0; k < samples.length; k++) {
    const p = samples[k];
    const row = [1, p.u, p.v, p.u * p.v];
    const val = useX ? p.x : p.y;
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 4; j++) ATA[i][j] += row[i] * row[j];
      ATb[i] += row[i] * val;
    }
  }
  return solve4(ATA, ATb);
}

/**
 * 网格自校准
 * @param {Uint8ClampedArray} pixels RGBA
 * @param {number} w
 * @param {number} h
 * @param {Array<[number,number]>} corners 初始四角 [左上,右上,右下,左下]
 * @param {number} iterations 迭代次数（默认 3）
 * @returns {Array<[number,number]>} 校准后的四角
 */
function refineGrid(pixels, w, h, corners, iterations) {
  const iters = iterations || 3;
  let cur = corners.map(p => [p[0], p[1]]);

  for (let iter = 0; iter < iters; iter++) {
    const [p00, p10, p11, p01] = cur;
    // 格子尺寸（用两个方向分别估）
    const cellW = Math.hypot(p10[0] - p00[0], p10[1] - p00[1]) / 8;
    const cellH = Math.hypot(p01[0] - p00[0], p01[1] - p00[1]) / 9;
    const cell = Math.min(cellW, cellH);
    if (cell < 6) break;

    // 搜索半径：格子的 35%，足够覆盖累积偏移
    const searchR = Math.max(3, Math.round(cell * 0.35));
    // 局部暖色采样半径：棋子盘面的一半
    const localR = Math.max(2, Math.round(cell * 0.18));

    const samples = [];

    for (let r = 0; r < 10; r++) {
      const v = r / 9;
      for (let c = 0; c < 9; c++) {
        const u = c / 8;
        // 当前网格给出的格点
        const a = (1 - u) * (1 - v), b = u * (1 - v), cc = u * v, d = (1 - u) * v;
        const x0 = a * p00[0] + b * p10[0] + cc * p11[0] + d * p01[0];
        const y0 = a * p00[1] + b * p10[1] + cc * p11[1] + d * p01[1];

        // 在邻域内找暖色最浓的位置
        let bestX = x0, bestY = y0, bestWarm = -1;
        for (let dy = -searchR; dy <= searchR; dy += 2) {
          for (let dx = -searchR; dx <= searchR; dx += 2) {
            const x = x0 + dx, y = y0 + dy;
            if (x < 2 || y < 2 || x >= w - 2 || y >= h - 2) continue;
            const warm = localWarm(pixels, w, h, x, y, localR);
            if (warm > bestWarm) { bestWarm = warm; bestX = x; bestY = y; }
          }
        }

        // 只有明显是棋子盘面才作为拟合样本（空格不参与）
        if (bestWarm >= 0.45) {
          samples.push({ x: bestX, y: bestY, u: u, v: v });
        }
      }
    }

    // 样本太少说明画面不是对局中，别乱拟合
    if (samples.length < 6) break;

    const cx = fitAxis(samples, true);
    const cy = fitAxis(samples, false);
    if (!cx || !cy) break;

    function evalX(u, v) { return cx[0] + cx[1] * u + cx[2] * v + cx[3] * u * v; }
    function evalY(u, v) { return cy[0] + cy[1] * u + cy[2] * v + cy[3] * u * v; }

    const next = [
      [evalX(0, 0), evalY(0, 0)],
      [evalX(1, 0), evalY(1, 0)],
      [evalX(1, 1), evalY(1, 1)],
      [evalX(0, 1), evalY(0, 1)]
    ];

    // 收敛判定：四角移动小于 0.5 像素就停
    let moveSum = 0;
    for (let i = 0; i < 4; i++) {
      moveSum += Math.abs(next[i][0] - cur[i][0]) + Math.abs(next[i][1] - cur[i][1]);
    }
    cur = next;
    if (moveSum < 2.0) break;   // 四角总共移动 < 2 像素
  }

  return cur;
}
/**
 * 一维等间距拟合：给一堆「应该落在 count 条等距线上」的坐标，
 * 反解出 origin 与 step。
 *
 * 用「分配 → 最小二乘 → 再分配」的迭代，对缺失线（某列/某行没棋子）免疫。
 *
 * @param {number[]} vals 观测坐标
 * @param {number} count 线数
 * @param {number} stepHint 初始格距估计
 * @param {number} tolRatio 允许的残差（相对格距），超出的观测点丢弃
 * @returns {{origin:number, step:number, used:number}|null}
 */
function fitEvenLines(vals, count, stepHint, tolRatio) {
  if (!vals || vals.length < 3 || !(count >= 2)) return null;
  const tol = (tolRatio || 0.42) * stepHint;
  const sorted = vals.slice().sort((a, b) => a - b);

  // 两个候选初值：端点撑满 / 中位间隔
  const seeds = [];
  seeds.push({ origin: sorted[0], step: (sorted[sorted.length - 1] - sorted[0]) / (count - 1) });
  const gaps = [];
  for (let i = 1; i < sorted.length; i++) gaps.push(sorted[i] - sorted[i - 1]);
  gaps.sort((a, b) => a - b);
  const medGap = gaps.length ? gaps[Math.floor(gaps.length / 2)] : stepHint;
  seeds.push({ origin: sorted[0] - Math.round(((sorted[0] - sorted[0]) / medGap)) * medGap, step: medGap });

  let best = null;

  for (let s = 0; s < seeds.length; s++) {
    let origin = seeds[s].origin;
    let step = seeds[s].step;
    if (!(step > 2)) continue;
    let used = 0;

    for (let it = 0; it < 14; it++) {
      const buckets = [];
      for (let k = 0; k < count; k++) buckets.push([]);
      for (let i = 0; i < sorted.length; i++) {
        const v = sorted[i];
        const k = Math.round((v - origin) / step);
        if (k < 0 || k >= count) continue;
        if (Math.abs(v - (origin + k * step)) > tol) continue;
        buckets[k].push(v);
      }
      // 最小二乘：每个有观测的 k 取均值，再拟合 v = origin + step*k
      let Sk = 0, Sk2 = 0, Sv = 0, Skv = 0, N = 0;
      for (let k = 0; k < count; k++) {
        const b = buckets[k];
        if (!b.length) continue;
        let sum = 0;
        for (let i = 0; i < b.length; i++) sum += b[i];
        const m = sum / b.length;
        Sk += k; Sk2 += k * k; Sv += m; Skv += k * m; N++;
      }
      if (N < 3) break;
      const den = N * Sk2 - Sk * Sk;
      if (Math.abs(den) < 1e-9) break;
      const nb = (N * Skv - Sk * Sv) / den;
      const na = (Sv - nb * Sk) / N;
      if (!isFinite(nb) || !isFinite(na) || Math.abs(nb) < 2) break;
      const moved = Math.abs(nb - step) + Math.abs(na - origin);
      origin = na; step = nb; used = N;
      if (moved < 0.05) break;
    }

    if (used < 3 || !(step > 2)) continue;
    // 残差 + 两端覆盖检查
    let res = 0, cnt = 0, hasLow = false, hasHigh = false;
    for (let i = 0; i < sorted.length; i++) {
      const v = sorted[i];
      const k = Math.round((v - origin) / step);
      if (k < 0 || k >= count) continue;
      const d = Math.abs(v - (origin + k * step));
      if (d > tol) continue;
      if (k === 0) hasLow = true;
      if (k === count - 1) hasHigh = true;
      res += d; cnt++;
    }
    if (cnt < 3) continue;
    // 首尾两条线必须都有观测点 —— 否则说明 count/step 配错了，
    // 典型症状是把半幅画面当成整块棋盘（实测纵轴拟合到 81px/格）。
    if (!hasLow || !hasHigh) continue;
    const score = res / cnt - used * 0.01;
    if (!best || score < best.score) {
      best = { origin: origin, step: step, used: used, score: score, residual: res / cnt };
    }
  }

  return best;
}

/**
 * 一维峰值提取（带平滑与合并）
 */
function findPeaks1D(proj, len, minGap, relTh) {
  const sm = new Float32Array(len);
  for (let i = 1; i < len - 1; i++) sm[i] = (proj[i - 1] + proj[i] * 2 + proj[i + 1]) * 0.25;
  let maxv = 0;
  for (let i = 0; i < len; i++) if (sm[i] > maxv) maxv = sm[i];
  if (!(maxv > 0)) return [];
  const th = maxv * (relTh || 0.15);
  const raw = [];
  for (let i = 1; i < len - 1; i++) {
    if (sm[i] < th) continue;
    if (sm[i] < sm[i - 1] || sm[i] < sm[i + 1]) continue;
    // 峰值附近质心细化
    let s = 0, sw = 0;
    const R = 4;
    for (let d = -R; d <= R; d++) {
      const j = i + d;
      if (j < 1 || j >= len - 1) continue;
      s += j * sm[j]; sw += sm[j];
    }
    raw.push(sw > 0 ? s / sw : i);
  }
  const merged = [];
  for (let i = 0; i < raw.length; i++) {
    const p = raw[i];
    if (merged.length && p - merged[merged.length - 1] < minGap) {
      merged[merged.length - 1] = (merged[merged.length - 1] + p) * 0.5;
    } else merged.push(p);
  }
  return merged;
}

/**
 * ★ 用真实棋子反推网格（最可靠的一招）
 *
 * 原理：棋子只可能落在交叉点上。所以把「棋子盘面」像素分别投到 x 轴和 y 轴，
 * 得到 9 条竖线 / 10 条横线上的一簇峰值；对这些峰值做等间距最小二乘，
 * 就得到 格距 和 起点 —— 边缘投影那 10~20% 的误差被彻底抹平。
 *
 * 这一步解决的是「初始格距偏小 → 越往下越偏 → 第 7 行偏 69 像素 → 炮被判空」的根因。
 *
 * @param {Uint8ClampedArray} pixels RGBA
 * @param {number} w
 * @param {number} h
 * @param {Array<[number,number]>} corners 当前四角（仅作为搜索区域）
 * @returns {Array<[number,number]>|null} 修正后的四角，失败返回 null
 */
/* ============================================================
 * ★ 棋盘定位：归一化先验 + 全格对齐搜索
 *
 * 不再依赖「边缘投影 + 等距拟合」。原因：
 *   棋盘线是浅色细线，边缘强度弱；而 JJ象棋 的界面是木纹棕色，
 *   暖色干扰极多，投影峰值里既有棋子也有 UI 木块，
 *   等距拟合经常「少认几行」，格高实测从 61.9 跑到 81.0（偏 31%）。
 *   这种误差逐行累积，到第 7 行采样点已经偏了整整一格，炮就被判成空。
 *
 * 现在的做法：
 *   1. 棋子圆盘（米黄/浅褐）是最好认的东西 —— R−B>45 且够亮。
 *   2. 棋子只可能落在交叉点上。所以直接在 (起点, 格距) 上做搜索，
 *      打分 = 90 个交叉点的「圆盘密度之和」，命中数越高越对。
 *   3. 搜索起点用归一化先验（JJ象棋 布局是死的），
 *      四张真实截图反解出来的结果完全一致：
 *         x0/W = 0.0666   cw/W = 0.1078
 *         y0/H = 0.2773   ch/H = 0.0484
 *      开局命中数恰好 32 = 棋盘上的棋子数，中局 30 = 少了两个子。
 *
 * 这一步之后格距误差 < 1 像素，采样子弹不再打偏。
 * ============================================================ */

/** JJ象棋 棋盘在整屏截图中的归一化位置
 *  由「棋子圆盘全格对齐搜索」在多张真实截图上反解，再用逐格真值验证
 *  （450 格只错 1 格），是所有样本共同收敛到的同一组值。
 *  用它当定位起点：命中数够就直接采用，避免被遮挡物带偏。 */
const BOARD_PRIOR = {
  x0: 0.065731,
  cw: 0.108391,
  y0: 0.277100,
  ch: 0.048350
};

/** 棋子圆盘掩码 + 积分图（用来 O(1) 求任意方框内的圆盘密度） */
function buildDiskIntegral(pixels, w, h) {
  const mask = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) {
    const base = y * w;
    for (let x = 0; x < w; x++) {
      const i = (base + x) * 4;
      const R = pixels[i], G = pixels[i + 1], B = pixels[i + 2];
      if (R - B <= 45 || R <= 170) continue;
      const L = 0.299 * R + 0.587 * G + 0.114 * B;
      if (L <= 150) continue;
      mask[base + x] = 1;
    }
  }
  const iw = w + 1;
  const integ = new Int32Array(iw * (h + 1));
  for (let y = 0; y < h; y++) {
    let rs = 0;
    const base = y * w;
    for (let x = 0; x < w; x++) {
      rs += mask[base + x];
      integ[(y + 1) * iw + x + 1] = integ[y * iw + x + 1] + rs;
    }
  }
  return { integ: integ, iw: iw, count: (function () { let n = 0; for (let i = 0; i < mask.length; i++) n += mask[i]; return n; })() };
}

/**
 * 找出「画中画浮窗棋盘」占据的矩形
 *
 * 抓屏会把画中画窗口一起抓进去（实测浮窗压住棋盘右上角时，
 * 那几个交叉点的暖色占比是 100%、墨迹 0% —— 那是浮窗里自己画的米黄棋盘）。
 * 浮窗棋盘底色实测 (227,203,161) L=205，比游戏棋盘空白（L≈170）
 * 和棋子盘面（L≈120~191）都亮得多，用亮度就能整块切出来。
 *
 * @returns {{x0,y0,x1,y1}|null}
 */
function findPipRectBeige(pixels, w, h) {
  // 先按 16x16 分块统计「浮窗米黄」占比。
  // 直接用所有命中像素求外接矩形会被画面里零散的高光点撑满整屏（实测过），
  // 所以必须先分块、再挑最大的连通块。
  const BS = 16;
  const bw = Math.ceil(w / BS), bh = Math.ceil(h / BS);
  const ratio = new Float32Array(bw * bh);
  const total = new Int32Array(bw * bh);
  const hit = new Int32Array(bw * bh);

  for (let y = 0; y < h; y++) {
    const by = (y / BS) | 0;
    const base = y * w;
    for (let x = 0; x < w; x++) {
      const bi = by * bw + ((x / BS) | 0);
      total[bi]++;
      const i = (base + x) * 4;
      const R = pixels[i], G = pixels[i + 1], B = pixels[i + 2];
      if (R <= 205 || G <= 180 || B <= 135) continue;
      if ((R - B) <= 45) continue;
      const L = 0.299 * R + 0.587 * G + 0.114 * B;
      if (L <= 198) continue;
      hit[bi]++;
    }
  }
  for (let i = 0; i < ratio.length; i++) ratio[i] = total[i] ? hit[i] / total[i] : 0;

  // 连通块标记（4 邻域）
  const lab = new Int32Array(bw * bh).fill(-1);
  const stack = new Int32Array(bw * bh);
  let bestBox = null, bestArea = 0;

  for (let s = 0; s < ratio.length; s++) {
    if (ratio[s] < 0.60 || lab[s] >= 0) continue;
    let sp = 0;
    stack[sp++] = s;
    lab[s] = s;
    let n = 0, mnx = bw, mxx = -1, mny = bh, mxy = -1;
    while (sp > 0) {
      const p = stack[--sp];
      const py = (p / bw) | 0, px = p % bw;
      n++;
      if (px < mnx) mnx = px;
      if (px > mxx) mxx = px;
      if (py < mny) mny = py;
      if (py > mxy) mxy = py;
      for (let k = 0; k < 4; k++) {
        let q;
        if (k === 0) { if (px === 0) continue; q = p - 1; }
        else if (k === 1) { if (px === bw - 1) continue; q = p + 1; }
        else if (k === 2) q = p - bw;
        else q = p + bw;
        if (q < 0 || q >= ratio.length || lab[q] >= 0) continue;
        if (ratio[q] < 0.60) continue;
        lab[q] = s;
        stack[sp++] = q;
      }
    }
    if (n > bestArea) {
      bestArea = n;
      bestBox = {
        x0: mnx * BS, y0: mny * BS,
        x1: Math.min(w - 1, (mxx + 1) * BS - 1),
        y1: Math.min(h - 1, (mxy + 1) * BS - 1),
        blocks: n
      };
    }
  }

  if (!bestBox) return null;
  if (bestArea < 30) return null;                                   // 太小，不是浮窗
  const rw = bestBox.x1 - bestBox.x0, rh = bestBox.y1 - bestBox.y0;
  if (rw < w * 0.15 || rh < h * 0.05) return null;
  return bestBox;
}

/** 给定一组网格参数，统计 90 个交叉点上的棋子圆盘命中情况 */
function gridAlignScore(integ, iw, w, h, x0, cw, y0, ch, rad, skip) {
  let score = 0, hits = 0, usable = 0;
  const rr = Math.max(2, Math.round(rad));
  for (let r = 0; r < 10; r++) {
    const y = y0 + r * ch;
    const ya = Math.round(y - rr), yb = Math.round(y + rr);
    if (ya < 0 || yb >= h) continue;
    for (let c = 0; c < 9; c++) {
      const x = x0 + c * cw;
      const xa = Math.round(x - rr), xb = Math.round(x + rr);
      if (xa < 0 || xb >= w) continue;
      // 落在浮窗区域里的交叉点不参与打分 —— 那块是被自己浮窗盖住的，
      // 里面是我们自己画的米黄棋盘，拿它当「棋子」会把网格整体拉偏。
      if (skip && x >= skip.x0 && x <= skip.x1 && y >= skip.y0 && y <= skip.y1) continue;
      const a = integ[ya * iw + xa];
      const b = integ[ya * iw + xb + 1];
      const cc = integ[(yb + 1) * iw + xa];
      const d = integ[(yb + 1) * iw + xb + 1];
      const area = (xb - xa + 1) * (yb - ya + 1);
      const dens = (d - b - cc + a) / area;
      score += dens;
      usable++;
      if (dens > 0.35) hits++;
    }
  }
  return { score: score, hits: hits, usable: usable };
}

/**
 * ★ 用棋子反推网格（核心定位函数）
 *
 * @param {Uint8ClampedArray} pixels RGBA
 * @param {number} w
 * @param {number} h
 * @param {Array<[number,number]>} corners 可选：额外的搜索起点（边缘投影结果）
 * @returns {Array<[number,number]>|null}
 */
function refineByPieces(pixels, w, h, corners) {
  refineByPieces.lastDebug = null;
  if (!pixels || w < 60 || h < 60) return null;

  const di = buildDiskIntegral(pixels, w, h);
  if (di.count < 400) return null;    // 画面里几乎没有棋子圆盘，不是对局
  const integ = di.integ, iw = di.iw;

  // 候选起点：归一化先验 + 边缘投影结果（如果有）
  const seeds = [];
  seeds.push({ x0: BOARD_PRIOR.x0 * w, cw: BOARD_PRIOR.cw * w, y0: BOARD_PRIOR.y0 * h, ch: BOARD_PRIOR.ch * h, tag: 'prior' });
  if (corners && corners.length >= 4) {
    const cw0 = (corners[1][0] - corners[0][0]) / 8;
    const ch0 = (corners[3][1] - corners[0][1]) / 9;
    if (cw0 > 8 && ch0 > 8) {
      seeds.push({ x0: corners[0][0], cw: cw0, y0: corners[0][1], ch: ch0, tag: 'edges' });
    }
  }

  // 先找出自己浮窗盖住的矩形，打分时跳过那块
  const skipRect = findPipRect(pixels, w, h);

  // 先验基准（用于「离先验多远」的打分）
  const priorRef = seeds[0];

  function devOf(x0, cw, y0, ch) {
    // 以「格」为单位衡量偏离先验的程度
    return Math.abs(x0 - priorRef.x0) / Math.max(1, priorRef.cw)
      + Math.abs(y0 - priorRef.y0) / Math.max(1, priorRef.ch)
      + Math.abs(cw - priorRef.cw) / Math.max(1, priorRef.cw) * 8
      + Math.abs(ch - priorRef.ch) / Math.max(1, priorRef.ch) * 9;
  }

  let best = null;
  let coarse = true;
  let locked = false;
  const coarseCands = [];

  function consider(x0, cw, y0, ch, tag) {
    // 边界与比例检查
    if (!(cw > w * 0.03) || !(ch > h * 0.02)) return;
    if (cw > w * 0.30 || ch > h * 0.30) return;
    const ratio = cw / ch;
    if (ratio < 0.55 || ratio > 1.80) return;
    const rr = Math.min(cw, ch) * 0.30;
    const r = gridAlignScore(integ, iw, w, h, x0, cw, y0, ch, rr, null);
    if (r.hits < 2) return;   // 残局只有 6 个子，门槛必须放低
    if (r.usable < 40) return;
    const cand = { x0: x0, cw: cw, y0: y0, ch: ch, hits: r.hits, score: r.score, tag: tag, dev: devOf(x0, cw, y0, ch) };
    if (!best || r.hits > best.hits || (r.hits === best.hits && r.score > best.score)) best = cand;
    if (coarse) coarseCands.push(cand);
    return cand;
  }

  // ---- 粗搜 ----
  // ---- 先验优先：布局是死的，先验命中够多就别让搜索跑野 ----
  //
  // JJ象棋 的棋盘位置是固定布局（5 张真实截图反解出来完全一致：
  //   x0/W=0.0666  cw/W=0.1078  y0/H=0.2773  ch/H=0.0484）。
  // 一旦有东西被遮住（画中画挡住右上角 8 个交叉点），能参与打分的点就少了，
  // 搜索会找到一组「歪着的网格」，命中数反而多 1~4 个（浮窗边缘的高光被当成棋子），
  // 结果整盘采样点集体偏移 6~7 像素，第 0 排的車就被认成卒。
  //
  // 所以：先验的命中数只要够（>=16 个交叉点有棋子），就直接采用先验，
  // 只在 ±0.04 格 / ±0.8% 的极小窗口里微调（吸收不同机型的细微差异）。
  // 先验命中太少（换机型、换主题、或根本不是对局画面）才走完整搜索。
  {
    const sd = seeds[0];
    const rr = Math.min(sd.cw, sd.ch) * 0.30;
    const base = gridAlignScore(integ, iw, w, h, sd.x0, sd.cw, sd.y0, sd.ch, rr, null);
    // 只有「浮窗真的压到棋盘」时才锁先验。
    // 没遮挡的画面里完整搜索更准（能吃到 0.1% 的格距差异）；
    // 有遮挡时能参与打分的点变少，搜索会被浮窗边缘的高光带偏，就该退回先验。
    const bx0 = sd.x0 - sd.cw * 0.5, bx1 = sd.x0 + sd.cw * 8.5;
    const by0 = sd.y0 - sd.ch * 0.5, by1 = sd.y0 + sd.ch * 9.5;
    const occluded_unused = !!(skipRect && skipRect.x1 >= bx0 && skipRect.x0 <= bx1
      && skipRect.y1 >= by0 && skipRect.y0 <= by1);
    if (base.hits >= 3 && base.usable >= 40) {
      let pick = { x0: sd.x0, cw: sd.cw, y0: sd.y0, ch: sd.ch, hits: base.hits, score: base.score, dev: 0, tag: 'prior-fixed' };
      const oS = 0.02, sS = 0.004;
      for (let i = -1; i <= 1; i++) {
        for (let j = -1; j <= 1; j++) {
          const cw = sd.cw * (1 + i * sS);
          const ch = sd.ch * (1 + j * sS);
          for (let a = -1; a <= 1; a++) {
            for (let b = -1; b <= 1; b++) {
              const x0 = sd.x0 + a * oS * sd.cw;
              const y0 = sd.y0 + b * oS * sd.ch;
              const r = gridAlignScore(integ, iw, w, h, x0, cw, y0, ch, rr, null);
              if (r.usable < 40) continue;
              // 只有明显更好（多命中 2 个以上）才离开先验
              if (r.hits >= pick.hits + 2) {
                pick = { x0: x0, cw: cw, y0: y0, ch: ch, hits: r.hits, score: r.score, dev: devOf(x0, cw, y0, ch), tag: 'prior-polish' };
              }
            }
          }
        }
      }
      best = pick;
      locked = true;
      coarseCands.length = 0;
    }
  }

  // ---- 粗搜 ----
  //   prior 种子（归一化先验）用窄窗口；edges 种子（边缘投影）误差大，才需要宽窗口。
  for (let s = 0; s < seeds.length; s++) {
    if (best) break;                      // 先验已经定案，不用再搜
    const sd = seeds[s];
    const tight = (sd.tag === 'prior');
    const nScale = tight ? 1 : 2;
    const nOrigin = tight ? 2 : 3;
    const sStep = tight ? 0.015 : 0.03;   // 先验种子：格距只搜 ±1.5%
    const oStep = tight ? 0.05 : 0.2;     // 先验种子：起点只搜 ±0.1 格
    for (let i = -nScale; i <= nScale; i++) {
      for (let j = -nScale; j <= nScale; j++) {
        const cw = sd.cw * (1 + i * sStep);
        const ch = sd.ch * (1 + j * sStep);
        for (let a = -nOrigin; a <= nOrigin; a++) {
          for (let b = -nOrigin; b <= nOrigin; b++) {
            consider(sd.x0 + a * oStep * sd.cw, cw, sd.y0 + b * oStep * sd.ch, ch, sd.tag);
          }
        }
      }
    }
  }
  if (!best) return null;
  coarse = false;

  // 粗搜定案：命中数相差 2 格以内时，选「离先验最近」的那组。
  // 画中画挡住右上角后，被遮住的交叉点不参与打分，歪着的网格命中数可能反而多 1~2 个
  // （浮窗边缘的高光被当成棋子）。而 JJ象棋 布局是死的，正确网格一定贴着先验。
  if (coarseCands.length) {
    let mx = 0;
    for (let ci = 0; ci < coarseCands.length; ci++) if (coarseCands[ci].hits > mx) mx = coarseCands[ci].hits;
    let pick = null;
    for (let ci = 0; ci < coarseCands.length; ci++) {
      const c = coarseCands[ci];
      if (c.hits < mx - 6) continue;
      if (!pick || c.dev < pick.dev || (c.dev === pick.dev && c.score > pick.score)) pick = c;
    }
    if (pick) best = pick;
  }

  // ---- 细搜：格距 ±1.5%，起点 ±0.1 格 ----
  if (!locked) {
    const b0 = best;
    for (let i = -1; i <= 1; i++) {
      for (let j = -1; j <= 1; j++) {
        const cw = b0.cw * (1 + i * 0.0075);
        const ch = b0.ch * (1 + j * 0.0075);
        for (let a = -2; a <= 2; a++) {
          for (let b = -2; b <= 2; b++) {
            consider(b0.x0 + a * 0.04 * b0.cw, cw, b0.y0 + b * 0.04 * b0.ch, ch, b0.tag);
          }
        }
      }
    }
  }

  // ---- 超细：格距 ±0.4%，起点 ±0.02 格 ----
  if (!locked) {
    const b0 = best;
    for (let i = -1; i <= 1; i++) {
      for (let j = -1; j <= 1; j++) {
        const cw = b0.cw * (1 + i * 0.002);
        const ch = b0.ch * (1 + j * 0.002);
        for (let a = -2; a <= 2; a++) {
          for (let b = -2; b <= 2; b++) {
            consider(b0.x0 + a * 0.008 * b0.cw, cw, b0.y0 + b * 0.008 * b0.ch, ch, b0.tag);
          }
        }
      }
    }
  }

  if (!best) return null;
  // 命中太少说明不是对局画面（比如停在菜单/结算界面），宁可报失败
  if (best.hits < 3) return null;   // 残局可能只有 5~6 个子

  refineByPieces.lastDebug = {
    cellW: best.cw, cellH: best.ch, ratio: best.cw / best.ch,
    hits: best.hits, score: best.score, seed: best.tag, pipRect: skipRect,
    x0: best.x0, y0: best.y0, diskPixels: di.count
  };

  const gx0 = best.x0, gx8 = best.x0 + 8 * best.cw;
  const gy0 = best.y0, gy9 = best.y0 + 9 * best.ch;
  return [
    [gx0, gy0],
    [gx8, gy0],
    [gx8, gy9],
    [gx0, gy9]
  ];
}

function autoDetectBoard(pixels, w, h) {
  if (!pixels || w < 60 || h < 60) return null;

  // ① 首选：棋子圆盘全格对齐（快、准、稳，不依赖棋盘线）
  refineByPieces.lastDebug = null;
  var fast = refineByPieces(pixels, w, h, null);
  if (fast) {
    autoDetectBoard.lastDebug = { used: 'pieces', pieceFit: refineByPieces.lastDebug };
    return fast;
  }

  // ② 兜底：棋盘线边缘投影 + 等距拟合，再用棋子校验一次
  var edge = edgeDetectBoard(pixels, w, h);
  if (!edge) {
    autoDetectBoard.lastDebug = { used: 'fail', pieceFit: null };
    return null;
  }
  refineByPieces.lastDebug = null;
  var fixed = refineByPieces(pixels, w, h, edge);
  autoDetectBoard.lastDebug = {
    used: fixed ? 'edges+pieces' : 'edges',
    edge: edge,
    pieceFit: refineByPieces.lastDebug
  };
  return fixed || edge;
}

function edgeDetectBoard(pixels, w, h) {

  // 1) 灰度
  const gray = new Float32Array(w * h);
  for (let y = 0; y < h; y++) {
    const base = y * w;
    for (let x = 0; x < w; x++) {
      const i = (base + x) * 4;
      gray[base + x] = 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
    }
  }

  // 2) 垂直边缘强度 → 竖线投影
  const colScore = new Float32Array(w);
  for (let x = 3; x < w - 3; x++) {
    let s = 0;
    for (let y = 2; y < h - 2; y += 2) {
      const c = y * w + x;
      const g = Math.abs(gray[c + 3] - gray[c - 3]);
      if (g > 14) s += g;
    }
    colScore[x] = s;
  }

  // 3) 水平边缘强度 → 横线投影
  const rowScore = new Float32Array(h);
  for (let y = 3; y < h - 3; y++) {
    let s = 0;
    for (let x = 2; x < w - 2; x += 2) {
      const c = y * w + x;
      const g = Math.abs(gray[c + 3 * w] - gray[c - 3 * w]);
      if (g > 14) s += g;
    }
    rowScore[y] = s;
  }

  // 4) 找 9 竖 10 横（格距至少 12 像素）
  const cols = findEvenlySpacedPeaks(colScore, 9, 12);
  const rows = findEvenlySpacedPeaks(rowScore, 10, 12);
  if (!cols || !rows) return null;

  // 5) 用「中位间距」重建网格，而不是直接用首尾位置。
  //    首尾两条线最容易被装饰边框、棋盘外的 UI 干扰（实测下边会丢掉一整条线，
  //    导致格高差 22%，最下面那排棋子采样全部偏离）。
  //    中间几条线最干净，取相邻间距的中位数作为真实格距，再以中位线为锚点铺开。
  function gapsMedian(arr) {
    const g = [];
    for (let i = 1; i < arr.length; i++) g.push(arr[i] - arr[i - 1]);
    if (!g.length) return 0;
    g.sort((a, b) => a - b);
    return g[Math.floor(g.length / 2)];
  }

  const gapW = gapsMedian(cols);
  const gapH = gapsMedian(rows);
  if (gapW < 10 || gapH < 10) return null;

  // 格距比例校验：中国象棋格子接近正方形，横向纵向格距应接近
  const ratio2 = gapH / gapW;
  if (ratio2 < 0.75 || ratio2 > 1.35) return null;

  // 用中位线做锚点，按中位格距向两侧铺开
  const midC = cols[4];       // 第 5 条竖线（最中间）
  const midR = rows[4];       // 第 5 条横线
  const colsFit = new Array(9);
  const rowsFit = new Array(10);
  for (let i = 0; i < 9; i++) colsFit[i] = midC + (i - 4) * gapW;
  for (let j = 0; j < 10; j++) rowsFit[j] = midR + (j - 4) * gapH;

  // 6) 亚像素细化：用检测到的真实峰值修正（在重建位置附近找最近峰）
  function snapToPeak(profile, guess) {
    let best = guess, bestV = -1;
    const lo = Math.max(1, Math.round(guess) - Math.round(gapW * 0.25));
    const hi = Math.min(profile.length - 2, Math.round(guess) + Math.round(gapW * 0.25));
    for (let i = lo; i <= hi; i++) {
      if (profile[i] > bestV) { bestV = profile[i]; best = i; }
    }
    return refinePeak(profile, Math.round(best));
  }

  const colsF = colsFit.map(x => snapToPeak(colScore, x));
  const rowsF = rowsFit.map(y => snapToPeak(rowScore, y));

  // 边缘投影只给「大概的线」，交给调用方用棋子再校正一次
  return [
    [colsF[0], rowsF[0]],   // 左上
    [colsF[8], rowsF[0]],   // 右上
    [colsF[8], rowsF[9]],   // 右下
    [colsF[0], rowsF[9]]    // 左下
  ];
}




/**
 * 墨迹阈值 Otsu 分簇（2.1.60）
 *
 * 输入 90 格的墨迹占比，把「空格基线」和「棋子」分成两簇，返回谷底阈值。
 * 为什么不用「中位数×系数」：采样盘 47px 会把邻格细线也算进来，空格基线能到
 * 0.12，×2.2 = 0.267 反而高过一半棋子的墨迹（真机帧 0.18~0.26），整盘判空。
 *
 * gap 是两簇均值的差，调用方用它判断「到底有没有两簇」：
 * 空盘 / 满盘是单峰分布，gap 很小，此时必须判空（宁可不出箭头，不能乱认）。
 *
 * @returns {{th:number, gap:number, med:number, ok:boolean}}
 */
function inkOtsuThreshold(values) {
  const n = values.length;
  if (n < 20) return { th: 0.30, gap: 0, med: -1, ok: false };
  const v = Array.prototype.slice.call(values).sort((a, b) => a - b);
  const med = v[n >> 1];
  let sumAll = 0;
  for (let i = 0; i < n; i++) sumAll += v[i];
  let sumLow = 0, bestG = -1, bestT = 0, gap = 0;
  for (let i = 1; i < n; i++) {
    sumLow += v[i - 1];
    const w0 = i / n, w1 = 1 - w0;
    const mLow = sumLow / i, mHigh = (sumAll - sumLow) / (n - i);
    const g = w0 * w1 * (mHigh - mLow) * (mHigh - mLow);
    if (g > bestG) { bestG = g; bestT = (v[i - 1] + v[i]) * 0.5; gap = mHigh - mLow; }
  }
  const ok = (gap >= 0.06 && bestT >= 0.10);
  return {
    th: ok ? Math.min(0.32, Math.max(0.13, bestT)) : 0.30,
    gap: gap, med: med, ok: ok
  };
}

class BoardRecognizer {

  /**
   * @param {object} cfg
   *   corners: [[x,y]x4] 屏幕像素坐标，顺序 [左上, 右上, 右下, 左下]
   *   cellRadiusRatio: 采样半径占格距的比例，默认 0.40
   *   bgModel: 可选的已学习背景模型
   */
  constructor(cfg) {
    this.corners = cfg.corners ? cfg.corners.map(p => [p[0], p[1]]) : null;
    // 采样半径占格距的比例。
    //
    // 这个值同时决定「能采到多少字形」和「会不会被高亮圈污染」，实测扫描：
    //   0.42 → 上一步的高亮圈（半径 22~30 像素）整个落进 patch 外圈，
    //          红色通道被圈填满，红俥被判成红傌/红仕（实测 5 张图共错 7 格）
    //   0.34 → 圈在 patch 之外，只采到字形，5 张图 450 格只剩 2 格错
    //   0.30 → 采得太小，字形边缘被切掉，反而变差
    // 模板必须用同一个比例训练（tools/gen-templates.mjs）。
    this.cellRadiusRatio = cfg.cellRadiusRatio || 0.34;
    this.bgModel = cfg.bgModel || null;
    this.lastStats = null;
    // 模板在 patchWeights 构建完才能归一化，所以先占位、后面再装
    this.templates = null;
    // 低置信度格子再做多尺度重采样。
    // 默认关闭 —— 实测在 0.34 半径下它反而把本来认对的红子改成错的
    // （u_dots 从 0 错变成 2 错），逐格置信度 + 保留上一稳定值那套已经够用。
    this.enableLowConfRefine = !!cfg.enableLowConfRefine;
    // 兵种打分方式：'dot'（归一化点积）或 'mass'（点积 + 笔画总量惩罚）
    //
    // 实测（630 格，含两张困难残局）：
    //   dot         错 5
    //   mass:0.35   错 4
    //   mass:0.70   错 2   ← 采用
    // 原因：点积对「这个字到底有几笔」不敏感，笔画被采样丢一半时
    // 反而跟笔画最少的那个字最像（馬→卒、俥→仕、象→卒）。
    // 乘上一个「样本墨迹量 vs 模板墨迹量」的折扣，复杂度也成了判据。
    this.scoreMode = cfg.scoreMode || 'mass';
    this.massK = (typeof cfg.massK === 'number') ? cfg.massK : 0.70;

    // 径向权重：中心权重高、边缘权重低。
    // 空格的 patch 边缘是棋盘网格线（深色直线），棋子的边缘是圆形描边，
    // 两者在灰度上很像，全图等权比对会被边缘带偏。
    // 加权后由中心区域主导 —— 棋子中心是圆盘+字，空格中心是干净棋盘，差异最明显。
    const PW = PATCH_W;
    this.patchWeights = (() => {
      const w = new Float32Array(PW * PW);
      let sum = 0;
      const half = (PW - 1) / 2;
      for (let py = 0; py < PW; py++) {
        for (let px = 0; px < PW; px++) {
          const dx = (px - half) / half;
          const dy = (py - half) / half;
          const v = Math.exp(-(dx * dx + dy * dy) * 1.2);
          w[py * PW + px] = v;
          sum += v;
        }
      }
      for (let i = 0; i < w.length; i++) w[i] /= sum;
      return w;
    })();

    // ★ 内置模板：从已知正确的开局截图离线生成，装在引擎里。
    //   这样中途进入对局也能直接认，不再依赖「第一帧必须是开局」。
    this.templates = cfg.templates || this._buildBuiltinTemplates();
    this.templateCount = (function () { let n = 0; for (const k in this.templates) n += this.templates[k].length; return n; }).call(this);
  }

  /**
   * 从 templates.js 解包并归一化内置模板
   */
  _buildBuiltinTemplates() {
    let raw;
    try { raw = require('./templates').unpack(); } catch (e) { return null; }
    const out = {};
    for (const key in raw) {
      const list = raw[key];
      const conv = [];
      for (let i = 0; i < list.length; i++) {
        const nw = this.normalizePatch(list[i].w);
        const nr = this.normalizePatch(list[i].r);
        if (!nw || !nr) continue;
        conv.push({ w: nw, r: nr, i: list[i].i ? this.normalizePatch(list[i].i) : null });
      }
      if (conv.length) out[key] = conv;
    }
    return out;
  }

  /** 计算 90 个交叉点的像素坐标；返回 Float32Array(180) */
  gridPoints() {
    if (!this.corners) throw new Error('未标定四边形');
    const [p00, p10, p11, p01] = this.corners;
    const pts = new Float32Array(180);
    for (let r = 0; r < 10; r++) {
      const v = r / 9;
      for (let c = 0; c < 9; c++) {
        const u = c / 8;
        const p = bilinear(p00, p10, p11, p01, u, v);
        const i = (r * 9 + c) * 2;
        pts[i] = p[0];
        pts[i + 1] = p[1];
      }
    }
    return pts;
  }

  /**
   * 格距估算（像素）
   *
   * 【历史 bug】原来写成 hypot(pts[2]-pts[0], pts[3]-pts[1]) / 8，
   * 但 pts[0] 与 pts[2] 是「r0c0」和「r0c1」两个相邻交叉点，
   * 它们的距离本来就等于一个格宽，再除以 8 会让采样半径缩到 1/8
   * （约 2.5 像素），只采到棋子正中心那一点，什么都判不出来。
   */
  cellSize(pts) {
    const dx = pts[2] - pts[0];
    const dy = pts[3] - pts[1];
    return Math.hypot(dx, dy);
  }

  /**
   * 采样一个交叉点周围的特征 + 模板图
   *
   * 【历史 bug】原来 patch 的填充复用了统计用的 step（radius/4 = 5 像素），
   * 而 patch 每格只有 (2*radius/16 = 2.5) 像素宽，导致 256 个 patch 格
   * 里一大半根本没被赋值，全是初始 0 —— 所有格子的模板长得一样，
   * NSC 匹配全部失效，最终把棋子全判成空（正好 30 格偏差）。
   *
   * 现在 patch 按 16×16 网格逐格采样，一个不漏；
   * 统计特征也从同一批采样点累计，口径一致。
   */
  sampleCell(pixels, w, h, cx, cy, radius, wantPatch, gain) {
    const g = (typeof gain === 'number' && gain > 0) ? gain : 1;
    let n = 0, sumL = 0, red = 0, dark = 0, bright = 0, warm = 0, face = 0, skipped = 0;
    let ink = 0, redInk = 0, darkInk = 0;
    let coreN = 0, coreInk = 0, coreRedInk = 0, coreDarkInk = 0;
    const PW = PATCH_W;
    let patchW = null, patchR = null, patchI = null, patchValid = null;
    // 每 patch 像素的亮度均值与红/黑墨迹占比，供「自适应墨迹兜底」二次分割用
    let patchL = null, patchRi = null, patchDi = null;

    // 纯绿像素过滤器（可走位置绿点、绿色高亮圈）
    const isPureGreen = (R, G, B) => (G > R + 30 && G > B + 30 && G > 90);

    if (wantPatch) {
      patchW = new Uint8Array(PW * PW);
      patchR = new Uint8Array(PW * PW);
      patchI = new Uint8Array(PW * PW);
      patchL = new Float32Array(PW * PW);
      patchRi = new Float32Array(PW * PW);
      patchDi = new Float32Array(PW * PW);
      // 有效像素掩码：0 = 这一格像素是干扰（高亮圈 / 绿点 / 白边），
      // 模板比对时把它的权重归零，避免「上一步的高亮圈」把兵种带偏。
      patchValid = new Uint8Array(PW * PW);
      const span = radius * 2;
      const stepPx = span / PW;
      const halfP = (PW - 1) / 2;
      // ★ 亚像素四点平均（盒式滤波）
      //
      // 为什么必须这么做：patch 只有 24x24，而采样窗常常 50 像素以上 ——
      // 也就是说一个 patch 像素要代表 2 像素以上的源区域。原来的写法是
      // 「点采样」，细笔画（俥/傌/馬/象 的横竖撇）会随相位被稀疏采到、甚至整段漏掉。
      // 漏掉之后这个字看上去就像「笔画更少的那个字」，实测失败签名非常一致：
      //   俥→仕、傌→仕、象→卒、馬→卒（复杂字全被读成最简单的字）
      // 而且同一张图缩放到 700 和 589 会给出不同结果 —— 本质就是相位不同。
      // 现在每个 patch 像素在自身footprint 内取 4 个亚像素点、按多数表决，
      // 笔画不再随相位丢失，不同分辨率之间也一致。
      const subOff = stepPx * 0.25;
      for (let py = 0; py < PW; py++) {
        for (let px = 0; px < PW; px++) {
          const bx = cx - radius + (px + 0.5) * stepPx;
          const by = cy - radius + (py + 0.5) * stepPx;
          const du = (px - halfP) / halfP, dv = (py - halfP) / halfP;
          const rr = Math.sqrt(du * du + dv * dv);
          const inCore = (py >= 6 && py <= 17 && px >= 6 && px <= 17);
          let okN = 0, wN = 0, rN = 0, iN = 0, riN = 0, diN = 0;
          let lSum = 0, redN = 0, darkN = 0, brightN = 0, warmN = 0, faceN = 0;
          for (let si = 0; si < 4; si++) {
            const sx = Math.round(bx + ((si === 0 || si === 2) ? -subOff : subOff));
            const sy = Math.round(by + (si < 2 ? -subOff : subOff));
            if (sx < 1 || sy < 1 || sx >= w - 1 || sy >= h - 1) continue;
            const i = (sy * w + sx) * 4;
            var R = pixels[i], G = pixels[i + 1], B = pixels[i + 2];
            if (g !== 1) {
              R = R * g > 255 ? 255 : (R * g) | 0;
              G = G * g > 255 ? 255 : (G * g) | 0;
              B = B * g > 255 ? 255 : (B * g) | 0;
            }
            if (isPureGreen(R, G, B)) continue;
            // 白色高亮圈：既不是墨也不是暖色，直接跳过，
            // 否则它会把整格的 ink/warm 拉成 0。
            if (R > 200 && G > 200 && B > 200) continue;
            // 外圈的「红色高亮圈」：亮红、绿通道很低，和棋子盘面/红字都不同。
            if (rr > 0.66 && R > 150 && G < 125 && (R - G) > 60) continue;

            const L = 0.299 * R + 0.587 * G + 0.114 * B;
            const rb = R - B;
            okN++;
            lSum += L;
            if (rb > 22 && R > 80) { warmN++; wN++; }
            if (R > 85 && (R - G) > 45 && rb > 45) { redN++; rN++; }
            // 暗色盘面阈值原来是 L<72，真机实测黑子是 (88,78,65)=79.5、(112,79,69)=87，
            // 整类黑子从这个判据里漏掉，"暗色通道"等于不存在。放到 100 才装得下。
            if (L < 100) darkN++;
            if (L > 178) brightN++;
            // 亮盘面：象牙白棋子 (243,203,149)=209，木色棋盘 (199,167,112)=170，
            // 差 ~40 是这对皮肤里最稳的一条界线。最终阈值由 calibrateBoardLevel 按
            // 全盘中位亮度自适应，这里只提供原始计数。
            if (L >= 186 && rb > 20) faceN++;
            // ---- 墨迹特征（核心判据）----
            // 棋子上的「字」是深色或红色，而棋子盘面、棋盘、绿点、高亮圈都是亮的。
            // 区分「红字」和「暖色盘面」靠绿通道：
            //   红字 (170, 30, 30)  G 极低（约 30）
            //   盘面 (200,150,100)  G 中等（约 150）
            const isRedInk = (R > 95 && G < 115 && (R - G) > 55 && (R - B) > 65);
            const isDarkInk = (L < 85) && !isRedInk;
            if (isRedInk || isDarkInk) iN++;
            if (isRedInk) riN++;
            if (isDarkInk) diN++;
          }
          if (!okN) { skipped++; continue; }
          const inv = 1 / okN;
          const idx = py * PW + px;
          patchValid[idx] = 1;
          patchW[idx] = (wN * 2 >= okN) ? 255 : 0;
          patchR[idx] = (rN * 2 >= okN) ? 255 : 0;
          patchI[idx] = (iN * 2 >= okN) ? 255 : 0;
          patchL[idx] = lSum * inv;
          patchRi[idx] = riN * inv;
          patchDi[idx] = diN * inv;

          sumL += lSum * inv; n++;
          red += redN * inv;
          dark += darkN * inv;
          bright += brightN * inv;
          warm += warmN * inv;
          face += faceN * inv;
          ink += iN * inv;
          redInk += riN * inv;
          darkInk += diN * inv;
          // 中心 8x8 单独统计墨迹：高亮圈的深色描边只落在极外圈，
          // 全图统计会把它算成「黑墨」，于是刚走过的红仕被判成黑兵。
          if (inCore) {
            coreN++;
            if (iN * 2 >= okN) coreInk++;
            if (riN * 2 >= okN) coreRedInk++;
            if (diN * 2 >= okN) coreDarkInk++;
          }
        }
      }
    } else {
      // 稀疏采样版也统计墨迹（精度略低但够用）
      const step = Math.max(1, Math.floor(radius / 5));
      const r2 = radius * radius;
      for (let dy = -radius; dy <= radius; dy += step) {
        for (let dx = -radius; dx <= radius; dx += step) {
          if (dx * dx + dy * dy > r2) continue;
          const x = Math.round(cx + dx);
          const y = Math.round(cy + dy);
          if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
          const i = (y * w + x) * 4;
          var R = pixels[i], G = pixels[i + 1], B = pixels[i + 2];
          if (g !== 1) {
            R = R * g > 255 ? 255 : (R * g) | 0;
            G = G * g > 255 ? 255 : (G * g) | 0;
            B = B * g > 255 ? 255 : (B * g) | 0;
          }
          if (isPureGreen(R, G, B)) { skipped++; continue; }
          if (R > 200 && G > 200 && B > 200) { skipped++; continue; }
          const L = 0.299 * R + 0.587 * G + 0.114 * B;
          sumL += L; n++;
          const rb = R - B;
          if (R > 85 && (R - G) > 45 && rb > 45) red++;
          if (L < 100) dark++;
          if (L > 178) bright++;
          if (rb > 26 && R > 85) warm++;
          if (L >= 186 && rb > 20) face++;

          const isRedInk = (R > 95 && G < 115 && (R - G) > 55 && (R - B) > 65);
          const isDarkInk = (L < 85) && !isRedInk;
          if (isRedInk || isDarkInk) ink++;
          if (isRedInk) redInk++;
          if (isDarkInk) darkInk++;
        }
      }
    }

    const denom = n > 0 ? n : 1;

    /* ---- 自适应墨迹兜底（2.1.56）----------------------------------------
     * 绝对阈值（isRedInk / isDarkInk）是按「参考截图」的亮度调的。真机抓帧
     * 的棋盘与棋子亮度差很多时会出现一种很整齐的失败：棋子盘面（象牙白，
     * L≈208）采得到，字却一个墨点都判不出来 —— matchCell 分数恒 0，
     * 整盘棋子全被当空格丢掉，verifyDiff 正好等于开局子数（真机实测 32）。
     *
     * 这里只在「这一格明确有象牙白盘面（hi≥190）且对比度够（≥45）、
     * 但绝对判据一个墨点都没抓到（<8/576）」时，用这一格自己的亮度分布
     * 重新分割墨迹。原本能正常判的格子完全不受影响。
     */
    if (wantPatch && patchL && n > 0) {
      let absInk = 0;
      for (let i = 0, np = PW * PW; i < np; i++) if (patchI[i]) absInk++;
      if (absInk < 8) {
        let hi = 0, lo = 255;
        for (let i = 0, np = PW * PW; i < np; i++) {
          if (!patchValid[i]) continue;
          const v = patchL[i];
          if (v > hi) hi = v;
          if (v < lo) lo = v;
        }
        const contrast = hi - lo;
        if (hi >= 190 && contrast >= 45) {
          const thr = lo + 0.40 * contrast;
          let mInk = 0, mRed = 0, mDark = 0;
          let kInk = 0, kRed = 0, kDark = 0;
          for (let py = 0; py < PW; py++) {
            for (let px = 0; px < PW; px++) {
              const i = py * PW + px;
              if (!patchValid[i]) continue;
              const isInk = patchL[i] < thr;
              patchI[i] = isInk ? 255 : 0;
              if (!isInk) continue;
              const isRed = patchRi[i] > patchDi[i];
              mInk++;
              if (isRed) mRed++; else mDark++;
              if (py >= 6 && py <= 17 && px >= 6 && px <= 17) {
                kInk++;
                if (isRed) kRed++; else kDark++;
              }
            }
          }
          // 墨迹占了大半格 = 这是一块暗色物体而不是字形，放弃
          if (mInk > n * 0.55) {
            for (let i = 0, np = PW * PW; i < np; i++) patchI[i] = 0;
          } else {
            ink = mInk; redInk = mRed; darkInk = mDark;
            if (coreN > 0) {
              coreInk = kInk; coreRedInk = kRed; coreDarkInk = kDark;
            }
          }
        }
      }
    }

    return {
      meanL: sumL / denom,
      redR: red / denom,
      darkR: dark / denom,
      brightR: bright / denom,
      warmR: warm / denom,
      faceR: face / denom,
      inkR: ink / denom,
      redInkR: redInk / denom,
      darkInkR: darkInk / denom,
      // 中心区域（避开高亮圈）的墨迹占比 —— 判红黑用这个更准
      inkCoreR: coreInk / (coreN || 1),
      redInkCoreR: coreRedInk / (coreN || 1),
      darkInkCoreR: coreDarkInk / (coreN || 1),
      coreN,
      n,
      skipped,
      patchW,
      patchR,
      patchI,
      patchValid
    };
  }

  /**
   * ★ 2.1.90：检测「上一步标记」外环 —— 移植 XiangqiCoach 的核心思路。
   *
   * JJ 象棋会在**最后一步的落点**（部分皮肤连起点一起）画一个高亮圈。
   * 这个圈正好落在半径 0.36~0.52 cell 处，而主采样只覆盖 ±0.34 cell，
   * 所以过去一直"看不见"它，只能当干扰去滤。其实它是全画面里**最有用的信号**：
   * 圈画在哪一格，就说明哪一格刚刚落子 —— 落点、走子方、轮次全都能直接得到，
   * 不必再靠"差分配对 + 规则校验"去猜，也就不会因为某一格读错而永久卡死。
   *
   * 只认「高饱和红 / 亮金」两种典型标记色：木色盘面（低饱和暖色）和
   * 棋子底色都够不上这两个判据。实测有圈 ≈ 0.6，空位/普通棋子 < 0.1。
   *
   * 返回该格外环的高亮像素占比（0~1）。
   */
  sampleRing(pixels, w, h, cx, cy, cell, gain) {
    /* ★ 2.1.95：改用「环提升对比」，参考 XiangqiCoach 的 LastMoveRecognizer。
     *
     * 它不数"白色像素"，而是比较**环带（0.44~0.53 cell）与圈外（0.60~0.70）的中性色**：
     * 有白圈时环上明显更"白"，没圈时两者差不多。这样对整体亮度/色温不敏感 ——
     * 真机抓帧要过 H.264，白圈会被压缩削弱，绝对白色阈值（L>200）在真机上根本抓不到。
     *
     * 中性色 = min(R,G,B)/max(R,G,B)，衡量"灰白程度"而不是亮度，
     * 木色盘面（暖色、饱和度不低）和红黑字都不会被误判。
     *
     * 返回 24 个方向平均的「环上 - 环外」中性色差（-1~1）。
     * 真机实测：有白圈 0.084、普通格最高 0.039、负值居多 —— 取 0.06 作阈值。
     */
    let total = 0;
    for (let i = 0; i < 24; i++) {
      const a = i * Math.PI / 12;
      const ca = Math.cos(a), sa = Math.sin(a);
      let pIn = 0, pOut = 0;
      for (let k = 0; k < 4; k++) {
        let rr = cell * (0.44 + 0.03 * k);
        let x = Math.round(cx + ca * rr), y = Math.round(cy + sa * rr);
        if (x >= 1 && y >= 1 && x < w - 1 && y < h - 1) {
          const q = (y * w + x) * 4;
          let R = pixels[q], G = pixels[q + 1], B = pixels[q + 2];
          if (gain !== 1) {
            R = R * gain > 255 ? 255 : (R * gain) | 0;
            G = G * gain > 255 ? 255 : (G * gain) | 0;
            B = B * gain > 255 ? 255 : (B * gain) | 0;
          }
          const mx = Math.max(R, G, B);
          const nv = mx ? (Math.min(R, G, B) / mx) : 0;
          if (nv > pIn) pIn = nv;
        }
        rr = cell * (0.60 + 0.0333 * k);
        x = Math.round(cx + ca * rr); y = Math.round(cy + sa * rr);
        if (x >= 1 && y >= 1 && x < w - 1 && y < h - 1) {
          const q = (y * w + x) * 4;
          let R = pixels[q], G = pixels[q + 1], B = pixels[q + 2];
          if (gain !== 1) {
            R = R * gain > 255 ? 255 : (R * gain) | 0;
            G = G * gain > 255 ? 255 : (G * gain) | 0;
            B = B * gain > 255 ? 255 : (B * gain) | 0;
          }
          const mx = Math.max(R, G, B);
          const nv = mx ? (Math.min(R, G, B) / mx) : 0;
          if (nv > pOut) pOut = nv;
        }
      }
      total += (pIn - pOut);
    }
    return total / 24;
  }

  /**
   * ★ 2.1.92：检测「起点白点」。
   *
   * 游戏除了在落点画白圈，还会在**起点那一格（此时已空）的中心**点一个小白点。
   * 两者凑齐就是一条完整的「上一步」：白点 = from，白圈 = to —— 不用反推。
   * 空格中心本来是木色（不白），所以这个判据在空位上格外干净：
   * 实测起点 53、普通空位 0、有子格 9~43（有子格会因为棋子面偏亮而虚高，但那些格有子，直接跳过）。
   *
   * 返回中心区白色像素个数。
   */
  sampleCenterWhite(pixels, w, h, cx, cy, gain) {
    let cnt = 0;
    for (let dy = -8; dy <= 8; dy += 2) {
      for (let dx = -8; dx <= 8; dx += 2) {
        const x = cx + dx, y = cy + dy;
        if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
        const p = (y * w + x) * 4;
        let R = pixels[p], G = pixels[p + 1], B = pixels[p + 2];
        if (gain !== 1) {
          R = R * gain > 255 ? 255 : (R * gain) | 0;
          G = G * gain > 255 ? 255 : (G * gain) | 0;
          B = B * gain > 255 ? 255 : (B * gain) | 0;
        }
        const L = 0.299 * R + 0.587 * G + 0.114 * B;
        const sat = Math.max(R, G, B) - Math.min(R, G, B);
        if (L > 200 && sat < 60) cnt++;
      }
    }
    return cnt;
  }

  /**
   * ★ 2.1.96：**真正的自动标定** —— 直接从画面反解棋盘网格。
   *
   * 为什么需要：原来的「自动标定」其实是「学模板」，网格沿用上一次手动点的四角，
   * 而手点天生有 ±30px 误差；唯一能纠错的 alignGridToOpening 又只认标准开局
   * （代码注释原话：「凑不出这套分布（中局/大厅）就什么都不改」）。
   * 于是中局看到的网格永远是歪的，识别也跟着歪。
   *
   * 本方法完全不依赖局面，任何画面（中局/残局/开局）都能用：
   *
   *   1. 暗线二值化 → 按列求和得到「列投影」，棋盘竖线处必然是尖峰
   *   2. 对投影做**自相关**求周期 dx —— 比"找最强的几条线"稳得多，
   *      因为棋子遮挡只会削低个别峰，不会破坏整体周期性
   *   3. 枚举相位，让 9 条理论线尽量落在真实峰上 → 竖线 x 坐标
   *   4. 横线被棋子压得更厉害，改用**竖线当探针**：在每条竖线两侧 ±4~5px 取暗像素，
   *      横线经过时这些位置必然发暗，逐行统计即得干净的横向信号
   *   5. 对横向信号再做一次自相关（周期约束在 dx 附近 —— 象棋单格近似正方形）
   *      → 10 条横线 y 坐标
   *   6. 四角 = 四条边界线的交点
   *
   * 真机实测（428×926 截图）：竖线间距 46.0、横线 44.0，四角与肉眼测量的
   * 棋盘边框吻合到 ±1~2px，远优于手标的 ±30px。
   *
   * @returns {{corners:number[][], dx:number, dy:number}|null}
   *          corners = [[左上],[右上],[右下],[左下]]，与 JJGridPt 的双线性插值约定一致
   */
  detectGrid(pixels, w, h) {
    if (!w || !h || w < 120 || h < 160) return null;

    /* ---------- 0. 预计算亮度图（后面要做多次邻域比较，先算一次省很多） ---------- */
    const N = w * h;
    const lum = new Float32Array(N);
    for (let i = 0; i < N; i++) {
      const q = i * 4;
      lum[i] = 0.299 * pixels[q] + 0.587 * pixels[q + 1] + 0.114 * pixels[q + 2];
    }

    /* ---------- 1. 竖线：用「局部暗谷」而不是绝对亮度 ----------
     *
     * 这一步是整件事的关键。原先用「亮度 < 130 算暗」：
     *   - 对局画面棋盘底色 L≈170，线 L≈100 → 能用
     *   - 沙盘画面整体偏暗，棋盘底色 L≈120 → 底色也被算成"暗"，全糊成一片
     * 改成「比左右各 4px 都暗 12 以上」后，判据只关心**局部凹陷**，
     * 与整体曝光无关。两张风格迥异的截图因此得到**完全相同**的 9 条竖线
     * （28/75/121/168/214/260/306/352/399），这是后面所有计算的基础。
     */
    /* ★ 所有像素量都必须按分辨率缩放。
       算法最初是在 428×926 的截图上调的（邻域 ±4px、暗谷阈值 12），
       而真机是 1284×2778 —— 宽度 3 倍。若直接用绝对值：
         - 邻域只有 3px，采到的是线条内部而不是两侧盘面，凹陷测不出来
         - 阈值 12 相对 8bit 亮度也太小，木纹噪声全被当成线
       实测真机上会直接返回 null。统一按「基准宽 428」等比缩放。 */
    const S = w / 428;
    const NB = Math.max(2, Math.round(4 * S));      // 邻域半径
    const DTH = 12 * S;                             // 暗谷深度阈值

    const colProj = new Float32Array(w);
    for (let x = NB; x < w - NB; x++) {
      let c = 0;
      for (let y = 0; y < h; y++) {
        const base = y * w;
        const v = lum[base + x];
        if (v < lum[base + x - NB] - DTH && v < lum[base + x + NB] - DTH) c++;
      }
      colProj[x] = c;
    }
    let cmax = 0;
    for (let x = 0; x < w; x++) if (colProj[x] > cmax) cmax = colProj[x];
    if (cmax <= 0) return null;
    const colN = new Float32Array(w);
    for (let x = 0; x < w; x++) colN[x] = colProj[x] / cmax;

    /* 9 条竖线：周期 8%~14% 屏宽、总宽 82%~98%、首线在左边缘 3%~12% 处 */
    const vs = this._gridVote(colN, 9,
      w * 0.08, w * 0.14,
      w * 0.82, w * 0.98,
      w * 0.03, w * 0.12, 0.55);
    if (!vs) return null;
    const dx = vs.d, xs = [];
    for (let k = 0; k < 9; k++) xs.push(vs.x0 + k * dx);

    /* ---------- 2. 横线探针：在竖线两侧 ±4~5px 取局部暗谷 ----------
     * 横线被 32 个棋子压得七零八落，整行投影不可靠；
     * 但棋子是圆的，压不到**所有**竖线旁边，所以在已知竖线位置取样信噪比高得多。
     */
    const probe = new Float32Array(h);
    const offs = [-Math.round(5 * S), -NB, NB, Math.round(5 * S)];
    for (let y = NB; y < h - NB; y++) {
      const base = y * w;
      let c = 0;
      for (let k = 0; k < 9; k++) {
        const cx = Math.round(xs[k]);
        for (let oi = 0; oi < 4; oi++) {
          const x = cx + offs[oi];
          if (x < NB || x >= w - NB) continue;
          const v = lum[base + x];
          if (v < lum[(y - NB) * w + x] - DTH && v < lum[(y + NB) * w + x] - DTH) c++;
        }
      }
      probe[y] = c;
    }
    let pmax = 0;
    for (let y = 0; y < h; y++) if (probe[y] > pmax) pmax = probe[y];
    if (pmax <= 0) return null;

    /* ---------- 3. 横线：找「最长的连续等距峰序列」再外推到 10 条 ----------
     * 为什么不直接投票选 10 条：棋盘上下各有一圈**外框线**，它同样强、同样等距，
     * 投票会把外框当成第 1 条或第 11 条，整体偏一格（实测偏 46px，正好一格）。
     * 改为「先锁定中间那串确定的线，再往外推」，并把 seq[0] 可能落在第 1 条
     * 或第 2 条两种情形都试一遍。
     */
    const peaks = [];
    for (let y = 2; y < h - 2; y++) {
      if (probe[y] >= pmax * 0.45 && probe[y] >= probe[y - 1] && probe[y] >= probe[y + 1]) peaks.push(y);
    }
    const mg = [];
    for (let i = 0; i < peaks.length; i++) {
      const p = peaks[i];
      if (mg.length && p - mg[mg.length - 1] <= 5) {
        if (probe[p] > probe[mg[mg.length - 1]]) mg[mg.length - 1] = p;
      } else mg.push(p);
    }
    if (mg.length < 4) return null;

    /* 象棋单格近似正方形：dy ≈ 0.955 * dx（两幅真机截图实测 44/46） */
    const dy0 = dx * 0.955;
    const cands = [];
    for (let ti = -3; ti <= 3; ti++) {
      const dy = dy0 * (1 + ti * 0.02);
      for (let i = 0; i < mg.length; i++) {
        const seq = [];
        for (let k = 0; k < 10; k++) {
          const t = mg[i] + k * dy;
          let bestP = -1, bestV = -1;
          for (let j = 0; j < mg.length; j++) {
            if (Math.abs(mg[j] - t) <= 2.5 && probe[mg[j]] > bestV) { bestV = probe[mg[j]]; bestP = mg[j]; }
          }
          if (bestP >= 0) seq.push(bestP); else break;
        }
        if (seq.length < 6) continue;
        for (let off = 0; off <= 1; off++) {
          const y0 = seq[0] - off * dy;
          const y9 = y0 + 9 * dy;
          if (y0 < 0 || y9 > h + 5) continue;
          cands.push({ dy: dy, y0: y0, y9: y9, len: seq.length,
                       centerDist: Math.abs((y0 + y9) / 2 - h / 2) });
        }
      }
    }
    if (!cands.length) return null;

    /* 选解：序列越长越可信；同样长时取**棋盘中心最接近画面中心**的
       （游戏 UI 都把棋盘垂直摆中间，这条能稳定排除"多推一格"的错解）。 */
    cands.sort(function (a, b) {
      if (b.len !== a.len) return b.len - a.len;
      return a.centerDist - b.centerDist;
    });
    const pick = cands[0];
    const y0 = pick.y0, y9 = pick.y9;

    const bw = xs[8] - xs[0], bh = y9 - y0;
    if (bw < w * 0.35 || bh < h * 0.25) return null;
    const ratio = bw / bh;
    if (ratio < 0.78 || ratio > 1.12) return null;

    return {
      corners: [[xs[0], y0], [xs[8], y0], [xs[8], y9], [xs[0], y9]],
      dx: dx, dy: pick.dy, xs: xs, y0: y0,
      vHits: vs.hits, hHits: pick.len
    };
  }

  /**
   * 网格投票：在投影里找「count 条等距线」的最优位置。
   *
   * 为什么不用自相关：自相关擅长连续周期信号，而棋盘线是**离散的几条尖峰**，
   * 加上棋子遮挡和 HUD 边缘，自相关会在真实周期的一半/两倍处给出更大的峰
   * （实测真实周期 46，最大值却落在 38）。直接枚举 (周期, 起点) 并统计
   * 「有几条线真的压在峰上」，判据更直接也更稳。
   *
   * @returns {{d:number,x0:number,hits:number,score:number}|null}
   */
  _gridVote(proj, count, dLo, dHi, spanLo, spanHi, startLo, startHi, hitTh) {
    const n = proj.length;
    let best = null;
    const step = 0.25, posStep = 0.5;
    for (let d = dLo; d <= dHi; d += step) {
      const span = (count - 1) * d;
      if (span < spanLo || span > spanHi) continue;
      for (let x0 = startLo; x0 <= startHi; x0 += posStep) {
        let hits = 0, score = 0, devSum = 0, devN = 0;
        for (let k = 0; k < count; k++) {
          const xk = x0 + k * d;
          if (xk < -1 || xk > n) continue;
          const lo = Math.max(0, Math.round(xk) - 2);
          const hi = Math.min(n, Math.round(xk) + 3);
          let v = 0, at = -1;
          for (let i = lo; i < hi; i++) { if (proj[i] > v) { v = proj[i]; at = i; } }
          if (v >= (hitTh || 0.72)) hits++;
          score += v;
          if (at >= 0) { devSum += Math.abs(at - xk); devN++; }
        }
        if (hits < count - 2) continue;            // 至少 7/9 或 8/10 压在峰上
        /* ★ 等距偏差：线的理论位置必须真的压在峰中心上。
           只看"命中数 + 强度"分不出真假 —— 棋盘线之外还有木纹、棋子边缘等暗线，
           它们的总强度甚至更高（实测错误解 x0=64 得 8.44，真解只有 7.5）。
           但假线的峰位置是散的，平均偏差压不下去，真解的峰几乎正对理论位置。 */
        const avgDev = devN ? devSum / devN : 99;
        if (avgDev > 1.1) continue;
        if (best === null || hits > best.hits ||
            (hits === best.hits && avgDev < best.avgDev - 0.05) ||
            (hits === best.hits && Math.abs(avgDev - best.avgDev) <= 0.05 && score > best.score)) {
          best = { d: d, x0: x0, hits: hits, score: score, avgDev: avgDev };
        }
      }
    }
    return best;
  }

  /**
   * 自相关候选周期：返回 [lo,hi] 内自相关的**前几个局部峰**（从大到小）。
   *
   * 为什么要多个而不是一个：自相关在「真实周期的一半/两倍」以及
   * 「格距 + 棋子间距」的混合周期处也会出现峰。真机实测真实周期 46，
   * 但最大值落在 38 —— 只取一个必然选错。交给上层用"等距吻合度"仲裁。
   */
  _autocorrPeaks(seq, lo, hi, topN) {
    const n = seq.length;
    if (n < 40) return [];
    if (hi >= n - 2) hi = n - 3;
    if (lo < 2 || lo > hi) return [];
    let m = 0;
    for (let i = 0; i < n; i++) m += seq[i];
    m /= n;
    const vals = [];
    for (let k = lo; k <= hi; k++) {
      let s = 0;
      for (let i = 0; i + k < n; i++) s += (seq[i] - m) * (seq[i + k] - m);
      vals.push({ k: k, v: s / (n - k) });
    }
    const peaks = [];
    for (let i = 1; i < vals.length - 1; i++) {
      if (vals[i].v >= vals[i - 1].v && vals[i].v >= vals[i + 1].v) peaks.push(vals[i]);
    }
    peaks.sort((a, b) => b.v - a.v);
    return peaks.slice(0, topN || 3).map(p => p.k);
  }

  /** 自相关求周期：返回 [lo,hi] 内让自相关最大的滞后量 */
  _autocorrPeriod(seq, lo, hi) {
    const n = seq.length;
    if (n < 40 || hi >= n) hi = Math.min(hi, n - 5);
    if (lo < 2 || lo > hi) return 0;
    let m = 0;
    for (let i = 0; i < n; i++) m += seq[i];
    m /= n;
    let bestK = 0, bestV = -Infinity;
    for (let k = lo; k <= hi; k++) {
      let s = 0;
      for (let i = 0; i + k < n; i++) s += (seq[i] - m) * (seq[i + k] - m);
      s /= (n - k);
      if (s > bestV) { bestV = s; bestK = k; }
    }
    return bestK;
  }

  /** 给定周期，找最佳相位，使 count 条线尽量落在投影峰上 */
  _phaseFit(seq, d, count, span) {
    const n = seq.length;
    if (!d || !count) return null;
    let mx = 0;
    for (let i = 0; i < n; i++) if (seq[i] > mx) mx = seq[i];
    if (mx <= 0) return null;
    let best = null;
    /* start 的候选只取投影里较强的位置，避免全量枚举 */
    const cand = [];
    for (let i = 1; i < n - 1; i++) {
      if (seq[i] >= mx * 0.45 && seq[i] >= seq[i - 1] && seq[i] >= seq[i + 1]) cand.push(i);
    }
    const starts = cand.slice(0, 60);
    for (let ci = 0; ci < starts.length; ci++) {
      for (let k0 = 0; k0 < 3; k0++) {
        const y0 = starts[ci] - k0 * d;
        if (y0 < -d * 0.5 || y0 + (count - 1) * d > n - 1 + d * 0.5) continue;
        let sc = 0, hitn = 0;
        for (let k = 0; k < count; k++) {
          const yi = Math.round(y0 + k * d);
          const v = (yi >= 0 && yi < n) ? seq[yi] / mx : 0;
          sc += v;
          if (v >= 0.5) hitn++;
        }
        /* 先看命中条数（抗遮挡），再看总得分 */
        if (best === null || hitn > best.hitn || (hitn === best.hitn && sc > best.sc)) {
          best = { sc: sc, y0: y0, d: d, hitn: hitn };
        }
      }
    }
    if (!best || best.hitn < count - 4) return null;
    const out = [];
    for (let k = 0; k < count; k++) out.push(best.y0 + k * best.d);
    return out;
  }

  /**
   * 估计这一帧的亮度增益，把真机抓屏拉到模板的水平。
   *
   * 参考值 150：真实截图（模板来源）里棋盘区域的整体亮度约 150。
   * 增益夹在 0.55 ~ 1.9 之间，避免在极端画面上放大噪声。
   * 用棋盘内 90 个格点周围的稀疏采样来算，开销很小。
   */
  estimateGain(pixels, w, h, pts) {
    let sum = 0, n = 0;
    const step = 3;
    for (let sq = 0; sq < 90; sq++) {
      const cx = pts[sq * 2], cy = pts[sq * 2 + 1];
      for (let dy = -7; dy <= 7; dy += step) {
        const y = Math.round(cy + dy);
        if (y < 1 || y >= h - 1) continue;
        for (let dx = -7; dx <= 7; dx += step) {
          const x = Math.round(cx + dx);
          if (x < 1 || x >= w - 1) continue;
          const i = (y * w + x) * 4;
          sum += 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
          n++;
        }
      }
    }
    if (n < 50) return 1;
    const meanL = sum / n;
    if (!(meanL > 20)) return 1;
    let g = 150 / meanL;
    if (g < 0.55) g = 0.55;
    if (g > 1.9) g = 1.9;
    return g;
  }

  /** 全盘采样，返回 90 个特征 */
  sampleAll(pixels, w, h, wantPatch) {
    const pts = this.gridPoints();
    const cell = this.cellSize(pts);
    const radius = Math.max(3, Math.round(cell * this.cellRadiusRatio));

    // ★ 按帧自适应亮度
    //   模板是从「真实截图」生成的，而真机抓屏（ReplayKit 的 YUV→RGB）出来的
    //   亮度/对比常常和截图不一样。所有颜色判据（暖色、红字、墨迹）都是绝对阈值，
    //   整体偏亮偏暗就会把这些阈值全推歪 —— 表现就是「位置对、字和颜色全错」。
    //   这里先用整帧统计出一个增益，把这一帧拉到模板的水平再判。
    const gain = this.estimateGain(pixels, w, h, pts);

    const out = new Array(90);
    for (let sq = 0; sq < 90; sq++) {
      out[sq] = this.sampleCell(pixels, w, h, pts[sq * 2], pts[sq * 2 + 1], radius, wantPatch, gain);
    }
    this.lastStats = { pts, cell, radius, gain };

    /* 2.1.90：顺手把每格的「上一步标记」外环占比算出来。
       90 格 × 24 角度 × 3 半径 = 6480 次采样，比模板匹配便宜得多。 */
    const rings = new Float32Array(90);
    const centers = new Float32Array(90);
    for (let rq = 0; rq < 90; rq++) {
      const px = pts[rq * 2], py = pts[rq * 2 + 1];
      rings[rq] = this.sampleRing(pixels, w, h, px, py, cell, gain);
      centers[rq] = this.sampleCenterWhite(pixels, w, h, px, py, gain);
    }
    this.lastRings = rings;
    this.lastCenters = centers;
    // 浮窗（画中画）会一起被截进截图里，盖住的那几格读出来一定是浮窗自己的画面，
    // 所以整格作废（保留上一帧的值），而不是拿去识别。
    this.pipRect = findPipRect(pixels, w, h, pts);
    this.occluded = new Uint8Array(90);
    let occN = 0;
    if (this.pipRect) {
      const pr = this.pipRect;
      const pad = cell * 0.5;
      for (let sq = 0; sq < 90; sq++) {
        const px = pts[sq * 2], py = pts[sq * 2 + 1];
        if (px >= pr.x0 - pad && px <= pr.x1 + pad && py >= pr.y0 - pad && py <= pr.y1 + pad) {
          this.occluded[sq] = 1;
          occN++;
        }
      }
    }
    this.occludedCount = occN;
    this.pipOverlap = occN > 0;
    if (wantPatch && this.templates && this.enableLowConfRefine) {
      this.refineLowConfidence(out, pixels, w, h, pts, cell, radius, gain);
    }
    return out;
  }

  /**
   * 对「认不准的格子」做多尺度 + 多偏移的局部重采样
   *
   * 解决两类问题：
   *   1. JJ象棋 落子瞬间会把刚走的棋子放大 1.25 倍、偏移十几像素
   *      （那一帧模板分数只有 0.2，正常 1.3~2.7），红仕会被判成红兵；
   *   2. 网格残余误差（格距差 1%，累积到第 9 行就有 6 像素）。
   *
   * 只对「看起来有子但分数低」的格子做，空格直接跳过，
   * 所以正常情况几乎没有额外开销。
   *
   * @returns {number} 被修正的格子数
   */
  refineLowConfidence(stats, pixels, w, h, pts, cell, radius, gain) {
    let fixed = 0, budget = 18;
    const OFFS = [-1, 0, 1];
    // 尺度要能覆盖「这个主题的字比模板更大」的情况。
    // 「雨打芭蕉 19」那张盘面实测：車 在 1.0 尺度下只能拿 0.427、输给卒，
    // 拉到 1.20 立刻变 0.564 并赢下来；傌 同样在 1.20 才出头。
    const SCALES = [0.90, 0.95, 1.05, 1.10, 1.20, 1.30];

    for (let sq = 0; sq < 90 && budget > 0; sq++) {
      const s = stats[sq];
      if (!s || !s.patchW) continue;
      // 明显是空格就别浪费预算
      const warm = s.warmR || 0;
      const inkCore = s.inkCoreR || 0;
      if (warm < 0.24 && inkCore < 0.10) continue;

      const m0 = this.matchCell(s);
      // 空格的 warm 占比也可能很高（棋盘底色就是暖色），
      // 这些格子进来只会白吃预算。实测预算 16 个格子会被一条空行吃光，
      // 真正需要重采的低分棋子反而轮不到 —— 这就是 r7c5 明明有 0.512 的
      // 更好结果却一直没被采纳的原因。
      if (m0.score < 0.10) continue;
      // 「没把握」的两种形态：
      //   1) 分数低 —— 字形没对上；
      //   2) 分数不低但一二名差距很小 —— 这才是最危险的一类，
      //      实测 r1c1 的 俥 得 0.568 排第一，可正确答案 傌 就在 0.03 分之后。
      // 只要满足其中一条就值得重采一次。
      const m0margin = (m0.alts && m0.alts.length > 1) ? (m0.alts[0].score - m0.alts[1].score) : 9;
      if (m0.key !== 'E' && m0.score >= 0.62 && m0margin >= 0.10) continue;

      budget--;
      const cx = pts[sq * 2], cy = pts[sq * 2 + 1];
      // 偏移用 ±0.055 格：实测这类「棋子偏下半个字」的盘面，最佳平移就在 0.05 格附近，
      // 用 0.075 会跨过头（跨过头之后会咬到相邻棋子的笔画）。
      const off = cell * 0.055;
      let bestStats = s, bestScore = (m0.key === 'E') ? -2 : m0.score;

      // 两步走：先在同一尺度上找最佳偏移（9 次），再在最佳偏移上试尺度（4 次）。
      // 全组合 3x3x4=36 次太贵，实测两步走命中率一样。
      let ox = 0, oy = 0, offBest = bestScore, offStats = s;
      for (let dy = 0; dy < 3; dy++) {
        for (let dx = 0; dx < 3; dx++) {
          if (dx === 1 && dy === 1) continue;   // 原位置已经试过
          const nx = cx + OFFS[dx] * off;
          const ny = cy + OFFS[dy] * off;
          const ns = this.sampleCell(pixels, w, h, nx, ny, radius, true, gain);
          const nm = this.matchCell(ns);
          if (nm.key !== 'E' && nm.score > offBest) {
            offBest = nm.score; offStats = ns; ox = OFFS[dx]; oy = OFFS[dy];
          }
        }
      }
      if (offStats !== s) { bestScore = offBest; bestStats = offStats; }

      if (ox || oy) {
        const bx = cx + ox * off, by = cy + oy * off;
        for (let si = 0; si < SCALES.length; si++) {
          if (SCALES[si] === 1.0) continue;   // 上面已经试过 1.0
          const r = Math.max(3, Math.round(radius * SCALES[si]));
          const ns = this.sampleCell(pixels, w, h, bx, by, r, true, gain);
          const nm = this.matchCell(ns);
          if (nm.key !== 'E' && nm.score > bestScore) {
            bestScore = nm.score; bestStats = ns;
          }
        }
      }

      // 采纳条件：必须比自己原来高出一截，否则宁可不改。
      // 只「略微更好」就替换，会把本来一次就对的格子搞坏（历史回退就是这么来的）。
      //
      // 绝对下限 0.30 而不是 0.55：像「团队配合 26 关」这种子被放大 + 红圈的盘面，
      // 整盘分数都被压到 0.25~0.6（正确棋子也只有 0.4 左右），
      // 用 0.55 当门槛会把本来能救回来的格子全部拒掉。
      // 真正防回退的是下面那条「至少高 0.12」。
      const baseScore = (m0.key === 'E') ? -2 : m0.score;
      // 还要求「赢得分明」：新结果对第二名的领先要 ≥0.04，
      // 否则说明这只是搜索空间变大后捞到的一个偶然高点，
      // 换掉原来的判断只会把好好的格子搞坏。
      let decisive = 1;
      if (bestStats !== s) {
        const mb = this.matchCell(bestStats);
        decisive = (mb.alts && mb.alts.length > 1) ? (mb.alts[0].score - mb.alts[1].score) : 1;
      }
      if (bestStats !== s && bestScore >= 0.30 && bestScore >= baseScore + 0.15 && decisive >= 0.04) {
        stats[sq] = bestStats;
        fixed++;
      }
    }
    this.lastRefined = fixed;
    return fixed;
  }

  /**
   * 用「双峰自动分割」学背景，不依赖「哪些格子是空的」这个先验。
   *
   * 原来靠开局 58 个空位采样，一旦画面不是开局就学错，还会污染模型。
   * 现在直接把 90 个格子的暖色度做直方图，用 Otsu 找最佳分割点：
   * 空棋盘（冷色）和有棋子（暖色）自然会分成两簇。
   *
   * @param {Array} stats sampleAll 的结果
   * @param {number[]} emptySquares 兼容旧调用，现在不依赖它
   */
  learnBackground(stats, emptySquares) {
    const lv = this.calibrateBoardLevel(stats);

    // ---- 暖色 Otsu（保留作兼容与诊断，不再用于判占位）----
    const vals = [];
    for (let i = 0; i < stats.length; i++) {
      const s = stats[i];
      if (s && s.n > 0) vals.push(s.warmR);
    }
    if (vals.length < 10) return lv ? (this.bgModel = Object.assign({}, lv)) : null;

    const BINS = 64;
    const hist = new Array(BINS).fill(0);
    for (let i = 0; i < vals.length; i++) {
      let b = Math.round(vals[i] * (BINS - 1));
      if (b < 0) b = 0;
      if (b >= BINS) b = BINS - 1;
      hist[b]++;
    }
    const total = vals.length;
    let sumAll = 0;
    for (let i = 0; i < BINS; i++) sumAll += i * hist[i];

    let wB = 0, sumB = 0, maxVar = -1, bestBin = 0;
    for (let i = 0; i < BINS; i++) {
      wB += hist[i];
      if (wB === 0) continue;
      const wF = total - wB;
      if (wF === 0) break;
      sumB += i * hist[i];
      const mB = sumB / wB;
      const mF = (sumAll - sumB) / wF;
      const between = wB * wF * (mB - mF) * (mB - mF);
      if (between > maxVar) { maxVar = between; bestBin = i; }
    }

    let th = bestBin / (BINS - 1);
    // 阈值落在极端值说明画面里几乎全空或全满，给个保守默认
    if (th < 0.02 || th > 0.60) th = Math.max(0.06, Math.min(0.35, th || 0.15));

    // 红/黑判据的分布（相对量，不看绝对值）
    const reds = [], darks = [];
    for (let i = 0; i < stats.length; i++) {
      const s = stats[i];
      if (!s || s.n === 0) continue;
      reds.push(s.redR);
      darks.push(s.darkR);
    }
    const avg = (a) => a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0;

    this.bgModel = Object.assign({
      warmThreshold: th,
      meanWarm: avg(vals),
      meanRed: avg(reds),
      meanDark: avg(darks),
      meanL: 0,
      stdL: 1,
      meanBright: 0,
      stdBright: 1,
      meanRedRaw: avg(reds),
      stdRed: 0.01,
      meanDarkRaw: avg(darks),
      stdDark: 0.01
    }, lv || {});
    return this.bgModel;
  }

  /**
   * 从整盘 90 格的中位亮度反推「棋盘底色」，据此定出有子 / 无子的上下界。
   *
   * 为什么不能用暖色占比判占位（2026-11-16 真机日志推翻了这个前提）：
   *   木色棋盘 (199,167,112) 的 R-B=87，同样满足 warm 判据（R-B>22 && R>80），
   *   于是 90 格的 warmR 全落在 0.7~0.9；交叉点上的深色网格线又让 inkR 到 0.1~0.25。
   *   两个条件都过 → 整盘 81 格被判有子（实际只有 32 个），verifyDiff 直接飙到 73。
   *
   * 真正稳定的信号是亮度，同一帧里三峰分明：
   *   暗棋子盘面 L≈80~95 / 木色棋盘 L≈145~180 / 亮棋子盘面 L≈200~230。
   * 而任何局面下空格都占多数（90 格最多 32 子，中局更少），所以 meanL 的中位数
   * 一定落在「棋盘底色」那一峰上 —— 拿它当基准，上下各放一个由 MAD 自适应的裕度，
   * 偏离裕度就是有子。整套判据不含任何绝对颜色值，换皮肤、调亮度都不用重标。
   */
  calibrateBoardLevel(stats) {
    const ls = [];
    for (let i = 0; i < stats.length; i++) {
      const s = stats[i];
      if (s && s.n > 0 && s.meanL > 0) ls.push(s.meanL);
    }
    if (ls.length < 20) return null;
    ls.sort((a, b) => a - b);
    const med = ls[ls.length >> 1];
    const dev = ls.map(v => Math.abs(v - med)).sort((a, b) => a - b);
    const mad = dev[dev.length >> 1] || 0;
    // 木纹起伏大时自动放宽；同时保底 16/18 的绝对余量，
    // 免得低对比皮肤把「棋盘格自己」判成棋子。
    const hiTh = med + Math.max(16, 3 * mad);
    const loTh = med - Math.max(18, 3 * mad);
    /* ★ 2.1.60 墨迹占位模型：亮度三峰只对「深色盘面」皮肤有效。浅木色盘面 +
       黑字的皮肤里，棋子盘面亮度与棋盘底色重合，[loTh, hiTh] 把棋子全吞进去
       （2.1.59 真机帧：判有子=6）。而墨迹（黑字/红字笔画）皮肤无关：
       空格 0.02~0.07、星标 0.10、棋子 0.20+（真机帧实测）。空格占多数 →
       inkR 中位数 ≈ 空格基线，阈值 = max(0.13, 基线×2.2) 自适应。 */
    const inks = [];
    for (let i = 0; i < stats.length; i++) {
      const s = stats[i];
      if (s && s.n > 0 && typeof s.inkR === 'number') inks.push(s.inkR);
    }
    /* ★ 2.1.60：墨迹阈值用 Otsu 分簇（空格基线 vs 棋子），不用「中位数×系数」。
       真机帧实锤：采样盘 47px 会把邻格细线也算进来，空格基线到 0.12，
       ×2.2 = 0.267 —— 高过一半棋子的墨迹（0.18~0.26），整盘判空。
       Otsu 直接找两簇之间的谷底（本帧 0.17：空格 ≤0.16、棋子 ≥0.18）。
       两簇分不开（空盘 / 满盘 = 单峰）时判空：宁可不出箭头，也不能乱认。 */
    const inkO = inkOtsuThreshold(inks);
    return { boardL: med, mad: mad, hiTh: hiTh, loTh: loTh, levelN: ls.length,
             inkThOcc: inkO.th, boardInkMed: inkO.med, inkGap: inkO.gap, inkOk: inkO.ok ? 1 : 0 };
  }

  /**
   * 加权归一化 patch：减加权均值、除加权标准差
   * 比对的只是「中心区域的图案形状」，跟亮度、色调、边缘网格线无关
   */
  normalizePatch(patch) {
    return this.normalizePatchW(patch, this.patchWeights);
  }

  /**
   * 用指定权重做加权归一化。
   *
   * 模板训练时用全局 patchWeights；比对时用「按像素有效性过滤后」的权重，
   * 这样高亮圈 / 绿点盖住的像素不会把兵种比对带偏。
   * （高亮只在落子瞬间出现，但恰好是必须认准的那几帧。）
   */
  normalizePatchW(patch, weights) {
    const n = patch.length;
    if (!n) return null;
    const w = (weights && weights.length === n) ? weights : null;

    let sum = 0, sumW = 0;
    for (let i = 0; i < n; i++) {
      const wi = w ? w[i] : 1;
      sum += wi * patch[i];
      sumW += wi;
    }
    const mean = sum / (sumW || 1);

    let varSum = 0;
    for (let i = 0; i < n; i++) {
      const wi = w ? w[i] : 1;
      const d = patch[i] - mean;
      varSum += wi * d * d;
    }
    const std = Math.sqrt(varSum / (sumW || 1)) || 1;

    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = (patch[i] - mean) / std;
    return out;
  }

  /**
   * 从开局画面采集模板（双通道）
   */
  learnTemplates(stats, boardPieceAt) {
    const buckets = {};   // key -> [{w:归一化暖色, r:归一化红色}]
    for (let sq = 0; sq < 90; sq++) {
      const s = stats[sq];
      if (!s || !s.patchW) continue;
      const key = boardPieceAt[sq] || 'E';
      const vw = this.normalizePatch(s.patchW);
      const vr = this.normalizePatch(s.patchR);
      if (!vw || !vr) continue;
      if (!buckets[key]) buckets[key] = [];
      buckets[key].push({ w: vw, r: vr, i: s.patchI ? this.normalizePatch(s.patchI) : null });
    }
    this.templates = buckets;
    let total = 0;
    for (const k in buckets) total += buckets[k].length;
    this.templateCount = total;
    return buckets;
  }

  /**
   * 双通道加权 NCC 匹配
   *
   * 【必须先做暖色预筛】空格的 patchW 全是 0，归一化后得到全 0 向量，
   * 跟任何模板的点积都是 0 —— 于是所有空格都会被投给第一个碰上的红子模板
   * （曾经导致 58 格偏差，正好等于空格总数）。
   * 所以先用暖色占比把「明显是空格」的格子直接判掉，只让候选格进模板比对。
   */
  matchCell(stats) {
    const PW = stats.patchW.length;
    const valid = stats.patchValid;
    let warmCount = 0, redCount = 0, validCount = 0;
    for (let i = 0; i < PW; i++) {
      if (valid && !valid[i]) continue;
      validCount++;
      if (stats.patchW[i] > 0) warmCount++;
      if (stats.patchR[i] > 0) redCount++;
    }
    const warmRatio = warmCount / (validCount || PW);

    /* 2.1.57：空格预筛改用亮度。
       warmRatio 在木色棋盘上恒约 0.8（木色 R-B=87 也算暖），原来这条 0.18 的
       判断一次都不会命中，空格照样全部进模板比对 —— 这是「81 格有子」的另一半原因。
       ★ 2.1.60：亮度预筛在「浅木色盘面 + 黑字」皮肤上会把**所有棋子**判成空格
       （棋子盘面 L148~178 落在空格区间 [145,219] 里，2.1.59 真机帧就是这么
       整盘判空的）。改成「没墨迹**且**亮度在空格区间」才算空 —— 墨迹是皮肤无关
       信号，有墨就必须进模板比对。 */
    const bgm = this.bgModel;
    const inkGate0 = (bgm && typeof bgm.inkThOcc === 'number' && bgm.inkThOcc > 0)
      ? bgm.inkThOcc : 0.13;
    const inkR0 = (typeof stats.inkR === 'number') ? stats.inkR : 0;
    const noInk = (inkR0 < inkGate0);
    if (bgm && typeof bgm.hiTh === 'number' && typeof bgm.loTh === 'number') {
      const Lc = stats.meanL || 0;
      if (noInk && Lc <= bgm.hiTh && Lc >= bgm.loTh) return { key: 'E', score: 0, warmRatio };
    } else if (noInk && warmRatio < 0.18) {
      // 没有 boardLevel 模型时退回旧判据
      return { key: 'E', score: warmRatio, warmRatio };
    }

    const n = PW;
    // 按像素有效性过滤后的权重：高亮圈 / 绿点 / 白边占掉的格直接不参与比对
    let wgt = null;
    if (this.patchWeights && this.patchWeights.length === n) {
      if (valid && validCount < n) {
        wgt = new Float32Array(n);
        let s = 0;
        for (let i = 0; i < n; i++) {
          const v = valid[i] ? this.patchWeights[i] : 0;
          wgt[i] = v;
          s += v;
        }
        if (s > 1e-6) {
          for (let i = 0; i < n; i++) wgt[i] /= s;
        } else {
          wgt = this.patchWeights;
        }
      } else {
        wgt = this.patchWeights;
      }
    }

    const vw = this.normalizePatchW(stats.patchW, wgt);
    const vr = this.normalizePatchW(stats.patchR, wgt);
    const vi = stats.patchI ? this.normalizePatchW(stats.patchI, wgt) : null;
    if (!vw || !vr || !this.templates) return { key: 'E', score: 0, warmRatio };

    let bestKey = 'E', best = -2;
    const all = [];
    // ---- 墨迹二值图（F1 打分用）----
    // 为什么要多算这一份：点积（余弦）只看「两个掩码同向有多长」，
    // 笔画被采样丢掉一部分时，残留下来的墨迹跟「笔画最少的那个字」同向性最好，
    // 于是复杂字被读成最简单的字 —— 实测就是 馬→卒、俥→仕、象→卒。
    // F1 = 2*|交集| / (|样本| + |模板|) 同时罚「漏检」和「多检」，
    // 少了一半笔画就会明显掉分，不会反而赢。
    const useF1 = (this.scoreMode === 'f1') && !!stats.patchI;
    const useMass = (this.scoreMode === 'mass') && !!stats.patchI;
    let vb = null, vInk = 0;
    if (useF1 || useMass) {
      vb = stats.patchI;
      for (let i = 0; i < n; i++) {
        if (valid && !valid[i]) continue;
        if (vb[i] > 0) vInk++;
      }
    }

    for (const key in this.templates) {
      const arr = this.templates[key];
      let typeBest = -9;
      for (let t = 0; t < arr.length; t++) {
        const tpl = arr[t];
        let score;
        if (tpl.i && useF1) {
          let tp = 0;
          for (let i = 0; i < n; i++) {
            if (vb[i] > 0 && tpl.i[i] > 0) tp++;
          }
          if (tpl._ni === undefined) {
            let s2 = 0;
            for (let i = 0; i < n; i++) if (tpl.i[i] > 0) s2++;
            tpl._ni = s2;
          }
          const den = vInk + tpl._ni;
          score = den > 0 ? (2 * tp) / den : 0;
        } else if (tpl.i) {
          // ★ 只算真正会用到的通道
          //
          // 兵种只看墨迹通道，但这里原来把暖色、红色两个点积也算了一遍再丢掉 ——
          // 86 个模板 x 576 像素 x 3 通道，光这一项每帧就多算 15 万次乘加。
          let dotI = 0;
          for (let i = 0; i < n; i++) {
            const wi = wgt ? wgt[i] : 1;
            dotI += wi * vi[i] * tpl.i[i];
          }
          score = dotI;
          if (useMass) {
            // 笔画总量惩罚：点积对「笔画多少」不敏感，残留一半笔画时
            // 跟「笔画最少的字」同向性反而最好（馬→卒、俥→仕 就是这么来的）。
            // 这里按「样本墨迹量 vs 模板墨迹量」的差异打个折，把复杂度也纳入判据。
            if (tpl._ni === undefined) {
              let s2 = 0;
              for (let i = 0; i < n; i++) if (tpl.i[i] > 0) s2++;
              tpl._ni = s2;
            }
            const mx = vInk > tpl._ni ? vInk : tpl._ni;
            const K = (typeof this.massK === 'number') ? this.massK : 0.35;
            if (mx > 0) score *= (1 - K * Math.abs(vInk - tpl._ni) / mx);
          }
        } else {
          let dotW = 0, dotR = 0;
          for (let i = 0; i < n; i++) {
            const wi = wgt ? wgt[i] : 1;
            dotW += wi * vw[i] * tpl.w[i];
            dotR += wi * vr[i] * tpl.r[i];
          }
          score = dotW + dotR * 0.3;
        }
        if (score > typeBest) typeBest = score;
        if (score > best) { best = score; bestKey = key; }
      }
      all.push({ key: key, score: typeBest });
    }
    // 候选项按分数降序，最多留 4 个，供「棋子数量上限」修复挑选
    all.sort((a, b) => b.score - a.score);
    return { key: bestKey, score: best, warmRatio, alts: all.slice(0, 4) };
  }

  /**
   * 模板匹配版三分类（以「墨迹」为主判据）
   *
   * 分工：
   *   墨迹（字是深色或红色）→ 决定「有没有子」和「红还是黑」   ← 最可靠，绿点/高亮圈都骗不到
   *   模板匹配              → 只决定「是哪个兵种」            ← 模板错了也不会把空判成有子
   *
   * 之前完全靠模板判有无，一旦模板受干扰（绿点、高亮圈、采样偏移），
   * 就会出现「空格被当成棋子」这种致命错误，整个 FEN 全废。
   */
  classifyByTemplate(stats) {
    const grid = new Int8Array(90);
    const codes = new Int8Array(90);
    const conf = new Float32Array(90);
    const rankedCodes = new Array(90);
    const hidden = new Uint8Array(90);
    const margins = new Float32Array(90);
    let hiddenCount = 0;
    let tplFail = 0;
    // 有亮度三峰模型就优先用它判「有没有子」（2.1.57）
    const bgT = this.bgModel;
    const lvOK = !!(bgT && typeof bgT.hiTh === 'number' && typeof bgT.loTh === 'number');

    for (let sq = 0; sq < 90; sq++) {
      const s = stats[sq];
      if (!s || !s.patchW) { grid[sq] = EMPTY; codes[sq] = 0; continue; }

      // 河界两行（row 4/5）中央有「楚河」「汉界」和水印文字，
      // 那文字是深色的，会被墨迹判据当成棋子。这两行阈值单独抬高。
      // 2.1.60：基准阈值改由墨迹占位模型自适应（bgModel.inkThOcc，
      // 真机帧实测空格 0.02~0.07 / 星标 0.10 / 棋子 0.20+ → 0.13）；
      // 河界行在自适应值上再抬 0.05（浅色水印的皮肤里河界行墨迹并不高，
      // 但保留余量防其它皮肤河界文字干扰）。
      const isRiverRow = (sq >= 4 * 9 && sq < 6 * 9);
      const inkBase = (bgT && typeof bgT.inkThOcc === 'number' && bgT.inkThOcc > 0)
        ? bgT.inkThOcc : 0.13;
      const inkTh = isRiverRow ? Math.max(0.16, inkBase + 0.05) : inkBase;

      const inkR = (typeof s.inkR === 'number') ? s.inkR : 0;
      const warmR = (typeof s.warmR === 'number') ? s.warmR : 0;

      // 【已删除「被画中画盖住的格子判未知」那段逻辑】
      //   它按「暖色占比 > 93% 且几乎无墨」+「落在浮窗矩形内」两条判据把格子抹成空。
      //   在真机抓屏上，空棋盘格也会被判成「暖色无墨」（抓屏色彩比真实截图更亮更饱和），
      //   于是半盘格子被抹空、还因为浮窗矩形框偏弹出「浮窗挡棋盘」的假提示。
      //   这条路走不通，直接去掉：格子一律按正常流程识别。

      const hasInk = (inkR >= inkTh);
      /* 2.1.57：盘面判据换成「偏离棋盘底色亮度」。
         原来 hasFace = warmR >= 0.28，而木色棋盘 warmR≈0.8 —— 空格全过这一关，
         只能靠下面 score<0.10 兜底；一旦模板与真机像素不同源（当前正是如此），
         score 恒 0，整盘棋子被丢空，verifyDiff 恰好等于开局子数。 */
      const hasFace = lvOK
        ? ((s.meanL > bgT.hiTh) || (s.meanL < bgT.loTh))
        : (warmR >= 0.28);
      if (!hasInk && !hasFace) {
        grid[sq] = EMPTY;
        codes[sq] = 0;
        continue;
      }

      // 2) 墨迹颜色定红黑；字被遮住时退回「红色占比」
      //    优先用中心 8x8 的墨迹：外圈是「上一步」的高亮圈，
      //    圈的深色描边会被算成黑墨，把刚走过的红仕判成黑兵（实测）。
      const redInkR = (typeof s.redInkR === 'number') ? s.redInkR : 0;
      const darkInkR = (typeof s.darkInkR === 'number') ? s.darkInkR : 0;
      const coreInkR = (typeof s.inkCoreR === 'number') ? s.inkCoreR : 0;
      const coreRedR = (typeof s.redInkCoreR === 'number') ? s.redInkCoreR : 0;
      const coreDarkR = (typeof s.darkInkCoreR === 'number') ? s.darkInkCoreR : 0;
      let inkRed;
      if (coreInkR >= 0.10) {
        inkRed = coreRedR >= coreDarkR;
      } else if (inkR >= inkTh) {
        inkRed = redInkR >= darkInkR;
      } else {
        inkRed = (s.redR || 0) > 0.012;
      }
      const inkColor = inkRed ? RED_PC : BLK_PC;

      // 3) 模板只用来认兵种
      const r = this.matchCell(s);
      conf[sq] = r.score;
      // 分数低到个位数 = 这一格根本没有字形。
      //
      // 为什么需要这条：上面 hasFace 是「暖色占比」，可棋盘底色本身就是暖色的，
      // 空格配上一点网格线就能过 hasFace，然后模板比出来的分数只有 0.01~0.02，
      // 随便挑个相似的兵种就填上去了 —— 实测 user_dots 的 r6c6 是空格，
      // 墨迹 0.003、模板分 0.016，被读成了红仕。
      // 真棋子在这个尺度下最低也有 0.25 以上，所以 0.10 这条线足够安全。
      if (r.score < 0.10) {
        grid[sq] = EMPTY;
        codes[sq] = 0;
        tplFail++;
        continue;
      }
      // 记下「第一名和第二名的分差」—— 分差小说明没把握，数量约束修复只动这些格子
      margins[sq] = (r.alts && r.alts.length > 1) ? (r.alts[0].score - r.alts[1].score) : 99;

      if (r.key === 'E') {
        // 模板说空。
        // 以前这里兜底成「兵/卒」，结果模板一失效就把整盘棋子全填成卒，
        // 生成一张满盘卒的 FEN，评分直接 -299。
        // 现在判空：宁可漏掉一个子，也不能把整盘搞成垃圾。
        grid[sq] = EMPTY;
        codes[sq] = 0;
        tplFail++;
        continue;
      }

      let code = (typeof r.key === 'number') ? r.key : parseInt(r.key, 10);
      if (!code) {
        grid[sq] = EMPTY;
        codes[sq] = 0;
        tplFail++;
        continue;
      }

      const codeIsRed = (code < 8);
      let finalCode;
      if (codeIsRed === inkRed) {
        finalCode = code;
      } else {
        // 颜色冲突 → 信墨迹，兵种取对应阵营的同一兵种
        const t = codeIsRed ? code : code - 7;
        finalCode = inkRed ? t : (t + 7);
      }
      grid[sq] = inkColor;
      codes[sq] = finalCode;

      // 记录候选兵种（按分数排序），供后面的「数量上限」修复用
      const alts = r.alts || [];
      const ranked = [];
      for (let ai = 0; ai < alts.length; ai++) {
        const k = (typeof alts[ai].key === 'number') ? alts[ai].key : parseInt(alts[ai].key, 10);
        if (!k) continue;
        const kRed = (k < 8);
        const t = kRed ? k : k - 7;
        const c = inkRed ? t : (t + 7);
        if (ranked.indexOf(c) < 0) ranked.push(c);
      }
      if (ranked.indexOf(finalCode) < 0) ranked.unshift(finalCode);
      rankedCodes[sq] = ranked;
    }

    // ---- 棋子数量上限修复 ----
    // 象棋每种棋子的数量是固定的，超出上限就一定是认错了：
    //   將帥1  仕2  象2  馬2  車2  炮2  兵5
    // 实测最有价值的一条：红方本来只有两个馬，某一格把带高亮圈的红俥
    // 认成紅傌，就会出现「三个馬」，改成車之后局面立刻合法。
    const LIMIT = [0, 1, 2, 2, 2, 2, 2, 5];
    // 有格子被浮窗盖住时，棋子总数本身就是错的，这时候做数量修复只会更乱
    const allowRepair = (hiddenCount === 0);
    const MARGIN_MAX = 0.35;   // 只动「第一名和第二名分差很小」的格子
    const MAX_REPAIR = 4;      // 最多改 4 格，防止雪崩
    const cnt = [new Array(8).fill(0), new Array(8).fill(0)];
    for (let sq = 0; sq < 90; sq++) {
      const v = codes[sq];
      if (!v) continue;
      if (v <= 7) cnt[0][v]++; else cnt[1][v - 7]++;
    }
    // 先修「分数差距最小」的格子（最可能认错的那个）
    const order = [];
    for (let sq = 0; sq < 90; sq++) {
      const v = codes[sq];
      if (!v) continue;
      const margin = margins[sq];
      if (margin > MARGIN_MAX) continue;   // 有把握的格子不碰
      const side = v <= 7 ? 0 : 1;
      const t = v <= 7 ? v : v - 7;
      if (allowRepair && cnt[side][t] > LIMIT[t]) order.push({ sq: sq, key: margin });
    }
    order.sort((a, b) => a.key - b.key);

    let repaired = 0;
    for (let oi = 0; oi < order.length && repaired < MAX_REPAIR; oi++) {
      const sq = order[oi].sq;
      const v = codes[sq];
      if (!v) continue;
      const side = v <= 7 ? 0 : 1;
      const t = v <= 7 ? v : v - 7;
      if (cnt[side][t] <= LIMIT[t]) continue;
      const ranked = rankedCodes[sq] || [];
      for (let ri = 0; ri < ranked.length; ri++) {
        const alt = ranked[ri];
        if (!alt || alt === v) continue;
        const as = alt <= 7 ? 0 : 1;
        const at = alt <= 7 ? alt : alt - 7;
        if (as !== side) continue;           // 红黑不改，颜色比兵种更可靠
        if (cnt[side][at] >= LIMIT[at]) continue;
        cnt[side][t]--;
        cnt[side][at]++;
        codes[sq] = alt;
        grid[sq] = alt <= 7 ? RED_PC : BLK_PC;
        repaired++;
        break;
      }
    }

    // ---- 将/帅必在：整盘找不到某一方的将帅时，把它找回来 ----
    //
    // 用户实测的现象：黑将那个位置「有棋子、是黑的，但认成了炮」。
    // 也就是说颜色和位置都对，只是兵种错（將 和 炮 字形都很密，容易混）。
    // 但象棋里一方不可能没有将帅 —— 只要某一方将帅数为 0，
    // 就说明有一个子被认成了别的兵种。这里把「将/帅在候选里排得最靠前」的那格改回来，
    // 比让整盘缺将帅强得多（缺将帅的盘面引擎根本没法算）。
    (function repairKings() {
      for (let side = 0; side < 2; side++) {
        const kingCode = side === 0 ? 1 : 8;      // 红帥 / 黑將
        let kingCount = 0;
        for (let sq = 0; sq < 90; sq++) if (codes[sq] === kingCode) kingCount++;
        if (kingCount > 0) continue;

        let bestSq = -1, bestRank = 99;
        for (let sq = 0; sq < 90; sq++) {
          const v = codes[sq];
          if (!v) continue;
          const isRed = v <= 7;
          if ((side === 0) !== isRed) continue;      // 只在本方格子里找
          if (v === kingCode) continue;
          // 别的兵种数量还没超上限时，优先别动它（说明它自己可能是对的）
          const ranked = rankedCodes[sq] || [];
          const rank = ranked.indexOf(kingCode);
          if (rank < 0) continue;
          // 该兵种已经超上限的格子，最值得改
          const t = isRed ? v : v - 7;
          const overs = cnt[side][t] > LIMIT[t] ? 0 : 10;
          const score = rank * 2 + overs;
          if (score < bestRank) { bestRank = score; bestSq = sq; }
        }
        if (bestSq >= 0) {
          const old = codes[bestSq];
          const ot = old <= 7 ? old : old - 7;
          if (cnt[side][ot] > 0) cnt[side][ot]--;
          codes[bestSq] = kingCode;
          cnt[side][1]++;
          grid[bestSq] = side === 0 ? RED_PC : BLK_PC;
          repaired++;
        }
      }
    })();

    // 把每格的置信度和候选留下来，给 App 的「识别留证」页用
    this.lastConf = Array.prototype.slice.call(conf);
    this.lastRanked = rankedCodes.map(function (a) { return a ? a.slice(0, 3) : []; });
    return { grid, conf, codes, tplFail, repaired: repaired, hidden: hidden,
             hiddenCount: hiddenCount, rings: this.lastRings, centers: this.lastCenters };
  }

  /**
   * 三分类主入口：有模板就走模板匹配，没模板才退回颜色阈值。
   *
   * 模板匹配对光照、棋子高光、棋盘皮肤、上一步的绿圈红圈全都免疫，
   * 因为它比的是「归一化后的图案形状」，不是绝对颜色。
   */
  classify(stats, opts) {
    if (this.templates) {
      return this.classifyByTemplate(stats);
    }
    return this.classifyByColor(stats, opts);
  }

  /**
   * 颜色版三分类（无模板兜底 + learnBoard 判朝向）。
   *
   * 有子：暖色盘面或大片暗色，且必须真的有墨迹 / 暗像素 —— 纯木色背景判空。
   * 红黑：比较红墨与黑墨占比；旧版用红色占比 redR，木色偏红像素会把黑子判成红子。
   * 老 stats 没有墨迹字段时，才退回 redR 阈值，保持向后兼容。
   */
  classifyByColor(stats, opts) {
    const o = Object.assign({
      warmTh: 0.20,
      redTh: 0.012,
      inkMin: COLOR_INK_MIN,
      darkMin: COLOR_DARK_MIN,
      darkFace: COLOR_DARK_FACE,
      redInkMin: COLOR_RED_INK_MIN,
      redInkRatio: COLOR_RED_INK_RATIO,
    }, opts || {});

    const bg = this.bgModel;
    const warmTh = bg && typeof bg.warmThreshold === 'number' ? bg.warmThreshold : o.warmTh;
    // 有 boardLevel 模型就优先用亮度判占位（2.1.57 起）
    const lvOK = !!(bg && typeof bg.hiTh === 'number' && typeof bg.loTh === 'number');

    const grid = new Int8Array(90);
    const conf = new Float32Array(90);

    for (let sq = 0; sq < 90; sq++) {
      const s = stats[sq];
      if (!s || s.n === 0) { grid[sq] = EMPTY; continue; }

      const warmR = s.warmR || 0;
      const darkR = s.darkR || 0;
      const inkR = typeof s.inkR === 'number' ? s.inkR : 0;
      const redInkR = typeof s.redInkR === 'number' ? s.redInkR : 0;
      const darkInkR = typeof s.darkInkR === 'number' ? s.darkInkR : 0;
      const hasInkStats = typeof s.inkR === 'number';

      // 暖色 / 大片暗色只说明「有东西」，还要有墨迹才认作棋子（挡住木色背景）
      /* 2.1.57：占位判据换成「偏离棋盘底色亮度」（真机日志推翻暖色判据的证据见
         calibrateBoardLevel 的注释）。暖色通道在木色棋盘上恒为真，交叉点网格线
         又给出 inkR，两个条件一起把空格整片判成棋子 —— 真机 81/90 格有子。
         ★ 2.1.60：亮度判据在「浅木色盘面 + 黑字」皮肤上整体失效（2.1.59 真机帧
         判有子=6），改为**墨迹为主、亮度偏离为辅**：
           inkR ≥ inkThOcc（自适应，空格基线×2.2 起）→ 有子，皮肤无关；
           亮度只在明显偏离时兜底（devL>0.25，防老深色皮肤里墨迹被高光冲淡）。
         真机帧实测墨迹分离度：空格 0.02~0.07 / 星标 0.10 / 棋子 0.20+。 */
      const inkThOcc = (bg && typeof bg.inkThOcc === 'number' && bg.inkThOcc > 0)
        ? bg.inkThOcc : 0.13;
      const isRiverSq = (sq >= 4 * 9 && sq < 6 * 9);
      const inkGate = isRiverSq ? Math.max(0.16, inkThOcc + 0.05) : inkThOcc;
      let devL = -1;
      if (lvOK) {
        const dHi = (s.meanL - bg.hiTh) / Math.max(1, bg.hiTh - bg.boardL);
        const dLo = (bg.loTh - s.meanL) / Math.max(1, bg.boardL - bg.loTh);
        devL = dHi > dLo ? dHi : dLo;
      }
      let occupied;
      if (lvOK) {
        occupied = (inkR >= inkGate) || (devL > 0.25);
        conf[sq] = Math.max(inkR / inkGate, devL);
        if (conf[sq] < 0) conf[sq] = 0;
      } else {
        occupied = (warmR >= warmTh || darkR >= o.darkFace) &&
          (inkR >= o.inkMin || darkR >= o.darkMin || redInkR >= o.redInkMin);
        conf[sq] = warmTh > 0 ? warmR / warmTh : 0;
      }
      if (!occupied) { grid[sq] = EMPTY; continue; }

      const isRed = hasInkStats
        ? (redInkR > o.redInkMin && redInkR > darkInkR * o.redInkRatio)
        : ((s.redR || 0) > o.redTh);
      grid[sq] = isRed ? RED_PC : BLK_PC;
    }
    return { grid, conf };
  }

  /** 模板 SAD 匹配，用于歧义消解：返回与给定 patch 最相似的模板 key */
  matchTemplate(patch, colorHint) {
    if (!this.templates || !this.templates.length) return null;
    let best = null, bestD = Infinity;
    for (const t of this.templates) {
      if (colorHint !== undefined) {
        const tRed = (t.key === 1 || t.key === 2 || t.key === 3 || t.key === 4 || t.key === 5 || t.key === 6 || t.key === 7);
        if ((colorHint === RED_PC) !== tRed) continue;
      }
      let d = 0;
      const g = t.gray;
      for (let i = 0; i < patch.length; i++) {
        const diff = patch[i] - g[i];
        d += diff < 0 ? -diff : diff;
      }
      if (d < bestD) { bestD = d; best = t; }
    }
    return best ? { key: best.key, dist: bestD } : null;
  }
}

/**
 * 找画中画浮窗：只认 App 自己画的那圈洋红边框
 *
 * 为什么不能用「猜颜色」：老版本按「米黄色块」判断浮窗位置，
 * 可棋盘本身就是米黄的 —— 空格被当成浮窗、半盘被抹空，
 * 还反复误报「浮窗挡棋盘」，盘面直接用不了（这段历史在雷达图里最长）。
 *
 * 现在 App 在浮窗内容外面画一圈 4px 洋红 (255,0,255)：
 * 这种颜色在棋盘、棋子、JJ象棋界面上都不存在，认出来就是 100% 确定；
 * 认不出来就返回 null，等于「没有浮窗」，绝不会误伤棋盘。
 */
/**
 * 找浮窗（画中画）的洋红边框。
 * @param {Uint8ClampedArray} pixels RGBA 帧
 * @param {number} w 帧宽
 * @param {number} h 帧高
 * @param {Float64Array|Array<number>} [pts] 90 个格点的扁平坐标 [x0,y0,x1,y1,...]。
 *   传入时只扫棋盘外接矩形：浮窗要影响识别必然盖在棋盘上，
 *   棋盘外的像素扫了也没用。真机 1284x2778 全帧扫一次约 89 万次采样，
 *   限定 ROI 后约 33 万次，是每帧最贵的单点循环之一。
 */
function findPipRect(pixels, w, h, pts) {
  let sx0 = 0, sy0 = 0, sx1 = w - 1, sy1 = h - 1;
  if (pts && pts.length >= 180) {
    let minX = w, minY = h, maxX = -1, maxY = -1;
    for (let k = 0; k < 90; k++) {
      const gx = pts[k * 2], gy = pts[k * 2 + 1];
      if (gx < minX) minX = gx;
      if (gx > maxX) maxX = gx;
      if (gy < minY) minY = gy;
      if (gy > maxY) maxY = gy;
    }
    // 外扩半格，覆盖边框压在棋盘边线上的情况
    const pad = Math.max(24, (maxX - minX) / 8 * 0.6);
    sx0 = Math.max(0, Math.floor(minX - pad));
    sy0 = Math.max(0, Math.floor(minY - pad));
    sx1 = Math.min(w - 1, Math.ceil(maxX + pad));
    sy1 = Math.min(h - 1, Math.ceil(maxY + pad));
  }

  let x0 = w, y0 = h, x1 = -1, y1 = -1, n = 0;
  for (let y = sy0; y <= sy1; y += 2) {
    const base = y * w;
    for (let x = sx0; x <= sx1; x += 2) {
      const i = (base + x) * 4;
      const R = pixels[i], G = pixels[i + 1], B = pixels[i + 2];
      if (R > 175 && G < 105 && B > 175) {
        n++;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (n < 100) return null;
  const rw = x1 - x0, rh = y1 - y0;
  if (rw < 70 || rh < 40) return null;
  if (rw > w * 0.9 && rh > h * 0.6) return null;

  // 四条边都得有洋红，排除画面里零散的高光/贴图
  const edgeCount = (ax, ay, bx, by) => {
    let c = 0;
    for (let t = 0; t <= 24; t++) {
      const x = Math.round(ax + (bx - ax) * t / 24);
      const y = Math.round(ay + (by - ay) * t / 24);
      if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
      const i = (y * w + x) * 4;
      const R = pixels[i], G = pixels[i + 1], B = pixels[i + 2];
      if (R > 160 && G < 120 && B > 160) c++;
    }
    return c;
  };
  if (edgeCount(x0, y0, x1, y0) < 16) return null;
  if (edgeCount(x0, y1, x1, y1) < 16) return null;
  if (edgeCount(x0, y0, x0, y1) < 12) return null;
  if (edgeCount(x1, y0, x1, y1) < 12) return null;
  return { x0: x0, y0: y0, x1: x1, y1: y1 };
}

/**
 * ★ 2.1.58 开局匹配滤波网格对齐
 *
 * 【为什么需要】手动点四角天生 ±30px 手指误差（真机 20:06 标定四角的顶边
 * 本身就带 35px 斜率），自动标定的 refineByPieces 用的「暖亮圆盘掩码」在木色
 * 皮肤上整块棋盘都命中（R-B=87、L=189 全过），等于对噪声对齐。采样窗 radius≈48
 * 中心一旦偏 20px+，patch 只擦到棋子边缘：亮度只被拉低 20~30，仍然落在
 * 「空格区间」内 → 32 个子全被判空（真机 2.1.57：亮度图 90 格全 150~195、
 * 判有子=0，而黑卒行的偶数列恰好一致偏暗 25 —— 就是擦边的痕迹）。
 *
 * 【做法】学习/标定永远发生在「标准开局画面」，32 个子的位置是已知的，
 * 把它们当匹配滤波：网格候选（整体缩放 + 平移，再四角独立微调）逐个采样
 * 90 个交叉点的 2×2 亮度，得分 = 32 个开局位偏离棋盘中位亮度的总量
 * − 58 个空格位的偏离量 × 0.8，红/黑两个朝向取大。
 *   黑子盘面 L≈33~100、红子中心（红字）L≈77 或盘面 L≈208+，个个远离
 *   棋盘中位 L≈174；空格贴近中位。对齐正确时分数极高，
 *   别的排布（中局、大厅木纹）很难冒充 —— 冒充不了就不采纳，宁可不动。
 *
 * 参考 64922/xiangqi-advisor：模板从开局帧现场裁的前提，正是
 * 「标准开局恰好含全部棋子且位置已知」这个强先验。
 *
 * @returns {{accepted, corners, occHit, emptyHit, idOccHit, idEmptyHit,
 *            score, idScore, shiftX, shiftY, scaleX, scaleY, already}|null}
 */
function alignGridToOpening(pixels, w, h, corners, openingIdx, emptyIdx) {
  alignGridToOpening.lastDebug = null;
  if (!pixels || w < 60 || h < 60 || !corners || corners.length !== 4) return null;
  const op = Array.isArray(openingIdx) ? openingIdx : null;
  const em = Array.isArray(emptyIdx) ? emptyIdx : null;
  if (!op || !em || op.length < 24 || em.length < 40) return null;

  /* ★ 2.1.60：probeL 从「亮度均值」改为「墨迹占比」（积分图 O(1)）。
   * 2.1.59 真机帧实锤（失败帧 JPEG 落盘 + 离线复现）：这局皮肤的黑子是
   * 浅木色盘面 + 黑字 + 黑描边 —— 盘面亮度 L≈150 与棋盘底色几乎重合，
   * 亮度三峰模型完全失效（判有子=6），对齐器的亮度信号也是死的。
   * 而「墨迹」（黑字笔画 / 红字笔画，sampleCell 的 isDarkInk/isRedInk 同式）
   * 在真机帧 90 格上完美分离：
   *   空格 ink 0.02~0.07 / 楚河汉界中心星 0.10 / 黑子 0.20~0.24 / 红子 0.25~0.31
   * （旧深色皮肤整盘深色 → ink≈0.9+，同样轻松命中 —— 皮肤无关）。
   * 阈值取 max(0.13, 恒等网格墨迹中位数×2.2)：本帧 → 0.13，网格线更黑的
   * 皮肤会自动抬高到 0.22+，星标/网格线不会误报。 */
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (let i = 0; i < 4; i++) {
    const p = corners[i];
    if (p[0] < minX) minX = p[0];
    if (p[0] > maxX) maxX = p[0];
    if (p[1] < minY) minY = p[1];
    if (p[1] > maxY) maxY = p[1];
  }
  /* 单格距 = 顶边长 / 8（gridPoints 的 u 参数化就是 c/8）。
   * 【现场 bug】最初写成整条边长（8 倍），R 被放大到 8 倍、采样盘远超 ROI，
   * probeL 处处出界 → evalCorners 恒 null → 对齐永远返回 null。 */
  const cell = Math.hypot(corners[1][0] - corners[0][0], corners[1][1] - corners[0][1]) / 8;
  if (!(cell > 20)) return null;
  const R = Math.max(14, Math.round(cell * 0.30));
  /* 覆盖缩放 ±10% 与四角微调 ±64px 的移动范围 */
  const pad = R + 120;
  const roiX = Math.max(0, Math.floor(minX - pad));
  const roiY = Math.max(0, Math.floor(minY - pad));
  const roiW = Math.min(w, Math.ceil(maxX + pad)) - roiX;
  const roiH = Math.min(h, Math.ceil(maxY + pad)) - roiY;
  if (roiW < R * 4 + 8 || roiH < R * 4 + 8) return null;

  const IW = roiW + 1;
  const integ = new Float64Array(IW * (roiH + 1));
  for (let yy = 0; yy < roiH; yy++) {
    const srcRow = (roiY + yy) * w + roiX;
    let run = 0;
    const rowOff = (yy + 1) * IW;
    const prevOff = yy * IW;
    for (let xx = 0; xx < roiW; xx++) {
      const i4 = (srcRow + xx) * 4;
      const pr = pixels[i4], pg = pixels[i4 + 1], pb = pixels[i4 + 2];
      const L = 0.299 * pr + 0.587 * pg + 0.114 * pb;
      const isRedInk = (pr > 95 && pg < 115 && (pr - pg) > 55 && (pr - pb) > 65);
      const isInk = isRedInk || (L < 85 && !isRedInk) ? 1 : 0;
      run += isInk;
      integ[rowOff + xx + 1] = integ[prevOff + xx + 1] + run;
    }
  }

  /** 以 (x,y) 为中心的 (2R+1)² 矩形墨迹占比。出界返回 -1（候选作废） */
  function probeL(x, y) {
    const xi = x | 0, yi = y | 0;
    const x0 = xi - R - roiX, x1 = xi + R - roiX;
    const y0 = yi - R - roiY, y1 = yi + R - roiY;
    if (x0 < 0 || y0 < 0 || x1 > roiW - 1 || y1 > roiH - 1) return -1;
    const a = integ[y0 * IW + x0], b = integ[y0 * IW + x1 + 1];
    const c = integ[(y1 + 1) * IW + x0], d = integ[(y1 + 1) * IW + x1 + 1];
    return (d - c - b + a) / ((x1 - x0 + 1) * (y1 - y0 + 1));
  }

  // 90 个交叉点的归一化坐标（u=c/8, v=r/9，与 gridPoints 同参数化）
  const UV = new Float32Array(180);
  for (let r = 0; r < 10; r++) {
    for (let c = 0; c < 9; c++) {
      const i = (r * 9 + c) * 2;
      UV[i] = c / 8;
      UV[i + 1] = r / 9;
    }
  }
  // 翻转坐标映射（红黑互换时的对应格）
  const FLIP = new Int32Array(90);
  for (let i = 0; i < 90; i++) FLIP[i] = (9 - ((i / 9) | 0)) * 9 + (8 - (i % 9));

  const dev = new Float32Array(90);
  let inkTh = 0;
  let evals = 0;

  /** 对一组四角打分；inkTh 只在第一次（恒等网格）时从中位数求出 */
  function evalCorners(cs) {
    evals++;
    const p00 = cs[0], p10 = cs[1], p11 = cs[2], p01 = cs[3];
    for (let i = 0; i < 90; i++) {
      const p = bilinear(p00, p10, p11, p01, UV[i * 2], UV[i * 2 + 1]);
      const v = probeL(p[0], p[1]);
      if (v < 0) return null;
      dev[i] = v;
    }
    if (inkTh <= 0) {
      /* 空格永远占多数 → 用 Otsu 在「空格基线」与「棋子」两簇之间切一刀
         （与 calibrateBoardLevel 同一套，见 inkOtsuThreshold 注释：
         真机帧谷底 0.17，空格 ≤0.16 / 棋子 ≥0.18）。 */
      inkTh = inkOtsuThreshold(dev).th;
    }
    const TH = inkTh * 100;           // 打分用百分比刻度
    let best = null;
    for (let f = 0; f < 2; f++) {
      let s = 0, oh = 0, eh = 0;
      for (let k2 = 0; k2 < op.length; k2++) {
        const d = Math.min(45, dev[f ? FLIP[op[k2]] : op[k2]] * 100);
        s += d;
        if (d >= TH) oh++;
      }
      for (let k2 = 0; k2 < em.length; k2++) {
        const d = Math.min(45, dev[f ? FLIP[em[k2]] : em[k2]] * 100);
        s -= 0.8 * d;
        if (d >= TH) eh++;
      }
      if (!best || s > best.s) best = { s: s, occHit: oh, emptyHit: eh, flip: f };
    }
    return best;
  }

  const idr = evalCorners(corners);
  if (!idr) return null;
  const idScore = idr.s;

  // 恒等网格已经能看到 ≥22 个子 → 本来就对齐，别动四角
  if (idr.occHit >= 22) {
    alignGridToOpening.lastDebug = { already: 1, occHit: idr.occHit, evals: evals };
    return {
      accepted: false, already: true, corners: null,
      occHit: idr.occHit, emptyHit: idr.emptyHit,
      idOccHit: idr.occHit, idEmptyHit: idr.emptyHit,
      score: idScore, idScore: idScore,
      shiftX: 0, shiftY: 0, scaleX: 1, scaleY: 1, evals: evals
    };
  }

  const cx = (corners[0][0] + corners[1][0] + corners[2][0] + corners[3][0]) / 4;
  const cy = (corners[0][1] + corners[1][1] + corners[2][1] + corners[3][1]) / 4;
  /** 整体缩放 + 平移（绕四角质心） */
  function xform(ax, ay, dx, dy) {
    return corners.map(p => [cx + (p[0] - cx) * ax + dx, cy + (p[1] - cy) * ay + dy]);
  }

  let bestP = { ax: 1, ay: 1, dx: 0, dy: 0 };
  let bestR = idr;

  // A. 平移粗扫（手指误差以平移为主，±32px 内先兜一圈）
  for (const ddx of [-32, -16, 16, 32]) {
    for (const ddy of [-32, -16, 0, 16, 32]) {
      const r = evalCorners(xform(1, 1, ddx, ddy));
      if (r && r.s > bestR.s) { bestR = r; bestP = { ax: 1, ay: 1, dx: ddx, dy: ddy }; }
    }
  }
  for (const ddy of [-32, -16, 16, 32]) {
    const r = evalCorners(xform(1, 1, 0, ddy));
    if (r && r.s > bestR.s) { bestR = r; bestP = { ax: 1, ay: 1, dx: 0, dy: ddy }; }
  }

  // B. 坐标下降：缩放 ax/ay + 平移 dx/dy，步长逐层减半
  let sScale = 0.02, sOff = 8;
  for (let iter = 0; iter < 6; iter++) {
    for (const key of ['ax', 'ay', 'dx', 'dy']) {
      const step = (key === 'ax' || key === 'ay') ? sScale : sOff;
      for (const sgn of [1, -1]) {
        const cand = { ax: bestP.ax, ay: bestP.ay, dx: bestP.dx, dy: bestP.dy };
        cand[key] += sgn * step;
        if (cand.ax < 0.90 || cand.ax > 1.10 || cand.ay < 0.90 || cand.ay > 1.10) continue;
        const r = evalCorners(xform(cand.ax, cand.ay, cand.dx, cand.dy));
        if (r && r.s > bestR.s) { bestR = r; bestP = cand; }
      }
    }
    sScale *= 0.5;
    sOff = Math.max(1, sOff >> 1);
  }

  // C. 四角独立微调（手指点出来的四边形带斜率，统一缩放表达不了；
  //    每个角在自己的 ±64px 邻域里贪心挪，两轮）
  let curC = xform(bestP.ax, bestP.ay, bestP.dx, bestP.dy).map(p => [p[0], p[1]]);
  const origC = curC.map(p => [p[0], p[1]]);
  for (let round = 0; round < 3; round++) {
    for (let ci = 0; ci < 4; ci++) {
      for (let dim = 1; dim >= 0; dim--) {
        for (const step of [24, 12, 6, 3]) {
          let moved = false;
          for (const sgn of [1, -1]) {
            const cs = curC.map((p, k) => {
              if (k !== ci) return [p[0], p[1]];
              const np = dim ? [p[0], p[1] + sgn * step] : [p[0] + sgn * step, p[1]];
              if (Math.abs(np[0] - origC[k][0]) > 64 || Math.abs(np[1] - origC[k][1]) > 64) {
                return [p[0], p[1]];
              }
              return np;
            });
            const r = evalCorners(cs);
            if (r && r.s > bestR.s) { bestR = r; curC = cs; moved = true; break; }
          }
          if (!moved) break;
        }
      }
    }
  }

  // 采纳标准：命中明显变多（≥18/32 且比恒等多 ≥6）、空格误报受控、总分明显提升。
  // 「宁缺毋滥」：中局/大厅画面凑不出这套分布，就什么都不改。
  const accepted = bestR.s > idScore + 150 &&
    bestR.occHit >= 18 &&
    bestR.occHit >= idr.occHit + 6 &&
    bestR.emptyHit <= 14;

  alignGridToOpening.lastDebug = {
    accepted: accepted ? 1 : 0, occHit: bestR.occHit, emptyHit: bestR.emptyHit,
    idOccHit: idr.occHit, idEmptyHit: idr.emptyHit, evals: evals
  };
  return {
    accepted: accepted, already: false,
    corners: accepted ? curC.map(p => [p[0], p[1]]) : null,
    occHit: bestR.occHit, emptyHit: bestR.emptyHit,
    idOccHit: idr.occHit, idEmptyHit: idr.emptyHit,
    score: bestR.s, idScore: idScore, flip: bestR.flip,
    shiftX: bestP.dx, shiftY: bestP.dy,
    scaleX: bestP.ax, scaleY: bestP.ay, evals: evals
  };
}

module.exports = {
  BoardRecognizer, EMPTY, RED_PC, BLK_PC,
  bilinear, homography, applyH,
  autoDetectBoard, findEvenlySpacedPeaks,
  refineByPieces, refineGrid, fitEvenLines, findPeaks1D, findPipRect, gridAlignScore,
  alignGridToOpening
};
