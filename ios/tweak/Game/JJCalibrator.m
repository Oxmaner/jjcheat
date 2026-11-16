//
//  JJCalibrator.m
//  JJCheat
//

#import "JJCalibrator.h"
#import "JJConfig.h"
#import "JJVisionBridge.h"
#import <UIKit/UIKit.h>
#import <math.h>

/** 双线性插值：四角 → 第 r 行 c 列交叉点（与 engine.js gridPoints 同算法） */
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

static double JJAbsD(double v) { return v < 0 ? -v : v; }

@interface JJCalibrator ()
@property (nonatomic, strong, nullable) NSArray<NSArray<NSNumber *> *> *pointCorners;
@property (nonatomic, strong, nullable) NSArray<NSArray<NSNumber *> *> *finalCorners;
@property (nonatomic, strong, nullable) NSArray<NSArray<NSNumber *> *> *gridPts;
@property (nonatomic, assign) int lastFrameW;
@property (nonatomic, assign) int lastFrameH;
/* 回滚快照 */
@property (nonatomic, strong, nullable) NSArray<NSArray<NSNumber *> *> *backupFinal;
@property (nonatomic, strong, nullable) NSArray<NSArray<NSNumber *> *> *backupPoint;
@property (nonatomic, strong, nullable) NSArray<NSArray<NSNumber *> *> *backupGrid;
@property (nonatomic, assign) BOOL hasSnapshot;
@end

@implementation JJCalibrator

+ (instancetype)shared {
    static JJCalibrator *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJCalibrator alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        /* 恢复持久化的 point 四角（屏幕坐标，抓帧尺寸确定后按比例现算） */
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:JJ_KEY_CORNERS];
        if (saved.count == 4) {
            NSMutableArray *corners = [NSMutableArray arrayWithCapacity:4];
            for (NSArray *p in saved) {
                if (![p isKindOfClass:[NSArray class]] || p.count < 2) continue;
                [corners addObject:@[[NSNumber numberWithDouble:[p[0] doubleValue]],
                                     [NSNumber numberWithDouble:[p[1] doubleValue]]]];
            }
            if (corners.count == 4) _pointCorners = corners;
        }
        _gridPts = @[];
    }
    return self;
}

- (BOOL)hasCorners {
    return self.finalCorners.count == 4 || self.pointCorners.count == 4;
}

- (void)clearRefined {
    self.finalCorners = nil;
    self.lastFrameW = 0;
    self.lastFrameH = 0;
}

#pragma mark - 几何体检

- (BOOL)cornersAreSane:(NSArray<NSArray<NSNumber *> *> *)c {
    if (c.count != 4) return NO;
    CGPoint p[4];
    for (int i = 0; i < 4; i++) {
        NSArray *xy = c[i];
        if (![xy isKindOfClass:[NSArray class]] || xy.count < 2) return NO;
        p[i] = CGPointMake([xy[0] doubleValue], [xy[1] doubleValue]);
    }
    double topW = JJAbsD(p[1].x - p[0].x), botW = JJAbsD(p[2].x - p[3].x);
    double leftH = JJAbsD(p[3].y - p[0].y), rightH = JJAbsD(p[2].y - p[1].y);
    /* 棋盘在 1284x2778 帧里约 1100x1200；留足余量兼容不同机型 / 缩放 */
    if (topW < 600 || topW > 1500 || botW < 600 || botW > 1500) return NO;
    if (leftH < 700 || leftH > 1700 || rightH < 700 || rightH > 1700) return NO;
    if (JJAbsD(topW - botW) > 200 || JJAbsD(leftH - rightH) > 260) return NO;
    /* 顺序必须是 左上 → 右上 → 右下 → 左下 */
    if (!(p[1].x > p[0].x + 200 && p[3].y > p[0].y + 200 &&
          p[2].x > p[3].x + 200 && p[2].y > p[1].y + 200)) return NO;
    return YES;
}

#pragma mark - 坐标换算

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

