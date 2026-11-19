//
//  JJHUDWindow.m
//  JJCheat
//
//  2.1.0 布局（顶部一条 56pt 面板）：
//    ① 记谱行   炮二平五                         +0.35
//    ② 状态行   引擎 就绪 · 深 18 · 1.2M · 胜率 62% ██████░░░░
//

#import "JJHUDWindow.h"
#import "JJConfig.h"
#import "JJCopy.h"
#import <math.h>

/* ============================================================
 *  绘制视图（棋盘网格 + 走法箭头 + 标定覆盖层）
 * ============================================================ */
@interface JJHUDView : UIView
@property (nonatomic, assign) NSInteger fromSq;      // -1 = 无
@property (nonatomic, assign) NSInteger toSq;
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *gridPts; // 屏幕像素
@property (nonatomic, strong) NSArray<NSValue *> *calibPoints;         // point

@property (nonatomic, assign) JJHUDMode mode;
@end

@implementation JJHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        _fromSq = -1;
        _toSq = -1;
        _calibPoints = @[];
    }
    return self;
}

- (void)setMode:(JJHUDMode)mode {
    _mode = mode;
    self.userInteractionEnabled = (mode == JJHUDModeCalibrate);
    [self setNeedsDisplay];
}

/* 屏幕像素 -> 视图 point */
- (CGPoint)pointFromPixel:(CGPoint)px {
    CGSize pb = self.bounds.size;
    CGSize pix = [UIScreen mainScreen].nativeBounds.size;
    if (pix.width <= 0 || pix.height <= 0) return px;
    return CGPointMake(px.x * pb.width / pix.width, px.y * pb.height / pix.height);
}

- (void)drawArrowInContext:(CGContextRef)ctx from:(CGPoint)a to:(CGPoint)b {
    CGFloat dx = b.x - a.x, dy = b.y - a.y;
    CGFloat len = hypot(dx, dy);
    if (len < 4) return;
    CGFloat ang = atan2(dy, dx);
    CGFloat head = MIN(30.0, MAX(16.0, len * 0.30));

    CGContextSaveGState(ctx);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    // 外发光
    CGContextSetStrokeColorWithColor(ctx, [[UIColor blackColor] colorWithAlphaComponent:0.35].CGColor);
    CGContextSetLineWidth(ctx, JJ_ARROW_WIDTH + 5.0);
    CGContextMoveToPoint(ctx, a.x, a.y);
    CGContextAddLineToPoint(ctx, b.x - cosf(ang) * head * 0.85, b.y - sinf(ang) * head * 0.85);
    CGContextStrokePath(ctx);

    // 主线
    CGContextSetStrokeColorWithColor(ctx, JJ_COLOR_ARROW.CGColor);
    CGContextSetLineWidth(ctx, JJ_ARROW_WIDTH);
    CGContextMoveToPoint(ctx, a.x, a.y);
    CGContextAddLineToPoint(ctx, b.x - cosf(ang) * head * 0.85, b.y - sinf(ang) * head * 0.85);
    CGContextStrokePath(ctx);

    // 箭头三角
    CGPoint p2 = CGPointMake(b.x - cosf(ang - 0.42f) * head, b.y - sinf(ang - 0.42f) * head);
    CGPoint p3 = CGPointMake(b.x - cosf(ang + 0.42f) * head, b.y - sinf(ang + 0.42f) * head);
    CGContextSetFillColorWithColor(ctx, JJ_COLOR_ARROW_HEAD.CGColor);
    CGContextMoveToPoint(ctx, b.x, b.y);
    CGContextAddLineToPoint(ctx, p2.x, p2.y);
    CGContextAddLineToPoint(ctx, p3.x, p3.y);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    CGContextRestoreGState(ctx);
}

/* 2.1.91：**只描边、不填充**，线宽 2。
   原因：游戏会在「最后走的那颗棋子」外面画一圈**白色高亮光圈**，
   那是识别侧判断「对方刚走了哪一步」的主要依据（见 recognizer.sampleRing）。
   原来这里画 r=20 的半透明填充圆，正好把那圈白光糊住 —— 等于自己把
   最关键的信息盖掉了，识别侧只能看到"没有标记"，于是永远等不到对方走子。
   描边圆不挡中心、也不挡外圈，双方都够用。 */
