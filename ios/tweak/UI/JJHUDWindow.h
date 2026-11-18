//
//  JJHUDWindow.h
//  JJCheat
//
//  2.1.0：HUD 只负责「画」。所有内容由 JJGameController 在
//  presentMergedResult 里合成好（识别结果 + Pikafish 结论）后一次性传进来，
//  HUD 不再自己判断该显示什么、更不碰引擎。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JJHUDMode) {
    JJHUDModeDisplay = 0,   // 只显示，不挡触摸
    JJHUDModeCalibrate,     // 四点标定，接收触摸
};

@interface JJHUDWindow : UIWindow

+ (instancetype)shared;

- (void)attach;

/**
 显示一条合并后的结果。

 支持的 key（全部可选，缺省按空处理）：
   suggest          NSString  ICCS 走法（如 h2e2），仅用于调试
   suggestChinese   NSString  中文记谱（如「炮二平五」）
   from / to        NSNumber  内部 sq（0..89），-1 表示无
   scoreText        NSString  已格式化的分值（「+0.35」/「+杀 3」）
   depth / nodes    NSNumber  搜索深度 / 节点数
   winrate          NSNumber  胜率 0..100
   sideToMove       NSString  @"red" / @"black"
   waitingOpponent  NSNumber  轮到对方
   skipAnalyze      NSNumber  盘面不可信
   engineState      NSString  引擎状态短文本（就绪/思考中/未启动…）
   enginePending    NSNumber  正在搜索同一局面
 */
- (void)showResult:(NSDictionary *)result
        gridPoints:(NSArray<NSArray<NSNumber *> *> *)points
               fen:(NSString *)fen;

/** 顶部一条状态提示（覆盖记谱行，同时清掉分值/引擎行） */
- (void)showStatus:(NSString *)text;

/** 进入四点标定；完成后回调（屏幕 point 坐标四角） */
- (void)beginCalibrationWithCompletion:(void (^)(NSArray<NSValue *> *corners))completion;

/** 2.1.105：只刷新网格并重绘 —— 标定完成后立刻让用户看到网格，不必等学习成功 */
- (void)applyGridPoints:(NSArray<NSArray<NSNumber *> *> *)pts;

/** 隐藏 / 显示整层 */
- (void)setHUDHidden:(BOOL)hidden;

/** 丢弃内容指纹，下一次 showResult 强制重绘 */
- (void)invalidateResultCache;

@property (nonatomic, assign) JJHUDMode mode;

@end

NS_ASSUME_NONNULL_END
