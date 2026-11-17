//
//  JJPikafishInstaller.m
//  JJCheat —— Pikafish 权重定位（2.1.52 起）
//

#import "JJPikafishInstaller.h"
#import "JJConfig.h"

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

/* 复制指纹：NSUserDefaults 记录「上次复制时源文件的大小」。
   装了新 deb（换了网）→ 大小几乎必变 → 下次启动自动重拷。 */
#define kJJKeyNetSize @"JJCheat.pikaNetSize"
/* 权重尺寸窗口。2.1.68 起换成「随 tag 配套」的网络：zstd 后约 4.19MB、解压 5.5MB。
   而官方 master-net 那个是**新架构**的 50MB 网络，与 Pikafish-2026-09-06 架构不符
   （fileHash 0xCACA41C8 vs engineHash 0x40C70FA6），引擎会拒绝加载。
   所以两头都要卡：太小=没下全；太大=又拿成 master-net 了。
   加上限还有第二个作用：老用户容器里存着 50MB 旧网络，靠它把旧文件判定为无效并重拷。 */
#define kJJMinNetSize (3LL * 1024 * 1024)
#define kJJMaxNetSize (24LL * 1024 * 1024)

static NSString *sResolvedNet = nil;

@interface JJPikafishInstaller ()
+ (nullable NSString *)findSourcePath;
/* 权重尺寸是否落在可用窗口内（见 kJJMinNetSize / kJJMaxNetSize 的说明） */
+ (BOOL)netSizeOK:(unsigned long long)size;
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

+ (NSString *)netPathInContainer {
    NSString *dir = [self engineDirInContainer];
    return dir.length ? [dir stringByAppendingPathComponent:JJ_PIKA_NET_NAME] : @"";
}

/* 相对 jbroot 的路径：Library/Application Support/JJCheat/Pikafish/pikafish.nnue */
+ (NSString *)artifactRelPath {
    return [JJ_PIKA_DIR_REL stringByAppendingPathComponent:JJ_PIKA_NET_NAME];
}

+ (NSArray<NSString *> *)candidateSources {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:6];
    NSString *rel = [self artifactRelPath];

    /* 块 0：容器目标 */
    NSString *dst = [self netPathInContainer];
    [paths addObject:dst.length ? dst : @""];

    /* 块 1：bundle/.jbroot（roothide 在主程序旁放的符号链接） */
    NSString *bundleRoot = [[NSBundle mainBundle] bundlePath];
    if (bundleRoot.length) {
        NSString *link = [bundleRoot stringByAppendingPathComponent:@".jbroot"];
        [paths addObject:[link stringByAppendingPathComponent:rel]];
    }

    /* 块 2：jbroot()（仅 roothide 构建有） */
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    [paths addObject:jbroot([@"/" stringByAppendingString:rel])];
#endif

    /* 块 3 / 4：rootless 与 rootful 字面量 */
    [paths addObject:[@"/var/jb" stringByAppendingPathComponent:rel]];
    [paths addObject:[@"/" stringByAppendingString:rel]];
    return paths;
}

+ (BOOL)netSizeOK:(unsigned long long)size {
    return size >= (unsigned long long)kJJMinNetSize && size <= (unsigned long long)kJJMaxNetSize;
}

+ (NSString *)findSourcePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *cands = [self candidateSources];
    for (NSUInteger i = 1; i < cands.count; i++) {   /* 从 1 开始：0 是容器目标本身 */
        NSString *p = cands[i];
        if (!p.length || ![fm fileExistsAtPath:p]) {
            NSLog(@"[JJCheat][Pika] 权重源位 %lu 未命中: %@", (unsigned long)i,
                  p.length ? p : @"(nil)");
            continue;
        }
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        if (![self netSizeOK:[attr fileSize]]) {
            NSLog(@"[JJCheat][Pika] 权重源位 %lu 尺寸不对（%llu 字节，期望 %lld~%lld），跳过: %@",
                  (unsigned long)i, [attr fileSize], (long long)kJJMinNetSize,
                  (long long)kJJMaxNetSize, p);
            continue;
        }
        NSLog(@"[JJCheat][Pika] 权重命中源位 %lu: %@（%llu 字节）", (unsigned long)i, p,
              [attr fileSize]);
        return p;
    }
    return nil;
}

