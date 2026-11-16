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

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

typedef NS_ENUM(NSInteger, JJCtrlState) {
    JJCtrlStateIdle = 0,
    JJCtrlStateCalibrating,
    JJCtrlStateWaitingBoard,   // 已标定，等用户进入一局新棋
    JJCtrlStateRunning,
};

/* ============================================================
 *  悬浮球 —— 点击弹出设置菜单，可拖动 / 长按快速手动标定
 * ============================================================ */
static const CGFloat kJJBallSize       = 52.0;
static const CGFloat kJJMenuWidth      = 232.0;
static const CGFloat kJJMenuRowHeight  = 44.0;

/** 插件图标：优先读随 deb 落到 jbroot 的 logo.png，读不到就回退文字「象棋」。 */
static UIImage *JJLoadLogoImage(void) {
    NSString *rel = [@"/" stringByAppendingString:JJ_LOGO_REL_PATH];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:5];
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    [paths addObject:jbroot(rel)];
#endif
    [paths addObject:rel];
    [paths addObject:[JJ_ENGINE_PATH_ROOTLESS stringByReplacingOccurrencesOfString:@"engine.js"
                                                                       withString:@"logo.png"]];
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (dirs.count) [paths addObject:[dirs[0] stringByAppendingPathComponent:@"JJCheat/logo.png"]];
    NSString *inBundle = [[NSBundle mainBundle] pathForResource:@"logo" ofType:@"png"];
    if (inBundle.length) [paths addObject:inBundle];

    for (NSString *p in paths) {
        if (!p.length) continue;
        UIImage *im = [UIImage imageWithContentsOfFile:p];
        if (im) {
            NSLog(@"[JJCheat] 插件图标命中: %@", p);
            return im;
        }
    }
    NSLog(@"[JJCheat] 插件图标未找到，悬浮球回退文字");
    return nil;
}

@interface JJBallWindow : UIWindow
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *menuView;
@property (nonatomic, assign) BOOL usesLogo;
@property (nonatomic, assign, getter=isMenuVisible) BOOL menuVisible;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);
@property (nonatomic, copy) void (^onMenuItem)(NSInteger index);

- (void)setActive:(BOOL)active;
- (void)showMenuWithTitles:(NSArray<NSString *> *)titles;
- (void)hideMenu;
@end

@implementation JJBallWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1001.0;
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [[UIViewController alloc] init];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        CGRect scr = [UIScreen mainScreen].bounds;
        /* 菜单遮罩：点空白处收起菜单，避免把触摸漏给游戏造成误落子 */
        _backdrop = [[UIView alloc] initWithFrame:scr];
        _backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22];
        _backdrop.hidden = YES;
        [_backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(closeMenuTap)]];
        [self.rootViewController.view addSubview:_backdrop];

        _menuView = [[UIView alloc] initWithFrame:CGRectZero];
        _menuView.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:0.97];
        _menuView.layer.cornerRadius = 12.0;
        _menuView.layer.borderWidth = 1.0;
        _menuView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        _menuView.clipsToBounds = YES;
        _menuView.hidden = YES;
        [self.rootViewController.view addSubview:_menuView];

        CGFloat d = kJJBallSize;
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

        UIImage *logo = JJLoadLogoImage();
        if (logo) {
            self.usesLogo = YES;
            [_ball setTitle:nil forState:UIControlStateNormal];
            [_ball setImage:logo forState:UIControlStateNormal];
            _ball.imageView.contentMode = UIViewContentModeScaleAspectFit;
            _ball.imageEdgeInsets = UIEdgeInsetsMake(3, 3, 3, 3);
            _ball.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.94];
            _ball.layer.borderColor = [UIColor colorWithWhite:0.85 alpha:1.0].CGColor;
        }

        [_ball addTarget:self action:@selector(tapBall) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panBall:)];
        [_ball addGestureRecognizer:pan];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(lpBall:)];
        [_ball addGestureRecognizer:lp];

        [self.rootViewController.view addSubview:_ball];
    }
    return self;
}

/* 未激活：半透明；激活后：实心（有 logo 时只改透明度，别把图片标题冲掉） */
- (void)setActive:(BOOL)active {
    self.ball.alpha = active ? 1.0 : 0.55;
    if (!self.usesLogo) {
        [self.ball setTitle:(active ? @"象\n棋" : @"点\n我") forState:UIControlStateNormal];
    }
}

- (void)tapBall { if (self.onTap) self.onTap(); }

- (void)closeMenuTap { [self hideMenu]; }

