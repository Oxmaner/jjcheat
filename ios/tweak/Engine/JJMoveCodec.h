//
//  JJMoveCodec.h
//  JJCheat —— 坐标换算 + 中文记谱（2.1.0 新增）
//
//  2.1.0 起棋力来自独立进程 Pikafish，识别仍在 engine.js。
//  两套坐标系必须在这里换算，绝不能散落各处：
//
//    内部 sq（engine.js constants.js）：sq = row*9 + col
//      row 0 = 黑方底线（屏幕最上）  row 9 = 红方底线（屏幕最下）
//      引擎自己的 ucci 串（sqToUcci）= 列字母 + row 数字，如 "h7e7"
//      （红炮在 row 7 —— 注意这不是标准 ICCS！）
//
//    标准 ICCS（Pikafish / 所有象棋界面）：
//      列 a..i 与内部 col 一致（红方视角左→右）
//      rank 0 = 红方底线（屏幕最下） → rank = 9 - row
//      红炮二平五 = "h2e2"（同一着在内部 ucci 里是 "h7e7"）
//
//  FEN 两侧逐字一致（黑底线在最前），本文件不做 FEN 翻译。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** 标准 ICCS 一步（如 "h2e2"）→ 内部 from/to sq（-1 非法）。
    idx: 0 = 起点, 1 = 终点。 */
int JJSqFromICCS(NSString *iccs, int idx);

/** 内部 sq → 屏幕 sq（旋转 180°）：sq' = (9 - row) * 9 + (8 - col)。
 *
 *  【为什么必须有这个函数】这是「我方执黑时箭头指向对角」的唯一修法。
 *
 *  引擎坐标（本文件的内部 sq / ICCS 换算结果）永远是「红在下」；
 *  而屏幕坐标（JJCalibrator.gridPts）的 row 0 是用户点按的顶边。
 *  我方执黑时用户在屏幕上看的是翻转后的盘面：
 *
 *      recognizer 读到的屏幕 90 格
 *          → flipCodes() 旋转 180° 　→ 引擎坐标（组 FEN 用）
 *          → 引擎算出 bestmove（ICCS）
 *          → JJSqFromICCS() 得到**引擎坐标**的 from/to
 *
 *  但画箭头时用的是 gridPts（**屏幕坐标**），中间少了反方向的旋转，
 *  于是行和列同时反向 → 箭头指向棋盘对角。
 *  注意必须是 180° 旋转（行列都反），不是上下翻转：
 *  九宫左右对称，只翻行的话合法性检查发现不了，但整盘列全错。
 *
 *  用法：`if (flipped) sq = JJSqRotate180(sq);` 再取 gridPts[sq]。
 *  同一个函数正反都能用（旋转 180° 两次等于不变），不要另写逆变换，
 *  否则两处实现迟早分叉 —— 这正是这次 bug 的成因。 */
int JJSqRotate180(int sq);

/** 上下翻转（行镜像，列不变）。引擎坐标 ↔ 屏幕坐标只差这一次翻转。
    ★ 不要用 JJSqRotate180 代替它 —— 180° 会连列一起镜像，箭头会指到对角。 */
int JJSqFlipVertical(int sq);

/** 取 FEN（屏幕序，红在上）某一格的兵种编码：0=空，1..7 红，8..14 黑，-1=解析失败。 */
int JJPieceAtFen(NSString *fen, int sq);

/** 中文记谱（「炮二平五」）。
    boardFen = 棋盘部分或完整 FEN（10 行斜杠分隔，第 1 行 = 屏幕最上）。
    iccs = 标准 ICCS 一步。走子方从 FEN 的 w/b 字段读；缺省按红方。
    解析失败返回 ICCS 原串。逻辑移植自 engine.js 的 cst/constants.js mvToChinese，
    保持两端口径一致（回归里有对照断言）。 */
NSString *JJMoveChinese(NSString *boardFen, NSString *iccs);

/** 同上，但显式指定传入 FEN 的朝向（2.0.0r19）。
    fenRedAtBottom=NO：FEN 红在上（anchorFen / lastMoveFenBefore，与屏幕一致）
    fenRedAtBottom=YES：FEN 红在下（searchFen，喂给 Pikafish 的那份）
    JJSqFromICCS 返回引擎坐标（红在下），不区分朝向会让红黑、路数全部对调。 */
NSString *JJMoveChineseEx(NSString *boardFen, NSString *iccs, BOOL fenRedAtBottom);

NS_ASSUME_NONNULL_END
