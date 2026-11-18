//
//  JJGameController.m
//  JJCheat
//

#import "JJGameController.h"
#import "JJConfig.h"
#import "JJCopy.h"
#import "JJCalibrator.h"
#import "JJVisionBridge.h"
#import "JJPikafish.h"
#import "JJPikafishInstaller.h"
#import "JJMoveCodec.h"
#import "JJEngineOptions.h"
#import "JJScreenGrabber.h"
#import "JJMetalGrabber.h"
#import "JJBallWindow.h"
#import "JJMenuSheet.h"
#import "JJMenuStyle.h"
#import "JJHUDWindow.h"
#import <UIKit/UIKit.h>
#import <math.h>

typedef NS_ENUM(NSInteger, JJGameState) {
    JJGameStateIdle = 0,
    JJGameStateCalibrating,
    JJGameStateWaitingBoard,   // 已标定，等用户进入一局新棋
    JJGameStateRunning,
};

/* 2.1.80：菜单动作标识。
 *
 * 【为什么必须枚举化】以前 onMenuItem 传的是「菜单数组下标」，菜单顺序一改就错位。
 * 2.1.78 把「重置开局」插到「HUD」前面之后，switch 没同步重排，结果：
 *   点「HUD」→ 执行 resetToStartPosition（HUD 当然不动）
 *   点「重置开局」→ 执行 toggleHUD
 * 这就是「HUD 开关不起作用」的根因。
 * 现在每项自带 action（从 100 起，一眼看出不是下标），顺序怎么变都不会错。
 */
typedef NS_ENUM(NSInteger, JJMenuAction) {
    JJMenuActionPlugin = 100,
    JJMenuActionManualCalibrate,
    JJMenuActionHUD,
    JJMenuActionResetBoard,
    JJMenuActionThink,
    JJMenuActionEngineOptions,
    JJMenuActionEngineStatus,
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
/* 2.1.80：当前显示的二级面板（步进器改值后要刷新它） */
@property (nonatomic, strong, nullable) JJMenuSheet *activeSheet;

- (void)showMenu;
- (void)setPluginEnabled:(BOOL)on;
- (void)manualCalibrate;
- (void)toggleHUD;
- (void)showEngineStatus;
- (void)applyThinkMs:(NSInteger)v;
/* 2.1.80：二级面板 */
- (void)showThinkSheet;
- (void)showEngineOptionsSheet;
- (void)showThreadsConfirmSheet;
- (void)applyThinkMs:(NSInteger)v announce:(BOOL)announce;
- (void)presentSheetTitled:(NSString *)title
                  subtitle:(nullable NSString *)subtitle
                      rows:(NSArray<JJSheetRow *> *)rows;
- (void)refreshActiveSheet;
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
        /* 2.1.79：思考时长与其它引擎参数的读取/迁移/夹区间统一在
           JJEngineOptions 里做，这里只取一次值，不再重复一遍迁移逻辑
           （两处各写一份是「同逻辑多实现」的典型，迟早分叉）。 */
        _thinkMs = [JJEngineOptions shared].thinkMs;
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
    self.ballWindow.onMenuItem = ^(NSInteger action) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        /* 2.1.80：按动作枚举分派（不再按下标）。
           每条都打一行日志，便于真机核对「点的是哪一项、实际执行了哪条路径」。 */
        NSLog(@"[JJCheat] 菜单动作 action=%ld", (long)action);
        switch (action) {
            case JJMenuActionPlugin:
                [self2 setPluginEnabled:!self2.enabled];
                break;
                break;
            case JJMenuActionManualCalibrate:
                [self2 manualCalibrate];
                break;
            case JJMenuActionHUD:
                [self2 toggleHUD];
                break;
            case JJMenuActionResetBoard:
                [self2 resetToStartPosition];
                break;
            case JJMenuActionThink:
                [self2 showThinkSheet];
                break;
            case JJMenuActionEngineOptions:
                [self2 showEngineOptionsSheet];
                break;
            case JJMenuActionEngineStatus:
                [self2 showEngineStatus];
                break;
            default:
                NSLog(@"[JJCheat] 未知菜单动作 %ld（菜单项未设置 action？）", (long)action);
                break;
        }
    };
    /* 2.1.79：搜索进度 → HUD。
       以前只在 bestmove 时刷新，用户点完球之后整段思考时间里界面毫无变化，
       主观上就是「卡住了」。现在深度/节点/分值边算边刷（引擎侧已 150ms 节流），
       而且着法一旦确定会先给中文提示，具体坐标等 bestmove 落地。
       注意：这里只更新文本，不画箭头 —— 箭头要等 bestmove，避免中途乱指。 */
    __weak typeof(self) ws = self;
    [[JJPikafish shared] setOnSearchProgress:^(NSDictionary *info) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        if (!s2.enginePending) return;          // 已经出结果了就不再刷
        NSMutableDictionary *disp = [NSMutableDictionary dictionary];
        NSDictionary *rec = s2.lastRecognition ?: @{};
        [disp addEntriesFromDictionary:rec];
        disp[@"from"] = @-1;                    // 搜索中不画箭头
        disp[@"to"] = @-1;
        disp[@"suggest"] = @"";
        disp[@"suggestChinese"] = @"";
        disp[@"depth"] = info[@"depth"] ?: @0;
        disp[@"nodes"] = info[@"nodes"] ?: @0;
        disp[@"score"] = info[@"score"] ?: @0;
        disp[@"mate"] = info[@"mate"] ?: @0;
        disp[@"enginePending"] = @1;
        disp[@"engineState"] = @"思考中";
        disp[@"sideToMove"] = rec[@"sideToMove"] ?: @"red";
        [[JJCalibrator shared] ensureGridPts];   // 2.1.104 兜底重建，防 gridPts 为空
        [[JJHUDWindow shared] showResult:disp
                              gridPoints:[JJCalibrator shared].gridPts
                                     fen:rec[@"fen"] ?: @""];
    }];

    [self.ballWindow attach];
}

