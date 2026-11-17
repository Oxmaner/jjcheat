//
//  JJCopy.h
//  JJCheat —— 对外文案（2.1.79 新增，带版本号）
//
//  【为什么单独一个文件】
//  本项目没有 LLM 解说层，所有文字都是规则生成的固定文案。以前它们散落在
//  JJHUDWindow / JJBallWindow / JJGameController 里，同一个意思写了两三遍
//  （比如「请先开启插件」4 处、「请先关闭当前弹窗」3 处），改一处漏一处。
//  现在集中在这里，用 JJ_COPY_VERSION 标记版本，便于对照日志与回滚。
//
//  【约定】
//  1. 只放「会显示给用户」的短句。日志（NSLog）里的技术描述不进来 ——
//     那些是给开发者看的，跟着代码走更合适。
//  2. 一句一个常量，禁止拼接长句（拼接会让翻译/改写变难）。
//  3. 新增文案加常量即可，不改任何流程代码。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** 文案版本。改了任何一条对外文案就 +1，日志里会打出来，便于确认装的是哪版。 */
#define JJ_COPY_VERSION  @"2.1.80-c1"

/* ---- 通用状态词 ---- */
extern NSString *const JJCopyOn;                    // 开
extern NSString *const JJCopyOff;                   // 关

/* ---- 前置条件 / 阻塞提示 ---- */
extern NSString *const JJCopyNeedPluginOn;          // 请先开启插件
extern NSString *const JJCopyCloseDialogFirst;      // 请先关闭当前弹窗

/* ---- 引擎状态 ---- */
extern NSString *const JJCopyEngineThinking;        // 思考中
extern NSString *const JJCopyEngineNetNotReady;     // 引擎网络未就绪
extern NSString *const JJCopyEngineUnavailable;     // 引擎不可用

/* ---- 识别状态 ---- */
extern NSString *const JJCopyRecogPendingKing;      // 识别待确认 · 王将不唯一
extern NSString *const JJCopyRecogPendingLowConf;   // 识别待确认 · 画面不清

/* ---- 标定 ---- */
extern NSString *const JJCopyCalibAutoRunning;      // 自动标定中 · 请停在开局棋盘画面
extern NSString *const JJCopyCalibTapFourCorners;   // 点棋盘四个角：左上→右上→右下→左下
extern NSString *const JJCopyCalibDone;             // 标定完成 · 请进入一局新棋
extern NSString *const JJCopyCalibInvalidRestored;  // 四角无效 · 已恢复上次标定
extern NSString *const JJCopyResetDone;             // 已重置 · 请停在开局棋盘画面

/* ---- 二级菜单（2.1.80） ---- */
extern NSString *const JJCopySheetThinkTitle;       // 思考时间
extern NSString *const JJCopySheetEngineTitle;      // 引擎参数
extern NSString *const JJCopySheetThreadsTitle;     // 改线程数？
extern NSString *const JJCopySheetDone;             // 完成
extern NSString *const JJCopySheetCancel;           // 取消

/** 拼「某状态 · 值」这种最常见的组合（如「思考 650ms」）。 */
NSString *JJCopyWithValue(NSString *title, NSString *value);

/** 启动时打一条版本日志，便于从 syslog 判断文案版本 */
void JJCopyLogVersion(void);

NS_ASSUME_NONNULL_END
