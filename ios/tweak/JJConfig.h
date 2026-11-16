#ifndef JJConfig_h
#define JJConfig_h

/* ============================================================
 *  JJCheat 运行配置
 * ============================================================ */

/* 每步搜索思考时长（毫秒）。越大越强，越费电。
   1.1.42 起改为运行时可在悬浮球菜单里修改（不再编译期写死）。
   默认 200ms：真机实测 350ms 在识别未收敛时会让 JS 队列长期满载。 */
#define JJ_THINK_MS_DEFAULT     200
#define JJ_THINK_MS_MIN         50
#define JJ_THINK_MS_MAX         3000

/* 抓帧频率（每秒）。每帧都要跑 90 格采样 + 86 模板比对 + 浮窗扫描，
   8 fps 时 JS 线程几乎没空闲；4 fps 仍远快于落子动画（~200ms）。 */
#define JJ_SCAN_FPS             4

/* process 调用节流（秒）。一次 process 在真机上要数秒，回调刚落地就立刻
   发下一帧会让引擎队列永不清空；识别未收敛时再退避更久，避免空转烧 CPU。 */
#define JJ_PROCESS_MIN_GAP      0.8
#define JJ_PROCESS_ILLEGAL_GAP  2.5
/* 锚定状态机判定为噪声帧（anchorRejected）时的退避：JS 已命中结论缓存，
   再跑一轮 90 格模板匹配纯属白烧 CPU；与 Metal 抓帧 1.5s 间隔对齐。 */
#define JJ_PROCESS_NOISE_GAP    1.5
#define JJ_LEARN_RETRY_GAP      3.0
/* 学习连续失败上限：超过就停下来提示用户切回开局画面，不再无限重试 */
#define JJ_LEARN_MAX_FAIL       6

/* 连续多少帧识别一致才认为局面稳定（防手抖/动画中间帧） */
#define JJ_STABLE_FRAMES        2

/* 顶部信息条高度（point） */
#define JJ_HUD_TOP_HEIGHT       54.0

/* 箭头线宽（point） */
#define JJ_ARROW_WIDTH          7.0

/* 建议走法箭头颜色 */
#define JJ_COLOR_ARROW          [UIColor colorWithRed:1.00 green:0.20 blue:0.20 alpha:0.92]
#define JJ_COLOR_ARROW_HEAD     [UIColor colorWithRed:1.00 green:0.15 blue:0.15 alpha:0.98]
#define JJ_COLOR_BOARD_LINE     [UIColor colorWithRed:1.00 green:0.35 blue:0.35 alpha:0.55]
#define JJ_COLOR_PANEL_BG       [UIColor colorWithRed:0.04 green:0.05 blue:0.08 alpha:0.86]
#define JJ_COLOR_TEXT_MAIN      [UIColor colorWithRed:1.00 green:0.95 blue:0.55 alpha:1.0]
#define JJ_COLOR_TEXT_SUB       [UIColor colorWithRed:0.72 green:0.86 blue:1.00 alpha:1.0]

/* 引擎脚本安装路径（Theos layout 会放到这里） */
#define JJ_ENGINE_PATH          @"/Library/Application Support/JJCheat/engine.js"
#define JJ_ENGINE_PATH_ROOTLESS @"/var/jb/Library/Application Support/JJCheat/engine.js"

/* 配置持久化 key */
#define JJ_KEY_CORNERS          @"JJCheat.corners"
#define JJ_KEY_ENABLED          @"JJCheat.enabled"
#define JJ_KEY_CALIBRATED       @"JJCheat.calibrated"
#define JJ_KEY_HUD_VISIBLE      @"JJCheat.hudVisible"
#define JJ_KEY_THINK_MS         @"JJCheat.thinkMs"

/* 插件图标：随 deb 落到 jbroot 下，悬浮球优先用它，读不到回退文字「象棋」 */
#define JJ_LOGO_REL_PATH        @"Library/Application Support/JJCheat/logo.png"

#endif /* JJConfig_h */
