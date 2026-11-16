//
//  JJMoveCodec.m
//  JJCheat
//

#import "JJMoveCodec.h"

/* ============================================================
 *  坐标换算：标准 ICCS（Pikafish） ↔ 内部 sq（engine.js）
 *
 *  内部:  sq = row*9+col, row0=黑底线(屏幕上), col0=屏幕左
 *  ICCS:  列 a..i = col, rank0 = 红底线(屏幕下) → rank = 9-row
 * ============================================================ */

/** ICCS 两位（如 "h2"）→ 内部 sq；非法返回 -1 */
static int JJSqFromTwo(unichar file, unichar rank) {
    int c = (int)file - 'a';
    int r = (int)rank - '0';
    if (c < 0 || c > 8 || r < 0 || r > 9) return -1;
    return (9 - r) * 9 + c;
}

int JJSqFromICCS(NSString *iccs, int idx) {
    if (iccs.length < 4) return -1;
    NSUInteger o = (NSUInteger)(idx * 2);
    return JJSqFromTwo([iccs characterAtIndex:o], [iccs characterAtIndex:o + 1]);
}

NSString *JJICCASToInternalUcci(NSString *iccs) {
    if (iccs.length < 4) return nil;
    int from = JJSqFromICCS(iccs, 0);
    int to = JJSqFromICCS(iccs, 1);
    if (from < 0 || to < 0) return nil;
    return [NSString stringWithFormat:@"%c%d%c%d",
            (char)('a' + from % 9), from / 9,
            (char)('a' + to % 9), to / 9];
}

NSString *JJInternalUcciToICCS(NSString *ucci) {
    if (ucci.length < 4) return nil;
    int fCol = (int)[ucci characterAtIndex:0] - 'a';
    int fRow = (int)[ucci characterAtIndex:1] - '0';
    int tCol = (int)[ucci characterAtIndex:2] - 'a';
    int tRow = (int)[ucci characterAtIndex:3] - '0';
    if (fCol < 0 || fCol > 8 || fRow < 0 || fRow > 9) return nil;
    if (tCol < 0 || tCol > 8 || tRow < 0 || tRow > 9) return nil;
    return [NSString stringWithFormat:@"%c%d%c%d",
            (char)('a' + fCol), 9 - fRow, (char)('a' + tCol), 9 - tRow];
}

/* ============================================================
 *  中文记谱 —— 移植自 engine.js cst/constants.js 的 mvToChinese，
 *  与 JS 侧「检测到走法」的中文口径保持一致。
 * ============================================================ */

static NSString *const kJJRedNames[]  = { @"", @"帅", @"仕", @"相", @"马", @"车", @"炮", @"兵" };
static NSString *const kJJBlackNames[] = { @"", @"将", @"士", @"象", @"马", @"车", @"炮", @"卒" };
/* 红方用汉字数字，黑方用全角数字（与 engine.js 相同） */
static NSString *const kJJRedNum[] = { @"", @"一", @"二", @"三", @"四", @"五", @"六", @"七", @"八", @"九" };
static NSString *const kJJBlackNum[] = { @"", @"１", @"２", @"３", @"４", @"５", @"６", @"７", @"８", @"９" };

/** FEN 棋盘部分 → 90 格兵种编码（0 空，1..7 红帅..红兵，8..14 黑将..黑卒）。
    第一个 rank 串 = 屏幕最上一行 = 内部 row 0。失败返回 nil。 */
static int8_t *JJBoardFromFen(NSString *boardFen) {
    if (!boardFen.length) return NULL;
    NSString *boardPart = [boardFen componentsSeparatedByString:@" "].firstObject;
    NSArray<NSString *> *lines = [boardPart componentsSeparatedByString:@"/"];
    if (lines.count != 10) return NULL;
    int8_t *board = calloc(90, 1);
    for (NSUInteger r = 0; r < 10; r++) {
        NSString *line = lines[r];
        int col = 0;
        for (NSUInteger k = 0; k < line.length; k++) {
            unichar ch = [line characterAtIndex:k];
            if (ch >= '1' && ch <= '9') { col += (int)(ch - '0'); continue; }
            if (col > 8) break;
            switch (ch) {
                case 'K': board[(int)r * 9 + col] = 1; break;
                case 'A': board[(int)r * 9 + col] = 2; break;
                case 'B': board[(int)r * 9 + col] = 3; break;
                case 'N': board[(int)r * 9 + col] = 4; break;
                case 'R': board[(int)r * 9 + col] = 5; break;
                case 'C': board[(int)r * 9 + col] = 6; break;
                case 'P': board[(int)r * 9 + col] = 7; break;
                case 'k': board[(int)r * 9 + col] = 8; break;
                case 'a': board[(int)r * 9 + col] = 9; break;
                case 'b': board[(int)r * 9 + col] = 10; break;
                case 'n': board[(int)r * 9 + col] = 11; break;
                case 'r': board[(int)r * 9 + col] = 12; break;
                case 'c': board[(int)r * 9 + col] = 13; break;
                case 'p': board[(int)r * 9 + col] = 14; break;
                default: free(board); return NULL;
            }
            col++;
        }
        if (col > 9) { free(board); return NULL; }
    }
    return board;
}

