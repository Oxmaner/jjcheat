//
//  JJPikafishInstaller.m
//  JJCheat
//

#import "JJPikafishInstaller.h"
#import "JJConfig.h"

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

/* 复制指纹：NSUserDefaults 里记录「上次复制时源文件的大小」。
   装了新 deb（pikafish 重新编译，大小几乎必变）→ 下次启动自动重新复制。 */
#define kJJKeyPikaBinSize @"JJCheat.pikaBinSize"

static NSString *JJEngineRelPath(void) {
    return [JJ_PIKA_DIR_REL stringByAppendingPathComponent:JJ_PIKA_BIN_NAME];
}

@implementation JJPikafishInstaller

+ (NSString *)engineDirInContainer {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        if (!paths.count) return;
        NSString *dir = [[paths[0] stringByAppendingPathComponent:@"JJCheat"]
                          stringByAppendingPathComponent:@"Pikafish"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        cached = dir;
    });
    return cached;
}

+ (NSString *)enginePathInContainer {
    return [[self engineDirInContainer] stringByAppendingPathComponent:JJ_PIKA_BIN_NAME];
}

+ (NSArray<NSString *> *)candidateSources {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:5];
    /* ① App 容器（目标） */
    NSString *dst = [self enginePathInContainer];
    if (dst.length) [paths addObject:dst];

    /* ② bundle 里的 .jbroot 符号链接（roothide 官方做法：链接就放在主程序旁） */
    NSString *bundleRoot = [[NSBundle mainBundle] bundlePath];
    if (bundleRoot.length) {
        NSString *jbrootLink = [bundleRoot stringByAppendingPathComponent:@".jbroot"];
        [paths addObject:[jbrootLink stringByAppendingPathComponent:JJEngineRelPath()]];
    }

    /* ③ roothide jbroot() 解析 */
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    [paths addObject:jbroot([@"/" stringByAppendingString:JJEngineRelPath()])];
#endif

    /* ④ rootless / rootful 字面量 */
    [paths addObject:[@"/var/jb" stringByAppendingPathComponent:JJEngineRelPath()]];
    [paths addObject:[@"/" stringByAppendingString:JJEngineRelPath()]];
    return paths;
}

/** 找一个存在的安装源（不含容器目标），返回 {path, size} 或 nil */
+ (NSDictionary *)findSource {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cands = [self candidateSources];
    for (NSUInteger i = 1; i < cands.count; i++) {
        NSString *p = cands[i];
        if (!p.length || ![fm fileExistsAtPath:p]) {
            NSLog(@"[JJCheat][Pika] 候选#%lu 未命中: %@", (unsigned long)i, p.length ? p : @"(nil)");
            continue;
        }
        NSLog(@"[JJCheat][Pika] 引擎源命中候选#%lu: %@", (unsigned long)i, p);
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        return @{@"path": p, @"size": @(attr.fileSize)};
    }
    return nil;
}

+ (BOOL)ensureInstalledWithError:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dst = [self enginePathInContainer];
    if (!dst.length) {
        if (error) *error = [NSError errorWithDomain:@"JJCheat" code:1
                        userInfo:@{NSLocalizedDescriptionKey: @"容器目录不可用"}];
        return NO;
    }

    NSDictionary *src = [self findSource];
    long long recordedSize = [[NSUserDefaults standardUserDefaults]
                              integerForKey:kJJKeyPikaBinSize];

    BOOL dstExists = [fm fileExistsAtPath:dst];
    /* 情况 1：容器已有副本，且没有新源（或源大小 == 记录值）→ 直接用 */
    if (dstExists && (!src || [(NSNumber *)src[@"size"] longLongValue] == recordedSize)) {
        NSDictionary *dstAttr = [fm attributesOfItemAtPath:dst error:nil];
        if (([dstAttr filePosixPermissions] & 0100) == 0) {
            [fm setAttributes:@{NSFilePosixPermissions: @(0755)} ofItemAtPath:dst error:nil];
            NSLog(@"[JJCheat][Pika] 补可执行位: %@", dst);
        }
        return YES;
    }

    /* 情况 2：容器为空或源大小变了 → 重新复制 */
    if (!src) {
        if (dstExists) {
            /* 源都没了（deb 被卸载？）但容器副本还在 → 容器版本继续用 */
            return YES;
        }
        if (error) *error = [NSError errorWithDomain:@"JJCheat" code:2
                        userInfo:@{NSLocalizedDescriptionKey:
                            @"deb 里找不到 pikafish（包未安装或损坏）"}];
        NSLog(@"[JJCheat][Pika] 安装失败：容器无副本且所有候选源都不存在");
        return NO;
    }

    NSString *srcPath = src[@"path"];
    NSError *copyErr = nil;
    if (dstExists) {
        NSString *old = [dst stringByAppendingString:@".old"];
        [fm removeItemAtPath:old error:nil];
        [fm moveItemAtPath:dst toPath:old error:nil];
    }
    BOOL ok = [fm copyItemAtPath:srcPath toPath:dst error:&copyErr];
    if (ok) {
        [fm setAttributes:@{NSFilePosixPermissions: @(0755)} ofItemAtPath:dst error:nil];
        [fm removeItemAtPath:[dst stringByAppendingString:@".old"] error:nil];
        [[NSUserDefaults standardUserDefaults] setInteger:[src[@"size"] longLongValue]
                                                  forKey:kJJKeyPikaBinSize];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[JJCheat][Pika] 引擎已复制到容器（%lld 字节）: %@",
              [(NSNumber *)src[@"size"] longLongValue], dst);
        return YES;
    }
    /* 复制失败：恢复旧副本（老版本引擎还能用） */
    NSLog(@"[JJCheat][Pika] 复制失败: %@", copyErr.localizedDescription);
    NSString *oldPath = [dst stringByAppendingString:@".old"];
    if ([fm fileExistsAtPath:oldPath]) {
        [fm removeItemAtPath:dst error:nil];
        [fm moveItemAtPath:oldPath toPath:dst error:nil];
    }
    if (error) *error = copyErr;
    return dstExists;
}

@end