- (void)drawRingAt:(CGPoint)p radius:(CGFloat)r color:(UIColor *)color {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(p.x - r, p.y - r, r * 2, r * 2));
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // ---- 标定模式 ----
    if (self.mode == JJHUDModeCalibrate) {
        CGContextSetFillColorWithColor(ctx, [[UIColor blackColor] colorWithAlphaComponent:0.45].CGColor);
        CGContextFillRect(ctx, self.bounds);

        // 已点的角
        NSArray *names = @[@"左上", @"右上", @"右下", @"左下"];
        for (NSUInteger i = 0; i < self.calibPoints.count; i++) {
            CGPoint p = [self.calibPoints[i] CGPointValue];
            [[UIColor colorWithRed:0.1 green:1.0 blue:0.5 alpha:1.0] set];
            CGContextFillEllipseInRect(ctx, CGRectMake(p.x - 12, p.y - 12, 24, 24));
            NSString *t = names[i];
            [t drawAtPoint:CGPointMake(p.x + 16, p.y - 10)
                withAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:15],
                                  NSForegroundColorAttributeName: [UIColor colorWithRed:0.1 green:1.0 blue:0.5 alpha:1.0] }];
        }
        /* ★ 2.1.105：连线必须画**全部**已点，而不是只连前两个。
           原来这里写死 calibPoints[0] → calibPoints[1]，点第 3、4 个角时
           屏幕上根本没有线接上去，主观感受就是「四点连线不能用」。 */
        if (self.calibPoints.count >= 2) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.1 green:1.0 blue:0.5 alpha:0.9].CGColor);
            CGContextSetLineWidth(ctx, 2);
            CGPoint a = [self.calibPoints[0] CGPointValue];
            CGContextMoveToPoint(ctx, a.x, a.y);
            for (NSUInteger i = 1; i < self.calibPoints.count; i++) {
                CGPoint q = [self.calibPoints[i] CGPointValue];
                CGContextAddLineToPoint(ctx, q.x, q.y);
            }
            /* 四点齐了就把首尾连上，形成闭合四边形 */
            if (self.calibPoints.count == 4) CGContextClosePath(ctx);
            CGContextStrokePath(ctx);
        }

        /* ★ 2.1.105：点满四点后**立刻画出完整的 9 列 × 10 行网格预览**
           （与上游 pikayu-jj 的交互一致：点完就能看出准不准，不必等学习）。
           这里用的是与 JJCalibrator 完全相同的双线性插值，只是坐标系是 point。 */
        if (self.calibPoints.count == 4) {
            CGPoint c0 = [self.calibPoints[0] CGPointValue];
            CGPoint c1 = [self.calibPoints[1] CGPointValue];
            CGPoint c2 = [self.calibPoints[2] CGPointValue];
            CGPoint c3 = [self.calibPoints[3] CGPointValue];
            /* u 沿列(0..8)，v 沿行(0..9)：左上→右上→右下→左下 */
            CGMutablePathRef gp = CGPathCreateMutable();
            for (int r = 0; r <= 9; r++) {
                CGFloat v = (CGFloat)r / 9.0;
                for (int c = 0; c <= 8; c++) {
                    CGFloat u = (CGFloat)c / 8.0;
                    CGFloat x = (1-u)*(1-v)*c0.x + u*(1-v)*c1.x + u*v*c2.x + (1-u)*v*c3.x;
                    CGFloat y = (1-u)*(1-v)*c0.y + u*(1-v)*c1.y + u*v*c2.y + (1-u)*v*c3.y;
                    if (c == 0) CGPathMoveToPoint(gp, NULL, x, y);
                    else CGPathAddLineToPoint(gp, NULL, x, y);
                }
            }
            for (int c = 0; c <= 8; c++) {
                CGFloat u = (CGFloat)c / 8.0;
                for (int r = 0; r <= 9; r++) {
                    CGFloat v = (CGFloat)r / 9.0;
                    CGFloat x = (1-u)*(1-v)*c0.x + u*(1-v)*c1.x + u*v*c2.x + (1-u)*v*c3.x;
                    CGFloat y = (1-u)*(1-v)*c0.y + u*(1-v)*c1.y + u*v*c2.y + (1-u)*v*c3.y;
                    if (r == 0) CGPathMoveToPoint(gp, NULL, x, y);
                    else CGPathAddLineToPoint(gp, NULL, x, y);
                }
            }
            CGContextAddPath(ctx, gp);
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.25 green:0.78 blue:1.00 alpha:0.95].CGColor);
            CGContextSetLineWidth(ctx, 1.0);
            CGContextStrokePath(ctx);
            CGPathRelease(gp);
        }
        // 提示
        NSUInteger step = self.calibPoints.count;
        NSString *tip = step < 4
            ? [NSString stringWithFormat:@"点第 %lu 个角：%@（棋盘最外圈的交叉点）",
                                         (unsigned long)(step + 1), names[step]]
            : @"标定完成";
        NSDictionary *attr = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:17],
                                NSForegroundColorAttributeName: [UIColor whiteColor] };
        CGSize sz = [tip sizeWithAttributes:attr];
        CGRect box = CGRectMake((self.bounds.size.width - sz.width) / 2 - 14, 90,
                                sz.width + 28, sz.height + 20);
        [[UIColor colorWithRed:0 green:0 blue:0 alpha:0.75] set];
        UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:10];
        [bp fill];
        [tip drawAtPoint:CGPointMake(box.origin.x + 14, box.origin.y + 10) withAttributes:attr];
        return;
    }

    // ---- 正常显示模式 ----
    if (self.gridPts.count == 90) {
        // 连接 90 个交叉点画一遍棋盘格，让用户确认标定没错
        CGContextSetStrokeColorWithColor(ctx, JJ_COLOR_BOARD_LINE.CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        for (int r = 0; r < 10; r++) {
            CGPoint prev = [self pointFromPixel:CGPointMake([self.gridPts[r * 9][0] doubleValue],
                                                           [self.gridPts[r * 9][1] doubleValue])];
            for (int c = 1; c < 9; c++) {
                CGPoint cur = [self pointFromPixel:CGPointMake([self.gridPts[r * 9 + c][0] doubleValue],
                                                              [self.gridPts[r * 9 + c][1] doubleValue])];
                CGContextMoveToPoint(ctx, prev.x, prev.y);
                CGContextAddLineToPoint(ctx, cur.x, cur.y);
                prev = cur;
            }
        }
        for (int c = 0; c < 9; c++) {
            CGPoint prev = [self pointFromPixel:CGPointMake([self.gridPts[c][0] doubleValue],
                                                           [self.gridPts[c][1] doubleValue])];
            for (int r = 1; r < 10; r++) {
                CGPoint cur = [self pointFromPixel:CGPointMake([self.gridPts[r * 9 + c][0] doubleValue],
                                                              [self.gridPts[r * 9 + c][1] doubleValue])];
                CGContextMoveToPoint(ctx, prev.x, prev.y);
                CGContextAddLineToPoint(ctx, cur.x, cur.y);
                prev = cur;
            }
        }
        CGContextStrokePath(ctx);
    }

    // 建议走法
    if (self.gridPts.count == 90 && self.fromSq >= 0 && self.toSq >= 0 &&
        self.fromSq < 90 && self.toSq < 90) {
        CGPoint a = [self pointFromPixel:CGPointMake([self.gridPts[self.fromSq][0] doubleValue],
                                                     [self.gridPts[self.fromSq][1] doubleValue])];
        CGPoint b = [self pointFromPixel:CGPointMake([self.gridPts[self.toSq][0] doubleValue],
                                                     [self.gridPts[self.toSq][1] doubleValue])];
        [self drawRingAt:a radius:20 color:JJ_COLOR_ARROW];
        [self drawRingAt:b radius:20 color:JJ_COLOR_ARROW_HEAD];
        [self drawArrowInContext:ctx from:a to:b];
    }
}

