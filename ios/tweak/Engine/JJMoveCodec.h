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

/** 标准 ICCS "h2e2" → 内部 ucci "h7e7"（rank 逐位翻转）。非法返回 nil。 */
NSString *JJICCASToInternalUcci(NSString *iccs);

/** 内部 ucci "h7e7" → 标准 ICCS "h2e2"。非法返回 nil。 */
NSString *JJInternalUcciToICCS(NSString *ucci);

/** 中文记谱（「炮二平五」）。
    boardFen = 棋盘部分或完整 FEN（10 行斜杠分隔，第 1 行 = 屏幕最上）。
    iccs = 标准 ICCS 一步。走子方从 FEN 的 w/b 字段读；缺省按红方。
    解析失败返回 ICCS 原串。逻辑移植自 engine.js 的 cst/constants.js mvToChinese，
    保持两端口径一致（回归里有对照断言）。 */
NSString *JJMoveChinese(NSString *boardFen, NSString *iccs);

NS_ASSUME_NONNULL_END