#pragma mark - 悬浮球菜单

- (void)showMenu {
    /* 2.1.78：从「6 行长文案」改成「2×3 图标网格」。
       每格 = 图标 + 2~4 字标签，开/关用颜色表达，状态值拼在标签后面。
       旧版每行一句「① 插件开关：开」压在棋盘上，既挡视线又要读半天。 */
    NSMutableArray<JJMenuEntry *> *arr = [NSMutableArray arrayWithCapacity:6];

    /* 每项都显式带 action，不再依赖数组顺序（顺序随便排也不会错位） */
    JJMenuEntry *e0 = [JJMenuEntry title:@"插件" symbol:@"power"];
    e0.action = JJMenuActionPlugin;
    e0.value = self.enabled ? @"开" : @"关";
    e0.on = self.enabled;
    [arr addObject:e0];

    /* 2.1.105：自动标定已整体移除（在你的棋盘皮肤上首尾横线被木框遮住，
       任何"自动找线"都不可靠）。原位置改为只读的插件版本号。 */
    JJMenuEntry *e1 = [JJMenuEntry title:@"版本" symbol:@"info.circle"];
    e1.value = JJ_CHEAT_VERSION;
    e1.action = 0;              // 0 = 无动作，只展示
    [arr addObject:e1];

    JJMenuEntry *e2 = [JJMenuEntry title:@"手动标定" symbol:@"hand.tap"];
    e2.action = JJMenuActionManualCalibrate;
    [arr addObject:e2];

    JJMenuEntry *e3 = [JJMenuEntry title:@"HUD" symbol:@"rectangle.topthird.inset.filled"];
    e3.action = JJMenuActionHUD;
    e3.value = self.hudVisible ? @"开" : @"关";
    e3.on = self.hudVisible;
    [arr addObject:e3];

    /* 2.1.78：resetToStartPosition 原先**没有任何 UI 入口**（声明+实现都有，
       但全工程没人调用），「重置到开局」等于不存在。现在补进菜单。 */
    JJMenuEntry *eReset = [JJMenuEntry title:@"重置开局" symbol:@"arrow.counterclockwise"];
    eReset.action = JJMenuActionResetBoard;
    [arr addObject:eReset];

    JJMenuEntry *e4 = [JJMenuEntry title:@"思考" symbol:@"timer"];
    e4.action = JJMenuActionThink;
    {
        JJEngineOptions *o = [JJEngineOptions shared];
        e4.value = o.thinkDepth > 0
            ? [NSString stringWithFormat:@"D%ld", (long)o.thinkDepth]
            : [NSString stringWithFormat:@"%ldms", (long)o.thinkMs];
    }
    [arr addObject:e4];

    /* 2.1.79：引擎可调参数统一入口。
       菜单项与 JJEngineOptions 的配置键一一对应，加新参数只改那一层 + 这里的弹窗，
       不动搜索主流程。 */
    JJMenuEntry *eOpts = [JJMenuEntry title:@"引擎参数" symbol:@"slider.horizontal.3"];
    eOpts.action = JJMenuActionEngineOptions;
    [arr addObject:eOpts];

    /* 引擎状态：就绪=绿、启动中/搜索中=绿、异常=红。
       颜色直接反映健康度，不必点进去才知道。 */
    JJPikaState st = [[JJPikafish shared] state];
    JJMenuEntry *e5 = [JJMenuEntry title:@"引擎" symbol:@"cpu"];
    e5.action = JJMenuActionEngineStatus;
    e5.value = [[JJPikafish shared] stateText];
    e5.on = (st == JJPikaStateReady || st == JJPikaStateSearching);
    e5.warn = (st == JJPikaStateDead);
    [arr addObject:e5];

    [self.ballWindow showMenuWithEntries:arr];
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
        [self.ballWindow toast:@"插件已开启 · 正在识别棋盘"];
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
        [self.ballWindow toast:@"插件已关闭 · 抓帧与引擎都已停"];
        NSLog(@"[JJCheat] 插件开关 → 关（停止抓帧 / 识别 / 引擎）");
    }
}

