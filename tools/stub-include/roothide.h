/*
 * 本机（Windows/Linux）语法检查用的 roothide.h 替身 —— 仅用于 tools/check-syntax.sh。
 * 真机/theos 构建用的是 roothide/theos 自带的头，签名以那份为准。
 *
 * 依据实际调用点反推的签名：
 *   Installer.m : [paths addObject:jbroot([@"/" stringByAppendingString:rel])]
 *   BallWindow.m: [paths addObject:jbroot(rel)]
 *   VisionBridge: [candidates addObject:jbroot(@"/Library/...")]
 * 即接受 NSString*、返回 NSString*（C 版本另有 jbrootc）。
 */
#ifndef JJ_STUB_ROOTHIDE_H
#define JJ_STUB_ROOTHIDE_H

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
/* roothide：把 jbroot 内的相对路径映射成当前越狱环境的真实绝对路径 */
NSString *jbroot(NSString *path);
#ifdef __cplusplus
}
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif
const char *jbrootc(const char *path);
#ifdef __cplusplus
}
#endif

#endif /* JJ_STUB_ROOTHIDE_H */
