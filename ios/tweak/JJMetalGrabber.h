//
//  JJMetalGrabber.h
//  JJCheat —— Metal 渲染游戏的抓帧（nextDrawable 延迟一帧读 IOSurface）
//
//  为什么需要：roothide 下 CARenderServer 被 App 沙箱静默拒绝（返回全黑），
//  CALayer renderInContext 抓不到 Metal 内容，EAGLContext hook 对 Metal 游戏不触发。
//  实测这游戏只走 CAMetalLayer -nextDrawable（presentDrawable 家族计数冻结），
//  所以第 N 帧记住 drawable 的 IOSurface，第 N+1 帧读它（此时内容已渲染完）。
//
//  1.1.44：hook 本体已迁到 Tweak.x 的 %hook CAMetalLayer，本文件只提供
//  「%orig 前 / %orig 后」两个 C 钩子和帧缓存，不再手写 method_setImplementation。
//
//  注意：extern "C" 守卫保留，让本头文件在 .x / .xm / .mm 任一编译单元里
//  都能对上 .m 导出的 C 符号（ObjC++ 下不用它会发生 C++ 名字修饰）。
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 取最新一帧 RGBA（5 秒内有效），没有则 nil；调用即视为已消费，允许再读一帧 */
NSData *JJMetalFrameCopy(int *outW, int *outH);

/** 已成功出帧的序号；上层用它跳过「同一帧重复喂给 JS」的白工 */
uint64_t JJMetalFrameSerial(void);

/** %hook CAMetalLayer -nextDrawable 在 %orig 之前调用：读/丢弃上一帧的 IOSurface */
void JJMetalBeforeNextDrawable(void);

/** %hook CAMetalLayer -nextDrawable 在 %orig 之后调用：记住本次 drawable 的 IOSurface */
void JJMetalAfterNextDrawable(id drawable);

/** 幂等诊断：hook 由 Logos 注册后打一条状态日志（不再负责安装 hook） */
void JJMetalInstallHooks(void);

/** 诊断串 */
NSString *JJMetalStatus(void);

/** 抓帧总开关：关掉后 nextDrawable hook 只透传，不做 IOSurface 读回/字节交换。
    待机、插件关闭时调用，避免每帧在游戏渲染线程上白烧 14MB 拷贝。 */
void JJMetalSetCaptureEnabled(BOOL enabled);

#ifdef __cplusplus
}
#endif
