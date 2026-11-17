//
//  JJGameController.m
//  JJCheat
//

#import "JJGameController.h"
#import "JJConfig.h"
#import "JJCalibrator.h"
#import "JJVisionBridge.h"
#import "JJPikafish.h"
#import "JJPikafishInstaller.h"
#import "JJMoveCodec.h"
#import "JJScreenGrabber.h"
#import "JJMetalGrabber.h"
#import "JJBallWindow.h"
#import "JJHUDWindow.h"
#import <UIKit/UIKit.h>
#import <math.h>

typedef NS_ENUM(NSInteger, JJGameState) {
    JJGameStateIdle = 0,
    JJGameStateCalibrating,
    JJGameStateWaitingBoard,   // 已标定，等用户进入一局新棋
    JJGameStateRunning,
};

@interface JJGameController ()
@property (nonatomic, assign) JJGameState state;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) JJBallWindow *ballWindow;
@property (nonatomic, assign) BOOL hudVisible;
@property (nonatomic, assign) BOOL learnedBoard;
@property (nonatomic, assign) BOOL busy;
/* 用户点过球、真正开始抓帧与识别（进 App 时只挂球，不工作） */
@property (nonatomic, assign) BOOL activated;
@property (nonatomic, assign) NSInteger tickCount;
/* 帧去重：Metal 没出新帧就不重复喂 JS（每帧 14MB 拷贝 + 90 格模板匹配） */
@property (nonatomic, assign) uint64_t lastFrameSerial;
/* 画面指纹：90 个交叉点的 RGB 快照。新帧但画面没变时整轮跳过 JS */
@property (nonatomic, strong) NSData *lastFingerprint;
@property (nonatomic, assign) NSTimeInterval lastLearnAttempt;
@property (nonatomic, assign) NSInteger learnFailCount;
/* 插件总开关 */
@property (nonatomic, assign) BOOL enabled;
/* 2.1.59：学习失败帧落盘（诊断用，见 dumpFrameJPEG） */
- (void)dumpFrameJPEG:(NSData *)rgba width:(int)w height:(int)h;
/* 思考时长（ms，Pikafish 的 go movetime），持久化 */
@property (nonatomic, assign) NSInteger thinkMs;
@property (nonatomic, assign) NSTimeInterval lastProcessTime;
@property (nonatomic, assign) NSTimeInterval processNotBefore;
@property (nonatomic, assign) BOOL autoCalibrating;
/* 重标定必须学成才采纳，失败回滚 */
@property (nonatomic, assign) BOOL calibrationPending;
@property (nonatomic, assign) NSTimeInterval lastHeartbeatTs;

/* ---- 2.1.0 引擎联动 ---- */
/* 最近一次识别结果（recognition dict），拼装 HUD 用 */
@property (nonatomic, strong, nullable) NSDictionary *lastRecognition;
/* 已派发搜索的局面（原生缓存键） */
@property (nonatomic, copy, nullable) NSString *lastSearchFen;
/* 该局面的引擎结论（from/to/scoreText/depth/...） */
@property (nonatomic, strong, nullable) NSDictionary *engineResult;
/* 请求代号：新请求 / 新局 / 重锚都会自增，用来丢弃过期回调 */
@property (nonatomic, assign) NSInteger engineGen;
@property (nonatomic, assign) BOOL enginePending;
@property (nonatomic, assign) NSTimeInterval lastDotRefresh;

- (void)showMenu;
- (void)setPluginEnabled:(BOOL)on;
- (void)autoCalibrate;
- (void)manualCalibrate;
- (void)toggleHUD;
- (void)editThinkMs;
- (void)showEngineStatus;
- (void)applyThinkMs:(NSInteger)v;
@end

@implementation JJGameController

+ (instancetype)shared {
    static JJGameController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJGameController alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        _state = JJGameStateIdle;
        _enabled = [ud objectForKey:JJ_KEY_ENABLED] ? [ud boolForKey:JJ_KEY_ENABLED] : YES;
        _hudVisible = [ud objectForKey:JJ_KEY_HUD_VISIBLE] ? [ud boolForKey:JJ_KEY_HUD_VISIBLE] : YES;
        NSInteger savedMs = [ud integerForKey:JJ_KEY_THINK_MS];
        if (![ud boolForKey:JJ_KEY_THINK_MS_V2]) {
            /* 一次性迁移：2.0.x 的 200ms 是给 JS 引擎调的值，
               Pikafish 吃 48MB NNUE，这个时长等于没思考。 */
            if (savedMs > 0 && savedMs <= 250) savedMs = 0;
            [ud setBool:YES forKey:JJ_KEY_THINK_MS_V2];
            [ud synchronize];
        }
        _thinkMs = savedMs > 0
            ? MIN(JJ_THINK_MS_MAX, MAX(JJ_THINK_MS_MIN, savedMs))
            : JJ_THINK_MS_DEFAULT;
        _engineGen = 0;
        NSLog(@"[JJCheat] 配置: 插件=%@ HUD=%@ 思考=%ldms",
              _enabled ? @"开" : @"关", _hudVisible ? @"开" : @"关", (long)_thinkMs);
    }
    return self;
}

#pragma mark - 生命周期

- (void)start {
    NSLog(@"[JJCheat] 待机：只挂悬浮球，不抓帧（进对局后点球开始）");
    self.activated = NO;
    self.state = JJGameStateIdle;
    self.learnedBoard = NO;
    [self setupBall];
    [self.ballWindow setActive:NO];
    [self.ballWindow setEngineDotColor:nil];
    /* 待机时把 Metal 读帧彻底关掉：hook 只透传，不占渲染线程 */
    JJMetalSetCaptureEnabled(NO);
}