@end

/* ============================================================
 *  窗口
 * ============================================================ */
@interface JJHUDWindow () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) JJHUDView *hudView;
@property (nonatomic, strong) UIView *topPanel;
@property (nonatomic, strong) UILabel *lineMain;      // 中文记谱 / 状态
@property (nonatomic, strong) UILabel *lineScore;     // 右侧分值
@property (nonatomic, strong) UILabel *lineSub;       // 引擎状态 + 深度 + 胜率条
@property (nonatomic, copy) void (^calibBlock)(NSArray<NSValue *> *);
@property (nonatomic, strong) NSMutableArray<NSValue *> *calibPoints;
/* 2.1.105：标定手势复用（原来每次进标定都 addGestureRecognizer 且从不解绑，
   第二次标定时一次点击会同时触发两个手势、一下加两个点，直接错乱） */
@property (nonatomic, strong) UITapGestureRecognizer *calibTap;
/* 2.1.105：撤销 / 重来 */
@property (nonatomic, strong) UIButton *calibUndoBtn;
@property (nonatomic, strong) UIButton *calibResetBtn;
/** 上一次 showResult 的内容指纹；相同就跳过整轮文本排版 + 90 格重绘 */
@property (nonatomic, copy) NSString *lastResultKey;
@end

@implementation JJHUDWindow

