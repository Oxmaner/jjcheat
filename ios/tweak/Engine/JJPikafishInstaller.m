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
   装了新 deb（pikafish 重新编译 / 换了网，大小几乎必变）→ 下次启动自动重拷。 */
#define kJJKeyPikaBinSize @"JJCheat.pikaBinSize"
#define kJJKeyPikaNetSize @"JJCheat.pikaNetSize"

/* 两个产物 —— 数组顺序即安装顺序，日志按这个顺序打。
   下标 0 是可执行文件（要补 0755），下标 1 是 NNUE 权重。 */
static NSString *const kJJArtifactNames[] = { JJ_PIKA_BIN_NAME, JJ_PIKA_NET_NAME };
static const NSUInteger kJJArtifactCount = 2;

static NSString *JJKeyForSize(NSUInteger idx) {
    return idx == 0 ? kJJKeyPikaBinSize : kJJKeyPikaNetSize;
}

/** 相对 jbroot 的路径：Library/Application Support/JJCheat/Pikafish/<name> */
static NSString *JJArtifactRelPath(NSUInteger idx) {
    return [JJ_PIKA_DIR_REL stringByAppendingPathComponent:kJJArtifactNames[idx]];
}

@interface JJPikafishInstaller ()
+ (nullable NSString *)containerPathFor:(NSUInteger)idx;
+ (nullable NSDictionary *)findSourceFor:(NSUInteger)idx;
+ (BOOL)installArtifact:(NSUInteger)idx error:(NSError **)error;
@end

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
    NSString *dir = [self engineDirInContainer];
    return dir.length ? [dir stringByAppendingPathComponent:JJ_PIKA_BIN_NAME] : @"";
}

+ (NSString *)netPathInContainer {
    NSString *dir = [self engineDirInContainer];
    return dir.length ? [dir stringByAppendingPathComponent:JJ_PIKA_NET_NAME] : @"";
}

+ (NSString *)containerPathFor:(NSUInteger)idx {
    NSString *dir = [self engineDirInContainer];
    if (!dir.length) return nil;
    return [dir stringByAppendingPathComponent:kJJArtifactNames[idx]];
}

/* 候选源按「块」排列，每块正好 kJJArtifactCount 个，块内顺序与产物下标一致：
 *   块 0: App 容器（目标，不当作源）
 *   块 1: <bundle>/.jbroot/...  （roothide 在主程序旁放的符号链接）
 *   块 2: jbroot("/Library/...")（仅 roothide 构建有）
 *   块 3: /var/jb/Library/...    （rootless）
 *   块 4: /Library/...           （rootful）
 * 这样 findSourceFor: 只要 base = k*(产物数) 就能定位到对应产物。 */
+ (NSArray<NSString *> *)candidateSources {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:10];

    /* 块 0：容器目标 */
    for (NSUInteger i = 0; i < kJJArtifactCount; i++) {
        NSString *dst = [self containerPathFor:i];
        [paths addObject:dst ?: @""];
    }

    /* 块 1：bundle/.jbroot */
    NSString *bundleRoot = [[NSBundle mainBundle] bundlePath];
    for (NSUInteger i = 0; i < kJJArtifactCount; i++) {
        if (!bundleRoot.length) break;
        NSString *link = [bundleRoot stringByAppendingPathComponent:@".jbroot"];
        [paths addObject:[link stringByAppendingPathComponent:JJArtifactRelPath(i)]];
    }

    /* 块 2：jbroot() */
    for (NSUInteger i = 0; i < kJJArtifactCount; i++) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
        [paths addObject:jbroot([@"/" stringByAppendingString:JJArtifactRelPath(i)])];
#endif
    }

    /* 块 3 / 4：rootless 与 rootful 字面量 */
    for (NSUInteger i = 0; i < kJJArtifactCount; i++) {
        [paths addObject:[@"/var/jb" stringByAppendingPathComponent:JJArtifactRelPath(i)]];
    }
    for (NSUInteger i = 0; i < kJJArtifactCount; i++) {
        [paths addObject:[@"/" stringByAppendingString:JJArtifactRelPath(i)]];
    }
    return paths;
}

