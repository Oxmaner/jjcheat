//
//  JJBallWindow.m
//  JJCheat
//

#import "JJBallWindow.h"
#import "JJConfig.h"

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

static const CGFloat kJJBallSize      = 52.0;
static const CGFloat kJJMenuWidth     = 232.0;
static const CGFloat kJJMenuRowHeight = 44.0;
/** 引擎状态点直径（2.1.0 新增：球右上角小圆点） */
static const CGFloat kJJEngineDotSize = 12.0;

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

@interface JJBallWindow ()
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *engineDot;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *menuView;
@property (nonatomic, assign) BOOL usesLogo;
@property (nonatomic, assign, readwrite) BOOL menuVisible;
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

        /* 引擎状态点：默认隐藏，等控制器设色 */
        _engineDot = [[UIView alloc] initWithFrame:CGRectMake(d - kJJEngineDotSize + 1,
                                                            1,
                                                            kJJEngineDotSize,
                                                            kJJEngineDotSize)];
        _engineDot.backgroundColor = [UIColor clearColor];
        _engineDot.layer.cornerRadius = kJJEngineDotSize / 2;
        _engineDot.layer.borderWidth = 1.5;
        _engineDot.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
        _engineDot.userInteractionEnabled = NO;
        _engineDot.hidden = YES;
        [_ball addSubview:_engineDot];
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

- (void)setEngineDotColor:(UIColor *)color {
    if (!color) {
        self.engineDot.hidden = YES;
        return;
    }
    self.engineDot.hidden = NO;
    self.engineDot.backgroundColor = color;
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
    /* 部署下限 iOS 14.0（Makefile TARGET / control firmware），connectedScenes 必然存在 */
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            sc.activationState == UISceneActivationStateForegroundActive) {
            self.windowScene = (UIWindowScene *)sc;
            break;
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
