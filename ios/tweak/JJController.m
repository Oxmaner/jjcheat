//
//  JJController.m
//  JJCheat
//

#import "JJController.h"
#import "JJConfig.h"
#import "JJEngineBridge.h"
#import "JJScreenGrabber.h"
#import "JJHUDWindow.h"
#import "JJMetalGrabber.h"
#import <UIKit/UIKit.h>
#import <math.h>

typedef NS_ENUM(NSInteger, JJCtrlState) {
    JJCtrlStateIdle = 0,
    JJCtrlStateCalibrating,
    JJCtrlStateWaitingBoard,   // 已标定，等用户进入一局新棋
    JJCtrlStateRunning,
};

/* ============================================================
 *  悬浮球 —— 用来控制显隐 / 重新标定 / 重置
 * ============================================================ */
@interface JJBallWindow : UIWindow
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);
@end

@implementation JJBallWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1001.0;
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [[UIViewController alloc] init];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        CGFloat d = 52;
        CGRect scr = [UIScreen mainScreen].bounds;
        _ball = [UIButton buttonWithType:UIButtonTypeCustom];
        _ball.frame = CGRectMake(0, 0, d, d);
        _ball.center = CGPointMake(scr.size.width - 34, scr.size.height * 0.45);
        _ball.backgroundColor = [UIColor colorWithRed:0.85 green:0.1 blue:0.2 alpha:0.85];
        _ball.layer.cornerRadius = d / 2;
        _ball.layer.borderWidth = 2;
        _ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
        _ball.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        _ball.titleLabel.numberOfLines = 2;
        [_ball setTitle:@"象\n棋" forState:UIControlStateNormal];
        [_ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_ball addTarget:self action:@selector(tapBall) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panBall:)];
        [_ball addGestureRecognizer:pan];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(lpBall:)];
        [_ball addGestureRecognizer:lp];

        [self.rootViewController.view addSubview:_ball];
    }
    return self;
}

/* 未激活：半透明 + 提示「点我」；激活后：实心「象棋」 */
- (void)setActive:(BOOL)active {
    self.ball.alpha = active ? 1.0 : 0.55;
    [self.ball setTitle:(active ? @"象\n棋" : @"点\n我") forState:UIControlStateNormal];
}

- (void)tapBall { if (self.onTap) self.onTap(); }

- (void)lpBall:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}

- (void)panBall:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateEnded) {
        CGPoint t = [g translationInView:self];
        self.ball.center = CGPointMake(self.ball.center.x + t.x, self.ball.center.y + t.y);
        [g setTranslation:CGPointZero inView:self];
    }
}

- (void)attach {
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive) {
                self.windowScene = (UIWindowScene *)sc;
                break;
            }
        }
    }
    self.frame = [UIScreen mainScreen].bounds;
    self.hidden = NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self.ball) ? v : nil;
}

@end

/* ============================================================
 *  主控制器
 * ============================================================ */
@interface JJController ()
@property (nonatomic, assign) JJCtrlState state;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) JJBallWindow *ballWindow;
@property (nonatomic, assign) BOOL hudVisible;
@property (nonatomic, assign) BOOL learnedBoard;
@property (nonatomic, assign) BOOL busy;
/* 用户点过球、真正开始抓帧与识别（进 App 时只挂球，不工作） */
@property (nonatomic, assign) BOOL activated;
@property (nonatomic, assign) NSInteger tickCount;
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *gridPtsCache;
/* 标定得到的屏幕 point 坐标（原始值）；像素坐标按实际抓帧尺寸现算 */
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *pointCorners;
@property (nonatomic, assign) int lastFrameW;
@property (nonatomic, assign) int lastFrameH;
/* 四角自校准只做一次；finalCorners 是 JS refineGrid 采纳后的最终四角 */
@property (nonatomic, assign) BOOL refineDone;
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *finalCorners;
/* 帧去重：Metal 没出新帧就不重复喂 JS（每帧 14MB 拷贝 + 90 格模板匹配） */
@property (nonatomic, assign) uint64_t lastFrameSerial;
/* 学习失败退避：learnAndRefine 要几百 ms~几秒，不能每 250ms 重跑一次 */
@property (nonatomic, assign) NSTimeInterval lastLearnAttempt;
@end

@implementation JJController