- (void)toggleHUD {
    self.hudVisible = !self.hudVisible;
    [[NSUserDefaults standardUserDefaults] setBool:self.hudVisible forKey:JJ_KEY_HUD_VISIBLE];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
    [self.ballWindow toast:self.hudVisible ? @"HUD 已显示" : @"HUD 已隐藏（建议文字仍可在球上看到）"];
    NSLog(@"[JJCheat] HUD 显示=%@（window.hidden=%d, 键=%@）",
          self.hudVisible ? @"开" : @"关",
          (int)[JJHUDWindow shared].isHidden, JJ_KEY_HUD_VISIBLE);
}

#pragma mark - 思考时间（二级面板）

- (void)applyThinkMs:(NSInteger)v {
    [self applyThinkMs:v announce:YES];
}

- (void)applyThinkMs:(NSInteger)v announce:(BOOL)announce {
    /* 夹区间与持久化都在配置层，这里只同步内存值 + 反馈 */
    [[JJEngineOptions shared] setThinkMs:v];
    self.thinkMs = [JJEngineOptions shared].thinkMs;
    v = self.thinkMs;
    [[JJHUDWindow shared] showStatus:[NSString stringWithFormat:@"思考时间 %ld ms", (long)v]];
    if (announce) {
        [self.ballWindow toast:[NSString stringWithFormat:@"思考时间 %ld ms（下一步生效）", (long)v]];
    }
    NSLog(@"[JJCheat] 思考时间=%ld ms", (long)v);
}

/** 二级面板：思考时间。步进器 + 预设行，全程不弹系统键盘（键盘会盖住棋盘）。 */
- (void)showThinkSheet {
    if (!self.enabled) {
        [self.ballWindow toast:JJCopyNeedPluginOn];
        return;
    }
    JJEngineOptions *o = [JJEngineOptions shared];
    __weak typeof(self) ws = self;

    NSMutableArray<JJSheetRow *> *rows = [NSMutableArray array];

    [rows addObject:[JJSheetRow info:[NSString stringWithFormat:
                                     @"下一步生效 · 范围 %d~%d ms",
                                     JJ_OPT_THINK_MS_MIN, JJ_OPT_THINK_MS_MAX]]];

    /* 步进器：每档 50ms。为什么用步进而不是键盘 —— 键盘会盖住棋盘，
       而且这个值调一次就长期不动，微调比重新输入更顺手。
       回调里的 row 就是本行（2.1.81 起由面板传入），不要再反向捕获自己：
       「刚创建、还没强持有者」的对象赋给 __weak 会立刻变 nil，
       随后 addObject 抛 NSInvalidArgumentException（真机 07:49:42 崩在这）。 */
    JJSheetRow *step = [JJSheetRow stepper:@"时长"
                                    symbol:@"timer"
                                     value:[NSString stringWithFormat:@"%ld ms", (long)o.thinkMs]
                                  onChange:^(NSInteger delta, JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        NSInteger v = [JJEngineOptions shared].thinkMs + delta * 50;
        if (v < JJ_OPT_THINK_MS_MIN) v = JJ_OPT_THINK_MS_MIN;
        if (v > JJ_OPT_THINK_MS_MAX) v = JJ_OPT_THINK_MS_MAX;
        [s2 applyThinkMs:v announce:NO];
        row.detail = [NSString stringWithFormat:@"%ld ms", (long)v];
        [s2 refreshActiveSheet];
    }];
    [rows addObject:step];

    /* 预设：包含「当前值」并打勾，一键选回默认 */
    NSMutableArray<NSNumber *> *presets =
        [NSMutableArray arrayWithArray:@[@(350), @(650), @(1000), @(2000)]];
    if (![presets containsObject:@(o.thinkMs)]) [presets insertObject:@(o.thinkMs) atIndex:0];
    for (NSNumber *n in presets) {
        JJSheetRow *r = [JJSheetRow action:[NSString stringWithFormat:@"%@ ms", n]
                                        symbol:@"bolt.horizontal"
                                        detail:nil
                                       handler:^(JJSheetRow *row) {
            __strong typeof(ws) s2 = ws;
            if (!s2) return;
            [s2 applyThinkMs:n.integerValue announce:YES];
            /* 预设点完同步步进器的显示值，避免同屏两个数字不一致 */
            step.detail = [NSString stringWithFormat:@"%ld ms",
                           (long)[JJEngineOptions shared].thinkMs];
            for (JJSheetRow *rr in rows) {
                if (rr.kind == JJSheetRowKindAction) rr.on = NO;
            }
            row.on = YES;
            [s2 refreshActiveSheet];
        }];
        r.on = (n.integerValue == o.thinkMs);
        [rows addObject:r];
    }

    [rows addObject:[JJSheetRow action:JJCopySheetDone symbol:nil detail:nil handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [s2.ballWindow dismissSheet];
        [s2.ballWindow toast:[NSString stringWithFormat:@"思考时间 %ld ms",
                              (long)[JJEngineOptions shared].thinkMs]];
    }]];

    [self presentSheetTitled:JJCopySheetThinkTitle
                    subtitle:[o summary]
                        rows:rows];
    NSLog(@"[JJCheat] 打开思考时间面板");
}