- (void)activate {
    if (self.activated || !self.enabled) return;
    self.activated = YES;
    [self.ballWindow setActive:YES];
    NSLog(@"[JJCheat] 用户点球 → 开始抓帧与识别");

    JJMetalSetCaptureEnabled(YES);
    self.lastProcessTime = 0;
    self.processNotBefore = 0;
    [[JJScreenGrabber shared] start];
    [[JJVisionBridge shared] loadEngine];
    /* 2.1.0：引擎独立进程，激活就开始拉起（首次要把 45MB 复制进容器 + NNUE 初始化） */
    [[JJPikafish shared] start];
    [[JJHUDWindow shared] attach];
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];

    if ([[JJCalibrator shared] hasCorners]) {
        self.state = JJGameStateWaitingBoard;
        [[JJHUDWindow shared] showStatus:@"已就绪 · 进对局画面后自动学习"];
        [self startTimer];
    } else {
        [self recalibrate];
    }
    [self refreshEngineDot];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    self.state = JJGameStateIdle;
    self.activated = NO;
    self.busy = NO;
    JJMetalSetCaptureEnabled(NO);
    [[JJScreenGrabber shared] stop];
    [[JJPikafish shared] shutdown];
}

- (void)setupBall {
    if (self.ballWindow) return;
    self.ballWindow = [[JJBallWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    __weak typeof(self) weakSelf = self;
    self.ballWindow.onTap = ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        if (self2.ballWindow.menuVisible) {
            [self2.ballWindow hideMenu];
            return;
        }
        if (!self2.activated && self2.enabled) [self2 activate];
        [self2 showMenu];
    };
    self.ballWindow.onLongPress = ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || !self2.enabled) return;
        if (!self2.activated) [self2 activate];
        [self2 manualCalibrate];
    };
    self.ballWindow.onMenuItem = ^(NSInteger idx) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        switch (idx) {
            case 0: [self2 setPluginEnabled:!self2.enabled]; break;
            case 1: [self2 autoCalibrate];                   break;
            case 2: [self2 manualCalibrate];                 break;
            case 3: [self2 toggleHUD];                       break;
            case 4: [self2 editThinkMs];                     break;
            case 5: [self2 showEngineStatus];                break;
            default: break;
        }
    };
    [self.ballWindow attach];
}

#pragma mark - 悬浮球菜单

- (void)showMenu {
    NSArray<NSString *> *titles = @[
        [NSString stringWithFormat:@"① 插件开关：%@", self.enabled ? @"开" : @"关"],
        @"② 自动标定棋盘（开局画面）",
        @"③ 手动标定棋盘（点四角）",
        [NSString stringWithFormat:@"④ HUD 显示：%@", self.hudVisible ? @"开" : @"关"],
        [NSString stringWithFormat:@"⑤ 思考时间：%ld ms", (long)self.thinkMs],
        [NSString stringWithFormat:@"⑥ 引擎：%@（点开详情）",
            [[JJPikafish shared] stateText]]
    ];
    [self.ballWindow showMenuWithTitles:titles];
    [self refreshEngineDot];
}

- (void)setPluginEnabled:(BOOL)on {
    self.enabled = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:JJ_KEY_ENABLED];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (on) {
        [self.ballWindow setActive:YES];
        if (!self.activated) {
            [self activate];
        } else {
            JJMetalSetCaptureEnabled(YES);
            [[JJScreenGrabber shared] start];
            [[JJPikafish shared] start];
            [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
            [self startTimer];
        }
        [[JJHUDWindow shared] showStatus:@"插件已开启"];
        NSLog(@"[JJCheat] 插件开关 → 开");
    } else {
        [self.timer invalidate];
        self.timer = nil;
        self.busy = NO;
        [[JJScreenGrabber shared] stop];
        JJMetalSetCaptureEnabled(NO);
        [[JJPikafish shared] shutdown];
        [[JJHUDWindow shared] setHUDHidden:YES];
        [self.ballWindow setActive:NO];
        [self.ballWindow setEngineDotColor:nil];
        NSLog(@"[JJCheat] 插件开关 → 关（停止抓帧 / 识别 / 引擎）");
    }
}

- (void)toggleHUD {
    self.hudVisible = !self.hudVisible;
    [[NSUserDefaults standardUserDefaults] setBool:self.hudVisible forKey:JJ_KEY_HUD_VISIBLE];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
    NSLog(@"[JJCheat] HUD 显示=%@", self.hudVisible ? @"开" : @"关");
}

- (void)applyThinkMs:(NSInteger)v {
    if (v <= 0) v = JJ_THINK_MS_DEFAULT;
    v = MIN(JJ_THINK_MS_MAX, MAX(JJ_THINK_MS_MIN, v));
    self.thinkMs = v;
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:JJ_KEY_THINK_MS];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[JJHUDWindow shared] showStatus:[NSString stringWithFormat:@"思考时间已设为 %ld ms", (long)v]];
    NSLog(@"[JJCheat] 思考时间=%ld ms", (long)v);
}

