//
//  JJMenuSheet.m
//  JJCheat —— 二级菜单面板
//

#import "JJMenuSheet.h"
#import "JJMenuStyle.h"

static const CGFloat kJJSheetTitleH = 34.0;
static const CGFloat kJJSheetSubH   = 20.0;
static const CGFloat kJJSheetInfoH  = 32.0;
static const CGFloat kJJSheetRowGap = 6.0;
static const CGFloat kJJStepBtnW    = 32.0;
static const CGFloat kJJStepValueW  = 52.0;

@implementation JJSheetRow

+ (instancetype)info:(NSString *)text {
    JJSheetRow *r = [[JJSheetRow alloc] init];
    r.kind = JJSheetRowKindInfo;
    r.title = text ?: @"";
    r.enabled = NO;
    return r;
}

+ (instancetype)action:(NSString *)title
                symbol:(NSString *)symbol
                detail:(NSString *)detail
               handler:(void (^)(JJSheetRow *row))handler {
    JJSheetRow *r = [[JJSheetRow alloc] init];
    r.kind = JJSheetRowKindAction;
    r.title = title ?: @"";
    r.symbol = symbol;
    r.detail = detail;
    r.enabled = YES;
    r.handler = handler;
    return r;
}

+ (instancetype)stepper:(NSString *)title
                 symbol:(NSString *)symbol
                  value:(NSString *)value
               onChange:(void (^)(NSInteger delta, JJSheetRow *row))onChange {
    JJSheetRow *r = [[JJSheetRow alloc] init];
    r.kind = JJSheetRowKindStepper;
    r.title = title ?: @"";
    r.symbol = symbol;
    r.detail = value;
    r.enabled = YES;
    r.stepper = onChange;
    return r;
}

+ (instancetype)danger:(NSString *)title
                symbol:(NSString *)symbol
               handler:(void (^)(JJSheetRow *row))handler {
    JJSheetRow *r = [[JJSheetRow alloc] init];
    r.kind = JJSheetRowKindDanger;
    r.title = title ?: @"";
    r.symbol = symbol;
    r.enabled = YES;
    r.handler = handler;
    return r;
}

@end

@interface JJMenuSheet ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, copy) NSArray<JJSheetRow *> *rows;

/* 每行一套控件，下标与 rows 严格对齐；不用 viewWithTag，避免与 300/400 段撞车，
   也不靠 subviews 顺序猜哪个是标题。info 行只填 titleLabels。 */
/* 用 NSMutableArray<id> 而不是强类型：部分行（info / action）没有图标或步进按钮，
   这些槽位放 nil，强类型数组在 -Wincompatible-pointer-types 下会报错。
   nil 会以 NSNull 形式存储，取值时用 `== nil` 判断即可（见下方辅助宏）。 */
@property (nonatomic, strong) NSMutableArray *rowViews;
@property (nonatomic, strong) NSMutableArray *titleLabels;
@property (nonatomic, strong) NSMutableArray *valueLabels;
@property (nonatomic, strong) NSMutableArray *iconViews;
@property (nonatomic, strong) NSMutableArray *minusButtons;
@property (nonatomic, strong) NSMutableArray *plusButtons;
@end

@implementation JJMenuSheet

+ (CGFloat)rowHeightForKind:(JJSheetRowKind)kind {
    return (kind == JJSheetRowKindInfo) ? kJJSheetInfoH : JJMenuSheetRowH;
}

+ (CGFloat)heightForWidth:(CGFloat)width rows:(NSArray<JJSheetRow *> *)rows hasSubtitle:(BOOL)hasSub {
    CGFloat h = JJMenuSheetPad + kJJSheetTitleH;
    if (hasSub) h += kJJSheetSubH;
    h += 6.0;
    for (JJSheetRow *r in rows) h += [self rowHeightForKind:r.kind] + kJJSheetRowGap;
    h += JJMenuSheetPad - kJJSheetRowGap;
    return h;
}

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                         rows:(NSArray<JJSheetRow *> *)rows {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _rows = [rows copy] ?: @[];
        _rowViews = [NSMutableArray array];
        _titleLabels = [NSMutableArray array];
        _valueLabels = [NSMutableArray array];
        _iconViews = [NSMutableArray array];
        _minusButtons = [NSMutableArray array];
        _plusButtons = [NSMutableArray array];

        JJMenuApplyPanelStyle(self);

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.text = title ?: @"";
        _titleLabel.textColor = JJMenuTextColor();
        _titleLabel.font = JJMenuSheetTitleFont();
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        if (subtitle.length) {
            _subLabel = [[UILabel alloc] initWithFrame:CGRectZero];
            _subLabel.text = subtitle;
            _subLabel.textColor = JJMenuSubTextColor();
            _subLabel.font = JJMenuSheetSubFont();
            _subLabel.numberOfLines = 2;
            _subLabel.userInteractionEnabled = NO;
            [self addSubview:_subLabel];
        }

        for (NSUInteger i = 0; i < _rows.count; i++) [self buildRow:_rows[i] index:i];
    }
    return self;
}

