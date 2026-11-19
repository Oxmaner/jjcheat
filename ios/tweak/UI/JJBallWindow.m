//
//  JJBallWindow.m
//  JJCheat
//

#import "JJBallWindow.h"
#import "JJConfig.h"
#import "JJMenuStyle.h"

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

static const CGFloat kJJBallSize      = 52.0;
/** 引擎状态点直径（2.1.0 新增：球右上角小圆点） */
static const CGFloat kJJEngineDotSize = 12.0;

/* ---- 一级菜单网格尺寸 ----
   为什么从「竖排文字长条」改成「2 列图标网格」：
   旧的 232×264 文字列表贴在球内侧，几乎必然压住棋盘右半边，而且每行一句长文案
   要读半天。现在 174×226、纯图标 + 2~4 字标签，横向只占屏幕边缘一条，
   配合毛玻璃让底下的棋子仍然可辨 —— 这才是「不遮挡视线」的实质。

   2.1.80：颜色与圆角不再在这里定义，统一取 JJMenuStyle（与二级面板共用）。 */
static const CGFloat kJJMenuCellW  = 76.0;
static const CGFloat kJJMenuCellH  = 66.0;
static const CGFloat kJJMenuGap    = 6.0;
static const CGFloat kJJMenuPad    = 8.0;
static const NSInteger kJJMenuCols = 2;

/** 插件图标：优先读随 deb 落到 jbroot 的 logo.png，读不到就回退文字「象棋」。 */
static UIImage *JJLoadLogoImage(void) {
    NSString *rel = [@"/" stringByAppendingString:JJ_LOGO_REL_PATH];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:5];
    /* ★ 2.0.0r3：这里**必须**直呼 jbroot，不能改成 dlsym 运行时取符号。
     * r2 试过 dlsym(RTLD_DEFAULT,"jbroot") 再强转函数指针调用，arm64e 真机
     * 启动即崩：EXC_BAD_ACCESS / possible pointer authentication failure。
     * 原因是 arm64e 的间接调用要走 ptrauth 签名，dlsym 拿到的裸指针没签名，
     * 且 jbroot 的实际 ABI 与强转的类型不一定一致 → 返回垃圾 NSString，
     * 下一行 pathExtension/extract 就踩死。所以保持原样，用 libroothide。 */
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

#pragma mark - JJMenuEntry

@implementation JJMenuEntry

+ (instancetype)title:(NSString *)title symbol:(NSString *)symbol {
    JJMenuEntry *e = [[JJMenuEntry alloc] init];
    e.title = title ?: @"";
    e.symbol = symbol;
    e.action = 0;        // 0 = 未指定，按位置下标回调（兼容）
    return e;
}

@end

#pragma mark - JJBallWindow