- (void)showEngineOptionsSheet {
    if (!self.enabled) {
        [self.ballWindow toast:JJCopyNeedPluginOn];
        return;
    }
    JJEngineOptions *o = [JJEngineOptions shared];
    __weak typeof(self) ws = self;

    NSMutableArray<JJSheetRow *> *rows = [NSMutableArray array];
    [rows addObject:[JJSheetRow info:@"改完立即下发；标「需重启」的项会重载权重"]];

    /* ---- 思考方式：时间 / 深度二选一 ---- */
    JJSheetRow *byTime = [JJSheetRow action:@"按时间思考" symbol:@"clock" detail:nil
                                     handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [o setThinkDepth:0];
        [s2 afterEngineOptionsChanged:NO];
        [s2 showEngineOptionsSheet];        // 重开面板刷新勾选态与可用状态
        (void)row;
    }];
    byTime.on = (o.thinkDepth == 0);
    [rows addObject:byTime];

    JJSheetRow *timeStep = [JJSheetRow stepper:@"时长"
                                        symbol:@"timer"
                                         value:[NSString stringWithFormat:@"%ld ms", (long)o.thinkMs]
                                      onChange:^(NSInteger delta, JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        NSInteger v = [JJEngineOptions shared].thinkMs + delta * 50;
        v = MAX(JJ_OPT_THINK_MS_MIN, MIN(JJ_OPT_THINK_MS_MAX, v));
        o.thinkDepth = 0;                   // 调时间即视为「按时间思考」
        [o setThinkMs:v];
        s2.thinkMs = v;
        row.detail = [NSString stringWithFormat:@"%ld ms", (long)v];
        [s2 afterEngineOptionsChanged:NO];
        [s2 refreshActiveSheet];
    }];
    timeStep.enabled = (o.thinkDepth == 0);
    [rows addObject:timeStep];

    JJSheetRow *byDepth = [JJSheetRow action:@"按深度思考" symbol:@"chart.bar" detail:nil
                                      handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        if ([o thinkDepth] <= 0) [o setThinkDepth:10];   // 打开深度模式给个常用值
        [s2 afterEngineOptionsChanged:NO];
        [s2 showEngineOptionsSheet];
        (void)row;
    }];
    byDepth.on = (o.thinkDepth > 0);
    [rows addObject:byDepth];

    JJSheetRow *depthStep = [JJSheetRow stepper:@"深度"
                                         symbol:@"arrow.down.to.line"
                                          value:(o.thinkDepth > 0
                                                 ? [NSString stringWithFormat:@"%ld 层", (long)o.thinkDepth]
                                                 : @"关闭")
                                       onChange:^(NSInteger delta, JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        NSInteger v = [JJEngineOptions shared].thinkDepth;
        v = MAX(JJ_OPT_THINK_DEPTH_MIN, MIN(JJ_OPT_THINK_DEPTH_MAX, v + delta));
        [o setThinkDepth:v];
        row.detail = v > 0 ? [NSString stringWithFormat:@"%ld 层", (long)v] : @"关闭";
        NSLog(@"[JJCheat] 引擎参数 ThinkDepth=%ld（0=按时间）", (long)v);
        [s2 afterEngineOptionsChanged:NO];
        [s2 refreshActiveSheet];
    }];
    depthStep.enabled = (o.thinkDepth > 0);
    [rows addObject:depthStep];

    /* ---- 资源 ---- */
    JJSheetRow *hash = [JJSheetRow stepper:@"哈希表"
                                    symbol:@"memorychip"
                                     value:[NSString stringWithFormat:@"%ld MB", (long)o.hashMb]
                                  onChange:^(NSInteger delta, JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        NSInteger v = [JJEngineOptions shared].hashMb + delta * 8;
        v = MAX(JJ_OPT_HASH_MB_MIN, MIN(JJ_OPT_HASH_MB_MAX, v));
        [o setHashMb:v];
        row.detail = [NSString stringWithFormat:@"%ld MB", (long)v];
        NSLog(@"[JJCheat] 引擎参数 Hash=%ldMB → applyOptionsHot", (long)v);
        [s2 afterEngineOptionsChanged:NO];
        [s2 refreshActiveSheet];
    }];
    [rows addObject:hash];

    JJSheetRow *mpv = [JJSheetRow stepper:@"多线路"
                                   symbol:@"list.number"
                                    value:[NSString stringWithFormat:@"%ld", (long)o.multiPV]
                                 onChange:^(NSInteger delta, JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        NSInteger v = [JJEngineOptions shared].multiPV + delta;
        v = MAX(JJ_OPT_MULTIPV_MIN, MIN(JJ_OPT_MULTIPV_MAX, v));
        [o setMultiPV:v];
        row.detail = [NSString stringWithFormat:@"%ld", (long)v];
        NSLog(@"[JJCheat] 引擎参数 MultiPV=%ld → applyOptionsHot", (long)v);
        [s2 afterEngineOptionsChanged:NO];
        [s2 refreshActiveSheet];
    }];
    [rows addObject:mpv];

    /* ---- 其它（2.1.80 补齐：此前有配置键但无 UI 入口）---- */
    JJSheetRow *overhead = [JJSheetRow stepper:@"落子余量"
                                        symbol:@"hourglass"
                                         value:[NSString stringWithFormat:@"%ld ms", (long)o.moveOverhead]
                                      onChange:^(NSInteger delta, JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        NSInteger v = [JJEngineOptions shared].moveOverhead + delta * 10;
        v = MAX(JJ_OPT_MOVE_OVERHEAD_MIN, MIN(JJ_OPT_MOVE_OVERHEAD_MAX, v));
        [o setMoveOverhead:v];
        row.detail = [NSString stringWithFormat:@"%ld ms", (long)v];
        NSLog(@"[JJCheat] 引擎参数 MoveOverhead=%ldms → applyOptionsHot", (long)v);
        [s2 afterEngineOptionsChanged:NO];
        [s2 refreshActiveSheet];
    }];
    [rows addObject:overhead];

    JJSheetRow *wdl = [JJSheetRow action:@"显示胜率"
                                  symbol:@"percent"
                                  detail:(o.showWDL ? @"开" : @"关")
                                 handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        JJEngineOptions *oo = [JJEngineOptions shared];
        [oo setShowWDL:!oo.showWDL];
        row.on = oo.showWDL;
        row.detail = oo.showWDL ? @"开" : @"关";
        NSLog(@"[JJCheat] 引擎参数 ShowWDL=%d → applyOptionsHot", (int)oo.showWDL);
        [s2 afterEngineOptionsChanged:NO];
        [s2 refreshActiveSheet];
    }];
    wdl.on = o.showWDL;
    [rows addObject:wdl];

    /* ---- 线程数：危险项，单独二次确认 ---- */
    JJSheetRow *threads = [JJSheetRow danger:[NSString stringWithFormat:@"线程数（当前 %ld）",
                                              (long)o.threads]
                                      symbol:@"cpu"
                                     handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [s2 showThreadsConfirmSheet];
        (void)row;
    }];
    [rows addObject:threads];

    [rows addObject:[JJSheetRow action:JJCopySheetDone symbol:nil detail:nil handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [s2.ballWindow dismissSheet];
        (void)row;
    }]];

    [self presentSheetTitled:JJCopySheetEngineTitle subtitle:[o summary] rows:rows];
    NSLog(@"[JJCheat] 打开引擎参数面板");
}

