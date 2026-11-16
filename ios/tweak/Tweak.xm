//
//  Tweak.xm
//  JJCheat —— 注入 JJ象棋 进程，抓画面、算棋、在棋盘上标注
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/QuartzCore.h>

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
 *  兜底：如果 3 秒内没触发（APP 冷启动慢），用 didFinishLaunching 补一次
 * ============================================================ */
%hook UIApplication

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL r = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JJStartOnce();
    });
    return r;
}

%end

/* ============================================================
 *  从后台恢复时把 HUD 窗口重新挂到前台 scene 上
 * ============================================================ */

/* ============================================================
 *  入口
 * ============================================================ */
%ctor {
    %init;

    NSLog(@"[JJCheat] tweak 已加载 (pid=%d)", getpid());

    Class eagl = NSClassFromString(@"EAGLContext");
    BOOL hasPresent = eagl && [eagl instancesRespondToSelector:@selector(presentRenderbuffer:)];
    NSLog(@"[JJCheat] EAGLContext=%p presentRenderbuffer:=%@", eagl, hasPresent ? @"有" : @"没有");
    if (!hasPresent) {
        NSLog(@"[JJCheat] 警告：拿不到 GL hook 点，抓帧将退化为 CARenderServer/CALayer，可能全黑");
    }

    /* Metal 抓帧放到主线程延迟装：%ctor 阶段遍历全类表太重，容易把启动拖死 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            JJMetalInstallHooks();
        } @catch (NSException *e) {
            NSLog(@"[JJCheat] Metal hook 调用异常: %@", e);
        }
    });

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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JJStartOnce();
    });
}