+ (instancetype)shared {
    static JJHUDWindow *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[JJHUDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    });
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1000.0;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.rootViewController = [[UIViewController alloc] init];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        _hudView = [[JJHUDView alloc] initWithFrame:self.bounds];
        _hudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.rootViewController.view addSubview:_hudView];

        // 顶部信息面板
        CGFloat panelW = self.bounds.size.width - 16.0;
        // 真正的位置在 layoutTopPanel 里按安全区算，这里的 8 只是初值
        _topPanel = [[UIView alloc] initWithFrame:CGRectMake(8, 8, panelW, JJ_HUD_TOP_HEIGHT)];
        _topPanel.backgroundColor = JJ_COLOR_PANEL_BG;
        _topPanel.layer.cornerRadius = 10;
        _topPanel.layer.masksToBounds = YES;
        _topPanel.userInteractionEnabled = NO;
        [self.rootViewController.view addSubview:_topPanel];

        CGFloat scoreW = 96.0;
        _lineMain = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, panelW - 24 - scoreW - 6, 26)];
        _lineMain.font = [UIFont boldSystemFontOfSize:19];
        _lineMain.textColor = JJ_COLOR_TEXT_MAIN;
        _lineMain.adjustsFontSizeToFitWidth = YES;
        _lineMain.minimumScaleFactor = 0.75;
        [_topPanel addSubview:_lineMain];

        _lineScore = [[UILabel alloc] initWithFrame:CGRectMake(panelW - 12 - scoreW, 6, scoreW, 26)];
        _lineScore.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightBold];
        _lineScore.textColor = JJ_COLOR_TEXT_MAIN;
        _lineScore.textAlignment = NSTextAlignmentRight;
        _lineScore.adjustsFontSizeToFitWidth = YES;
        _lineScore.minimumScaleFactor = 0.7;
        [_topPanel addSubview:_lineScore];

        _lineSub = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, panelW - 24, 18)];
        _lineSub.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        _lineSub.textColor = JJ_COLOR_TEXT_SUB;
        _lineSub.adjustsFontSizeToFitWidth = YES;
        _lineSub.minimumScaleFactor = 0.75;
        [_topPanel addSubview:_lineSub];

        _topPanel.hidden = YES;
        _calibPoints = [NSMutableArray array];
        [self layoutTopPanel];
    }
    return self;
}

/**
 顶部面板贴安全区下沿。
 iPhone 14 Pro Max 的顶部安全区约 59pt（灵动岛），原来固定 y=8 会被整块盖住；
 这里按 safeAreaInsets 动态下移，老机型（20pt）也不会顶进状态栏。
 面板高度不变，只挪位置，不改布局逻辑。
 */
- (void)layoutTopPanel {
    if (!_topPanel) return;
    CGFloat safeTop = self.safeAreaInsets.top;
    if (safeTop < 20.0) safeTop = 20.0;
    CGFloat panelW = self.bounds.size.width - 16.0;
    if (panelW < 200.0) panelW = 200.0;
    _topPanel.frame = CGRectMake(8, safeTop + 4.0, panelW, JJ_HUD_TOP_HEIGHT);

    CGFloat scoreW = 96.0;
    _lineMain.frame = CGRectMake(12, 6, panelW - 24 - scoreW - 6, 26);
    _lineScore.frame = CGRectMake(panelW - 12 - scoreW, 6, scoreW, 26);
    _lineSub.frame = CGRectMake(12, 32, panelW - 24, 18);
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self layoutTopPanel];
}