- (void)editThinkMs {
    NSString *msg = [NSString stringWithFormat:
                     @"皮卡鱼每步搜索时长，范围 %d~%d ms，默认 %d ms。\n数值越大越强，越费电。",
                     JJ_THINK_MS_MIN, JJ_THINK_MS_MAX, JJ_THINK_MS_DEFAULT];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"思考时间（ms）"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    NSInteger cur = self.thinkMs;
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.placeholder = @"毫秒";
        tf.text = [NSString stringWithFormat:@"%ld", (long)cur];
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAc = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存输入值" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self2 = weakSelf;
        UIAlertController *alert = weakAc;
        if (!self2 || !alert) return;
        [self2 applyThinkMs:[alert.textFields.firstObject.text integerValue]];
    }]];
    for (NSNumber *n in @[@(300), @(800), @(1500), @(3000)]) {
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ ms", n]
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (self2) [self2 applyThinkMs:n.integerValue];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (self.ballWindow.hidden) [self.ballWindow attach];
    [self.ballWindow.rootViewController presentViewController:ac animated:YES completion:nil];
    NSLog(@"[JJCheat] 打开思考时间设置");
}

/** 引擎状态详情：一眼看出 Pikafish 到底在不在、跑没跑起来。
    2.1.52 起引擎在进程内跑（静态库链进 dylib），没有可执行文件可查，
    所以只报告「权重路径 / 权重大小 / 引擎线程是否活着」。 */
- (void)showEngineStatus {
    JJPikafish *pika = [JJPikafish shared];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"状态：%@\n", [pika stateText]];
    [msg appendFormat:@"引擎：进程内（Pikafish 静态库）\n"];
    [msg appendFormat:@"线程：%@\n", [pika engineThreadAlive] ? @"运行中" : @"未运行"];

    NSString *net = [pika netPathInUse];
    if (!net.length) net = [JJPikafishInstaller netPathInContainer];
    NSDictionary *na = [fm attributesOfItemAtPath:net error:nil];
    [msg appendFormat:@"权重：%@（%@ 字节）\n",
        na ? @"已就位" : @"缺失", na ? @([na fileSize]) : @"-"];
    if (net.length) [msg appendFormat:@"路径：%@\n", net];

    /* 2.1.68：把引擎自己说的话摆在这里。
       成功是 `NNUE evaluation using ...`；失败是
       `JJ-NNUE FAIL reason=... decompressed=... fileHash=0x… engineHash=0x…`。
       这一行能直接区分「文件没读到」和「权重与引擎不配套」，不用去翻 syslog。 */
    NSString *notice = [pika lastEngineNotice];
    if (notice.length) {
        [msg appendFormat:@"\n引擎自述：\n%@\n", notice];
    }
    if ([pika state] == JJPikaStateDead || [notice hasPrefix:@"JJ-NNUE FAIL"]) {
        [msg appendString:@"\n网络校验没通过 → 引擎会跳过搜索（不会再闪退）。"];
    }

    [msg appendFormat:@"线程 1 · 哈希 %d MB · 每步 %ld ms", JJ_PIKA_HASH_MB, (long)self.thinkMs];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"皮卡鱼引擎"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    if (self.ballWindow.hidden) [self.ballWindow attach];
    [self.ballWindow.rootViewController presentViewController:ac animated:YES completion:nil];
}

/** 球右上角状态点：绿=就绪/思考 黄=启动中 红=不可用 */
- (void)refreshEngineDot {
    if (!self.activated || !self.enabled) {
        [self.ballWindow setEngineDotColor:nil];
        return;
    }
    switch ([JJPikafish shared].state) {
        case JJPikaStateReady:
        case JJPikaStateSearching:
            [self.ballWindow setEngineDotColor:[UIColor colorWithRed:0.2 green:0.85 blue:0.45 alpha:1.0]];
            break;
        case JJPikaStateStarting:
            [self.ballWindow setEngineDotColor:[UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:1.0]];
            break;
        default:
            [self.ballWindow setEngineDotColor:[UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:1.0]];
            break;
    }
}

#pragma mark - 标定动作

- (void)autoCalibrate {
    if (!self.enabled) {
        [[JJHUDWindow shared] showStatus:@"请先开启插件"];
        return;
    }
    if (!self.activated) [self activate];
    [[JJCalibrator shared] snapshot];
    [[JJCalibrator shared] clearRefined];
    self.learnedBoard = NO;
    self.learnFailCount = 0;
    self.lastLearnAttempt = 0;
    self.lastFrameSerial = 0;
    self.lastFingerprint = nil;
    self.processNotBefore = 0;
    self.autoCalibrating = YES;
    self.calibrationPending = YES;
    self.state = JJGameStateWaitingBoard;
    [self startTimer];
    [[JJHUDWindow shared] showStatus:@"自动标定中…请停在【开局】棋盘画面"];
    NSLog(@"[JJCheat] 自动标定棋盘：备份旧标定，重新学习（不清空 JS 锚盘）");
}

- (void)manualCalibrate {
    if (!self.enabled) {
        [[JJHUDWindow shared] showStatus:@"请先开启插件"];
        return;
    }
    if (!self.activated) [self activate];
    self.autoCalibrating = NO;
    [self recalibrate];
}

- (void)recalibrate {
    [[JJCalibrator shared] snapshot];
    [self.timer invalidate];
    self.timer = nil;
    self.learnedBoard = NO;
    self.state = JJGameStateCalibrating;

    __weak typeof(self) weakSelf = self;
    [[JJHUDWindow shared] beginCalibrationWithCompletion:^(NSArray<NSValue *> *corners) {
        __strong typeof(weakSelf) self2 = weakSelf;
        [self2 handleCalibration:corners];
    }];
}

