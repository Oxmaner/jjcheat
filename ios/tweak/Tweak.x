//
//  Tweak.x
//  JJCheat —— 注入 JJ象棋 进程，抓画面、算棋、在棋盘上标注
//
//  1.1.44（Logos 审查修复）：
//   - 本文件没有 C++ / MSHookIvar，按规范用 .x（Objective-C）而非 .xm。
//   - 删掉 %hook UIApplication -application:didFinishLaunchingWithOptions:。
//     那是 UIApplicationDelegate 协议方法，UIApplication 类根本不实现，
//     这段 hook 永不触发；启动本来就是 %ctor 里的 3s dispatch_after 兜底。
//   - CAMetalLayer -nextDrawable 从 JJMetalGrabber.m 的手写
//     method_setImplementation 迁回 %hook + %orig；删掉 presentDrawable
//     家族的全类表遍历（真机计数冻结在 65，纯启动开销 + 误伤风险）。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

#import "JJController.h"
#import "JJScreenGrabber.h"
#import "JJHUDWindow.h"
#import "JJEngineBridge.h"
#import "JJMetalGrabber.h"

static BOOL gJJStarted = NO;

static void JJStartOnce(void) {
    if (gJJStarted) return;
    gJJStarted = YES;
    @try {
        [[JJController shared] start];
    } @catch (NSException *e) {
        NSLog(@"[JJCheat] 启动异常: %@", e);
    }
}

/* ============================================================
 *  OpenGL ES 抓帧（备用通道）
 *  cocos2d-x 用 EAGL 渲染，presentRenderbuffer 之后帧缓冲还在，
 *  此时 glReadPixels 可以拿到完整游戏画面。
 * ============================================================ */
%hook EAGLContext

/* 抓帧统一入口：在 %orig 之前读，此时 renderbuffer 还是刚渲染完的内容；
   放在 %orig 之后的话，present 已经把 buffer 换走，读出来就是黑的。 */
static void JJCaptureThrottled(EAGLContext *ctx, NSUInteger target) {
    static unsigned int sThrottle = 0;
    if (((sThrottle++) & 3u) != 0u) return;   /* 每 4 帧抓一次 */
    @try {
        [[JJScreenGrabber shared] captureGLContext:ctx target:target];
    } @catch (NSException *e) {
        /* 静默 */
    }
}

- (BOOL)presentRenderbuffer:(NSUInteger)target {
    JJCaptureThrottled(self, target);
    return %orig;
}

/* cocos2d-x 3.x 起常用这两个带时间的变体，只 hook 上一个会永远不触发 */
- (BOOL)presentRenderbuffer:(NSUInteger)target atTime:(double)timestamp {
    JJCaptureThrottled(self, target);
    return %orig;
}

- (BOOL)presentRenderbuffer:(NSUInteger)target afterMinimumDuration:(double)duration {
    JJCaptureThrottled(self, target);
    return %orig;
}

%end

/* ============================================================
 *  Metal 抓帧（主通道）
 *
 *  实测这游戏只走 -nextDrawable，不走 presentDrawable 家族。
 *  第 N 帧 %orig 前读上一帧的 IOSurface（此时内容已渲染完、还没被复用），
 *  %orig 后记住本次 drawable 的 surface，交给第 N+1 帧。
 *  开关关闭时 JJMetal* 两个函数都只透传，不做 14MB 拷贝/字节交换。
 * ============================================================ */
%hook CAMetalLayer

- (id<CAMetalDrawable>)nextDrawable {
    JJMetalBeforeNextDrawable();
    id<CAMetalDrawable> drawable = %orig;
    JJMetalAfterNextDrawable(drawable);
    return drawable;
}

%end

/* ============================================================
 *  入口
 * ============================================================ */
%ctor {
    /* 未分组 hook（EAGLContext + CAMetalLayer）一次注册完。
       Logos 只解析类名，比旧版 1.5s 后遍历全类表手写 swizzle 轻得多。 */
    %init;

    NSLog(@"[JJCheat] tweak 已加载 (pid=%d)", getpid());

    Class eagl = NSClassFromString(@"EAGLContext");
    BOOL hasPresent = eagl && [eagl instancesRespondToSelector:@selector(presentRenderbuffer:)];
    NSLog(@"[JJCheat] EAGLContext=%p presentRenderbuffer:=%@", eagl, hasPresent ? @"有" : @"没有");
    if (!hasPresent) {
        NSLog(@"[JJCheat] 警告：拿不到 GL hook 点，抓帧将退化为 CARenderServer/CALayer，可能全黑");
    }
    /* 幂等诊断日志，确认 CAMetalLayer 类在 %ctor 时已可用 */
    JJMetalInstallHooks();

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        // 每次回到前台，确保 HUD 没被系统 window 层级盖掉
        @try {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[JJHUDWindow shared] attach];
            });
        } @catch (NSException *e) {}
    }];

    /* 冷启动慢时兜底拉起控制器（原来误挂在 UIApplication 的死 hook 里） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JJStartOnce();
    });
}