- (void)attach {
    /* 部署下限 iOS 14.0，connectedScenes 必然存在，无需 @available 门控 */
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            sc.activationState == UISceneActivationStateForegroundActive) {
            self.windowScene = (UIWindowScene *)sc;
            break;
        }
    }
    self.frame = [UIScreen mainScreen].bounds;
    // 只用 hidden=NO 显示，不调 makeKeyAndVisible ——
    // 抢 key window 会把 JJ象棋 的触摸吃掉。
    self.hidden = NO;
    // windowScene 定下来之后 safeAreaInsets 才准，这里再摆一次面板
    [self layoutTopPanel];
}

- (void)setMode:(JJHUDMode)mode {
    _mode = mode;
    self.hudView.mode = mode;
    self.lastResultKey = nil;   // 切模式后下一帧结果必须重绘
    if (mode == JJHUDModeCalibrate) {
        self.hudView.calibPoints = @[];
        [self.calibPoints removeAllObjects];
        self.topPanel.hidden = YES;
    }
    [self.hudView setNeedsDisplay];
}

- (void)invalidateResultCache {
    self.lastResultKey = nil;
}

/* 胜率条：用方块直观显示，0..10 格 */
static NSString *JJWinrateBar(NSInteger wr) {
    NSInteger filled = (NSInteger)lround(MAX(0, MIN(100, wr)) / 10.0);
    NSMutableString *bar = [NSMutableString stringWithCapacity:10];
    for (NSInteger i = 0; i < 10; i++) [bar appendString:(i < filled ? @"█" : @"░")];
    return bar;
}

/* 节点数：1234567 -> 1.2M，方便塞进一行 */
static NSString *JJFormatNodes(NSInteger nodes) {
    if (nodes <= 0) return @"-";
    if (nodes >= 1000000) return [NSString stringWithFormat:@"%.1fM", nodes / 1000000.0];
    if (nodes >= 1000) return [NSString stringWithFormat:@"%.0fK", nodes / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)nodes];
}