@interface JJBallWindow ()
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *engineDot;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *menuView;
@property (nonatomic, strong) UIVisualEffectView *menuBlur;
/* 2.1.80：二级面板容器（与一级菜单共用同一套 JJMenuStyle 外观） */
@property (nonatomic, strong) UIView *sheetContainer;
@property (nonatomic, assign, readwrite) BOOL sheetVisible;
@property (nonatomic, assign) BOOL usesLogo;
@property (nonatomic, assign, readwrite) BOOL menuVisible;
@property (nonatomic, assign) NSInteger entryCount;
/* 2.1.80：与 entries 一一对应的 action 标识（0 = 用位置下标） */
@property (nonatomic, strong) NSMutableArray<NSNumber *> *entryActions;
@property (nonatomic, strong) UILabel *toastLabel;
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

        /* 菜单遮罩：**完全透明但可点击**。
           旧版是 0.22 全屏黑，一开菜单整块画面就暗下去 —— 这是「遮挡视线」最主要的来源。
           用 clearColor 意味着背景色 alpha=0，但 view 自身 alpha 仍是 1.0，
           hitTest 照常命中，所以「点空白处收起菜单」的能力一点没丢，画面却不再被压暗。 */
        _backdrop = [[UIView alloc] initWithFrame:scr];
        _backdrop.backgroundColor = [UIColor clearColor];
        _backdrop.hidden = YES;
        [_backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(closeMenuTap)]];
        [self.rootViewController.view addSubview:_backdrop];

        /* 菜单面板：毛玻璃 + 细边框。
           毛玻璃是「不遮挡视线」的关键 —— 底下的棋盘与棋子仍然透得出来。 */
        /* 2.1.80：外观统一由 JJMenuStyle 的 JJMenuApplyPanelStyle 提供
           （深色 UltraThin 毛玻璃 + 18pt 圆角 + 0.5pt 白 14% 描边 + 底层深色 30%），
           二级面板走同一个函数，两级观感才能一致。 */
        _menuView = [[UIView alloc] initWithFrame:CGRectZero];
        JJMenuApplyPanelStyle(_menuView);
        _menuView.hidden = YES;
        [self.rootViewController.view addSubview:_menuView];

        CGFloat d = kJJBallSize;
        _ball = [UIButton buttonWithType:UIButtonTypeCustom];
        _ball.frame = CGRectMake(0, 0, d, d);
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

        /* 球位置持久化：允许用户把球拖到不碍事的地方，重启后还在那儿。
           这也是「不遮挡视线」的一环 —— 球本身也会压住棋子。 */
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"JJCheat.ballCenter"];
        if (saved.count == 2) {
            CGPoint c = CGPointMake([saved[0] doubleValue], [saved[1] doubleValue]);
            _ball.center = [self clampBallCenter:c inScreen:scr];
        } else {
            _ball.center = CGPointMake(scr.size.width - 34, scr.size.height * 0.45);
        }

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

- (CGPoint)clampBallCenter:(CGPoint)c inScreen:(CGRect)scr {
    CGFloat half = kJJBallSize / 2.0;
    CGFloat top = 60.0, bottom = scr.size.height - 40.0;
    return CGPointMake(MAX(half + 4.0, MIN(c.x, scr.size.width - half - 4.0)),
                       MAX(top + half, MIN(c.y, bottom)));
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

- (void)closeMenuTap {
    /* 有二级面板时先收二级（返回上一层），这是「层级不变」的关键：
       点空白 = 退一层，不是一次全关。 */
    if (self.sheetVisible) { [self dismissSheet]; return; }
    [self hideMenu];
}

#pragma mark - 菜单

- (void)showMenuWithTitles:(NSArray<NSString *> *)titles {
    NSMutableArray<JJMenuEntry *> *arr = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString *t in titles) [arr addObject:[JJMenuEntry title:t symbol:nil]];
    [self showMenuWithEntries:arr];
}

