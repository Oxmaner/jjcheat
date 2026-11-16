//
//  JJPikafishInstaller.h
//  JJCheat —— Pikafish 资源定位（2.1.52 起只管 NNUE 权重）
//
//  2.1.0 时代这里要安装「可执行文件 + 权重」两个产物；2.1.52 改成进程内
//  运行后，可执行文件已经编进 dylib，只剩权重需要落盘。
//
//  deb 把权重放在 jbroot 的 Library/Application Support/JJCheat/Pikafish/ 下。
//  为什么要复制进 App 容器：引擎用 mmap 读这个文件，一旦读失败 Pikafish 的
//  Network::load 会直接 exit(EXIT_FAILURE)——那是把游戏一起带走，赌不起。
//  容器副本是我们自己写的，读权限 100% 确定。首次复制 48MB，之后按大小指纹复用。
//
//  源查找走 4 级回退（日志写明哪条命中，同时是真机沙盒探针）：
//    ① App 容器（已复制过，直接用）
//    ② <主程序 bundle>/.jbroot/...（roothide 在 bundle 里放的符号链接）
//    ③ jbroot("/Library/Application Support/JJCheat/Pikafish/...")
//    ④ /var/jb/...（rootless）与 /Library/...（rootful）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JJPikafishInstaller : NSObject

/** 资源目录：<容器>/Library/Application Support/JJCheat/Pikafish */
+ (NSString *)engineDirInContainer;

/** 权重在 App 容器内的完整路径 */
+ (NSString *)netPathInContainer;

/** 全部候选源路径（诊断用），第 0 个是容器目标，其余按优先级排列 */
+ (NSArray<NSString *> *)candidateSources;

/**
 * 解析出「引擎真正该用的权重路径」，带缓存，可反复调用。
 * 正常返回容器副本的绝对路径；源缺失但容器已有副本时也返回容器副本。
 * 返回 nil 时 error 说明缺什么。
 */
+ (nullable NSString *)resolveNetPathWithError:(NSError **)error;

/** 同上，但强制重新检查源指纹（升级 deb 后由调用方决定是否重来）。 */
+ (nullable NSString *)resolveNetPathWithError:(NSError **)error force:(BOOL)force;

@end

NS_ASSUME_NONNULL_END