NSString *JJMoveChinese(NSString *boardFen, NSString *iccs) {
    int8_t *board = JJBoardFromFen(boardFen);
    if (!board) return iccs;

    /* 走子方：FEN 第 2 个字段 w=红 b=黑，缺省红 */
    NSArray *parts = [boardFen componentsSeparatedByString:@" "];
    BOOL isRed = (parts.count < 2) || ![parts[1] isEqualToString:@"b"];

    int from = JJSqFromICCS(iccs, 0);
    int to = JJSqFromICCS(iccs, 1);
    if (from < 0 || to < 0 || from > 89 || to > 89) { free(board); return iccs; }

    int pc = board[from];
    if (!pc) { free(board); return iccs; }
    /* 内部棋子编码与阵营：红 1..7 黑 8..14 —— 与 engine.js 相同 */
    int type = pc > 7 ? pc - 7 : pc;
    BOOL isRedPiece = pc <= 7;

    int fr = from / 9, fc = from % 9;
    int tr = to / 9, tc = to % 9;

    NSString *const *names = isRedPiece ? kJJRedNames : kJJBlackNames;
    NSString *const *nums = isRedPiece ? kJJRedNum : kJJBlackNum;
    /* 红方从右往左数 1..9（col8=一），黑方从左往右数（col0=一） */
    int (^fileOf)(int) = ^int(int col) { return isRedPiece ? 9 - col : col + 1; };

    /* 同列同名棋子 → 前/中/后 */
    NSMutableIndexSet *sameFile = [NSMutableIndexSet indexSet];
    for (int sq = 0; sq < 90; sq++) {
        if (board[sq] == pc && (sq % 9) == fc) [sameFile addIndex:sq];
    }
    NSString *head = nil;
    if (sameFile.count == 2) {
        /* 靠近对方的一侧为「前」。红方 row 小者在前（朝黑方），黑方 row 大者在前 */
        int a = (int)[sameFile firstIndex], b = (int)[sameFile lastIndex];
        int frontSq = isRedPiece ? MIN(a, b) : MAX(a, b);
        head = [NSString stringWithFormat:@"%@%@",
                (from == frontSq ? @"前" : @"后"), names[type]];
    } else if (sameFile.count > 2) {
        /* 按行排序：红方 row 升序（row 小=靠前），黑方 row 降序 */
        NSMutableArray *arr = [NSMutableArray array];
        for (NSUInteger i = [sameFile firstIndex]; i != NSNotFound; i = [sameFile indexGreaterThanIndex:i]) {
            [arr addObject:@(i)];
        }
        [arr sortUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
            int rx = x.intValue / 9, ry = y.intValue / 9;
            return isRedPiece ? (rx < ry ? NSOrderedAscending : NSOrderedDescending)
                              : (rx > ry ? NSOrderedAscending : NSOrderedDescending);
        }];
        NSUInteger idx = [arr indexOfObject:@(from)];
        if (idx == NSNotFound) idx = 0;
        NSString *prefix;
        if (arr.count == 3) {
            prefix = (idx == 0) ? @"前" : (idx == 1) ? @"中" : @"后";
        } else {
            prefix = (idx == 0) ? @"前" : @"后";
        }
        head = [NSString stringWithFormat:@"%@%@", prefix, names[type]];
    } else {
        head = [NSString stringWithFormat:@"%@%@", names[type], nums[fileOf(fc)]];
    }

    NSString *out;
    if (fr == tr) {
        /* 横走 = 平 */
        out = [NSString stringWithFormat:@"%@平%@", head, nums[fileOf(tc)]];
    } else if (fc == tc) {
        /* 纵走 = 进/退 */
        BOOL isAdvance = isRedPiece ? (tr < fr) : (tr > fr);
        out = [NSString stringWithFormat:@"%@%@%@",
                head, (isAdvance ? @"进" : @"退"), nums[ABS(tr - fr)]];
    } else {
        BOOL isAdvance = isRedPiece ? (tr < fr) : (tr > fr);
        out = [NSString stringWithFormat:@"%@%@%@",
                head, (isAdvance ? @"进" : @"退"), nums[fileOf(tc)]];
    }
    free(board);
    return out;
}
