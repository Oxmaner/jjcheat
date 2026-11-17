//
//  JJMenuStyle.m
//  JJCheat —— 菜单统一视觉规范
//

#import "JJMenuStyle.h"

const CGFloat JJMenuPanelRadius  = 18.0;
const CGFloat JJMenuCellRadius   = 12.0;
const CGFloat JJMenuSheetPad     = 14.0;
const CGFloat JJMenuSheetRowH    = 42.0;
const CGFloat JJMenuSheetMaxW    = 300.0;
const CGFloat JJMenuAnimDuration = 0.16;

UIColor *JJMenuAccentColor(void) {
    return [UIColor colorWithRed:0.25 green:0.85 blue:0.63 alpha:1.0];
}

UIColor *JJMenuWarnColor(void) {
    return [UIColor colorWithRed:1.00 green:0.42 blue:0.34 alpha:1.0];
}

UIColor *JJMenuTextColor(void) {
    return [UIColor colorWithWhite:0.92 alpha:1.0];
}

UIColor *JJMenuSubTextColor(void) {
    return [UIColor colorWithWhite:0.62 alpha:1.0];
}

UIColor *JJMenuBorderColor(void) {
    return [UIColor colorWithWhite:1 alpha:0.14];
}

UIColor *JJMenuPanelColor(void) {
    /* 底层只留一点深色保证文字对比度；真正的观感交给毛玻璃。
       用 UltraThin 而不是 Thin/Regular：棋盘是暖色木纹，材质越薄越透，
       底下的棋子才看得出来 —— 这是「不遮挡视线」的核心。 */
    return [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:0.30];
}

UIColor *JJMenuCellColor(BOOL on) {
    return [UIColor colorWithWhite:1 alpha:(on ? 0.10 : 0.04)];
}

UIColor *JJMenuSeparatorColor(void) {
    return [UIColor colorWithWhite:1 alpha:0.10];
}

UIFont *JJMenuCellLabelFont(BOOL on) {
    return [UIFont systemFontOfSize:11.5
                             weight:(on ? UIFontWeightSemibold : UIFontWeightRegular)];
}

UIFont *JJMenuSheetTitleFont(void) {
    return [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
}

UIFont *JJMenuSheetSubFont(void) {
    return [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
}

UIFont *JJMenuSheetRowFont(void) {
    return [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
}

UIFont *JJMenuSheetValueFont(void) {
    return [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium];
}

UIVisualEffect *JJMenuBlurEffect(void) {
    if (@available(iOS 13.0, *))
        return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

void JJMenuApplyPanelStyle(UIView *view) {
    if (!view) return;
    view.layer.cornerRadius = JJMenuPanelRadius;
    view.layer.borderWidth = 0.5;
    view.layer.borderColor = JJMenuBorderColor().CGColor;
    view.clipsToBounds = YES;
    view.backgroundColor = JJMenuPanelColor();

    /* 毛玻璃放在最底层，不参与交互（否则会挡住单元的点击） */
    UIVisualEffect *eff = JJMenuBlurEffect();
    if (eff) {
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:eff];
        blur.userInteractionEnabled = NO;
        blur.frame = view.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view insertSubview:blur atIndex:0];
    }
}

void JJMenuApplyCellStyle(UIView *view, BOOL on, BOOL warn) {
    if (!view) return;
    view.layer.cornerRadius = JJMenuCellRadius;
    view.layer.borderWidth = 0.5;
    UIColor *stroke = warn ? JJMenuWarnColor()
                           : (on ? [JJMenuAccentColor() colorWithAlphaComponent:0.55]
                                 : [UIColor colorWithWhite:1 alpha:0.08]);
    view.layer.borderColor = stroke.CGColor;
    view.backgroundColor = JJMenuCellColor(on);
}

void JJMenuAnimateIn(UIView *view) {
    if (!view) return;
    view.alpha = 0.0;
    view.transform = CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:JJMenuAnimDuration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        view.alpha = 1.0;
        view.transform = CGAffineTransformIdentity;
    } completion:nil];
}
