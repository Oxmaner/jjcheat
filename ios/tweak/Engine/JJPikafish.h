//
//  JJPikafish.h
//  JJCheat —— Pikafish 独立引擎进程（2.1.0 核心）
//
//  2.1.0 架构：识别在 engine.js（JSContext），棋力在独立进程 Pikafish。
//  通信走标准 UCI 方言（Pikafish 源自 Stockfish，position fen / go movetime /
//  bestmove；不是 UCCI——那是皮卡鱼早期 GUI 的叫法）。
//
//  设计要点（全部踩坑预防）：
//   - 独立进程：搜索不吃游戏 JSC/CPU 预算，内存不挤游戏的 jetsam，
//     引擎崩溃杀不死游戏进程。
//   - 引擎只在 App 沙箱内活动：posix_spawn 一个可执行副本（安装器已放进
//     容器），stdin/stdout/stderr 走管道，子进程继承沙箱但只碰自己目录。
//   - 看门狗：go 发出后 movetime+3s 仍无 bestmove → kill -9 → 重生 → 重试一次；
//     连续 3 次起不来 → 退避 30s，HUD 显示引擎不可用。
//   - 队列：所有引擎交互都在串行 pikaQueue 上，回调统一回主线程。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JJPikaState) {
    JJPikaStateIdle = 0,      // 未启动
    JJPikaStateStarting,      // 安装/spawn/握手中
    JJPikaStateReady,         // 可用
    JJPikaStateSearching,     // 搜索中
    JJPikaStateDead,          // 崩溃/超时，等待重生或退避
};

/** bestmove 回调（主线程）。result 为 nil = 本次没结果（引擎不可用）。
    result 字段：bestmove/pv（ICCS）、from/to（内部 sq，可直接画箭头）、
    score/mate/depth/nodes/nps/winrate、ponder。 */
typedef void (^JJPikaResultBlock)(NSDictionary * _Nullable result);

@interface JJPikafish : NSObject

+ (instancetype)shared;

/** 当前状态（诊断/菜单用，读取线程安全） */
@property (nonatomic, readonly) JJPikaState state;

/** 状态简述（HUD / 悬浮球引擎状态点用） */
- (NSString *)stateText;

/** 启动引擎：确保安装 → spawn → UCI 握手。幂等，可反复调用。 */
- (void)start;

/** 停止引擎（插件关闭时调用；quit + 收尸 + 关管道） */
- (void)shutdown;

/**
 * 分析一个局面（FEN 必须是引擎坐标：红在下 + w/b 走子方，与 engine.js
 * 的 engineFen 同源）。回调主线程。
 * 局面不变时上层自己缓存（controller 记 lastFen），本方法不去重。
 * movetime 单位 ms（用户思考时间设置）。
 */
- (void)analyzeFen:(NSString *)fen movetime:(NSInteger)movetime completion:(JJPikaResultBlock)completion;

/** 新对局（engine.js 判定 newGame=1 时调用）：ucinewgame + isready。 */
- (void)notifyNewGame;

/** 是否就绪（分析请求就绪或已在后台拉起）。未就绪时 analyze 会先排队。 */
- (BOOL)isReadyOrStarting;

@end

NS_ASSUME_NONNULL_END