- (void)showMenuWithEntries:(NSArray<JJMenuEntry *> *)entries {
    if (!entries.count) return;
    for (UIView *v in [self.menuView.subviews copy]) {
        if (v != self.menuBlur) [v removeFromSuperview];
    }

    const NSInteger cols = kJJMenuCols;
    const NSInteger rows = (NSInteger)((entries.count + cols - 1) / cols);
    const CGFloat w = kJJMenuPad * 2 + cols * kJJMenuCellW + (cols - 1) * kJJMenuGap;
    const CGFloat h = kJJMenuPad * 2 + rows * kJJMenuCellH + (rows - 1) * kJJMenuGap;
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.safeAreaInsets;

    /* 贴球所在那一侧的屏幕边缘：横向只占一条，尽量不压棋盘中心 */
    BOOL rightSide = CGRectGetMidX(self.ball.frame) > scr.size.width / 2.0;
    CGFloat x = rightSide ? (scr.size.width - w - 8.0) : 8.0;

    /* 纵向避开球：优先放球下方，放不下再放上方，都不行才允许重叠（球 z 序更高，仍可点） */
    CGFloat belowY = CGRectGetMaxY(self.ball.frame) + 10.0;
    CGFloat aboveY = CGRectGetMinY(self.ball.frame) - 10.0 - h;
    CGFloat topLimit = safe.top + 10.0;
    CGFloat bottomLimit = scr.size.height - safe.bottom - 10.0;
    CGFloat y;
    if (belowY + h <= bottomLimit) y = belowY;
    else if (aboveY >= topLimit) y = aboveY;
    else y = MAX(topLimit, MIN(belowY, bottomLimit - h));

    self.menuView.frame = CGRectMake(x, y, w, h);
    if (self.menuBlur) self.menuBlur.frame = self.menuView.bounds;
    self.entryCount = (NSInteger)entries.count;

    self.entryActions = [NSMutableArray arrayWithCapacity:entries.count];
    for (JJMenuEntry *e in entries) [self.entryActions addObject:@(e.action)];

    for (NSUInteger i = 0; i < entries.count; i++) {
        JJMenuEntry *e = entries[i];
        NSUInteger r = i / cols, c = i % cols;
        /* 奇数项时最后一项独占两列宽，否则右下角留个空格子很难看 */
        BOOL wide = (entries.count % 2 == 1) && (i == entries.count - 1);
        CGFloat cw = wide ? (cols * kJJMenuCellW + (cols - 1) * kJJMenuGap) : kJJMenuCellW;
        CGRect cell = CGRectMake(kJJMenuPad + c * (kJJMenuCellW + kJJMenuGap),
                                 kJJMenuPad + r * (kJJMenuCellH + kJJMenuGap),
                                 cw, kJJMenuCellH);
        UIButton *b = [self makeCellForEntry:e rect:cell];
        b.tag = (NSInteger)(100 + i);
        [b addTarget:self action:@selector(menuItemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.menuView addSubview:b];
    }

    self.backdrop.hidden = NO;
    self.menuView.hidden = NO;
    self.menuVisible = YES;

    /* 轻微放大淡入，提示「从这里展开了」 */
    JJMenuAnimateIn(self.menuView);
}

/** 一个网格单元：SF Symbol 图标在上，短标签在下，状态用颜色和右侧小字表达。 */
- (UIButton *)makeCellForEntry:(JJMenuEntry *)e rect:(CGRect)rect {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = rect;
    JJMenuApplyCellStyle(b, e.on, e.warn);

    UIColor *tint = e.warn ? JJMenuWarnColor()
                           : (e.on ? JJMenuAccentColor() : JJMenuTextColor());

    /* 图标：SF Symbols（iOS 13+）。取不到就只显示文字，不留白块。 */
    UIImage *icon = nil;
    if (e.symbol.length) {
        icon = [UIImage systemImageNamed:e.symbol];
        if (icon) {
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:21
                                                                weight:UIImageSymbolWeightMedium];
            icon = [icon imageByApplyingSymbolConfiguration:cfg];
            icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    }
    CGFloat iconY = 16.0;
    if (icon) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
        iv.tintColor = tint;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = CGRectMake((rect.size.width - 26) / 2, iconY, 26, 24);
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];
    }

    NSString *label = e.title ?: @"";
    if (e.value.length) label = [NSString stringWithFormat:@"%@ %@", label, e.value];
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(2, rect.size.height - 26,
                                                          rect.size.width - 4, 18)];
    lb.text = label;
    lb.textColor = e.on ? tint : JJMenuTextColor();
    lb.font = JJMenuCellLabelFont(e.on);
    lb.textAlignment = NSTextAlignmentCenter;
    lb.adjustsFontSizeToFitWidth = YES;
    lb.minimumScaleFactor = 0.75;
    lb.userInteractionEnabled = NO;
    [b addSubview:lb];
    return b;
}

#pragma mark - 二级面板（2.1.80）

