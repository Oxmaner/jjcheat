//
//  JJPikafish.h
//  JJCheat —— Pikafish 进程内引擎（2.1.52 起）
//
//  2.1.0 原本把 Pikafish 当独立可执行文件 posix_spawn 起来，真机验证失败：
//  iOS App 沙盒不允许对自己数据容器与 jbroot 下的二进制做 exec
//  （access(X_OK) 一路 EPERM），连容器副本都起不来。2.1.52 改为把 Pikafish
//  交叉编译成静态库链进 JJCheat.dylib，用 jjpika_shim 接管 std::cin/std::cout，
//  在专用线程里跑 UCIEngine::loop()。沙盒再也拦不到，也不再需要可执行文件。
//
//  仍然说标准 UCI 方言（Pikafish 源自 Stockfish：position fen / go movetime /
//  bestmove；不是 UCCI——那是皮卡鱼早期 GUI 的叫法）。
//
//  线程模型：
//    engine 线程  —— jjpika_start() 阻塞跑引擎主循环
//    reader 线程  —— jjpika_recv() 取输出行，dispatch 到 pikaQueue
//    pikaQueue    —— 串行：状态机、发命令、回调派发，全部在这上面
//  回调统一回主线程。引擎与界面之间没有任何共享可变状态。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JJPikaState) {
    JJPikaStateIdle = 0,      // 未启动
    JJPikaStateStarting,      // 加载权重 / UCI 握手中
    JJPikaStateReady,         // 可用
    JJPikaStateSearching,     // 搜索中
    JJPikaStateDead,          // 异常（权重缺失 / 握手超时），等待重试
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

/** 实际在用的 NNUE 权重路径（诊断面板用；为空表示还没解析出来） */
- (NSString *)netPathInUse;

/** 最近一条引擎自述（`info string ...`）。
    2.1.68 起引擎在网络校验失败时会发
    `info string JJ-NNUE FAIL reason=... | decompressed=... | fileHash=0x... engineHash=0x...`，
    这里原样留存，HUD 的「皮卡鱼引擎」详情面板直接显示 —— 不用抓 syslog
    就能分清「权重没读到」和「权重与引擎不配套」。成功时这里是
    `NNUE evaluation using ...`。 */
@property (nonatomic, readonly, copy, nullable) NSString *lastEngineNotice;

/** 引擎主循环是否在跑 */
- (BOOL)engineThreadAlive;

/** 启动引擎：解析权重 → 起线程 → UCI 握手。幂等，可反复调用。 */
- (void)start;

/** 停止引擎（插件关闭时调用）：发 quit，线程自行退出。 */
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