- (void)showThreadsConfirmSheet {
    JJEngineOptions *o = [JJEngineOptions shared];
    __weak typeof(self) ws = self;

    NSMutableArray<JJSheetRow *> *rows = [NSMutableArray array];
    [rows addObject:[JJSheetRow info:[NSString stringWithFormat:
        @"当前 %ld 线程。改线程数会重建引擎的搜索线程池；历史上（2.1.60~62）"
        @"真机出现过重建后搜索闪退。改完会立即重启引擎（重载 50MB 权重 1~3 秒）。"
        @"若闪退，重进 App 把线程数改回 1 即可恢复。", (long)o.threads]]];

    JJSheetRow *step = [JJSheetRow stepper:@"线程数"
                                    symbol:@"cpu"
                                     value:[NSString stringWithFormat:@"%ld", (long)o.threads]
                                  onChange:^(NSInteger delta, JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        NSInteger v = [JJEngineOptions shared].threads + delta;
        v = MAX(JJ_OPT_THREADS_MIN, MIN(JJ_OPT_THREADS_MAX, v));
        [o setThreads:v];
        row.detail = [NSString stringWithFormat:@"%ld", (long)v];
        [s2 refreshActiveSheet];
    }];
    [rows addObject:step];

    [rows addObject:[JJSheetRow danger:@"应用并重启引擎" symbol:@"arrow.clockwise"
                               handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [s2.ballWindow dismissSheet];
        [s2 afterEngineOptionsChanged:YES];
        (void)row;
    }]];

    [rows addObject:[JJSheetRow action:JJCopySheetCancel symbol:nil detail:nil handler:^(JJSheetRow *row) {
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [s2.ballWindow dismissSheet];
        (void)row;
    }]];

    [self presentSheetTitled:JJCopySheetThreadsTitle subtitle:nil rows:rows];
}