- (void)handleCalibration:(NSArray<NSValue *> *)corners {
    if (corners.count != 4) return;
    /* 2.0.1 四角几何校验：点歪 / 聚团 / 顺序反 → 拒绝，保留上一次成功标定 */
    if (![[JJCalibrator shared] handleManualCalibration:corners]) {
        [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
        if ([[JJCalibrator shared] restoreSnapshot]) {
            self.learnedBoard = YES;
            self.state = JJGameStateRunning;
            self.calibrationPending = NO;
            [self startTimer];
            [[JJHUDWindow shared] showStatus:@"四角无效 · 已恢复上次标定"];
        } else {
            self.state = JJGameStateWaitingBoard;
            [self startTimer];
            [[JJHUDWindow shared] showStatus:@"四角无效 · 请按左上→右上→右下→左下重标"];
        }
        return;
    }

    self.lastFrameSerial = 0;
    self.lastFingerprint = nil;
    self.lastLearnAttempt = 0;
    self.learnFailCount = 0;
    self.calibrationPending = YES;
    self.state = JJGameStateWaitingBoard;
    self.processNotBefore = 0;
    [self startTimer];
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
    [[JJHUDWindow shared] showStatus:@"标定完成 · 请进入一局新棋（开局布局）"];
}

- (void)resetToStartPosition {
    /* 用户显式「重置到开局」：这里才真正清空 JS 锚盘，重标定路径不会走 */
    self.learnedBoard = NO;
    self.calibrationPending = NO;
    self.autoCalibrating = NO;
    [[JJCalibrator shared] clearRefined];
    self.lastFingerprint = nil;
    self.lastFrameSerial = 0;
    self.processNotBefore = 0;
    self.lastProcessTime = 0;
    self.learnFailCount = 0;
    self.lastSearchFen = nil;
    self.engineResult = nil;
    self.engineGen++;
    [[JJVisionBridge shared] resetWithFen:nil];
    [[JJPikafish shared] notifyNewGame];
    self.state = JJGameStateWaitingBoard;
    [self startTimer];
    [[JJHUDWindow shared] showStatus:@"已重置 · 等开局画面"];
}

#pragma mark - 画面指纹（主线程极轻计算）

#define JJ_FP_POINTS  90
#define JJ_FP_VALUES  (JJ_FP_POINTS * 3)

static BOOL JJFrameFingerprint(NSData *rgba, int w, int h,
                               NSArray *corners, int32_t *out) {
    if (!rgba.length || corners.count != 4 || w <= 0 || h <= 0) return NO;
    const uint8_t *p = (const uint8_t *)rgba.bytes;
    NSUInteger len = rgba.length;
    for (int r = 0; r < 10; r++) {
        for (int c = 0; c < 9; c++) {
            double u = (double)c / 8.0, v = (double)r / 9.0;
            double x00 = [corners[0][0] doubleValue], y00 = [corners[0][1] doubleValue];
            double x08 = [corners[1][0] doubleValue], y08 = [corners[1][1] doubleValue];
            double x89 = [corners[2][0] doubleValue], y89 = [corners[2][1] doubleValue];
            double x80 = [corners[3][0] doubleValue], y80 = [corners[3][1] doubleValue];
            int x = (int)((1 - u) * (1 - v) * x00 + u * (1 - v) * x08 + u * v * x89 + (1 - u) * v * x80);
            int y = (int)((1 - u) * (1 - v) * y00 + u * (1 - v) * y08 + u * v * y89 + (1 - u) * v * y80);
            int idx = (r * 9 + c) * 3;
            if (x < 2 || y < 2 || x >= w - 2 || y >= h - 2) {
                out[idx] = out[idx + 1] = out[idx + 2] = 0;
                continue;
            }
            int sr = 0, sg = 0, sb = 0;
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    NSUInteger o = ((NSUInteger)(y + dy) * (NSUInteger)w + (NSUInteger)(x + dx)) * 4;
                    if (o + 2 < len) { sr += p[o]; sg += p[o + 1]; sb += p[o + 2]; }
                }
            }
            out[idx] = sr / 9; out[idx + 1] = sg / 9; out[idx + 2] = sb / 9;
        }
    }
    return YES;
}

static int JJFrameFingerprintDiff(const int32_t *a, const int32_t *b) {
    int d = 0;
    for (int i = 0; i < JJ_FP_VALUES; i++) {
        int v = (int)(a[i] - b[i]);
        d += (v < 0) ? -v : v;
    }
    return d;
}

#pragma mark - tick

- (void)startTimer {
    [self.timer invalidate];
    NSTimeInterval interval = 1.0 / MAX(1, JJ_SCAN_FPS);
    self.timer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self.timer setFireDate:[NSDate date]];
}

