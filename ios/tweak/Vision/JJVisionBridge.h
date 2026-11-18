//
//  JJVisionBridge.h
//  JJCheat
//
//  JavaScriptCore 桥：把 RGBA 像素喂给打包好的 engine.js，拿回识别结果。
//
//  2.1.0 职责划分（重构要点）：
//    本类只负责「视觉识别」——盘面 codes / FEN / 走子检测 / 轮次。
//    棋力不在 JS 里了：engine.js 只输出 needSearch + searchFen，
//    由 JJPikafish（独立进程）计算，控制器负责拼装 HUD 结论。
//
//  engine.js 定位（方案 B，2.1.0 沿用）：
//    ① App 沙箱内 <容器>/Library/Application Support/JJCheat/engine.js
//    ② jbroot() / /var/jb / /Library（roothide / rootless / rootful）
//    ③ 全部落空 → 编进 dylib 的内嵌副本（JJEngineScript.c）
//  首次载入会把内嵌副本写进 ①，之后读文件，可热改。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^JJVisionResultBlock)(NSDictionary * _Nullable result, NSError * _Nullable error);

@interface JJVisionBridge : NSObject

+ (instancetype)shared;

/** 加载 engine.js，返回是否成功 */
- (BOOL)loadEngine;

/** 四点标定 [[x,y] x4]，顺序 左上/右上/右下/左下，屏幕像素坐标 */
- (void)setCorners:(NSArray<NSArray<NSNumber *> *> *)corners;

/** 重置到指定局面（nil = 标准开局） */
- (void)resetWithFen:(nullable NSString *)fen;

/**
 * 学习棋盘 + 四角独立自校准，整段在引擎队列异步执行，回调回主线程。
 * learnAndRefine 跑 90 格模板匹配 + refineGrid 拟合，不能同步调用（会冻主线程）。
 */
- (void)learnAndRefineWithPixels:(NSData *)rgba
                           width:(int)w
                          height:(int)h
                     baseCorners:(nullable NSArray<NSArray<NSNumber *> *> *)baseCorners
                        callback:(JJVisionResultBlock)callback;

/** 识别一帧（异步，回调主线程）。2.1.0 起不再传入思考时间。 */
- (void)processPixels:(NSData *)rgba
                width:(int)w
               height:(int)h
             callback:(JJVisionResultBlock)callback;

@end

NS_ASSUME_NONNULL_END
