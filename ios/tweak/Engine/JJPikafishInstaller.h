//
//  JJPikafishInstaller.h
//  JJCheat —— Pikafish 引擎可执行文件的安装（2.1.0 新增）
//
//  deb 把 pikafish 放在 jbroot 的 Library/Application Support/JJCheat/Pikafish/
//  下（roothide 的包路径全部相对 jbroot）。但 App 沙箱对跨 App 容器目录的
//  访问受限（engine.js 踩过同款坑），而 posix_spawn 需要可读可执行的目标 ——
//  所以沿用 engine.js 的成熟方案：首次激活时把引擎复制进 App 自己的容器。
//
//  读取源走 4 级回退链，日志会写明哪条命中（这同时是真机沙盒探针）：
//    ① App 容器（已复制过，直接用）
//    ② <主程序 bundle>/.jbroot/...（roothide 在 bundle 里放的符号链接）
//    ③ jbroot("/Library/Application Support/JJCheat/Pikafish/pikafish")
//    ④ /var/jb/...（rootless）与 /Library/...（rootful）
//
//  spawn 额外兜底：即使容器复制被拦，②③ 路径只读也能直接 exec。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JJPikafishInstaller : NSObject

/** 引擎在 App 容器内的目录：<容器>/Library/Application Support/JJCheat/Pikafish */
+ (NSString *)engineDirInContainer;

/** 引擎可执行文件在 App 容器内的完整路径 */
+ (NSString *)enginePathInContainer;

/**
 * 确保容器里有一份可执行的 pikafish。升级判定按「安装源文件大小」指纹：
 * 新 deb 的 pikafish 大小一变就自动重新复制；源读不到但容器有副本时照常可用。
 */
+ (BOOL)ensureInstalledWithError:(NSError **)error;

/** 全部候选源路径（诊断用），第 0 个是容器目标，其余按优先级排列 */
+ (NSArray<NSString *> *)candidateSources;

@end

NS_ASSUME_NONNULL_END
