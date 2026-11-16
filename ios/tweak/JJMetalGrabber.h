//
//  JJMetalGrabber.h
//  JJCheat —— Metal 渲染游戏的抓帧（hook presentDrawable: 后用 blit 读回 texture）
//
//  为什么需要：roothide 下 CARenderServer 被 App 沙箱静默拒绝（返回全黑），
//  CALayer renderInContext 抓不到 Metal 内容，EAGLContext hook 对 Metal 游戏不触发。
//  唯一稳的路子是在 present 之前把 drawable 的 texture 拷到 shared buffer。
//

#import <Foundation/Foundation.h>

/** 取最新一帧 RGBA（1.5 秒内有效），没有则 nil */
NSData *JJMetalFrameCopy(int *outW, int *outH);

/** 安装 hook（幂等；Metal framework 未加载时会先 dlopen） */
void JJMetalInstallHooks(void);

/** 诊断串 */
NSString *JJMetalStatus(void);
