//
//  JJPikafishInstaller.h
//  JJCheat —— Pikafish 引擎资源安装（2.1.0 新增）
//
//  deb 把两个文件放在 jbroot 的 Library/Application Support/JJCheat/Pikafish/ 下：
//    pikafish        可执行文件（~800KB，iOS arm64，ldid ad-hoc 签名）
//    pikafish.nnue   NNUE 权重（~48MB，官方 master-net，zstd 压缩格式）
//
//  为什么权重必须随包走：Pikafish 2026 版取消了编译期内嵌（network.cpp 里
//  没有 INCBIN 分支），Network::load() 只在 {cwd, 二进制所在目录} 里找文件。
//  官方默认的 EvalFile 名就是 pikafish.nnue，所以「和二进制放同一目录」
//  是它自己会找的路径；我们另外再显式 setoption EvalFile 一次做双保险。
//
//  为什么要复制进 App 容器：roothide 的 App 沙箱跨容器读不了 jbroot，
//  而 posix_spawn 需要可读可执行的目标。沿用 engine.js 的成熟方案：
//  首次激活时把两个文件复制进 App 自己的容器，之后一直用容器副本。
//
//  读取源走 4 级回退链，日志写明哪条命中（这同时是真机沙盒探针）：
//    ① App 容器（已复制过，直接用）
//    ② <主程序 bundle>/.jbroot/...（roothide 在 bundle 里放的符号链接）
//    ③ jbroot("/Library/Application Support/JJCheat/Pikafish/...")
//    ④ /var/jb/...（rootless）与 /Library/...（rootful）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JJPikafishInstaller : NSObject

/** 引擎资源在 App 容器内的目录：<容器>/Library/Application Support/JJCheat/Pikafish */
+ (NSString *)engineDirInContainer;

/** 可执行文件在 App 容器内的完整路径 */
+ (NSString *)enginePathInContainer;

/** NNUE 权重在 App 容器内的完整路径（= 引擎二进制同目录） */
+ (NSString *)netPathInContainer;

/**
 * 确保容器里同时有可执行的 pikafish 与 pikafish.nnue。
 * 升级判定按「安装源文件大小」指纹：新 deb 的任一文件大小变了就重新复制。
 * 源读不到但容器已有副本时照常返回 YES（旧版继续用）。
 */
+ (BOOL)ensureInstalledWithError:(NSError **)error;

/** 全部候选源路径（诊断用），第 0 个是容器目标，其余按优先级排列 */
+ (NSArray<NSString *> *)candidateSources;

@end

NS_ASSUME_NONNULL_END