- (void)buildRow:(JJSheetRow *)row index:(NSUInteger)i {
    if (row.kind == JJSheetRowKindInfo) {
        UILabel *info = [[UILabel alloc] initWithFrame:CGRectZero];
        info.text = row.title;
        info.textColor = JJMenuSubTextColor();
        info.font = JJMenuSheetSubFont();
        info.numberOfLines = 3;
        info.userInteractionEnabled = NO;
        [self addSubview:info];

        [_rowViews addObject:[NSNull null]];
        [_titleLabels addObject:info];
        [_valueLabels addObject:[NSNull null]];
        [_iconViews addObject:[NSNull null]];
        [_minusButtons addObject:[NSNull null]];
        [_plusButtons addObject:[NSNull null]];
        return;
    }

    BOOL isDanger  = (row.kind == JJSheetRowKindDanger);
    BOOL isStepper = (row.kind == JJSheetRowKindStepper);

    /* 底板：action/danger 用按钮（整行可点且**样式直接加在按钮上**）；
       stepper 用不可点的 UIView（只有 ± 响应，避免误触整行）。
       以前的写法把样式加在另一个隐藏 bg 上、却把按钮当底板用，
       结果整行没有底色 —— 这是 2.1.80 初版的实际 bug，已修。 */
    UIView *backdrop = nil;
    if (isStepper) {
        UIView *bg = [[UIView alloc] initWithFrame:CGRectZero];
        bg.userInteractionEnabled = NO;
        JJMenuApplyCellStyle(bg, row.on, isDanger);
        [self addSubview:bg];
        backdrop = bg;
    } else {
        UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
        hit.tag = (NSInteger)(200 + i);
        JJMenuApplyCellStyle(hit, row.on, isDanger);
        [hit addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:hit];
        backdrop = hit;
    }
    [_rowViews addObject:backdrop];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectZero];
    t.text = row.title;
    t.textColor = isDanger ? JJMenuWarnColor() : JJMenuTextColor();
    t.font = JJMenuSheetRowFont();
    t.userInteractionEnabled = NO;
    t.adjustsFontSizeToFitWidth = YES;
    t.minimumScaleFactor = 0.85;
    [self addSubview:t];
    [_titleLabels addObject:t];

    UIImageView *iv = nil;
    if (row.symbol.length) {
        UIImage *icon = [UIImage systemImageNamed:row.symbol];
        if (icon) {
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:15
                                                                weight:UIImageSymbolWeightMedium];
            icon = [[icon imageByApplyingSymbolConfiguration:cfg]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            iv = [[UIImageView alloc] initWithImage:icon];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.tintColor = isDanger ? JJMenuWarnColor()
                                    : (row.on ? JJMenuAccentColor() : JJMenuTextColor());
            iv.userInteractionEnabled = NO;
            [self addSubview:iv];
        }
    }
    [_iconViews addObject:(iv ?: [NSNull null])];

    UILabel *val = [[UILabel alloc] initWithFrame:CGRectZero];
    val.text = isStepper ? row.detail
                         : (row.on ? (row.detail.length ? row.detail : @"已开启") : (row.detail ?: @""));
    val.textColor = isStepper ? JJMenuTextColor()
                              : (row.on ? JJMenuAccentColor() : JJMenuSubTextColor());
    val.font = JJMenuSheetValueFont();
    val.textAlignment = NSTextAlignmentRight;
    val.userInteractionEnabled = NO;
    [self addSubview:val];
    [_valueLabels addObject:val];

    if (isStepper) {
        UIButton *minus = [self makeStepButton:@"−" tag:(NSInteger)(300 + i)
                                        action:@selector(stepTapped:)];
        UIButton *plus  = [self makeStepButton:@"+" tag:(NSInteger)(400 + i)
                                        action:@selector(stepTapped:)];
        [_minusButtons addObject:minus];
        [_plusButtons addObject:plus];
    } else {
        [_minusButtons addObject:[NSNull null]];
        [_plusButtons addObject:[NSNull null]];
    }
}