- (void)showResult:(NSDictionary *)result
        gridPoints:(NSArray<NSArray<NSNumber *> *> *)points
               fen:(NSString *)fen {
    if (self.mode != JJHUDModeDisplay) return;

    /* 真机 process 每 1~2s 一轮，绝大多数帧结论完全相同。
       内容指纹没变就直接返回，省掉文本排版与 90 格网格重绘。 */
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@",
                     result[@"suggest"] ?: @"", result[@"from"] ?: @"",
                     result[@"to"] ?: @"", result[@"scoreText"] ?: @"",
                     result[@"depth"] ?: @"", result[@"nodes"] ?: @"",
                     result[@"sideToMove"] ?: @"", fen ?: @"",
                     result[@"waitingOpponent"] ?: @"", result[@"ply"] ?: @"",
                     result[@"skipAnalyze"] ?: @"", result[@"engineState"] ?: @"",
                     result[@"enginePending"] ?: @""];
    /* ★★ 2.1.100：网格坐标必须在「结果去重」之前更新。
     *
     * 原来这两行在上面那个 early-return 之后，而 key 只由分数/PV/深度这类
     * **结果字段**拼成，不含网格坐标。后果：自动标定完成后 gridPts 变了，
     * 但下一帧 result 内容没变 → key 相同 → 提前 return → gridPts 永远传不进去
     * → 网格画不出来。真机现象就是 HUD 明明提示"几何标定完成・网格已对齐"，
     * 屏幕上却一根网格线都没有（用像素扫描确认：除菜单图标外 0 个青色像素）。
     *
     * 网格是「几何状态」，与「分析结果」的去重无关，必须每次都同步。
     */
    /* 网格坐标变了就要**立刻重绘** —— 末尾那句 setNeedsDisplay 同样在这个
       early-return 之下，只提前赋值而不重绘的话，画面依旧看不到网格。
       只在真的变化时重绘，避免每帧无谓刷新。 */
    if (![self.hudView.gridPts isEqualToArray:(points ?: @[])]) {
        self.hudView.gridPts = points;
        [self.hudView setNeedsDisplay];
    }

    if ([key isEqualToString:self.lastResultKey] && !self.topPanel.hidden) return;
    self.lastResultKey = key;

    /* JJ 象棋红方先行。我方执黑时开局第一手归对方，
       轮到对方就不画箭头、不显示建议，避免「乱指挥」。 */
    BOOL waiting = [result[@"waitingOpponent"] boolValue];
    /* 盘面不可信时明确告诉用户怎么自救，别只显示「等待对方走子…」 */
    BOOL stalled = [result[@"skipAnalyze"] boolValue];
    BOOL pending = [result[@"enginePending"] boolValue];
    NSNumber *from = result[@"from"];
    NSNumber *to = result[@"to"];
    BOOL hasMove = !waiting && !stalled &&
        (from && to && from.integerValue >= 0 && to.integerValue >= 0 &&
         from.integerValue < 90 && to.integerValue < 90);
    self.hudView.fromSq = hasMove ? from.integerValue : -1;
    self.hudView.toSq = hasMove ? to.integerValue : -1;

    NSString *cn = result[@"suggestChinese"] ?: @"";
    NSString *scoreText = result[@"scoreText"] ?: @"";
    NSNumber *winrate = result[@"winrate"] ?: @(-1);
    NSNumber *depth = result[@"depth"] ?: @(0);
    NSNumber *nodes = result[@"nodes"] ?: @(0);
    NSString *side = [result[@"sideToMove"] isEqual:@"black"] ? @"黑方" : @"红方";
    NSString *engine = result[@"engineState"] ?: @"";
    if (!engine.length) engine = pending ? @"思考中" : @"-";
    NSString *blocked = result[@"engineBlocked"] ?: @"";

    // ---- 第一行：记谱 + 分值 ----
    if (stalled) {
        self.lineMain.text = @"识别未收敛 · 请点「重来」回开局";
        self.lineScore.text = @"";
    } else if (waiting) {
        self.lineMain.text = hasMove ? cn : @"等待对方走子（红先黑后）";
        self.lineScore.text = scoreText;
    } else if (hasMove) {
        self.lineMain.text = cn;
        self.lineScore.text = scoreText;
    } else if (pending) {
        self.lineMain.text = @"引擎思考中…";
        self.lineScore.text = @"";
    } else if (blocked.length) {
        /* 引擎自己拒绝了本次搜索（网络没加载上 / 引擎异常），或识别侧主动拦下
           （王将不唯一）。这时说「视角未对齐」是误导 —— 原因很具体，直接说。 */
        self.lineMain.text = [blocked hasPrefix:@"引擎"]
            ? [NSString stringWithFormat:@"%@ · 点球看⑥详情", blocked]
            : blocked;
        self.lineScore.text = @"";
    } else {
        self.lineMain.text = @"视角未对齐 · 请回开局画面";
        self.lineScore.text = @"";
    }

    // ---- 第二行：引擎状态 + 深度 + 节点 + 胜率 ----
    NSMutableString *sub = [NSMutableString stringWithFormat:@"%@ · 引擎 %@", side, engine];
    if (depth.integerValue > 0) [sub appendFormat:@" · 深 %ld", (long)depth.integerValue];
    if (nodes.integerValue > 0) [sub appendFormat:@" · %@", JJFormatNodes(nodes.integerValue)];
    if (winrate.integerValue >= 0) {
        [sub appendFormat:@" · %ld%% %@", (long)winrate.integerValue,
                          JJWinrateBar(winrate.integerValue)];
    } else if (pending) {
        [sub appendString:@" · 正在搜索"];
    }
    /* 2.1.88 诊断：第二行末尾附上「ply / 变化格数 / 锚盘拒绝数」三个小字。
       真机没有 log 命令，这几个数能直接看出轮次有没有推进、锚盘有没有卡住。
       正常盘面下它们很安静，不影响阅读。 */
    {
        id ply = result[@"ply"], d = result[@"diffChanged"], rej = result[@"anchorRejected"];
        if (ply != nil) {
            [sub appendFormat:@" │ p%@ d%@ r%@", ply ?: @"-", d ?: @"-", rej ?: @"-"];
        }
    }
    self.lineSub.text = sub;

    if (self.topPanel.hidden) [self layoutTopPanel];   // 首次显示时保险再摆一次
    self.topPanel.hidden = NO;
    [self.hudView setNeedsDisplay];
}

