//
//  JJMenuStyle.h
//  JJCheat —— 菜单统一视觉规范（2.1.80 新增）
//
//  【为什么抽出来】
//  一级菜单（悬浮球网格）与二级菜单（参数面板）原本各写一套颜色/字号/圆角：
//  一级在 JJBallWindow.m 里用一堆 #define 宏，二级干脆是系统 UIAlertController
//  （浅色卡片 + 蓝字），跟主界面完全不像一个软件。
//  这里把「视觉令牌」集中一处，两级菜单都从这里取，新增二级面板时不用再抄一遍。
//
//  【规范摘要】
//    面板   深色毛玻璃（UltraThin）+ 18pt 圆角 + 0.5pt 白 14% 描边
//    单元   白 4% 底 / 选中时白 10% 底 + 青绿描边 12pt 圆角
//    文字   主文字 白92% / 次文字 白62% / 强调青绿 / 危险橙红
//    动效   缩放 0.94 → 1.0 + 淡入，0.16s
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/* ---- 颜色 ---- */
/** 强调 / 激活 / 正常 */
UIColor *JJMenuAccentColor(void);
/** 危险 / 异常 */
UIColor *JJMenuWarnColor(void);
/** 主文字 */
UIColor *JJMenuTextColor(void);
/** 次文字（说明、值） */
UIColor *JJMenuSubTextColor(void);
/** 面板描边 */
UIColor *JJMenuBorderColor(void);
/** 面板底色（盖在毛玻璃之上，保证文字对比度） */
UIColor *JJMenuPanelColor(void);
/** 单元常态底 / 选中底 */
UIColor *JJMenuCellColor(BOOL on);
/** 分隔线颜色 */
UIColor *JJMenuSeparatorColor(void);

/* ---- 尺寸 ---- */
extern const CGFloat JJMenuPanelRadius;      // 18
extern const CGFloat JJMenuCellRadius;       // 12
extern const CGFloat JJMenuSheetPad;         // 14
extern const CGFloat JJMenuSheetRowH;        // 42（11 行的参数面板也不会占满屏）
extern const CGFloat JJMenuSheetMaxW;        // 300
extern const CGFloat JJMenuAnimDuration;     // 0.16

/* ---- 字体 ---- */
UIFont *JJMenuCellLabelFont(BOOL on);        // 一级网格标签 11.5
UIFont *JJMenuSheetTitleFont(void);          // 二级标题 14.5
UIFont *JJMenuSheetSubFont(void);            // 二级副标题 / 说明 11.5
UIFont *JJMenuSheetRowFont(void);            // 二级行主文字 13.5
UIFont *JJMenuSheetValueFont(void);          // 二级行右侧值 12.5

/* ---- 组件 ---- */
/** 深色毛玻璃；iOS 13+ 用 SystemUltraThinMaterialDark，越薄越透，底下的棋盘仍可辨 */
UIVisualEffect *JJMenuBlurEffect(void);

/** 给视图套上「面板」外观：圆角 + 描边 + 裁剪 + 毛玻璃底层 */
void JJMenuApplyPanelStyle(UIView *view);

/** 给视图套上「单元」外观：圆角 + 底色 + 描边（一级网格与二级行共用） */
void JJMenuApplyCellStyle(UIView *view, BOOL on, BOOL warn);

/** 面板出现动效：0.94 缩放 + 淡入 → 复原 */
void JJMenuAnimateIn(UIView *view);

NS_ASSUME_NONNULL_END