- (void)presentSheetTitled:(NSString *)title
                  subtitle:(NSString *)subtitle
                      rows:(NSArray<JJSheetRow *> *)rows {
    CGFloat w = MIN(JJMenuSheetMaxW, [UIScreen mainScreen].bounds.size.width - 32.0);
    CGFloat h = [JJMenuSheet heightForWidth:w rows:rows hasSubtitle:subtitle.length > 0];
    JJMenuSheet *sheet = [[JJMenuSheet alloc] initWithTitle:title subtitle:subtitle rows:rows];
    sheet.frame = CGRectMake(0, 0, w, h);
    self.activeSheet = sheet;
    [self.ballWindow showSheet:sheet];
}

- (void)refreshActiveSheet {
    if (!self.activeSheet || !self.activeSheet.superview) return;
    [self.activeSheet refreshValues];
    /* 副标题是「引擎参数摘要」：改完 Hash/线程 等，这里要跟着变，
       否则面板上写着旧值、实际已经改了，看起来像「设置没生效」。 */
    [self.activeSheet refreshSubtitle:[[JJEngineOptions shared] summary]];
}

- (void)afterEngineOptionsChanged:(BOOL)needsRestart {
    JJEngineOptions *o = [JJEngineOptions shared];
    if (needsRestart) {
        [self.ballWindow toast:@"正在重启引擎（重新加载权重）…"];
        [[JJPikafish shared] shutdown];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[JJPikafish shared] start];
            [self.ballWindow toast:@"引擎已按新参数重启"];
        });
    } else {
        /* 不重建线程：只下发 setoption，下一步搜索就生效 */
        [[JJPikafish shared] applyOptionsHot];
        /* 步进器连续点按不逐次 toast，避免刷屏；摘要已经显示在副标题里 */
    }
    NSLog(@"[JJCheat] 引擎参数变更: %@ (restart=%d)", [o summary], (int)needsRestart);
}

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

    [msg appendFormat:@"%@", [[JJEngineOptions shared] summary]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"皮卡鱼引擎"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    if (self.ballWindow.hidden) [self.ballWindow attach];
    if (self.ballWindow.rootViewController.presentedViewController) {
        [self.ballWindow toast:JJCopyCloseDialogFirst];
        return;
    }
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

- (void)manualCalibrate {
    if (!self.enabled) {
        [[JJHUDWindow shared] showStatus:JJCopyNeedPluginOn];
        [self.ballWindow toast:JJCopyNeedPluginOn];
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

    [self.ballWindow toast:JJCopyCalibTapFourCorners];
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
            [[JJHUDWindow shared] showStatus:JJCopyCalibInvalidRestored];
            [self.ballWindow toast:JJCopyCalibInvalidRestored];
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

    /* 2.1.105：标定一完成就**立刻把网格画出来**，让用户当场确认四角准不准，
       不必等模板学习（学习失败时原来什么都不会显示）。 */
    [[JJCalibrator shared] ensureGridPts];
    [[JJHUDWindow shared] applyGridPoints:[JJCalibrator shared].gridPts];
    self.processNotBefore = 0;
    [self startTimer];
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
    [[JJHUDWindow shared] showStatus:@"标定完成 · 请进入一局新棋（开局布局）"];
    [self.ballWindow toast:JJCopyCalibDone];
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
    [self.ballWindow toast:JJCopyResetDone];
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

/* 2.1.77：单点最大差。
   累加差会被 270 个值的基数稀释 —— 一个低对比度的子移动只影响 2 个点，
   每点差 30 左右，累加 ≈ 180，低于 JJ_FRAME_DIFF_THRESHOLD（260）就被判「画面没变」，
   整轮跳过。这正是「对方走了但没反应」的另一个来源。
   单点差不会被稀释：某一点跳变 45 以上就认为画面确实变了。 */
static int JJFrameFingerprintMaxPointDiff(const int32_t *a, const int32_t *b) {
    int mx = 0;
    for (int i = 0; i < JJ_FP_POINTS; i++) {
        int d = 0;
        for (int k = 0; k < 3; k++) {
            int v = (int)(a[i * 3 + k] - b[i * 3 + k]);
            if (v < 0) v = -v;
            d += v;
        }
        if (d > mx) mx = d;
    }
    return mx;
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

    NSArray *fpCorners = [JJCalibrator shared].finalCorners.count == 4
        ? [JJCalibrator shared].finalCorners
        : [[JJCalibrator shared] cornersForWidth:w height:h];

    /* 2.1.77：把棋盘四角交给抓帧层，让它能在 IOSurface 锁内只采 90 点判变化，
       而不是每 1.5 秒无条件拷 14MB。
       只在标定完成后启用：学习棋盘阶段必须保证「每 1.5 秒必有一帧」，
       否则静止画面靠 3 秒心跳供帧，学习重试节奏会被拖慢。
       没把握到角点时不传（nil），抓帧层自动退回旧的定时拷贝。 */
    JJMetalSetBoardCorners(self.learnedBoard && fpCorners.count == 4 ? fpCorners : nil);

    /* 帧差驱动：新帧但画面没变 → 整轮跳过（静态局面连 JS 都不调） */
    if (self.learnedBoard) {
        if (fpCorners.count == 4) {
            int32_t sample[JJ_FP_VALUES];
            if (JJFrameFingerprint(rgba, w, h, fpCorners, sample)) {
                const int32_t *prevFP = self.lastFingerprint.length == sizeof(sample)
                    ? (const int32_t *)self.lastFingerprint.bytes : NULL;
                BOOL unchanged = prevFP &&
                    JJFrameFingerprintDiff(prevFP, sample) < JJ_FRAME_DIFF_THRESHOLD &&
                    JJFrameFingerprintMaxPointDiff(prevFP, sample) < JJ_FP_POINT_DELTA;
                if (unchanged) {
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
    /* ★ 2.1.97：**几何检测的网格先采纳，不等模板学习**。
     *
     * learnBoard 干的是「学 90 格模板」，必须有标准开局的 32 个棋子才成功；
     * 空棋盘、中局、残局都必然失败。而 detectGrid 是纯几何反解（找 9 竖 10 横），
     * **空棋盘恰恰是最准的场景**（没有任何棋子遮挡线条）。
     *
     * 过去两者捆在一条链路上，几何算得再准，也会因为"模板没学成"被整条否决，
     * 网格于是永远停在旧坐标。真机实测证据：插件网格 x=32~394，而棋盘实际
     * x=28~399 —— 窄了 9px，两头各偏 4~5px，边缘棋子必然读错。
     */
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

    /* ★ 2.1.102：真机没有 log 命令，把整份学习诊断落到容器 Documents 里。
     * 关键要看两条：① verifyDiff 到底多大 ② 学习那一刻用的 corners 是什么。
     * 离线用同一份抓帧跑 learnAndRefine 是 verifyDiff=0，真机却失败，
     * 说明差异只可能在「真机传进去的四角」或「抓帧内容」上。 */
    {
        NSMutableString *dg = [NSMutableString string];
        [dg appendFormat:@"accepted=%d verifyDiff=%@ ok=%@ templateCount=%@\n",
            accepted, info[@"verifyDiff"] ?: @"-", info[@"ok"] ?: @"-", info[@"templateCount"] ?: @"-"];
        [dg appendFormat:@"finalCorners=%@\n", [JJCalibrator shared].finalCorners ?: @"nil"];
        [dg appendFormat:@"autoCalibrating=%d\n", self.autoCalibrating];
        [dg appendFormat:@"cell=%@ radius=%@ gain=%@ meanL=%@ gridAspect=%@\n",
            info[@"cell"] ?: @"-", info[@"radius"] ?: @"-", info[@"gain"] ?: @"-",
            info[@"meanL"] ?: @"-", info[@"gridAspect"] ?: @"-"];
        [dg appendFormat:@"redN=%@ blkN=%@ alignOccHit=%@ alignAccepted=%@\n",
            info[@"redN"] ?: @"-", info[@"blkN"] ?: @"-",
            info[@"alignOccHit"] ?: @"-", info[@"alignAccepted"] ?: @"-"];
        [dg appendFormat:@"mismatch=%@\n", info[@"mismatch"] ?: @"-"];
        [dg appendFormat:@"size=%dx%d\n", w, h];
        NSString *dp = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/JJCheat_learn_diag.txt"];
        [dg writeToFile:dp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

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
        /* 2.1.77：分级退避。旧值 2.5 秒是一刀切黑洞，对手在此期间落子会被整个漏掉。
           偶发一帧垃圾（illegalStreak <= 1）只歇 0.4 秒就重试；
           连续垃圾说明画面确实读不出来，才逐步拉到 1.2 秒。 */
        NSInteger streak = [result[@"illegalStreak"] integerValue];
        NSTimeInterval gap = (streak >= 3) ? JJ_PROCESS_ILLEGAL_GAP_LONG : JJ_PROCESS_ILLEGAL_GAP;
        self.processNotBefore = [[NSDate date] timeIntervalSince1970] + gap;
        self.lastSearchFen = nil;
        self.engineResult = nil;
        self.engineGen++;
        NSLog(@"[JJCheat] 识别未收敛：legalNow=%@ codesValid=%@ codesStable=%@ repaired=%@ illegalStreak=%@ skipReason=%@（退避 %.1fs）",
              result[@"legalNow"] ?: @"-", result[@"codesValid"] ?: @"-",
              result[@"codesStableCount"] ?: @"-", result[@"repairedCount"] ?: @"-",
              result[@"illegalStreak"] ?: @"-", result[@"skipReason"] ?: @"-",
              gap);
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
    } else if (moved && !fen.length) {
        /* 2.1.84：识别到走子、但本帧没有新的可搜索 FEN（例如刚走完、
           盘面还在稳定过程中）——立即作废旧结论，避免「我方走完箭头还挂着」。
           旧逻辑这里只打日志不清 engineResult，旧箭头会一直被端出来。 */
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
        disp[@"engineBlocked"] = JJCopyEngineNetNotReady;
    } else if ([[JJPikafish shared] state] == JJPikaStateDead) {
        disp[@"engineBlocked"] = JJCopyEngineUnavailable;
    } else if ([rec[@"skipReason"] isEqualToString:@"king"]) {
        /* 2.1.76：识别侧主动拦下了这一帧（王/将不唯一，或走子方能吃对方王）。
           这种盘面 Pikafish 会拒绝，以前会让它 exit 拆掉 App。
           现在只是这一帧不发搜索 —— 明确告诉用户是识别在等，不是视角问题。 */
        disp[@"engineBlocked"] = JJCopyRecogPendingKing;
    }
    disp[@"sideToMove"] = rec[@"sideToMove"] ?: (waiting ? @"black" : @"red");

    /* ★ 2.1.79 修「我方执黑时箭头指向对角」
     *
     * from/to 来自 JJSqFromICCS/JJPikafish，是**引擎坐标（红永远在下）**；
     * 而 gridPoints 是**屏幕坐标**（row 0 = 用户点按的顶边）。
     * 执黑时 JS 侧用 flipCodes() 把屏幕格旋转 180° 转成引擎坐标去组 FEN，
     * 但画箭头时没有转回来 —— 行、列同时反向 → 箭头指向对角。
     *
     * 统一在这里做一次反变换，只在「喂给 HUD」这一个出口做：
     * 不要在 JJPikafish 里改（那会污染搜索缓存与日志里的 FEN），
     * 也不要在 HUD 里改（HUD 不该知道引擎坐标的存在）。
     * 旋转 180° 正反同式，所以直接复用 JJSqRotate180。 */
    if ([rec[@"flipped"] integerValue] != 0) {
        NSInteger f = [disp[@"from"] integerValue];
        NSInteger t = [disp[@"to"] integerValue];
        if (f >= 0 && f < 90) disp[@"from"] = @(JJSqRotate180((int)f));
        if (t >= 0 && t < 90) disp[@"to"] = @(JJSqRotate180((int)t));

        /* pv 是 ICCS 串序列，将来画多层箭头时同样需要旋转。
           ICCS 与内部 sq 的关系：col = sq%9, rank = 9 - sq/9（见 JJMoveCodec.m 顶部）。
           这里从 ICCS 解出 sq → 旋转 → 再拼回 ICCS，顺序必须保持 from 在前。 */
        if ([disp[@"pv"] isKindOfClass:[NSArray class]]) {
            NSMutableArray *pv2 = [NSMutableArray array];
            for (id m in (NSArray *)disp[@"pv"]) {
                if (![m isKindOfClass:[NSString class]] || [(NSString *)m length] < 4) {
                    [pv2 addObject:m];
                    continue;
                }
                int a = JJSqFromICCS(m, 0), b = JJSqFromICCS(m, 1);
                if (a < 0 || b < 0) {
                    [pv2 addObject:m];
                    continue;
                }
                int ra = JJSqRotate180(a), rb = JJSqRotate180(b);
                /* sq → ICCS：列 = sq%9 的字母，rank = 9 - sq/9 */
                [pv2 addObject:[NSString stringWithFormat:@"%c%d%c%d",
                                (char)('a' + ra % 9), 9 - ra / 9,
                                (char)('a' + rb % 9), 9 - rb / 9]];
            }
            disp[@"pv"] = pv2;
        }
    }

    [[JJCalibrator shared] ensureGridPts];       // 2.1.104 兜底重建，防 gridPts 为空
    [[JJHUDWindow shared] showResult:disp
                          gridPoints:[JJCalibrator shared].gridPts
                                 fen:rec[@"fen"] ?: @""];
}

@end