- (void)showSheet:(UIView *)sheet {
    if (!sheet) return;
    [self hideMenu];                       // 一级收起，避免两层叠在一起
    [self dismissSheet];

    /* 宽度：与一级菜单同侧，最多 JJMenuSheetMaxW，屏幕窄时留 16pt 边距 */
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.safeAreaInsets;
    CGFloat w = MIN(JJMenuSheetMaxW, scr.size.width - 32.0);
    /* 高度由调用方用它自己的 rows 算好（JJMenuSheet +heightForWidth:rows:hasSubtitle:），
       这里只读不算 —— 免得两处各算一遍又不一致。 */
    CGFloat h = sheet.frame.size.height;
    if (h <= 0) h = 240.0;

    BOOL rightSide = CGRectGetMidX(self.ball.frame) > scr.size.width / 2.0;
    CGFloat x = rightSide ? (scr.size.width - w - 8.0 - safe.right) : (8.0 + safe.left);

    CGFloat belowY = CGRectGetMaxY(self.ball.frame) + 10.0;
    CGFloat aboveY = CGRectGetMinY(self.ball.frame) - 10.0 - h;
    CGFloat topLimit = safe.top + 10.0;
    CGFloat bottomLimit = scr.size.height - safe.bottom - 10.0;
    CGFloat y;
    if (belowY + h <= bottomLimit) y = belowY;
    else if (aboveY >= topLimit) y = aboveY;
    else y = MAX(topLimit, MIN(belowY, bottomLimit - h));

    sheet.frame = CGRectMake(x, y, w, h);
    /* 面板自己再套一次样式也无害（幂等），但容器不再另加背景，
       保证二级与一级用的是同一份 JJMenuStyle。 */
    [self.rootViewController.view addSubview:sheet];
    self.sheetContainer = sheet;
    self.sheetVisible = YES;
    self.backdrop.hidden = NO;
    JJMenuAnimateIn(sheet);
}

- (void)dismissSheet {
    if (!self.sheetContainer) {
        self.sheetVisible = NO;
        return;
    }
    UIView *v = self.sheetContainer;
    self.sheetContainer = nil;
    self.sheetVisible = NO;
    [UIView animateWithDuration:0.12 animations:^{ v.alpha = 0.0; }
                     completion:^(BOOL finished) { [v removeFromSuperview]; }];
    if (!self.menuVisible) self.backdrop.hidden = YES;
}

- (void)hideMenu {
    if (!self.menuVisible) {
        self.backdrop.hidden = YES;
        self.menuView.hidden = YES;
        return;
    }
    self.menuVisible = NO;
    self.backdrop.hidden = YES;
    self.menuView.hidden = YES;
    self.menuView.transform = CGAffineTransformIdentity;
    self.menuView.alpha = 1.0;
}

- (void)menuItemTapped:(UIButton *)b {
    NSInteger idx = b.tag - 100;
    if (idx < 0 || idx >= self.entryCount) return;

    /* 2.1.80：优先用菜单项自带的 action 标识，而不是位置下标。
       位置下标会在「菜单顺序调整」时错位 —— 2.1.78 就是这样让
       点「HUD」执行了「重置开局」，成了「HUD 开关不起作用」的根因。
       action 为 0（未设置）时回退到下标，保证旧调用方仍可用。 */
    NSInteger action = idx;
    if (idx < (NSInteger)self.entryActions.count) {
        NSInteger tagged = [self.entryActions[(NSUInteger)idx] integerValue];
        if (tagged != 0) action = tagged;
    }

    /* 先给一次明确的视觉反馈再收起。
       旧版点完立刻 hideMenu，加上很多动作的反馈只落在 HUD 上（HUD 关掉时就完全没反馈），
       用户会觉得「点了没反应」。现在按钮自己先亮一下。 */
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    b.userInteractionEnabled = NO;
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [s2 hideMenu];
        if (s2.onMenuItem) s2.onMenuItem(action);
    });
}

#pragma mark - Toast

