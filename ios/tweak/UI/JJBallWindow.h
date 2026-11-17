//
//  JJBallWindow.h
//  JJCheat —— 悬浮球 + 设置菜单
//
//  只做 UI：球的显示/拖动/点击、菜单弹出、引擎状态小圆点。
//  业务动作全部通过 block 回调给 JJGameController。
//
//  2.1.78 菜单重做：3×2 图标网格 + 毛玻璃 + 全透明遮罩（不压暗画面），
//  并把 hitTest 从「除球外全拦」改成白名单放行，修掉弹窗点不动的老 bug。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/** 一个菜单项的描述。用结构化数据而不是纯标题串：
 *  菜单要从「文字列表」变成「图标网格」，且需要表达开/关状态。 */
@interface JJMenuEntry : NSObject
/** 短标签，2~4 个汉字，网格里一行放得下 */
@property (nonatomic, copy) NSString *title;
/** SF Symbols 名称（iOS 13+）。为空则只显示文字 */
@property (nonatomic, copy, nullable) NSString *symbol;
/** 右侧状态文字，如「开」「650ms」「就绪」。空则不显示 */
@property (nonatomic, copy, nullable) NSString *value;
/** YES = 处于开启状态，图标与状态文字用主色高亮 */
@property (nonatomic, assign) BOOL on;
/** YES = 危险/异常状态（如引擎不可用），图标用警示色 */
@property (nonatomic, assign) BOOL warn;

/** 2.1.80：动作标识（由调用方定义，如 JJMenuActionHUD）。
 *
 *  【为什么必须有】以前回调传的是「数组下标」，菜单顺序一改就错位：
 *  2.1.78 把「重置开局」插到「HUD」前面后，点 HUD 实际执行了重置开局、
 *  点重置开局反而切 HUD —— 这正是「HUD 开关不起作用」的根因。
 *  现在每项自带 action，顺序怎么排都不会错。
 *  未设置（0）时回退为位置下标，兼容旧调用。 */
@property (nonatomic, assign) NSInteger action;

+ (instancetype)title:(NSString *)title symbol:(nullable NSString *)symbol;
@end

@interface JJBallWindow : UIWindow

@property (nonatomic, copy, nullable) void (^onTap)(void);
@property (nonatomic, copy, nullable) void (^onLongPress)(void);
/** 菜单项点击（下标对应 showMenuWithEntries: 的顺序） */
@property (nonatomic, copy, nullable) void (^onMenuItem)(NSInteger index);
@property (nonatomic, readonly) BOOL menuVisible;

- (void)attach;
/** 未激活：半透明「点我」；激活：实心「象棋」/logo */
- (void)setActive:(BOOL)active;

/** 引擎状态小圆点：绿=就绪 黄=启动/思考 红=不可用 nil=隐藏 */
- (void)setEngineDotColor:(nullable UIColor *)color;

/** 2.1.78：结构化菜单项。旧的 showMenuWithTitles: 仍保留（内部转成纯文字项）。 */
/** 2.1.78：轻量提示条（贴在球下方，2.2 秒自动消失）。
 *  为什么需要：很多操作原先只往 HUD 写一行状态，HUD 关掉时用户点完菜单
 *  **完全看不到任何回应**，体感就是「这个功能是坏的」。toast 不依赖 HUD。 */
- (void)toast:(NSString *)text;

- (void)showMenuWithEntries:(NSArray<JJMenuEntry *> *)entries;
- (void)showMenuWithTitles:(NSArray<NSString *> *)titles;
- (void)hideMenu;

/* ---- 2.1.80：二级面板（与一级菜单同一套 JJMenuStyle 视觉规范） ---- */

/** 显示二级面板（会先收起一级菜单）。面板贴在球同侧，空间不够则翻到另一侧。 */
- (void)showSheet:(UIView *)sheet;
/** 收起二级面板 */
- (void)dismissSheet;
@property (nonatomic, readonly) BOOL sheetVisible;

@end

NS_ASSUME_NONNULL_END