- (void)tick {
    if (!self.enabled || !self.activated) return;
    if (self.busy) return;
    if (self.state != JJGameStateWaitingBoard && self.state != JJGameStateRunning) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now < self.processNotBefore) return;

    /* 引擎状态点低频刷新（2.1.0） */
    if (now - self.lastDotRefresh >= JJ_ENGINE_DOT_GAP) {
        self.lastDotRefresh = now;
        [self refreshEngineDot];
    }

    uint64_t serial = JJMetalFrameSerial();
    if (serial > 0) {
        if (serial == self.lastFrameSerial) return;
        self.lastFrameSerial = serial;
    }

    int w = 0, h = 0;
    NSData *rgba = [[JJScreenGrabber shared] grabRGBAWithWidth:&w height:&h];
    if (!rgba || w <= 0 || h <= 0) return;

    [[JJCalibrator shared] applyForFrameWidth:w height:h];

    /* 帧差驱动：新帧但画面没变 → 整轮跳过（静态局面连 JS 都不调） */
    if (self.learnedBoard) {
        NSArray *fpCorners = [JJCalibrator shared].finalCorners.count == 4
            ? [JJCalibrator shared].finalCorners
            : [[JJCalibrator shared] cornersForWidth:w height:h];
        if (fpCorners.count == 4) {
            int32_t sample[JJ_FP_VALUES];
            if (JJFrameFingerprint(rgba, w, h, fpCorners, sample)) {
                if (self.lastFingerprint.length == sizeof(sample) &&
                    JJFrameFingerprintDiff((const int32_t *)self.lastFingerprint.bytes,
                                           sample) < JJ_FRAME_DIFF_THRESHOLD) {
                    if (now - self.lastHeartbeatTs >= JJ_HEARTBEAT_GAP) {
                        self.lastHeartbeatTs = now;
                        NSLog(@"[JJCheat] 画面静止 · 跳过本帧（静态零开销）");
                    }
                    return;
                }
                self.lastFingerprint = [NSData dataWithBytes:sample length:sizeof(sample)];
            }
        }
    }

    /* ---- 学习阶段：整段异步，主线程不等 ---- */
    if (!self.learnedBoard) {
        if (now - self.lastLearnAttempt < JJ_LEARN_RETRY_GAP) return;
        self.lastLearnAttempt = now;
        self.busy = YES;
        self.tickCount++;

        NSArray *base = [JJCalibrator shared].finalCorners.count == 4
            ? [JJCalibrator shared].finalCorners
            : [[JJCalibrator shared] cornersForWidth:w height:h];
        __weak typeof(self) weakSelf = self;
        [[JJVisionBridge shared] learnAndRefineWithPixels:rgba
                                                    width:w
                                                   height:h
                                              baseCorners:base
                                                 callback:^(NSDictionary *info, NSError *error) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            self2.busy = NO;
            [self2 handleLearnResult:info rgba:rgba width:w height:h];
        }];
        return;
    }

    if (now - self.lastProcessTime < JJ_PROCESS_MIN_GAP) return;
    self.lastProcessTime = now;

    self.busy = YES;
    self.tickCount++;
    __weak typeof(self) weakSelf = self;
    [[JJVisionBridge shared] processPixels:rgba
                                     width:w
                                    height:h
                                  callback:^(NSDictionary *result, NSError *error) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        self2.busy = NO;
        if (!result) return;
        [self2 handleProcessResult:result];
    }];
}

#pragma mark - 学习结果