- (void)toast:(NSString *)text {
    if (!text.length) return;
    if (!self.toastLabel) {
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
        lb.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:0.90];
        lb.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
        lb.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.numberOfLines = 2;
        lb.layer.cornerRadius = 10.0;
        lb.layer.masksToBounds = YES;
        lb.layer.borderWidth = 0.5;
        lb.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
        lb.alpha = 0.0;
        lb.userInteractionEnabled = NO;
        [self.rootViewController.view addSubview:lb];
        self.toastLabel = lb;
    }
    UILabel *lb = self.toastLabel;
    lb.text = text;

    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.safeAreaInsets;
    CGFloat maxW = scr.size.width - 40.0;
    CGSize fit = [lb sizeThatFits:CGSizeMake(maxW, 200.0)];
    CGFloat w = MIN(maxW, MAX(120.0, fit.width + 28.0));
    CGFloat h = MAX(30.0, fit.height + 12.0);
    /* 放球的下方；贴底就翻到上方，保证不出屏 */
    CGFloat cx = self.ball.center.x;
    cx = MAX(safe.left + w / 2 + 10, MIN(cx, scr.size.width - safe.right - w / 2 - 10));
    CGFloat y = CGRectGetMaxY(self.ball.frame) + 8.0;
    if (y + h > scr.size.height - safe.bottom - 10.0) {
        y = CGRectGetMinY(self.ball.frame) - 8.0 - h;
    }
    lb.frame = CGRectMake(cx - w / 2, y, w, h);

    [lb.layer removeAllAnimations];
    CGFloat dur = 2.2;
    [UIView animateWithDuration:0.18 animations:^{ lb.alpha = 1.0; }
                     completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35 delay:dur options:0 animations:^{
            lb.alpha = 0.0;
        } completion:nil];
    }];
}

#pragma mark - 手势

- (void)lpBall:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}

- (void)panBall:(UIPanGestureRecognizer *)g {
    CGRect scr = [UIScreen mainScreen].bounds;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self];
        self.ball.center = [self clampBallCenter:CGPointMake(self.ball.center.x + t.x,
                                                            self.ball.center.y + t.y)
                                        inScreen:scr];
        [g setTranslation:CGPointZero inView:self];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        NSArray *saved = @[@(self.ball.center.x), @(self.ball.center.y)];
        [[NSUserDefaults standardUserDefaults] setObject:saved forKey:@"JJCheat.ballCenter"];
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

/* 触摸分发：**白名单放行**，其余透传给游戏。
 *
 * 【2.1.78 修的关键 bug】旧实现是「除球外一律 return nil」：
 *     if (v == self.ball) return v;
 *     if (menuVisible && (遮罩||菜单)) return v;
 *     return nil;                    ← 弹窗的一切触摸都掉进这里
 * 而 ⑤思考时间 / ⑥引擎详情 都是 present 出来的 UIAlertController，
 * 它的视图既不是球、也不是菜单子视图 → 全部返回 nil →
 * **弹窗看得见但完全点不动，也关不掉，只能杀 App**。
 * 这就是「菜单各项功能失效」的真凶。
 * 现在补一条：只要 rootViewController 有 presentedViewController，就整窗放行。 */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (!v) return nil;
    /* ① 球（含状态点）始终可交互 */
    if (v == self.ball || [v isDescendantOfView:self.ball]) return v;
    /* ② 菜单 / 二级面板打开时，遮罩与其中的控件可交互 */
    if (self.menuVisible &&
        (v == self.backdrop || [v isDescendantOfView:self.menuView])) return v;
    if (self.sheetVisible && self.sheetContainer &&
        (v == self.backdrop || [v isDescendantOfView:self.sheetContainer])) return v;
    /* ③ 有模态弹窗在场 → 全窗放行，否则弹窗点不动（见上面的说明） */
    if (self.rootViewController.presentedViewController) return v;
    /* ④ 其余透传给下层 window（游戏画面） */
    return nil;
}

@end