/** 在球旁边竖排列出设置项；点击任意项先收起菜单再回调上层。 */
- (void)showMenuWithTitles:(NSArray<NSString *> *)titles {
    for (UIView *v in [self.menuView.subviews copy]) [v removeFromSuperview];

    CGFloat w = kJJMenuWidth;
    CGFloat rowH = kJJMenuRowHeight;
    CGFloat menuH = rowH * (CGFloat)titles.count;
    CGRect scr = [UIScreen mainScreen].bounds;

    CGFloat x = CGRectGetMinX(self.ball.frame) - w - 10.0;
    if (x < 8.0) x = CGRectGetMaxX(self.ball.frame) + 10.0;
    x = MAX(8.0, MIN(x, scr.size.width - w - 8.0));
    CGFloat y = CGRectGetMidY(self.ball.frame) - menuH / 2.0;
    y = MAX(60.0, MIN(y, scr.size.height - menuH - 40.0));
    self.menuView.frame = CGRectMake(x, y, w, menuH);

    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, (CGFloat)i * rowH, w, rowH);
        b.tag = (NSInteger)(100 + i);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14.0];
        b.titleLabel.numberOfLines = 2;
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.titleLabel.minimumScaleFactor = 0.8;
        [b addTarget:self action:@selector(menuItemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.menuView addSubview:b];
        if (i > 0) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(10, (CGFloat)i * rowH, w - 20, 0.5)];
            sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
            [self.menuView addSubview:sep];
        }
    }
    self.backdrop.hidden = NO;
    self.menuView.hidden = NO;
    self.menuVisible = YES;
}

- (void)hideMenu {
    self.backdrop.hidden = YES;
    self.menuView.hidden = YES;
    self.menuVisible = NO;
}

- (void)menuItemTapped:(UIButton *)b {
    NSInteger idx = b.tag - 100;
    [self hideMenu];
    if (self.onMenuItem) self.onMenuItem(idx);
}

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
    if (v == self.ball) return v;
    /* 菜单打开时放行遮罩与菜单按钮（点遮罩即收起），其余一律透传给游戏 */
    if (self.menuVisible && v &&
        (v == self.backdrop || [v isDescendantOfView:self.menuView])) {
        return v;
    }
    return nil;
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
/* 学习静默失败计数：每 5 次留一条日志，杜绝「没提示又没日志」的黑洞 */
@property (nonatomic, assign) NSInteger learnFailCount;
/* 插件总开关：关掉后连 Metal 抓帧 hook 都停止读帧，真正不占渲染线程 */
@property (nonatomic, assign) BOOL enabled;
/* 思考时长（ms），悬浮球菜单可改，持久化到 JJ_KEY_THINK_MS */
@property (nonatomic, assign) NSInteger thinkMs;
/* process 节流：一次 JS 处理要数秒，回调刚落地不能立刻再发下一帧 */
@property (nonatomic, assign) NSTimeInterval lastProcessTime;
@property (nonatomic, assign) NSTimeInterval processNotBefore;
/* 自动标定：本轮学习采纳的精修四角要写回 JJ_KEY_CORNERS */
@property (nonatomic, assign) BOOL autoCalibrating;

- (void)showMenu;
- (void)setPluginEnabled:(BOOL)on;
- (void)autoCalibrate;
- (void)manualCalibrate;
- (void)toggleHUD;
- (void)editThinkMs;
- (void)applyThinkMs:(NSInteger)v;
- (void)saveAutoCalibratedCorners:(NSArray *)fc width:(int)w height:(int)h;
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
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        _state = JJCtrlStateIdle;
        _enabled = [ud objectForKey:JJ_KEY_ENABLED] ? [ud boolForKey:JJ_KEY_ENABLED] : YES;
        _hudVisible = [ud objectForKey:JJ_KEY_HUD_VISIBLE] ? [ud boolForKey:JJ_KEY_HUD_VISIBLE] : YES;
        NSInteger savedMs = [ud integerForKey:JJ_KEY_THINK_MS];
        _thinkMs = savedMs > 0
            ? MIN(JJ_THINK_MS_MAX, MAX(JJ_THINK_MS_MIN, savedMs))
            : JJ_THINK_MS_DEFAULT;
        _learnedBoard = NO;
        _busy = NO;
        _tickCount = 0;
        NSLog(@"[JJCheat] 配置: 插件=%@ HUD=%@ 思考=%ldms",
              _enabled ? @"开" : @"关", _hudVisible ? @"开" : @"关", (long)_thinkMs);
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
    /* 待机时把 Metal hook 的读帧也彻底关掉：原来只是上层不取帧，
       hook 仍按 0.2s/次在游戏渲染线程读 14MB + 350 万次字节交换，游戏照样卡。 */
    JJMetalSetCaptureEnabled(NO);
    /* 这里刻意不做：loadEngine / grabber.start / HUD attach / startTimer
       避免在登录页、大厅、结算页上误学棋盘、误识别 */
}

