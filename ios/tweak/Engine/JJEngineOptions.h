//
//  JJEngineOptions.h
//  JJCheat —— Pikafish 可调参数（2.1.79 新增）
//
//  【为什么要单独一层】
//  引擎参数散在 JJConfig.h（编译期常量）和 JJPikafish.m（写死的 setoption 字符串）里，
//  想加一项（比如 MultiPV）就得同时改三处：常量、下发逻辑、菜单。
//  现在统一收在这里：
//    - 每一项 = 一个配置键 + 取值范围 + 是否需要重启 + 对应 UCI 名
//    - 下发集中在 JJPikafish 的 applyOptionsOnQueue，菜单只改键值
//  加新参数只改本文件 + 菜单，不动主流程。
//
//  【只暴露 Pikafish 真的支持的选项】
//  在 engine.cpp 里实测注册的选项（master @ 8d8db92f）：
//    Threads / Hash / Clear Hash / Ponder / MultiPV / Move Overhead /
//    nodestime / UCI_ShowWDL / EvalFile / NumaPolicy / Debug Log File
//  没有开局库、没有残局库 —— 皮卡鱼不是这个形态，别在菜单里假装有。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 配置键（NSUserDefaults）。命名与旧键保持兼容，避免升级后设置丢失。 */
extern NSString *const JJOptKeyThinkMs;        // go movetime，毫秒
extern NSString *const JJOptKeyThinkDepth;     // go depth（>0 时优先于 movetime）
extern NSString *const JJOptKeyHashMb;         // setoption Hash
extern NSString *const JJOptKeyThreads;        // setoption Threads
extern NSString *const JJOptKeyMultiPV;        // setoption MultiPV
extern NSString *const JJOptKeyMoveOverhead;   // setoption Move Overhead
extern NSString *const JJOptKeyShowWDL;        // setoption UCI_ShowWDL

/* 取值范围（与 Pikafish 的 Option(min,max) 对齐，超界会被引擎拒绝） */
#define JJ_OPT_THINK_MS_MIN        100
#define JJ_OPT_THINK_MS_MAX        3000
#define JJ_OPT_THINK_DEPTH_MIN     0      // 0 = 用 movetime
#define JJ_OPT_THINK_DEPTH_MAX     30
#define JJ_OPT_HASH_MB_MIN         16
#define JJ_OPT_HASH_MB_MAX         96     // iOS 内存有限，别给到引擎的 MaxHashMB
#define JJ_OPT_THREADS_MIN         1
#define JJ_OPT_THREADS_MAX         4      // 再多对 800ms 级搜索无收益，且重建线程池有风险
#define JJ_OPT_MULTIPV_MIN         1
#define JJ_OPT_MULTIPV_MAX         5
#define JJ_OPT_MOVE_OVERHEAD_MIN   0
#define JJ_OPT_MOVE_OVERHEAD_MAX   500

@interface JJEngineOptions : NSObject

+ (instancetype)shared;

/** 从 NSUserDefaults 读取（缺省值兜底 + 夹到合法区间）。启动时调一次即可。 */
- (void)reload;

/* ---- 读 ---- */
@property (nonatomic, readonly) NSInteger thinkMs;
@property (nonatomic, readonly) NSInteger thinkDepth;   // 0 = 不按深度
@property (nonatomic, readonly) NSInteger hashMb;
@property (nonatomic, readonly) NSInteger threads;
@property (nonatomic, readonly) NSInteger multiPV;
@property (nonatomic, readonly) NSInteger moveOverhead;
@property (nonatomic, readonly) BOOL showWDL;

/* ---- 写（逐项，写后自动持久化并夹到合法区间） ---- */
- (void)setThinkMs:(NSInteger)v;
- (void)setThinkDepth:(NSInteger)v;
- (void)setHashMb:(NSInteger)v;
- (void)setThreads:(NSInteger)v;
- (void)setMultiPV:(NSInteger)v;
- (void)setMoveOverhead:(NSInteger)v;
- (void)setShowWDL:(BOOL)v;

/** 需要 setoption 下发的行（不含 go）。
 *  只包含「引擎侧参数」，Hash/Threads/MultiPV/Move Overhead/UCI_ShowWDL。
 *  thinkMs/thinkDepth 是 go 的参数，不走 setoption，所以不在这里。 */
- (NSArray<NSString *> *)setoptionLines;

/** 改变这一项是否需要重建线程 / 重载权重。
 *  Threads 会 threads.clear() 再 pthread_create；真机实测重建不干净时
 *  worker 悬空 → go 时在 0x0 解引用 SIGSEGV（2.1.60~62 的血泪）。
 *  所以改它必须显式提示「需重启引擎」，并让用户二次确认。 */
+ (BOOL)requiresEngineRestartForKey:(NSString *)key;

/** 人类可读的当前配置摘要（引擎详情面板用） */
- (NSString *)summary;

@end

NS_ASSUME_NONNULL_END