- (void)handleLearnResult:(NSDictionary *)info rgba:(NSData *)rgba width:(int)w height:(int)h {
    if (!info || [info[@"templateCount"] integerValue] <= 0) {
        /* 每 5 次留一条：旧 engine.js 接口缺失时 info 恒 nil，不能静默 */
        self.learnFailCount++;
        if ((self.learnFailCount % 5) == 1) {
            NSLog(@"[JJCheat] 学习未完成（第 %ld 次）info=%@ templateCount=%@ verifyDiff=%@",
                  (long)self.learnFailCount,
                  info ? @"有" : @"nil",
                  info[@"templateCount"] ?: @"-",
                  info[@"verifyDiff"] ?: @"-");
        }
        if (self.learnFailCount >= JJ_LEARN_MAX_FAIL) {
            [self.timer invalidate];
            self.timer = nil;
            [[JJHUDWindow shared] showStatus:@"学习失败 · 请检查 engine.js 后重开插件"];
            NSLog(@"[JJCheat] 学习连续失败 %ld 次，已暂停重试", (long)self.learnFailCount);
            return;
        }
        [[JJHUDWindow shared] showStatus:@"正在学习棋盘…请停留在开局画面"];
        return;
    }

    BOOL accepted = [info[@"ok"] boolValue] &&
        [info[@"verifyDiff"] integerValue] <= JJ_LEARN_MAX_DIFF;
    if (!accepted) {
        self.learnFailCount++;
        NSLog(@"[JJCheat] 学习校验未通过 verifyDiff=%@ ok=%@（第 %ld 次）",
              info[@"verifyDiff"], info[@"ok"] ?: @"-", (long)self.learnFailCount);
        /* 2.1.56 诊断：真机 verifyDiff=32 恰好等于开局子数 = 整盘棋子被判空。
           光看这个数字分不清「墨迹没采到」还是「网格偏了」，所以把几何
           （cell/radius/gridAspect）、亮度（gain/meanL）和 90 格的
           墨迹/暖色/模板分三张图一次打全。 */
        NSLog(@"[JJCheat] 学习诊断 cell=%@ radius=%@ gain=%@ meanL=%@ aspect=%@ "
               "warmTh=%@ flipped=%@ redN=%@ blkN=%@ 底红黑=%@/%@ 顶红黑=%@/%@",
              info[@"cell"] ?: @"-", info[@"radius"] ?: @"-",
              info[@"gain"] ?: @"-", info[@"meanL"] ?: @"-",
              info[@"gridAspect"] ?: @"-", info[@"warmThreshold"] ?: @"-",
              info[@"flipped"] ?: @"-", info[@"redN"] ?: @"-", info[@"blkN"] ?: @"-",
              info[@"bottomRed"] ?: @"-", info[@"bottomBlack"] ?: @"-",
              info[@"topRed"] ?: @"-", info[@"topBlack"] ?: @"-");
        /* 2.1.57：亮度三峰模型。空格必须落在 [loTh, hiTh] 之内，
           暗子 < loTh、亮子 > hiTh；有子数 occludedN 应等于当前盘面子数（开局 32）。
           2.1.60：墨迹占位模型 —— 浅木色盘面的皮肤里亮度三峰失效，
           占位判据改看墨迹（inkThOcc 自适应阈值 / boardInkMed 空格基线）。 */
        NSLog(@"[JJCheat] 亮度模型 盘面L=%@ 空格区间=[%@,%@] mad=%@ 判有子=%@ 墨迹阈值=%@ 墨迹基线=%@ 簇差=%@",
              info[@"boardL"] ?: @"-", info[@"loTh"] ?: @"-",
              info[@"hiTh"] ?: @"-", info[@"mad"] ?: @"-",
              info[@"occludedN"] ?: @"-",
              info[@"inkThOcc"] ?: @"-", info[@"boardInkMed"] ?: @"-",
              info[@"inkGap"] ?: @"-");
        /* 2.1.57：占位差 ≤4 才会现场裁模板；bootMade=1 说明这一帧的模板
           与真机像素同源，之后 score 才有意义。 */
        NSLog(@"[JJCheat] 模板自举 尝试=%@ 占位差=%@ 成功=%@ 模板数=%@",
              info[@"bootTried"] ?: @"-", info[@"bootOccDiff"] ?: @"-",
              info[@"bootMade"] ?: @"-", info[@"tplCount"] ?: @"-");
        /* 2.1.58：开局匹配滤波对齐。命中=开局 32 位里偏离棋盘亮度的格数，
           原命中=对齐前恒等网格的命中数。手指点四角误差 ±30px 会让采样窗
           只擦到棋子边缘 → 32 子全判空（2.1.57 根因），对齐就是治这个的。
           2.1.59 补打 原误报：恒等网格的空格误报数，与「采纳但误报超限」
           这类矛盾能当场对账。 */
        NSLog(@"[JJCheat] 格点对齐 采纳=%@ 命中=%@/32 空格误报=%@ 原命中=%@ 原误报=%@ 平移=%@,%@ 缩放=%@,%@",
              info[@"alignAccepted"] ?: @"-", info[@"alignOccHit"] ?: @"-",
              info[@"alignEmptyHit"] ?: @"-", info[@"alignIdOccHit"] ?: @"-",
              info[@"alignIdEmptyHit"] ?: @"-",
              info[@"alignShiftX"] ?: @"-", info[@"alignShiftY"] ?: @"-",
              info[@"alignScaleX"] ?: @"-", info[@"alignScaleY"] ?: @"-");
        NSLog(@"[JJCheat] 墨迹图 i=%@", info[@"diagI"] ?: @"-");
        NSLog(@"[JJCheat] 暖色图 w=%@", info[@"diagW"] ?: @"-");
        NSLog(@"[JJCheat] 亮度图 l=%@（36 进制，一位 = L/10）", info[@"diagL"] ?: @"-");
        NSLog(@"[JJCheat] 模板分 s=%@", info[@"diagS"] ?: @"-");
        NSLog(@"[JJCheat] 识别值 c=%@ gotFen=%@", info[@"codes36"] ?: @"-",
              info[@"gotFen"] ?: @"-");
        NSLog(@"[JJCheat] 差异格 %@", info[@"mismatch"] ?: @"-");
        [[JJCalibrator shared] dumpSamplesWithPixels:rgba width:w height:h];
        [self dumpFrameJPEG:rgba width:w height:h];
        if (self.calibrationPending && [[JJCalibrator shared] hasSnapshot] &&
            self.learnFailCount >= JJ_CALIB_ROLLBACK_FAILS) {
            [self rollbackCalibration];
            return;
        }
        if (self.learnFailCount >= JJ_LEARN_MAX_FAIL) {
            if ([[JJCalibrator shared] hasSnapshot]) {
                [self rollbackCalibration];
            } else {
                [self.timer invalidate];
                self.timer = nil;
                [[JJHUDWindow shared] showStatus:@"学习失败 · 请停在开局画面再点自动标定"];
                NSLog(@"[JJCheat] 学习连续失败 %ld 次，已暂停重试（未进入识别）",
                      (long)self.learnFailCount);
            }
            return;
        }
        /* 对齐都说画面里没几个子 → 十有八九停错了画面（大厅/结算/没进对局），
           提示要具体，别再让用户以为「学习又失败了」。 */
        {
            NSInteger alignOcc = [info[@"alignOccHit"] integerValue];
            if (alignOcc >= 0 && alignOcc < 10) {
                [[JJHUDWindow shared] showStatus:@"画面里没看到棋子 · 请停在【开局】棋盘"];
            } else {
                [[JJHUDWindow shared] showStatus:@"学习未完成 · 请停在【开局】棋盘画面"];
            }
        }
        return;
    }

    self.learnedBoard = YES;
    self.state = JJGameStateRunning;
    self.calibrationPending = NO;
    NSArray *fc = info[@"finalCorners"];
    if ([[JJCalibrator shared] adoptRefinedCorners:fc] && self.autoCalibrating) {
        [[JJCalibrator shared] saveAutoCalibratedCorners:fc width:w height:h];
    }
    [[JJCalibrator shared] snapshot];
    self.autoCalibrating = NO;
    /* 学成这一帧不算数：清指纹/帧序号/所有退避，保证下一张帧立刻出建议 */
    self.lastFingerprint = nil;
    self.lastFrameSerial = 0;
    self.processNotBefore = 0;
    self.lastProcessTime = 0;
    self.lastHeartbeatTs = 0;
    self.learnFailCount = 0;
    self.lastSearchFen = nil;
    self.engineResult = nil;
    self.engineGen++;
    NSLog(@"[JJCheat] 棋盘学习完成 verifyDiff=%@ ok=1 · 下一帧立即出建议 "
           "（cell=%@ radius=%@ gain=%@ aspect=%@ 底红黑=%@/%@）",
          info[@"verifyDiff"], info[@"cell"] ?: @"-", info[@"radius"] ?: @"-",
          info[@"gain"] ?: @"-", info[@"gridAspect"] ?: @"-",
          info[@"bottomRed"] ?: @"-", info[@"bottomBlack"] ?: @"-");
}