+ (instancetype)shared {
    static JJController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJController alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = JJCtrlStateIdle;
        _hudVisible = YES;
        _learnedBoard = NO;
        _busy = NO;
        _tickCount = 0;
    }
    return self;
}

- (void)start {
    NSLog(@"[JJCheat] 待机：只挂悬浮球，不抓帧（进对局后点球开始）");
    self.activated = NO;
    self.state = JJCtrlStateIdle;
    self.learnedBoard = NO;
    [self setupBall];
    [self.ballWindow setActive:NO];
    /* 这里刻意不做：loadEngine / grabber.start / HUD attach / startTimer
       避免在登录页、大厅、结算页上误学棋盘、误识别 */
}

/* 用户点球后才真正开工 */
- (void)activate {
    if (self.activated) return;
    self.activated = YES;
    [self.ballWindow setActive:YES];
    NSLog(@"[JJCheat] 用户点球 → 开始抓帧与识别");

    [[JJScreenGrabber shared] start];
    [[JJEngineBridge shared] loadEngine];
    [[JJHUDWindow shared] attach];
    self.hudVisible = YES;

    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:JJ_KEY_CORNERS];
    if (saved.count == 4) {
        NSMutableArray *corners = [NSMutableArray array];
        for (NSArray *p in saved) {
            [corners addObject:@[[NSNumber numberWithDouble:[p[0] doubleValue]],
                                 [NSNumber numberWithDouble:[p[1] doubleValue]]]];
        }
        self.pointCorners = corners;
        self.lastFrameW = 0;
        self.lastFrameH = 0;
        self.state = JJCtrlStateWaitingBoard;
        self.gridPtsCache = [[JJEngineBridge shared] gridPoints];
        [[JJHUDWindow shared] showStatus:@"已就绪 · 进对局画面后自动学习"];
        [self startTimer];
    } else {
        [self recalibrate];
    }
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    self.state = JJCtrlStateIdle;
    self.activated = NO;
    [[JJScreenGrabber shared] stop];
}

- (void)setupBall {
    if (self.ballWindow) return;
    self.ballWindow = [[JJBallWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    __weak typeof(self) weakSelf = self;
    self.ballWindow.onTap = ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2.activated) {          /* 第一次点：开工 */
            [self2 activate];
            return;
        }
        self2.hudVisible = !self2.hudVisible;   /* 之后：切换 HUD 显隐 */
        [[JJHUDWindow shared] setHUDHidden:!self2.hudVisible];
    };
    self.ballWindow.onLongPress = ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2.activated) [self2 activate];
        [self2 recalibrate];
    };
    [self.ballWindow attach];
}

- (void)recalibrate {
    [self.timer invalidate];
    self.timer = nil;
    self.learnedBoard = NO;
    self.state = JJCtrlStateCalibrating;

    __weak typeof(self) weakSelf = self;
    [[JJHUDWindow shared] beginCalibrationWithCompletion:^(NSArray<NSValue *> *corners) {
        __strong typeof(weakSelf) self2 = weakSelf;
        [self2 handleCalibration:corners];
    }];
}

- (void)handleCalibration:(NSArray<NSValue *> *)corners {
    if (corners.count != 4) return;

    // point -> pixel
    CGRect nb = [UIScreen mainScreen].nativeBounds;
    CGRect pt = [UIScreen mainScreen].bounds;
    CGFloat sx = (pt.size.width > 0) ? nb.size.width / pt.size.width : 1.0;
    CGFloat sy = (pt.size.height > 0) ? nb.size.height / pt.size.height : 1.0;

    NSMutableArray *pxCorners = [NSMutableArray array];
    NSMutableArray *saved = [NSMutableArray array];
    for (NSValue *v in corners) {
        CGPoint p = [v CGPointValue];
        [pxCorners addObject:@[@(p.x * sx), @(p.y * sy)]];
        [saved addObject:@[@(p.x), @(p.y)]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:saved forKey:JJ_KEY_CORNERS];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:JJ_KEY_CALIBRATED];
    [[NSUserDefaults standardUserDefaults] synchronize];

    self.pointCorners = saved;   // 原始 point 坐标，抓帧尺寸确定后按比例现算
    self.lastFrameW = 0;
    self.lastFrameH = 0;
    self.refineDone = NO;
    self.finalCorners = nil;
    self.lastFrameSerial = 0;
    self.lastLearnAttempt = 0;
    [[JJEngineBridge shared] setCorners:pxCorners];
    [[JJEngineBridge shared] resetWithFen:nil];
    self.gridPtsCache = [[JJEngineBridge shared] gridPoints];

    self.state = JJCtrlStateWaitingBoard;
    [self startTimer];
    [[JJHUDWindow shared] showStatus:@"标定完成 · 请进入一局新棋（开局布局）"];
    NSLog(@"[JJCheat] 标定完成 %@", pxCorners);
}