- (void)showStatus:(NSString *)text {
    self.lastResultKey = nil;   // 状态条被改写，下次结果不能因指纹相同被跳过
    self.lineMain.text = text;
    self.lineScore.text = @"";
    self.lineSub.text = @"";
    if (self.topPanel.hidden) [self layoutTopPanel];
    self.topPanel.hidden = NO;
}

- (void)setHUDHidden:(BOOL)hidden {
    self.hidden = hidden;
    if (!hidden) self.lastResultKey = nil;
}

#pragma mark - 触摸（标定）

- (void)applyGridPoints:(NSArray<NSArray<NSNumber *> *> *)pts {
    if (pts.count != 90) return;
    self.hudView.gridPts = pts;
    [self.hudView setNeedsDisplay];
}

- (void)beginCalibrationWithCompletion:(void (^)(NSArray<NSValue *> *))completion {
    self.calibBlock = completion;
    self.mode = JJHUDModeCalibrate;
    self.hidden = NO;

    /* ★ 2.1.105：手势**只创建一次并复用**。
       原来每次 beginCalibration 都新建一个 addGestureRecognizer，而从不移除；
       第二次标定时一次点击会被两个手势各采一个点 → 点两下就凑满 4 个点提前结束，
       且坐标顺序错乱。这是「重标之后更不准」的直接原因。 */
    if (!self.calibTap) {
        self.calibTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCalibTap:)];
        self.calibTap.delegate = self;
        [self.hudView addGestureRecognizer:self.calibTap];
    }
    self.calibTap.enabled = YES;

    /* 撤销 / 重来：放在屏幕底部中央，避开棋盘主体 */
    CGFloat by = CGRectGetHeight(self.bounds) - 92;
    if (!self.calibUndoBtn) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(CGRectGetMidX(self.bounds) - 130, by, 110, 44);
        [b setTitle:@"撤销上一点" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithRed:0.20 green:0.45 blue:0.85 alpha:0.92];
        b.layer.cornerRadius = 10;
        [b addTarget:self action:@selector(calibUndo) forControlEvents:UIControlEventTouchUpInside];
        [self.hudView addSubview:b];
        self.calibUndoBtn = b;
    }
    if (!self.calibResetBtn) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(CGRectGetMidX(self.bounds) + 20, by, 110, 44);
        [b setTitle:@"重来" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithRed:0.75 green:0.25 blue:0.25 alpha:0.92];
        b.layer.cornerRadius = 10;
        [b addTarget:self action:@selector(calibReset) forControlEvents:UIControlEventTouchUpInside];
        [self.hudView addSubview:b];
        self.calibResetBtn = b;
    }
    self.calibUndoBtn.hidden = NO;
    self.calibResetBtn.hidden = NO;
}

/** 撤销最后一个点 */
- (void)calibUndo {
    if (self.mode != JJHUDModeCalibrate) return;
    if (self.calibPoints.count == 0) return;
    NSMutableArray *m = [self.calibPoints mutableCopy];
    [m removeLastObject];
    self.calibPoints = [m copy];
    self.hudView.calibPoints = self.calibPoints;
    [self.hudView setNeedsDisplay];
}

/** 全部重来 */
- (void)calibReset {
    if (self.mode != JJHUDModeCalibrate) return;
    [self.calibPoints removeAllObjects];
    self.hudView.calibPoints = @[];
    [self.hudView setNeedsDisplay];
}

- (void)handleCalibTap:(UITapGestureRecognizer *)g {
    if (self.mode != JJHUDModeCalibrate) return;
    CGPoint p = [g locationInView:self.hudView];
    [self.calibPoints addObject:[NSValue valueWithCGPoint:p]];
    self.hudView.calibPoints = [self.calibPoints copy];
    [self.hudView setNeedsDisplay];

    if (self.calibPoints.count >= 4) {
        self.mode = JJHUDModeDisplay;
        self.calibUndoBtn.hidden = YES;
        self.calibResetBtn.hidden = YES;
        NSArray *result = [self.calibPoints copy];
        self.hudView.calibPoints = @[];
        if (self.calibBlock) {
            self.calibBlock(result);
            self.calibBlock = nil;
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return self.mode == JJHUDModeCalibrate;
}

/** 标定模式下要吃掉触摸，显示模式完全放行 */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.mode == JJHUDModeDisplay) return nil;
    return [super hitTest:point withEvent:event];
}

@end