- (void)rollbackCalibration {
    [[JJCalibrator shared] restoreSnapshot];
    self.learnedBoard = YES;
    self.state = JJGameStateRunning;
    self.calibrationPending = NO;
    self.autoCalibrating = NO;
    self.lastFingerprint = nil;
    self.lastFrameSerial = 0;
    self.processNotBefore = 0;
    self.lastProcessTime = 0;
    self.learnFailCount = 0;
    [self startTimer];
    [[JJHUDWindow shared] showStatus:@"标定未成功 · 已恢复上次标定"];
    NSLog(@"[JJCheat] 重标定失败，回滚到上一次成功标定（JS 锚盘未清空）");
}

/* 2.1.59：学习失败时把这一帧落盘成 JPEG。
   2.1.58 真机日志出现「探针读到棋子色、90 格采样盘全木色」的矛盾，事后
   无法区分「帧里根本没有棋子（停错画面/棋子在别的渲染层）」还是「采样
   路径有 bug」。这张图一锤定音。固定文件名覆盖写，不堆积垃圾。 */
- (void)dumpFrameJPEG:(NSData *)rgba width:(int)w height:(int)h {
    if (!rgba.length || w <= 0 || h <= 0) return;
    if ((NSUInteger)w * (NSUInteger)h * 4 != rgba.length) return;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return;
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    CGImageRef img = prov ? CGImageCreate(w, h, 8, 32, (size_t)w * 4, space,
                                          kCGBitmapByteOrder32Big | kCGImageAlphaLast,
                                          prov, NULL, false, kCGRenderingIntentDefault)
                          : NULL;
    if (prov) CFRelease(prov);
    if (img) {
        UIImage *ui = [UIImage imageWithCGImage:img];
        CGImageRelease(img);
        NSData *jpg = ui ? UIImageJPEGRepresentation(ui, 0.55) : nil;
        if (jpg.length) {
            NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            NSString *path = [dir stringByAppendingPathComponent:@"JJCheat_frame_dump.jpg"];
            NSError *werr = nil;
            if ([jpg writeToFile:path options:NSDataWritingAtomic error:&werr]) {
                NSLog(@"[JJCheat] 失败帧已存图: %@（%lu B，取图看画面里到底有没有棋子）",
                      path, (unsigned long)jpg.length);
            } else {
                NSLog(@"[JJCheat] 失败帧存图失败: %@", werr.localizedDescription ?: @"-");
            }
        }
    }
    CGColorSpaceRelease(space);
}

#pragma mark - 识别结果 → 引擎 → HUD

- (void)handleProcessResult:(NSDictionary *)result {
    self.lastRecognition = result;

    BOOL stalled = [result[@"skipAnalyze"] boolValue];
    BOOL moved = [result[@"moveDetected"] boolValue];
    BOOL waiting = [result[@"waitingOpponent"] boolValue];
    BOOL newGame = [result[@"newGame"] boolValue];

    if (stalled) {
        self.processNotBefore = [[NSDate date] timeIntervalSince1970] + JJ_PROCESS_ILLEGAL_GAP;
        self.lastSearchFen = nil;
        self.engineResult = nil;
        self.engineGen++;
        NSLog(@"[JJCheat] 识别未收敛：legalNow=%@ codesValid=%@ codesStable=%@ repaired=%@ illegalStreak=%@ skipReason=%@（退避 %.1fs）",
              result[@"legalNow"] ?: @"-", result[@"codesValid"] ?: @"-",
              result[@"codesStableCount"] ?: @"-", result[@"repairedCount"] ?: @"-",
              result[@"illegalStreak"] ?: @"-", result[@"skipReason"] ?: @"-",
              JJ_PROCESS_ILLEGAL_GAP);
    }

    if (newGame) {
        NSLog(@"[JJCheat] 识别到新对局 → ucinewgame，清空引擎缓存");
        [[JJPikafish shared] notifyNewGame];
        self.lastSearchFen = nil;
        self.engineResult = nil;
        self.engineGen++;
    }

    /* 轮到我方且盘面可信 → 需要搜索 */
    NSString *fen = result[@"needSearch"] ? result[@"searchFen"] : nil;
    if (waiting || stalled) {
        /* 轮到对方 / 盘面不可信：不出箭头，丢掉旧结论 */
        self.engineResult = nil;
        self.lastSearchFen = nil;
        self.engineGen++;
        [self presentMergedResult];
    } else if (fen.length) {
        if ([fen isEqualToString:self.lastSearchFen] && self.engineResult) {
            [self presentMergedResult];   // 同一局面：直接端出缓存结论
        } else if ([fen isEqualToString:self.lastSearchFen] && self.enginePending) {
            [self presentMergedResult];   // 正在算同一局面：HUD 显示「思考中」
        } else {
            [self requestEngineForFen:fen];
            [self presentMergedResult];
        }
    } else {
        [self presentMergedResult];
    }

    /* 心跳：每 30s 一条盘面摘要 */
    NSTimeInterval hb = [[NSDate date] timeIntervalSince1970];
    if (hb - self.lastHeartbeatTs >= JJ_HEARTBEAT_GAP) {
        self.lastHeartbeatTs = hb;
        NSLog(@"[JJCheat] 盘面心跳 ply=%@ turn=%@ wait=%@ newGame=%@ engine=%@ rejected=%@ reseat=%@ skip=%@",
              result[@"ply"] ?: @"-", result[@"turn"] ?: @"-",
              result[@"waitingOpponent"] ?: @"-", result[@"newGame"] ?: @"-",
              [[JJPikafish shared] stateText], result[@"anchorRejected"] ?: @"-",
              result[@"reseat"] ?: @"-", result[@"skipReason"] ?: @"-");
    }

    if (moved) {
        NSLog(@"[JJCheat] 检测到走法 %@ %@ → FEN %@ | engine=%@ legalNow=%@ repaired=%@ diff=%@ rejected=%@ reseat=%@ ply=%@ wait=%@ anchor=%@",
              result[@"move"], result[@"moveChinese"], result[@"fen"],
              [[JJPikafish shared] stateText], result[@"legalNow"] ?: @"-",
              result[@"repairedCount"] ?: @"-", result[@"diffChanged"] ?: @"-",
              result[@"anchorRejected"] ?: @"-", result[@"reseat"] ?: @"-",
              result[@"ply"] ?: @"-", result[@"waitingOpponent"] ?: @"-",
              result[@"anchorFen"] ?: @"-");
    }
}

