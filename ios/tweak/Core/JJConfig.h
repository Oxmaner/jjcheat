#ifndef JJConfig_h
#define JJConfig_h

/* ============================================================
 *  JJCheat 运行配置
 * ============================================================ */

/* 每步搜索思考时长（毫秒）。越大越强，越费电。
   1.1.42 起可在悬浮球菜单里改（不再编译期写死）。
   2.1.0 换成独立进程 Pikafish 后默认 800ms：48MB 的 NNUE 大网络，
   旧 JS 时代的 200ms 连置换表都填不满，纯属白瞎这颗引擎。
   下限 100ms（再短不如直接看棋谱），上限 3000ms（手机发烫的临界）。 */
#define JJ_THINK_MS_DEFAULT     800
#define JJ_THINK_MS_MIN         100
#define JJ_THINK_MS_MAX         3000

/* 2.0.0：tick 只做「帧序号 + 稀疏指纹」两件极轻的检查，真正重活由新帧触发。
   2Hz 足够跟上落子动画（~200ms），也把主线程定时器唤醒次数减半。 */
#define JJ_SCAN_FPS             2

/* 帧保鲜：Metal 帧超过这个秒数就不能再喂给 JS。
   16:00 真机日志里 1.1.44 的 s_lastGoodMetal 无时间戳、永久复用同一张旧图，
   导致 12 分钟里真实画面再没进过识别；这个上限就是那类静默死锁的硬闸门。 */
#define JJ_FRAME_MAX_AGE        4.0

/* Metal 读帧间隔（秒）：在专用低优先级队列里执行，不占游戏渲染调用栈。
   与上层是否处理解耦，避免 1.1.44「上层一退避就再也不读新帧」的死锁。 */
#define JJ_METAL_READ_INTERVAL  1.5

/* 画面指纹阈值：90 个交叉点 × 3 通道的累计绝对差低于此值就认为「画面没变」，
   整轮跳过 JS 识别与引擎搜索（静态局面零开销，根治间歇性卡顿）。
   取偏低值：误触发只是多跑一次识别，漏检会直接导致「对方走完不给提示」。 */
#define JJ_FRAME_DIFF_THRESHOLD 260

/* process 调用节流（秒）。2.0 起帧序号 + 指纹已经保证不重复喂同一帧，
   这里只留一道很小的保险，防止回调刚落地又立刻发下一轮。 */
#define JJ_PROCESS_MIN_GAP      0.2
/* 盘面彻底不可信（JS 明确 skipAnalyze）时才退避，正常噪声帧不再退避：
   噪声帧由 JS 侧锚盘覆盖并命中结论缓存，退避只会拖慢真实走子的响应。 */
#define JJ_PROCESS_ILLEGAL_GAP  2.5
#define JJ_LEARN_RETRY_GAP      3.0
/* 学习连续失败上限：超过就停下来提示用户切回开局画面，不再无限重试 */
#define JJ_LEARN_MAX_FAIL       6
/* 学习校验允许的最大错格数，必须与 engine.js 里 learnBoard 的 ok 判据一致。
   2.0.1：重标定只有 verifyDiff <= 这个值才算成功，中局画面（真机 18~50）
   一律拒绝，避免把已收敛的锚盘冲成乱码。 */
#define JJ_LEARN_MAX_DIFF       8
/* 重标定失败几次后回滚到上一次成功标定 */
#define JJ_CALIB_ROLLBACK_FAILS 2
/* 低频心跳日志间隔（秒）：静态局面被帧差短路时也要留痕，
   否则日志里几十分钟空白，无法判断 JS 到底有没有在跑。 */
#define JJ_HEARTBEAT_GAP        30.0

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
/* 思考时间的一次性迁移标记：2.0.x 存下来的 200ms 是给 JS 引擎调的值，
   对 Pikafish 太短，首次启动时抬到新默认值，只做一次。 */
#define JJ_KEY_THINK_MS_V2      @"JJCheat.thinkMsV2"

/* 插件图标：随 deb 落到 jbroot 下，悬浮球优先用它，读不到回退文字「象棋」 */
#define JJ_LOGO_REL_PATH        @"Library/Application Support/JJCheat/logo.png"

/* ============================================================
 *  2.1.52 Pikafish 进程内引擎
 * ============================================================ */
/* deb 内资源目录（相对 jbroot）。2.1.52 起这里只有一个文件：权重。
   可执行文件已经编进 JJCheat.dylib（engine/build-ios.sh 产出 libpikafish.a），
   不再随包分发，也不再需要任何 exec 权限。 */
#define JJ_PIKA_DIR_REL         @"Library/Application Support/JJCheat/Pikafish"
/* NNUE 权重文件名。必须与 Pikafish 的 EvalFileDefaultName 一致：
   引擎会在 argv[0] 所在目录按这个名字找。 */
#define JJ_PIKA_NET_NAME        @"pikafish.nnue"
/* 哈希表 MB。手机别给太大：64MB 进程内内存，与游戏共用地址空间但独立分配 */
#define JJ_PIKA_HASH_MB         64
/* 引擎状态小圆点刷新间隔（秒） */
#define JJ_ENGINE_DOT_GAP       2.0

#endif /* JJConfig_h */