- (void)resetToStartPosition {
    self.learnedBoard = NO;
    [[JJEngineBridge shared] resetWithFen:nil];
    self.state = JJCtrlStateWaitingBoard;
    [[JJHUDWindow shared] showStatus:@"已重置 · 等开局画面"];
}

/* ------------------------------------------------------------
 *  标定坐标自适应
 *  handleCalibration / start 里是按 nativeBounds 把 point 换算成像素的，
 *  但 roothide 下抓帧往往走 GL-hook，拿到的是 GL framebuffer 尺寸，
 *  可能和 nativeBounds 不一致。一旦不一致，90 个采样点整体错位，
 *  识别结果就是「整盘空格」—— 表现正好是 verifyDiff=32、顶/底行 0 子。
 *  这里按「实际抓帧尺寸 / 屏幕 point」重算一次，尺寸变了才重设。
 * ------------------------------------------------------------ */
/* 只算不设：把标定的 point 坐标按抓帧尺寸换算成像素坐标 */
- (NSArray<NSArray<NSNumber *> *> *)cornersForWidth:(int)w height:(int)h {
    if (self.pointCorners.count != 4 || w <= 0 || h <= 0) return nil;
    CGSize pt = [UIScreen mainScreen].bounds.size;
    if (pt.width <= 0 || pt.height <= 0) return nil;
    CGFloat sx = (CGFloat)w / pt.width;
    CGFloat sy = (CGFloat)h / pt.height;
    NSMutableArray *px = [NSMutableArray arrayWithCapacity:4];
    for (NSArray *p in self.pointCorners) {
        [px addObject:@[@([p[0] doubleValue] * sx), @([p[1] doubleValue] * sy)]];
    }
    return px;
}

/* 四角双线性插值，和引擎里 gridPoints 的算法一致。
   纯本地计算，不 dispatch_sync 问 JS —— 主线程不能再等引擎队列。 */
static CGPoint JJGridPt(NSArray *corners, int r, int c) {
    double u = (double)c / 8.0;
    double v = (double)r / 9.0;
    double x00 = [corners[0][0] doubleValue], y00 = [corners[0][1] doubleValue];
    double x08 = [corners[1][0] doubleValue], y08 = [corners[1][1] doubleValue];
    double x89 = [corners[2][0] doubleValue], y89 = [corners[2][1] doubleValue];
    double x80 = [corners[3][0] doubleValue], y80 = [corners[3][1] doubleValue];
    double x = (1 - u) * (1 - v) * x00 + u * (1 - v) * x08 + u * v * x89 + (1 - u) * v * x80;
    double y = (1 - u) * (1 - v) * y00 + u * (1 - v) * y08 + u * v * y89 + (1 - u) * v * y80;
    return CGPointMake(x, y);
}

/** 用给定四角本地算 90 个交叉点（dump 诊断 + HUD 画箭头都用它）。 */
- (NSArray<NSArray<NSNumber *> *> *)gridPointsFromCorners:(NSArray *)corners {
    if (corners.count != 4) return @[];
    NSMutableArray *pts = [NSMutableArray arrayWithCapacity:90];
    for (int r = 0; r < 10; r++) {
        for (int c = 0; c < 9; c++) {
            CGPoint p = JJGridPt(corners, r, c);
            [pts addObject:@[@(p.x), @(p.y)]];
        }
    }
    return pts;
}

