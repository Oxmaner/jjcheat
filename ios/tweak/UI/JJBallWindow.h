//
//  JJBallWindow.h
//  JJCheat —— 悬浮球 + 设置菜单（2.1.0 从 JJController 拆出）
//
//  只做 UI：球的显示/拖动/点击、菜单弹出、引擎状态小圆点。
//  业务动作全部通过 block 回调给 JJGameController。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JJBallWindow : UIWindow

@property (nonatomic, copy, nullable) void (^onTap)(void);
@property (nonatomic, copy, nullable) void (^onLongPress)(void);
/** 菜单项点击（下标对应 showMenuWithTitles: 的顺序） */
@property (nonatomic, copy, nullable) void (^onMenuItem)(NSInteger index);
@property (nonatomic, readonly) BOOL menuVisible;

- (void)attach;
/** 未激活：半透明「点我」；激活：实心「象棋」/logo */
- (void)setActive:(BOOL)active;

/** 引擎状态小圆点：绿=就绪 黄=启动/思考 红=不可用 nil=隐藏 */
- (void)setEngineDotColor:(nullable UIColor *)color;

- (void)showMenuWithTitles:(NSArray<NSString *> *)titles;
- (void)hideMenu;

@end

NS_ASSUME_NONNULL_END