/* 用户点球后才真正开工 */
- (void)activate {
    if (self.activated || !self.enabled) return;
    self.activated = YES;
    [self.ballWindow setActive:YES];
    NSLog(@"[JJCheat] 用户点球 → 开始抓帧与识别");

    JJMetalSetCaptureEnabled(YES);
    self.lastProcessTime = 0;
    self.processNotBefore = 0;
    [[JJScreenGrabber shared] start];
    [[JJEngineBridge shared] loadEngine];
    [[JJHUDWindow shared] attach];
    /* attach 会把 window.hidden 置 NO，这里按持久化的 HUD 开关还原 */
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];

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
    self.busy = NO;
    JJMetalSetCaptureEnabled(NO);
    [[JJScreenGrabber shared] stop];
}

- (void)setupBall {
    if (self.ballWindow) return;
    self.ballWindow = [[JJBallWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    __weak typeof(self) weakSelf = self;
    self.ballWindow.onTap = ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        if (self2.ballWindow.isMenuVisible) {
            [self2.ballWindow hideMenu];
            return;
        }
        /* 第一次点球沿用原行为（开工），之后每次点球都弹设置菜单 */
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
            default: break;
        }
    };
    [self.ballWindow attach];
}

#pragma mark - 悬浮球菜单

/** 每次打开都按当前状态重新生成标题，避免显示过期开关值。 */
- (void)showMenu {
    NSArray<NSString *> *titles = @[
        [NSString stringWithFormat:@"① 插件开关：%@", self.enabled ? @"开" : @"关"],
        @"② 自动标定棋盘（开局画面）",
        @"③ 手动标定棋盘（点四角）",
        [NSString stringWithFormat:@"④ HUD 显示：%@", self.hudVisible ? @"开" : @"关"],
        [NSString stringWithFormat:@"⑤ 思考时间：%ld ms（点击修改）", (long)self.thinkMs]
    ];
    [self.ballWindow showMenuWithTitles:titles];
}

/** 插件总开关：关闭时连 Metal 抓帧都停，是真的不占渲染线程。 */
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
        [[JJHUDWindow shared] setHUDHidden:YES];
        [self.ballWindow setActive:NO];
        NSLog(@"[JJCheat] 插件开关 → 关（停止抓帧与识别）");
    }
}

/** 自动标定：清掉旧精修四角，用当前开局画面重新跑 learnAndRefine，
    采纳后的四角会写回 JJ_KEY_CORNERS，等价于一次自动四点标定。 */
- (void)autoCalibrate {
    if (!self.enabled) {
        [[JJHUDWindow shared] showStatus:@"请先开启插件"];
        return;
    }
    if (!self.activated) [self activate];
    self.finalCorners = nil;
    self.refineDone = NO;
    self.learnedBoard = NO;
    self.learnFailCount = 0;
    self.lastLearnAttempt = 0;
    self.lastFrameSerial = 0;
    self.processNotBefore = 0;
    self.autoCalibrating = YES;
    self.state = JJCtrlStateWaitingBoard;
    [[JJEngineBridge shared] resetWithFen:nil];
    [self startTimer];
    [[JJHUDWindow shared] showStatus:@"自动标定中…请停在开局棋盘画面"];
    NSLog(@"[JJCheat] 自动标定棋盘：清除精修四角，重新学习");
}

/** 手动标定：沿用原来的四点触摸标定 */
- (void)manualCalibrate {
    if (!self.enabled) {
        [[JJHUDWindow shared] showStatus:@"请先开启插件"];
        return;
    }
    if (!self.activated) [self activate];
    self.autoCalibrating = NO;
    [self recalibrate];
}

- (void)toggleHUD {
    self.hudVisible = !self.hudVisible;
    [[NSUserDefaults standardUserDefaults] setBool:self.hudVisible forKey:JJ_KEY_HUD_VISIBLE];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
    NSLog(@"[JJCheat] HUD 显示=%@", self.hudVisible ? @"开" : @"关");
}

