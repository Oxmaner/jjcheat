//
//  Tweak.x
//  JJCheat 2.1.0 —— 注入 JJ象棋 进程，抓画面、交 Pikafish 算棋、在棋盘上标箭头
//
//  本文件只做三件事：
//    1) hook EAGLContext -presentRenderbuffer*（GL 备用抓帧通道）
//    2) hook CAMetalLayer -nextDrawable（Metal 主通道）
//    3) %ctor 里拉起 JJGameController
//
//  业务逻辑一律不在 Logos 文件里：抓帧在 Capture/，识别在 Vision/，
//  棋力在 Engine/，状态机与 UI 在 Game/ 与 UI/。这样 %hook 段永远是纯转发，
//  出问题时能一眼判断是「hook 没触发」还是「上层逻辑不对」。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

#import "JJConfig.h"
#import "JJGameController.h"
#import "JJVisionBridge.h"
#import "JJHUDWindow.h"
#import "JJScreenGrabber.h"
#import "JJMetalGrabber.h"

static BOOL gJJStarted = NO;

static void JJStartOnce(void) {
    if (gJJStarted) return;
    gJJStarted = YES;
    @try {
        [[JJGameController shared] start];
    } @catch (NSException *e) {
        NSLog(@"[JJCheat] 启动异常: %@", e);
    }
}

/* ============================================================
 *  OpenGL ES 抓帧（备用通道）
 *  cocos2d-x 用 EAGL 渲染，presentRenderbuffer 之后帧缓冲还在，
 *  此时 glReadPixels 可以拿到完整游戏画面。
 *
 *  2.1.0 起 Metal 通道可用的机型上这套永远不生效
 *  （JJMetalCaptureEnabled() 为真时屏蔽回退，roothide 下 GL/CALayer 常全黑）。
 *
 *  抓帧节流函数放在 %hook 之外：%hook 块里只留被 hook 的方法，
 *  非 hook 的 C 代码留在文件作用域，出问题时一眼能分清哪段是 Logos 管的。
 * ============================================================ */
static void JJCaptureThrottled(EAGLContext *ctx, NSUInteger target) {
    static unsigned int sThrottle = 0;
    if (((sThrottle++) & 3u) != 0u) return;   /* 每 4 帧抓一次 */
    if (JJMetalCaptureEnabled()) return;      /* Metal 通道已启用，别走全黑回退 */
    @try {
        [[JJScreenGrabber shared] captureGLContext:ctx target:target];
    } @catch (NSException *e) {
        /* 静默：抓帧失败由上层帧保鲜机制兜底 */
    }
}

%hook EAGLContext

/* 抓帧统一入口：在 %orig 之前读，此时 renderbuffer 还是刚渲染完的内容；
   放在 %orig 之后的话，present 已经把 buffer 换走，读出来就是黑的。 */
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
 *  14MB 读回在专用 QOS_UTILITY 队列执行，渲染线程只做零拷贝登记。
 * ============================================================ */
%hook CAMetalLayer

/* Logos 的 %init 会为这里声明的方法生成注册代码，所以方法体必须在；
   否则 #if 摘掉整个方法时注册表仍引用它 → undefined-internal。
   诊断版（JJ_DISABLE_METAL_HOOK=1）直接 return %orig：hook 照常注册，
   但不登记 surface、不读 IOSurface、不碰任何 Metal 对象。 */
- (id<CAMetalDrawable>)nextDrawable {
#if JJ_DISABLE_METAL_HOOK
    return %orig;
#else
    JJMetalBeforeNextDrawable();
    id<CAMetalDrawable> drawable = %orig;
    JJMetalAfterNextDrawable(drawable);
    return drawable;
#endif
}

%end

/* ============================================================
 *  入口
 * ============================================================ */
%ctor {
    /* 两个未分组 hook 一次注册完。Logos 只解析类名，
       比手写 method_setImplementation + 全类表遍历轻得多。 */
    %init;

    NSLog(@"[JJCheat] tweak 已加载 (pid=%d, 2.1.0 pikafish)", getpid());

    /* 诊断日志：只报事实，不做分支。
       EAGLContext 一定存在、presentRenderbuffer: 一定有实现，
       真正决定抓帧走哪条路的是「游戏到底调不调这个 selector」——
       那个只有跑起来才知道，所以不在这里猜。 */
    Class eagl = NSClassFromString(@"EAGLContext");
    NSLog(@"[JJCheat] EAGLContext=%@ presentRenderbuffer:=%@ metalHook=%@",
          eagl ? @"有" : @"没有",
          (eagl && [eagl instancesRespondToSelector:@selector(presentRenderbuffer:)]) ? @"有" : @"没有",
          JJMetalCaptureEnabled() ? @"开" : @"关");

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

    /* 冷启动慢时兜底拉起控制器 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JJStartOnce();
    });
}