+ (NSDictionary *)findSourceFor:(NSUInteger)idx {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *cands = [self candidateSources];
    NSUInteger total = cands.count;

    /* 从块 1 开始（跳过容器目标本身），逐块找同一下标的产物 */
    for (NSUInteger base = kJJArtifactCount; base + idx < total; base += kJJArtifactCount) {
        NSUInteger pos = base + idx;
        NSString *p = cands[pos];
        if (!p.length || ![fm fileExistsAtPath:p]) {
            NSLog(@"[JJCheat][Pika] %@ 源位 %lu 未命中: %@", kJJArtifactNames[idx],
                  (unsigned long)pos, p.length ? p : @"(nil)");
            continue;
        }
        NSLog(@"[JJCheat][Pika] %@ 命中源位 %lu: %@", kJJArtifactNames[idx],
              (unsigned long)pos, p);
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        return @{ @"path": p, @"size": @(attr.fileSize) };
    }
    return nil;
}

+ (BOOL)installArtifact:(NSUInteger)idx error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *name = kJJArtifactNames[idx];
    NSString *dst = [self containerPathFor:idx];
    if (!dst.length) return NO;

    NSDictionary *src = [self findSourceFor:idx];
    long long recorded = [[NSUserDefaults standardUserDefaults] integerForKey:JJKeyForSize(idx)];
    BOOL dstExists = [fm fileExistsAtPath:dst];

    /* 情况 1：容器已有副本，且没有新源（或源大小 == 记录值）→ 直接用 */
    if (dstExists && (!src || [(NSNumber *)src[@"size"] longLongValue] == recorded)) {
        NSDictionary *attr = [fm attributesOfItemAtPath:dst error:nil];
        if (idx == 0 && (([attr filePosixPermissions] & 0100) == 0)) {
            [fm setAttributes:@{NSFilePosixPermissions: @(0755)} ofItemAtPath:dst error:nil];
            NSLog(@"[JJCheat][Pika] 补可执行位: %@", dst);
        }
        return YES;
    }

    /* 情况 2：容器为空，或源大小变了 → 重新复制 */
    if (!src) {
        if (dstExists) return YES;   /* 源没了（deb 被卸）但副本还在 → 继续用 */
        if (error) {
            *error = [NSError errorWithDomain:@"JJCheat" code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"deb 里找不到 %@（包未安装或损坏）", name]}];
        }
        NSLog(@"[JJCheat][Pika] 安装失败：容器无 %@ 且所有候选源都不存在", name);
        return NO;
    }

    NSString *srcPath = src[@"path"];
    NSString *oldPath = [dst stringByAppendingString:@".old"];
    NSError *copyErr = nil;
    if (dstExists) {
        [fm removeItemAtPath:oldPath error:nil];
        [fm moveItemAtPath:dst toPath:oldPath error:nil];
    }
    BOOL ok = [fm copyItemAtPath:srcPath toPath:dst error:&copyErr];
    if (ok) {
        if (idx == 0) {
            [fm setAttributes:@{NSFilePosixPermissions: @(0755)} ofItemAtPath:dst error:nil];
        }
        [fm removeItemAtPath:oldPath error:nil];
        [[NSUserDefaults standardUserDefaults] setInteger:[src[@"size"] longLongValue]
                                                  forKey:JJKeyForSize(idx)];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[JJCheat][Pika] %@ 已复制到容器（%lld 字节）", name,
              [(NSNumber *)src[@"size"] longLongValue]);
        return YES;
    }
    /* 复制失败：恢复旧副本，别让升级把能用的版本弄没 */
    NSLog(@"[JJCheat][Pika] %@ 复制失败: %@", name, copyErr.localizedDescription);
    if ([fm fileExistsAtPath:oldPath]) {
        [fm removeItemAtPath:dst error:nil];
        [fm moveItemAtPath:oldPath toPath:dst error:nil];
    }
    if (error) *error = copyErr;
    return dstExists;
}

+ (BOOL)ensureInstalledWithError:(NSError **)error {
    if (![self engineDirInContainer].length) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJCheat" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"容器目录不可用"}];
        }
        return NO;
    }
    for (NSUInteger i = 0; i < kJJArtifactCount; i++) {
        if (![self installArtifact:i error:error]) return NO;
    }
    return YES;
}

@end
