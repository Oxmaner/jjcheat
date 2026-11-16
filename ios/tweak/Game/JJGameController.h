//
//  JJGameController.h
//  JJCheat —— 主控制器（2.1.0 由 JJController 重构）
//
//  职责：
//    - 懒加载：进 App 只挂球，点球才抓帧
//    - tick 状态机：帧序号去重 → 画面指纹 → 学习 / 识别
//    - 搜索：engine.js 输出 needSearch + searchFen → JJPikafish 独立进程
//      → bestmove/深度/分值 → 拼装 HUD 结论（原生缓存，同一局面不重算）
//    - 菜单动作：插件开关 / 自动标定 / 手动标定 / HUD / 思考时间 / 引擎状态
//
//  四角标定细节在 JJCalibrator；悬浮球 UI 在 JJBallWindow；
//  识别在 JJVisionBridge；棋力在 JJPikafish。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JJGameController : NSObject

+ (instancetype)shared;

/** 启动：延迟等 APP 界面就绪后接管（只挂球，不抓帧） */
- (void)start;
- (void)stop;

/** 强制重新标定（手动四点） */
- (void)recalibrate;

/** 重置到标准开局（显式清锚盘） */
- (void)resetToStartPosition;

@end

NS_ASSUME_NONNULL_END