- (void)applyForFrameWidth:(int)w height:(int)h {
    if (w <= 0 || h <= 0) return;
    /* 学习已采纳精修四角后，不能再按 point 比例重设，否则梯形修正会被冲掉 */
    if (self.finalCorners.count == 4) {
        if (self.gridPts.count != 90) {
            self.gridPts = [self gridPointsFromCorners:self.finalCorners];
        }
        return;
    }
    if (self.pointCorners.count != 4) return;
    if (self.lastFrameW == w && self.lastFrameH == h) return;

    NSArray *px = [self cornersForWidth:w height:h];
    if (px.count != 4) return;

    self.lastFrameW = w;
    self.lastFrameH = h;
    [[JJVisionBridge shared] setCorners:px];
    self.gridPts = [self gridPointsFromCorners:px];

    CGRect nb = [UIScreen mainScreen].nativeBounds;
    CGSize pt = [UIScreen mainScreen].bounds.size;
    NSLog(@"[JJCheat] 抓帧 %dx%d（point %.0fx%.0f / native %.0fx%.0f）→ 标定缩放 %.3f/%.3f",
          w, h, pt.width, pt.height, nb.size.width, nb.size.height,
          pt.width > 0 ? w / pt.width : 1.0, pt.height > 0 ? h / pt.height : 1.0);
}

#pragma mark - 标定写入

- (BOOL)handleManualCalibration:(NSArray<NSValue *> *)corners {
    if (corners.count != 4) return NO;

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

    /* 四角几何校验：不接受「点歪了 / 聚成一团 / 顺序反了」的标定 */
    if (![self cornersAreSane:pxCorners]) {
        NSLog(@"[JJCheat] 手动标定四角不合理，已拒绝：%@", pxCorners);
        return NO;
    }

    [[NSUserDefaults standardUserDefaults] setObject:saved forKey:JJ_KEY_CORNERS];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:JJ_KEY_CALIBRATED];
    [[NSUserDefaults standardUserDefaults] synchronize];

    self.pointCorners = saved;
    self.finalCorners = nil;
    self.lastFrameW = 0;
    self.lastFrameH = 0;
    [[JJVisionBridge shared] setCorners:pxCorners];
    self.gridPts = [self gridPointsFromCorners:pxCorners];
    NSLog(@"[JJCheat] 标定完成 %@", pxCorners);
    return YES;
}

- (BOOL)adoptRefinedCorners:(NSArray *)fc {
    if (![fc isKindOfClass:[NSArray class]] || fc.count != 4) return NO;
    if (![self cornersAreSane:fc]) {
        NSLog(@"[JJCheat] 精修四角几何不合理，沿用原四角");
        return NO;
    }
    self.finalCorners = fc;
    self.gridPts = [self gridPointsFromCorners:fc];
    return YES;
}

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
    NSLog(@"[JJCheat] 自动标定完成，四角(point)=%@", saved);
}

#pragma mark - 快照 / 回滚

- (void)snapshot {
    self.backupFinal = self.finalCorners;
    self.backupPoint = self.pointCorners;
    self.backupGrid = self.gridPts;
    self.hasSnapshot = YES;
}

- (BOOL)restoreSnapshot {
    if (!self.hasSnapshot) return NO;
    self.finalCorners = self.backupFinal;
    self.pointCorners = self.backupPoint;
    self.gridPts = self.backupGrid;
    self.lastFrameW = 0;
    self.lastFrameH = 0;
    NSArray *px = nil;
    if (self.finalCorners.count == 4) {
        px = self.finalCorners;
    } else if (self.pointCorners.count == 4) {
        CGRect nb = [UIScreen mainScreen].nativeBounds;
        px = self.pointCorners;
        /* 推给识别层用 nativeBounds 换算（与手动标定同一口径） */
        CGSize pt = [UIScreen mainScreen].bounds.size;
        if (pt.width > 0 && pt.height > 0) {
            CGFloat sx = nb.size.width / pt.width, sy = nb.size.height / pt.height;
            NSMutableArray *a = [NSMutableArray arrayWithCapacity:4];
            for (NSArray *p in self.pointCorners) {
                [a addObject:@[@([p[0] doubleValue] * sx), @([p[1] doubleValue] * sy)]];
            }
            px = a;
        }
    }
    if (px.count == 4) {
        [[JJVisionBridge shared] setCorners:px];
        self.gridPts = [self gridPointsFromCorners:px];
    }
    NSLog(@"[JJCheat] 已回滚到上一次成功标定（JS 锚盘未清空）");
    return YES;
}

#pragma mark - 诊断

- (void)dumpSamplesWithPixels:(NSData *)rgba width:(int)w height:(int)h {
    NSArray<NSArray<NSNumber *> *> *grid = self.gridPts;
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

@end