- (UIButton *)makeStepButton:(NSString *)symbol tag:(NSInteger)tag action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    b.layer.cornerRadius = 8.0;
    b.layer.borderWidth = 0.5;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    [b setTitle:symbol forState:UIControlStateNormal];
    [b setTitleColor:JJMenuTextColor() forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat innerW = w - JJMenuSheetPad * 2;

    self.titleLabel.frame = CGRectMake(JJMenuSheetPad, JJMenuSheetPad, innerW, kJJSheetTitleH);
    CGFloat y = JJMenuSheetPad + kJJSheetTitleH;
    if (self.subLabel) {
        self.subLabel.frame = CGRectMake(JJMenuSheetPad, y, innerW, kJJSheetSubH);
        y += kJJSheetSubH;
    }
    y += 6.0;

    for (NSUInteger i = 0; i < self.rows.count; i++) {
        JJSheetRow *row = self.rows[i];
        CGFloat rh = [JJMenuSheet rowHeightForKind:row.kind];
        CGRect rowFrame = CGRectMake(JJMenuSheetPad, y, innerW, rh);

        if (row.kind == JJSheetRowKindInfo) {
            ((UILabel *)self.titleLabels[i]).frame = rowFrame;
            y += rh + kJJSheetRowGap;
            continue;
        }

        id back = self.rowViews[i];
        if (back != [NSNull null]) ((UIView *)back).frame = rowFrame;

        /* 行内控件都是**面板的直接子视图**（没有每行一个容器），
           所以坐标必须加上本行的 y 偏移。2.1.82 首版这里写的是行内局部坐标
           （y=0），结果所有行的文字/按钮全叠在面板顶部 —— 真机上表现为
           「面板只看得见一两行，其余被压住」。辅助功能树里所有元素的中心点
           都等于同一个 y，就是这个 bug 的特征。 */
        CGFloat rowTop = rowFrame.origin.y;

        id ivObj = self.iconViews[i];
        CGFloat textX = 10.0;
        if (ivObj != [NSNull null]) {
            ((UIImageView *)ivObj).frame =
                CGRectMake(textX, rowTop + (rh - 18.0) / 2, 18, 18);
            textX += 24.0;
        }

        UILabel *val = (UILabel *)self.valueLabels[i];
        UILabel *title = (UILabel *)self.titleLabels[i];

        if (row.kind == JJSheetRowKindStepper) {
            CGFloat right = innerW - 10.0;
            UIButton *plus  = (UIButton *)self.plusButtons[i];
            UIButton *minus = (UIButton *)self.minusButtons[i];
            plus.frame  = CGRectMake(right - kJJStepBtnW, rowTop + (rh - 30.0) / 2,
                                     kJJStepBtnW, 30);
            minus.frame = CGRectMake(right - kJJStepBtnW - kJJStepValueW - kJJStepBtnW - 4,
                                     rowTop + (rh - 30.0) / 2, kJJStepBtnW, 30);
            val.frame = CGRectMake(right - kJJStepBtnW - kJJStepValueW - 2,
                                   rowTop + (rh - 30.0) / 2, kJJStepValueW, 30);
            title.frame = CGRectMake(textX, rowTop,
                                     MAX(40, minus.frame.origin.x - textX - 6), rh);
        } else {
            CGFloat valW = MIN(120.0, innerW * 0.46);
            val.frame = CGRectMake(innerW - 10.0 - valW, rowTop, valW, rh);
            title.frame = CGRectMake(textX, rowTop,
                                     MAX(40, val.frame.origin.x - textX - 6), rh);
        }
        y += rh + kJJSheetRowGap;
    }
}

- (void)refreshValues {
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        JJSheetRow *row = self.rows[i];
        if (row.kind == JJSheetRowKindInfo) continue;
        id valObj = self.valueLabels[i];
        if (valObj == [NSNull null]) continue;
        UILabel *val = (UILabel *)valObj;
        if (row.kind == JJSheetRowKindStepper) {
            val.text = row.detail;
        } else {
            val.text = row.on ? (row.detail.length ? row.detail : @"已开启") : (row.detail ?: @"");
            val.textColor = row.on ? JJMenuAccentColor() : JJMenuSubTextColor();
        }
    }
}

/** 副标题通常是「引擎参数摘要」，改完参数要跟着变（面板高度已按有无副标题算好，不动态加） */
- (void)refreshSubtitle:(NSString *)text {
    if (!text.length || !self.subLabel) return;
    self.subLabel.text = text;
}

- (void)stepTapped:(UIButton *)b {
    BOOL isPlus = (b.tag >= 400);
    NSUInteger i = (NSUInteger)(isPlus ? (b.tag - 400) : (b.tag - 300));
    if (i >= self.rows.count) return;
    JJSheetRow *row = self.rows[i];
    if (row.stepper) row.stepper(isPlus ? 1 : -1, row);
}



- (void)rowTapped:(UIButton *)b {
    NSInteger idx = b.tag - 200;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
    JJSheetRow *row = self.rows[(NSUInteger)idx];
    if (!row.enabled) return;

    /* 按下反馈：先亮一下再执行，避免「点了没反应」的错觉（与一级菜单一致） */
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s2 = ws;
        if (!s2) return;
        [UIView animateWithDuration:0.12 animations:^{
            b.backgroundColor = JJMenuCellColor(row.on);
        }];
        if (row.handler) row.handler(row);
    });
}

@end