/**
 * 学习 + 四角自校准：整段丢到引擎队列异步跑，回调回主线程。
 *
 * 旧实现在这里用 JJOffsetScore 做 ±30px 纯平移粗搜/细搜，再 dispatch_sync 调
 * learnBoard，两个硬伤：
 *   ① 纯平移修不了梯形（真机底行左 y1967 / 右 y1994，9 行累计差 27px）；
 *   ② dispatch_sync 让主线程冻结 3~4 秒，学习失败时每 250ms 又重来一次，
 *      连着十几次正是日志里 12:08:19→12:08:50 那段 31 秒空白。
 * 现在交给 JS 的 learnAndRefine：refineGrid 双线性拟合四角，再用 verifyDiff
 * 前后对比取优（拟合拉歪也不会比现状差）。
 */
- (void)learnWithAutoRefine:(NSData *)rgba
                      width:(int)w
                     height:(int)h
                   callback:(void (^)(NSDictionary *info))callback {
    NSArray *base = self.finalCorners.count == 4
        ? self.finalCorners
        : [self cornersForWidth:w height:h];
    [[JJEngineBridge shared] learnAndRefineWithPixels:rgba
                                                  width:w
                                                 height:h
                                            baseCorners:base
                                               callback:^(NSDictionary *result, NSError *error) {
        if (callback) callback(result);
    }];
}

- (void)applyCornersForFrameWidth:(int)w height:(int)h {
    if (w <= 0 || h <= 0) return;
    /* 学习已采纳精修四角后，不能再按 point 比例重设，否则梯形修正会被冲掉 */
    if (self.finalCorners.count == 4) {
        if (self.gridPtsCache.count != 90) {
            self.gridPtsCache = [self gridPointsFromCorners:self.finalCorners];
        }
        return;
    }
    if (self.pointCorners.count != 4) return;
    if (self.lastFrameW == w && self.lastFrameH == h) return;

    CGSize pt = [UIScreen mainScreen].bounds.size;
    if (pt.width <= 0 || pt.height <= 0) return;

    CGFloat sx = (CGFloat)w / pt.width;
    CGFloat sy = (CGFloat)h / pt.height;

    NSMutableArray *px = [NSMutableArray arrayWithCapacity:4];
    for (NSArray *p in self.pointCorners) {
        [px addObject:@[@([p[0] doubleValue] * sx), @([p[1] doubleValue] * sy)]];
    }

    self.lastFrameW = w;
    self.lastFrameH = h;
    [[JJEngineBridge shared] setCorners:px];
    /* 本地算，不再 dispatch_sync 问 JS（那会让主线程等引擎队列） */
    self.gridPtsCache = [self gridPointsFromCorners:px];

    CGRect nb = [UIScreen mainScreen].nativeBounds;
    NSLog(@"[JJCheat] 抓帧 %dx%d（point %.0fx%.0f / native %.0fx%.0f）→ 标定缩放 %.3f/%.3f",
          w, h, pt.width, pt.height, nb.size.width, nb.size.height, sx, sy);
}

/* 学习校验没过时，把几个采样点的真实颜色打出来：
 *   全是背景色 → 采样点错位（标定/尺寸问题）
 *   有棋子色但判空 → 阈值或皮肤问题（调 recognizer 的 redTh/darkTh） */
- (void)dumpSamplesWithPixels:(NSData *)rgba width:(int)w height:(int)h {
    NSArray<NSArray<NSNumber *> *> *grid = self.gridPtsCache;
    if (grid.count != 90 || !rgba.length || w <= 0 || h <= 0) return;

    const uint8_t *px = (const uint8_t *)rgba.bytes;
    NSUInteger len = rgba.length;
    NSInteger probes[] = { 0, 4, 8, 40, 81, 85, 89, 13, 76 };
    NSMutableString *log = [NSMutableString string];
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        NSInteger idx = probes[i];
        if (idx < 0 || idx >= (NSInteger)grid.count) continue;
        int x = (int)lround([grid[(NSUInteger)idx][0] doubleValue]);
        int y = (int)lround([grid[(NSUInteger)idx][1] doubleValue]);
        if (x < 0 || y < 0 || x >= w || y >= h) {
            [log appendFormat:@" #%ld(%d,%d)越界", (long)idx, x, y];
            continue;
        }
        NSUInteger o = ((NSUInteger)y * (NSUInteger)w + (NSUInteger)x) * 4;
        if (o + 2 >= len) continue;
        [log appendFormat:@" #%ld(%d,%d)=(%d,%d,%d)",
         (long)idx, x, y, px[o], px[o + 1], px[o + 2]];
    }
    NSLog(@"[JJCheat] 采样点颜色(RGB) w=%d h=%d%@", w, h, log);
}

