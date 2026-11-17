//
//  JJMenuSheet.h
//  JJCheat —— 二级菜单面板（2.1.80 新增）
//
//  【为什么不用 UIAlertController】
//  系统弹窗是浅色卡片 + 蓝字 + 系统字体，与一级菜单（深色毛玻璃网格）完全两种观感；
//  而且带键盘的 Alert 会把棋盘整个盖住。这里用一个自绘面板，直接复用
//  JJMenuStyle 的令牌，保证两级菜单是一个软件。
//
//  【层级不变】仍是一级点进去 → 二级面板；面板内点行可以再开一个二级（如线程数确认），
//  返回即回到上一层。功能与取值范围与原来完全一致。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JJSheetRowKind) {
    JJSheetRowKindInfo = 0,   // 只读说明（居中/次文字，不可点）
    JJSheetRowKindAction,     // 可点行：左侧图标+标题，右侧值/勾
    JJSheetRowKindStepper,    // 数值行：− [值] ＋
    JJSheetRowKindDanger,     // 危险动作：橙红文字
};

@interface JJSheetRow : NSObject

@property (nonatomic, assign) JJSheetRowKind kind;
@property (nonatomic, copy) NSString *title;
/** 右侧值文字（stepper 的当前值、action 的状态） */
@property (nonatomic, copy, nullable) NSString *detail;
/** SF Symbols 名称 */
@property (nonatomic, copy, nullable) NSString *symbol;
/** 选中态（打勾 + 青绿） */
@property (nonatomic, assign) BOOL on;
@property (nonatomic, assign) BOOL enabled;
/** action / danger 点击回调 */
@property (nonatomic, copy, nullable) void (^handler)(void);
/** stepper 步进回调：+1 / -1（调用方自己换算成实际步长并更新 detail） */
@property (nonatomic, copy, nullable) void (^stepper)(NSInteger delta);

+ (instancetype)info:(NSString *)text;

+ (instancetype)action:(NSString *)title
                symbol:(nullable NSString *)symbol
                detail:(nullable NSString *)detail
               handler:(void (^)(void))handler;

+ (instancetype)stepper:(NSString *)title
                 symbol:(nullable NSString *)symbol
                  value:(NSString *)value
               onChange:(void (^)(NSInteger delta))onChange;

+ (instancetype)danger:(NSString *)title
                symbol:(nullable NSString *)symbol
               handler:(void (^)(void))handler;

@end

@interface JJMenuSheet : UIView

/** 右上角关闭 / 点遮罩关闭时回调（调用方负责从窗口移除） */
@property (nonatomic, copy, nullable) void (^onDismiss)(void);

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(nullable NSString *)subtitle
                         rows:(NSArray<JJSheetRow *> *)rows;

/** 行内容（值、勾选态）变了之后调用，只刷新文字不重建视图，避免闪烁 */
- (void)refreshValues;

/** 更新副标题（通常放「引擎参数摘要」，改完参数要跟着变）。
 *  只有创建时带了副标题才生效 —— 面板高度已按有无副标题算好，动态加会溢出。 */
- (void)refreshSubtitle:(NSString *)text;

/** 给定宽度下的理想高度（调用方决定宽度，通常是 JJMenuSheetMaxW 与屏幕取小） */
+ (CGFloat)heightForWidth:(CGFloat)width rows:(NSArray<JJSheetRow *> *)rows hasSubtitle:(BOOL)hasSub;

@end

NS_ASSUME_NONNULL_END
