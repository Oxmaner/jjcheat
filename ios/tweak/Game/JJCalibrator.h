//
//  JJCalibrator.h
//  JJCheat —— 四角标定与几何体检（2.1.0 从 JJController 拆出）
//
//  职责边界：只管「四角 → 90 个采样点」这条链路
//    - point 坐标四角持久化 / 按抓帧尺寸换算像素
//    - 手动四点标定的几何校验（乱点/顺序错必须拒绝）
//    - learnAndRefine 精修四角的采纳与回滚快照
//    - 90 个交叉点本地插值（HUD 画箭头 / 帧指纹共用）
//  不碰状态机、不碰引擎 —— 那些在 JJGameController。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JJCalibrator : NSObject

+ (instancetype)shared;

/** 有没有可用的标定（持久化 point 四角或精修四角） */
@property (nonatomic, readonly) BOOL hasCorners;

/** 精修后的像素四角（学习采纳后才有，count==4 时优先用它） */
@property (nonatomic, readonly, nullable) NSArray<NSArray<NSNumber *> *> *finalCorners;

/** 90 个交叉点的像素坐标缓存 */
@property (nonatomic, readonly) NSArray<NSArray<NSNumber *> *> *gridPts;

/** 四角几何是否合理（native 像素坐标）；乱点/聚团/顺序错一律 NO */
- (BOOL)cornersAreSane:(NSArray<NSArray<NSNumber *> *> *)c;

/** 清掉精修四角（重新自动标定前调用），point 四角保留 */
- (void)clearRefined;

/* ============================================================
 *  2.0.0r5 内置标定预设（取代人工四点标定）
 *
 *  两套预设定义在 JJConfig.h：0=人机对战，1=排位赛/棋力评测/锦标赛。
 *  两者只差纵向 50pt（排位赛顶部多了对手头像与大盘计时），列方向一致。
 * ============================================================ */
/** 应用指定预设（0=人机 1=排位），同时作废已学出的精修四角并持久化选择 */
- (void)applyPresetScheme:(NSInteger)scheme;
/** 当前生效的预设编号 */
- (NSInteger)currentCalibScheme;
/** 在人机 ↔ 排位之间切换一次（预设自检失败时用） */
- (void)switchPresetScheme;

/** point 四角 × 抓帧尺寸 → 像素四角；没有 point 四角返回 nil */
- (nullable NSArray<NSArray<NSNumber *> *> *)cornersForWidth:(int)w height:(int)h;

/** 抓帧尺寸变化时把四角推给识别层并重算 90 点（幂等，尺寸没变直接返回） */
- (void)applyForFrameWidth:(int)w height:(int)h;

/** 用任意四角本地插值出 90 个交叉点 */
- (NSArray<NSArray<NSNumber *> *> *)gridPointsFromCorners:(NSArray *)corners;

/** 学习成功：几何合理才采纳精修四角；返回是否采纳 */
- (BOOL)adoptRefinedCorners:(NSArray *)fc;

/** 手动四点标定（屏幕 point）。校验失败返回 NO，且不动任何状态。 */
- (BOOL)handleManualCalibration:(NSArray<NSValue *> *)corners;

/** 自动标定采纳后：像素四角 → point 持久化 */
- (void)saveAutoCalibratedCorners:(NSArray *)fc width:(int)w height:(int)h;
- (void)ensureGridPts;

/** 记住「当前是好标定」，供重标定失败时回滚 */
- (void)snapshot;
@property (nonatomic, readonly) BOOL hasSnapshot;

/** 回滚到快照；返回是否回滚成功 */
- (BOOL)restoreSnapshot;

/** 学习校验失败时 dump 9 个采样点真实颜色（诊断采样偏移 vs 颜色判据） */
- (void)dumpSamplesWithPixels:(NSData *)rgba width:(int)w height:(int)h;

@end

NS_ASSUME_NONNULL_END