/** 读一眼文件头，确认引擎 mmap 不会失败（读不了就宁可重拷） */
+ (BOOL)fileLooksReadable:(NSString *)path {
    if (!path.length) return NO;
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return NO;
    unsigned char buf[64];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);
    return n > 0;
}

+ (NSString *)resolveNetPathWithError:(NSError **)error {
    return [self resolveNetPathWithError:error force:NO];
}

+ (NSString *)resolveNetPathWithError:(NSError **)error force:(BOOL)force {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dst = [self netPathInContainer];
    if (!dst.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJCheat" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"容器目录不可用"}];
        }
        return nil;
    }

    if (!force && sResolvedNet.length && [fm fileExistsAtPath:sResolvedNet]) {
        return sResolvedNet;
    }

    unsigned long long dstSize =
        [[fm attributesOfItemAtPath:dst error:nil] fileSize];
    NSString *src = [self findSourcePath];
    unsigned long long srcSize = src ? [[fm attributesOfItemAtPath:src error:nil] fileSize] : 0;
    long long recorded = [[NSUserDefaults standardUserDefaults] integerForKey:kJJKeyNetSize];

    /* 情况 1：容器副本可用，且源没变（或压根没有源）→ 直接用，省掉 48MB 复制 */
    if ([self netSizeOK:dstSize]) {
        BOOL srcChanged = src && (long long)srcSize != recorded && srcSize != dstSize;
        if (!srcChanged && [self fileLooksReadable:dst]) {
            sResolvedNet = dst;
            return dst;
        }
        NSLog(@"[JJCheat][Pika] 权重源已变（记录 %lld / 源 %llu），重新复制", recorded, srcSize);
    }

    /* 情况 2：复制源 → 容器 */
    if (src.length) {
        NSString *oldPath = [dst stringByAppendingString:@".old"];
        [fm removeItemAtPath:oldPath error:nil];
        if (dstSize > 0) [fm moveItemAtPath:dst toPath:oldPath error:nil];

        NSError *copyErr = nil;
        if ([fm copyItemAtPath:src toPath:dst error:&copyErr]) {
            [fm setAttributes:@{NSFilePosixPermissions: @(0644)} ofItemAtPath:dst error:nil];
            [fm removeItemAtPath:oldPath error:nil];
            [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)srcSize
                                                      forKey:kJJKeyNetSize];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[JJCheat][Pika] 权重已复制到容器（%llu 字节）", srcSize);
            if ([self fileLooksReadable:dst]) {
                sResolvedNet = dst;
                return dst;
            }
            NSLog(@"[JJCheat][Pika] 复制完成但容器副本仍读不了，回退源路径");
            sResolvedNet = src;
            return src;
        }

        NSLog(@"[JJCheat][Pika] 权重复制失败: %@", copyErr.localizedDescription);
        if ([fm fileExistsAtPath:oldPath]) {
            [fm removeItemAtPath:dst error:nil];
            [fm moveItemAtPath:oldPath toPath:dst error:nil];
        }
        /* 复制失败但源可读：直接让引擎读源位（只读，不写） */
        if ([self fileLooksReadable:src]) {
            sResolvedNet = src;
            return src;
        }
    }

    /* 情况 3：源没了但容器还有旧副本 → 继续用，不因为升级失败把引擎弄没 */
    if ([self netSizeOK:dstSize] && [self fileLooksReadable:dst]) {
        sResolvedNet = dst;
        return dst;
    }

    if (error) {
        *error = [NSError errorWithDomain:@"JJCheat" code:2
                                 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"deb 里找不到 %@（包未安装或损坏）", JJ_PIKA_NET_NAME]}];
    }
    NSLog(@"[JJCheat][Pika] 权重缺失：容器无有效副本，所有候选源都不存在");
    return nil;
}

@end