/** 思考时间：弹输入框，钳制到 JJ_THINK_MS_MIN~MAX，立即生效并持久化。 */
/** 统一的写入口：钳制范围、持久化、给 HUD 反馈。 */
- (void)applyThinkMs:(NSInteger)v {
    if (v <= 0) v = JJ_THINK_MS_DEFAULT;
    v = MIN(JJ_THINK_MS_MAX, MAX(JJ_THINK_MS_MIN, v));
    self.thinkMs = v;
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:JJ_KEY_THINK_MS];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[JJHUDWindow shared] showStatus:[NSString stringWithFormat:@"思考时间已设为 %ld ms", (long)v]];
    NSLog(@"[JJCheat] 思考时间=%ld ms", (long)v);
}

/** 思考时间：输入框 + 4 个预设快捷值（键盘不弹时也能改），立即生效并持久化。 */
- (void)editThinkMs {
    NSString *msg = [NSString stringWithFormat:
                     @"每步搜索时长，范围 %d~%d ms，默认 %d ms。\n数值越小越流畅，棋力略降。",
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
    /* 预设值：不依赖键盘，点一下就改，真机上一个弹窗里全能完成 */
    for (NSNumber *n in @[@(100), @(200), @(350), @(500)]) {
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
    self.learnFailCount = 0;
    [[JJEngineBridge shared] setCorners:pxCorners];
    [[JJEngineBridge shared] resetWithFen:nil];
    self.gridPtsCache = [[JJEngineBridge shared] gridPoints];

    self.state = JJCtrlStateWaitingBoard;
    self.processNotBefore = 0;
    [self startTimer];
    /* beginCalibration 会把 HUD window 强制显示，标定完按用户设置还原 */
    [[JJHUDWindow shared] setHUDHidden:!self.hudVisible];
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
    if (!self.enabled || !self.activated) return;
    if (self.busy) return;
    if (self.state != JJCtrlStateWaitingBoard && self.state != JJCtrlStateRunning) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now < self.processNotBefore) return;

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
        /* 失败退避 3s：learnAndRefine 要几秒，旧逻辑每 250ms 重跑一次，
           连着十几次就是日志里 12:08:19→12:08:50 那段 31 秒主线程空白。 */
        if (now - self.lastLearnAttempt < JJ_LEARN_RETRY_GAP) return;
        self.lastLearnAttempt = now;
        self.busy = YES;
        self.tickCount++;

        __weak typeof(self) weakSelf = self;
        [self learnWithAutoRefine:rgba width:w height:h callback:^(NSDictionary *info) {
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            self2.busy = NO;
            if (!info || [info[@"templateCount"] integerValue] <= 0) {
                /* 每 5 次留一条：旧版 engine.js 让 learnAndRefine 变 undefined 时
                   info 恒为 nil，原来会一直静默重试，日志里什么都看不到。 */
                self2.learnFailCount++;
                if ((self2.learnFailCount % 5) == 1) {
                    NSLog(@"[JJCheat] 学习未完成（第 %ld 次）info=%@ templateCount=%@ verifyDiff=%@",
                          (long)self2.learnFailCount,
                          info ? @"有" : @"nil",
                          info[@"templateCount"] ?: @"-",
                          info[@"verifyDiff"] ?: @"-");
                }
                if (self2.learnFailCount >= JJ_LEARN_MAX_FAIL) {
                    [self2.timer invalidate];
                    self2.timer = nil;
                    [[JJHUDWindow shared] showStatus:@"学习失败 · 请检查 engine.js 后重开插件"];
                    NSLog(@"[JJCheat] 学习连续失败 %ld 次，已暂停重试", (long)self2.learnFailCount);
                    return;
                }
                [[JJHUDWindow shared] showStatus:@"正在学习棋盘…请停留在开局画面"];
                return;
            }
            BOOL accepted = [info[@"ok"] boolValue];
            /* 校验没过最多再学 2 次；之后仍进 Running，但 JS 侧 skipAnalyze 会在
               盘面不可信时直接短路，不会拿开局 FEN 空转算棋（1.1.41 的卡顿点）。 */
            if (!accepted && self2.learnFailCount < 2) {
                self2.learnFailCount++;
                NSLog(@"[JJCheat] 学习校验未通过（verifyDiff=%@），第 %ld 次重试",
                      info[@"verifyDiff"], (long)self2.learnFailCount);
                [self2 dumpSamplesWithPixels:rgba width:w height:h];
                [[JJHUDWindow shared] showStatus:@"学习未完成 · 请停在开局棋盘画面"];
                return;
            }
            self2.learnedBoard = YES;
            self2.state = JJCtrlStateRunning;
            NSArray *fc = info[@"finalCorners"];
            if ([fc isKindOfClass:[NSArray class]] && fc.count == 4) {
                self2.finalCorners = fc;
                self2.gridPtsCache = [self2 gridPointsFromCorners:fc];
                if (self2.autoCalibrating) {
                    [self2 saveAutoCalibratedCorners:fc width:w height:h];
                }
            } else {
                self2.gridPtsCache = [[JJEngineBridge shared] gridPoints];
            }
            NSLog(@"[JJCheat] 棋盘学习完成 %@", info);
            if (!accepted) {
                NSLog(@"[JJCheat] 学习校验未通过（verifyDiff=%@），交给 JS 合法性闸门兜底",
                      info[@"verifyDiff"]);
                [[JJHUDWindow shared] showStatus:@"识别未收敛 · 请确认棋盘完整可见"];
            }
        }];
        return;
    }

    /* 1.1.42：一次 process 在真机上要数秒，回调刚落地就发下一帧会让引擎队列
       永不清空。最小间隔 + 识别未收敛时退避，避免空转。 */
    if (now - self.lastProcessTime < JJ_PROCESS_MIN_GAP) return;
    self.lastProcessTime = now;

    self.busy = YES;
    self.tickCount++;
    NSInteger thinkMs = self.thinkMs;
    __weak typeof(self) weakSelf = self;
    [[JJEngineBridge shared] processPixels:rgba width:w height:h timeMs:(int)thinkMs
                                  callback:^(NSDictionary *result, NSError *error) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        self2.busy = NO;
        if (!result) return;

        if (self2.gridPtsCache.count != 90) {
            self2.gridPtsCache = [self2 gridPointsFromCorners:self2.finalCorners];
        }
        /* 盘面不可信（JS 已明确短路：裁剪后仍非法 / 一子未认出）→ 退避，别每帧重算。
           【1.1.43】旧判定还看 legalNow，但 legalNow=0 时配额裁剪已能修好盘面，
           再按它退避会把正常帧也拖进 2.5s 空转；现在只认 skipAnalyze。 */
        BOOL stalled = [result[@"skipAnalyze"] boolValue];
        if (stalled) {
            self2.processNotBefore = [[NSDate date] timeIntervalSince1970] + JJ_PROCESS_ILLEGAL_GAP;
            NSLog(@"[JJCheat] 识别未收敛：legalNow=%@ codesValid=%@ codesStable=%@ repaired=%@ illegalStreak=%@ skipReason=%@（退避 %.1fs）",
                  result[@"legalNow"] ?: @"-", result[@"codesValid"] ?: @"-",
                  result[@"codesStableCount"] ?: @"-", result[@"repairedCount"] ?: @"-",
                  result[@"illegalStreak"] ?: @"-", result[@"skipReason"] ?: @"-",
                  JJ_PROCESS_ILLEGAL_GAP);
        }

        [[JJHUDWindow shared] showResult:result gridPoints:self2.gridPtsCache fen:result[@"fen"] ?: @""];

        if ([result[@"moveDetected"] boolValue]) {
            NSLog(@"[JJCheat] 检测到走法 %@ %@ → FEN %@ | suggest=%@ legalNow=%@ repaired=%@",
                  result[@"move"], result[@"moveChinese"], result[@"fen"],
                  result[@"suggest"] ?: @"-", result[@"legalNow"] ?: @"-",
                  result[@"repairedCount"] ?: @"-");
        }
    }];
}

/** 自动标定：把 JS 采纳的像素四角换算回屏幕 point 并持久化。 */
- (void)saveAutoCalibratedCorners:(NSArray *)fc width:(int)w height:(int)h {
    CGSize pt = [UIScreen mainScreen].bounds.size;
    if (pt.width <= 0 || pt.height <= 0 || w <= 0 || h <= 0) return;
    CGFloat kx = pt.width / (CGFloat)w;
    CGFloat ky = pt.height / (CGFloat)h;
    NSMutableArray *saved = [NSMutableArray arrayWithCapacity:4];
    for (NSArray *p in fc) {
        [saved addObject:@[@([p[0] doubleValue] * kx), @([p[1] doubleValue] * ky)]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:saved forKey:JJ_KEY_CORNERS];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:JJ_KEY_CALIBRATED];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.pointCorners = saved;
    self.autoCalibrating = NO;
    [[JJHUDWindow shared] showStatus:@"自动标定完成"];
    NSLog(@"[JJCheat] 自动标定完成，四角(point)=%@", saved);
}

@end
