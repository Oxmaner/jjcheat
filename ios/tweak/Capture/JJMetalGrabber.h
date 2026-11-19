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
#import <CoreFoundation/CFBase.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 取最新一帧 RGBA；调用即视为已消费，允许读帧队列再取一张。
    2.0.0：这里不再按时间判过期（1.1.44 的 5s 过期与上层退避叠加，
    导致 frame=0 B 却永久复用旧帧）。新鲜度由 JJMetalFrameIsFresh 单独判断，
    上层只在序号变化且帧确实新鲜时才喂给 JS。 */
NSData *JJMetalFrameCopy(int *outW, int *outH);

/** 当前缓存帧是否在 JJ_FRAME_MAX_AGE 内；过期帧一律不许进入识别链路 */
BOOL JJMetalFrameIsFresh(void);

/** 当前缓存帧的年龄（秒），用于诊断日志 */
CFTimeInterval JJMetalFrameAge(void);

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

/** 抓帧开关当前是否打开。JJScreenGrabber 据此判断「Metal 已接管」：
    即使第一帧还没读回来，也绝不回退 CARenderServer / CALayer 全黑重活
    （16:39 真机日志：启动首帧 CALayer 全黑 → 第一次学习 verifyDiff=32）。 */
BOOL JJMetalCaptureEnabled(void);

/** 2.1.77：告诉抓帧层「棋盘四角在哪」（4 个 [x,y]，帧像素坐标）。
 *
 *  给了之后抓帧从「定时拷贝 14MB」改成「先廉价采样 90 点判有无变化，
 *  变了才拷」—— 对方落子到我们发现的延迟从 1.5 秒降到约 0.15 秒，
 *  而 14MB 拷贝次数反而从每秒 0.67 次降到「每步 1 次」。
 *
 *  为什么必须限定在棋盘内采样：整屏采样会被倒计时、动画、提示高亮带偏，
 *  每一帧都判「变了」就退化成旧的定时拷贝。
 *  传 nil / 非 4 点 → 自动退回旧的定时拷贝（未标定阶段需要这个兜底）。
 *  角点变化会让旧摘要失效，强制重新出一帧。 */
void JJMetalSetBoardCorners(NSArray *corners);

/** 2.0.0r9 抓帧分档：调整「摘要轮询」间隔（秒）。
    等对方走子时调宽（0.35），轮到我方调窄（0.15），
    目的是在对手落子动画期间少做几次 14MB 拷贝 + JS 识别。 */
void JJMetalSetPeekInterval(double seconds);

#ifdef __cplusplus
}
#endif