- (void)requestEngineForFen:(NSString *)fen {
    self.lastSearchFen = fen;
    self.enginePending = YES;
    self.engineResult = nil;
    NSInteger gen = ++self.engineGen;
    NSInteger movetime = self.thinkMs;
    __weak typeof(self) weakSelf = self;
    [[JJPikafish shared] analyzeFen:fen movetime:movetime completion:^(NSDictionary *res) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || gen != self2.engineGen) return;   // 过期结论丢弃
        self2.enginePending = NO;
        if (!res) {
            self2.engineResult = nil;
            [self2 presentMergedResult];
            return;
        }
        self2.engineResult = [self2 engineDisplayDictFrom:res fen:fen];
        [self2 presentMergedResult];
    }];
}

/** 引擎原始结果 → HUD 字段（中文记谱走原生 JJMoveCodec，不回头问 JS） */
- (NSDictionary *)engineDisplayDictFrom:(NSDictionary *)res fen:(NSString *)fen {
    NSString *mv = res[@"bestmove"] ?: @"";
    if (!mv.length) return @{};
    NSInteger score = [res[@"score"] integerValue];
    NSInteger mate = [res[@"mate"] integerValue];
    NSString *scoreText;
    if (mate != 0) {
        scoreText = [NSString stringWithFormat:@"%@杀 %ld", (mate > 0 ? @"+" : @"-"),
                     (long)labs(mate)];
    } else {
        scoreText = [NSString stringWithFormat:@"%@%.2f",
                     (score >= 0 ? @"+" : @""), score / 100.0];
    }
    return @{
        @"suggest": mv,
        @"suggestChinese": JJMoveChinese(fen, mv) ?: mv,
        @"from": res[@"from"] ?: @-1,
        @"to": res[@"to"] ?: @-1,
        @"scoreText": scoreText,
        @"score": @(score),
        @"mate": @(mate),
        @"winrate": res[@"winrate"] ?: @50,
        @"depth": res[@"depth"] ?: @0,
        @"nodes": res[@"nodes"] ?: @0,
        @"engine": @"pikafish"
    };
}

/** 合并识别结果 + 引擎结论 → HUD（包含箭头/文案/引擎状态） */
- (void)presentMergedResult {
    NSDictionary *rec = self.lastRecognition ?: @{};
    NSMutableDictionary *disp = [rec mutableCopy];
    NSDictionary *eng = self.engineResult;
    BOOL waiting = [rec[@"waitingOpponent"] boolValue];
    BOOL stalled = [rec[@"skipAnalyze"] boolValue];

    if (eng && !waiting && !stalled) {
        [disp addEntriesFromDictionary:eng];
    } else {
        disp[@"suggest"] = @"";
        disp[@"suggestChinese"] = @"";
        disp[@"from"] = @-1;
        disp[@"to"] = @-1;
    }
    disp[@"engineState"] = [[JJPikafish shared] stateText];
    disp[@"enginePending"] = self.enginePending ? @1 : @0;
    /* 2.1.68：把引擎"拒绝搜索"的真实原因透给 HUD。
       以前引擎网络加载失败时，HUD 会落到兜底分支显示「视角未对齐 · 请回开局画面」——
       那句话把人往识别方向引，而实际问题在引擎。这里明确区分开。 */
    NSString *notice = [JJPikafish shared].lastEngineNotice;
    if ([notice hasPrefix:@"JJ-NNUE FAIL"]) {
        disp[@"engineBlocked"] = @"网络未就绪";
    } else if ([[JJPikafish shared] state] == JJPikaStateDead) {
        disp[@"engineBlocked"] = @"引擎不可用";
    }
    disp[@"sideToMove"] = rec[@"sideToMove"] ?: (waiting ? @"black" : @"red");
    [[JJHUDWindow shared] showResult:disp
                          gridPoints:[JJCalibrator shared].gridPts
                                 fen:rec[@"fen"] ?: @""];
}

@end