- (void)startTimer {
    [self.timer invalidate];
    NSTimeInterval interval = 1.0 / MAX(1, JJ_SCAN_FPS);
    self.timer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self.timer setFireDate:[NSDate date]];
}

- (void)tick {
    if (self.busy) return;
    if (self.state != JJCtrlStateWaitingBoard && self.state != JJCtrlStateRunning) return;

    /* Metal 没出新帧就别把上一帧再喂一遍 JS：每帧要拷 14MB 进 JSContext
       再跑 90 格模板匹配，重复帧纯属白烧 CPU。 */
    uint64_t serial = JJMetalFrameSerial();
    if (serial > 0) {
        if (serial == self.lastFrameSerial) return;
        self.lastFrameSerial = serial;
    }

    int w = 0, h = 0;
    NSData *rgba = [[JJScreenGrabber shared] grabRGBAWithWidth:&w height:&h];
    if (!rgba || w <= 0 || h <= 0) return;

    // 抓帧尺寸可能和 nativeBounds 不一致（roothide 下走 GL-hook），标定按实际尺寸重算
    [self applyCornersForFrameWidth:w height:h];

    // ---- 学习阶段：整段异步，主线程一步都不等 ----
    if (!self.learnedBoard) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        /* 失败退避：learnAndRefine 要几百 ms~几秒，旧逻辑每 250ms 重跑一次，
           连着十几次就是日志里 12:08:19→12:08:50 那段 31 秒主线程空白。 */
        if (now - self.lastLearnAttempt < 1.5) return;
        self.lastLearnAttempt = now;
        self.busy = YES;
        self.tickCount++;

        __weak typeof(self) weakSelf = self;
        [self learnWithAutoRefine:rgba width:w height:h callback:^(NSDictionary *info) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            self2.busy = NO;
            if (!info || [info[@"templateCount"] integerValue] <= 0) {
                [[JJHUDWindow shared] showStatus:@"正在学习棋盘…请停留在开局画面"];
                return;
            }
            self2.learnedBoard = YES;
            self2.state = JJCtrlStateRunning;
            NSArray *fc = info[@"finalCorners"];
            if ([fc isKindOfClass:[NSArray class]] && fc.count == 4) {
                self2.finalCorners = fc;
                self2.gridPtsCache = [self2 gridPointsFromCorners:fc];
            } else {
                self2.gridPtsCache = [[JJEngineBridge shared] gridPoints];
            }
            NSLog(@"[JJCheat] 棋盘学习完成 %@", info);
            if (![info[@"ok"] boolValue]) {
                NSLog(@"[JJCheat] 学习校验未通过（verifyDiff=%@），dump 采样点定位", info[@"verifyDiff"]);
                [self2 dumpSamplesWithPixels:rgba width:w height:h];
            }
        }];
        return;
    }

    self.busy = YES;
    self.tickCount++;
    __weak typeof(self) weakSelf = self;
    [[JJEngineBridge shared] processPixels:rgba width:w height:h timeMs:JJ_TIME_MS
                                  callback:^(NSDictionary *result, NSError *error) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        self2.busy = NO;
        if (!result) return;

        if (self2.gridPtsCache.count != 90) {
            self2.gridPtsCache = [self2 gridPointsFromCorners:self2.finalCorners];
        }
        /* 合法性闸门没放行时留一条日志：识别错成红车 5 个时整盘作废，
           引擎会一直拿开局 FEN 算棋，表现就是「对方走完不给提示」。 */
        if (![result[@"legalNow"] boolValue]) {
            NSLog(@"[JJCheat] 识别未收敛：illegalStreak=%@ codesStable=%@（本帧盘面未采用）",
                  result[@"illegalStreak"], result[@"codesStableCount"]);
        }

        [[JJHUDWindow shared] showResult:result gridPoints:self2.gridPtsCache fen:result[@"fen"] ?: @""];

        if ([result[@"moveDetected"] boolValue]) {
            NSLog(@"[JJCheat] 检测到走法 %@ %@ → FEN %@",
                  result[@"move"], result[@"moveChinese"], result[@"fen"]);
        }
    }];
}

@end
