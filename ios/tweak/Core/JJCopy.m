//
//  JJCopy.m
//  JJCheat —— 对外文案
//

#import "JJCopy.h"

NSString *const JJCopyOn  = @"开";
NSString *const JJCopyOff = @"关";

NSString *const JJCopyNeedPluginOn     = @"请先开启插件";
NSString *const JJCopyCloseDialogFirst = @"请先关闭当前弹窗";

NSString *const JJCopyEngineThinking    = @"思考中";
NSString *const JJCopyEngineNetNotReady = @"引擎网络未就绪";
NSString *const JJCopyEngineUnavailable = @"引擎不可用";

NSString *const JJCopyRecogPendingKing    = @"识别待确认 · 王将不唯一";
NSString *const JJCopyRecogPendingLowConf = @"识别待确认 · 画面不清";

NSString *const JJCopyCalibAutoRunning     = @"自动标定中 · 请停在开局棋盘画面";
NSString *const JJCopyCalibTapFourCorners  = @"点棋盘四个角：左上→右上→右下→左下";
NSString *const JJCopyCalibDone            = @"标定完成 · 请进入一局新棋";
NSString *const JJCopyCalibInvalidRestored = @"四角无效 · 已恢复上次标定";
NSString *const JJCopyResetDone            = @"已重置 · 请停在开局棋盘画面";

NSString *const JJCopySheetThinkTitle   = @"思考时间";
NSString *const JJCopySheetEngineTitle  = @"引擎参数";
NSString *const JJCopySheetThreadsTitle = @"改线程数？";
NSString *const JJCopySheetDone         = @"完成";
NSString *const JJCopySheetCancel       = @"取消";

NSString *JJCopyWithValue(NSString *title, NSString *value) {
    if (!title) return value ?: @"";
    if (!value.length) return title;
    return [NSString stringWithFormat:@"%@ %@", title, value];
}

void JJCopyLogVersion(void) {
    NSLog(@"[JJCheat] 文案版本 %@", JJ_COPY_VERSION);
}
