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
/* 2.1.76：800 → 650。800ms 满载搜索与游戏渲染抢核，落子后有明显掉帧；
   650ms 在象棋上强度几乎无感差异，但单步占用 CPU 少两成。 */
#define JJ_THINK_MS_DEFAULT     650
#define JJ_THINK_MS_MIN         100
#define JJ_THINK_MS_MAX         3000

/* tick 只做「帧序号 + 稀疏指纹」两件极轻的检查，真正重活由新帧触发。
   2.1.77：2 → 4Hz。摘要层已经能 0.15 秒发现变化，但 tick 是唯一的消费入口，
   2Hz 的 500ms 会把它吃掉一半收益；tick 本身只读一个序号，代价可以忽略。 */
#define JJ_SCAN_FPS             4

/* 帧保鲜：Metal 帧超过这个秒数就不能再喂给 JS。
   16:00 真机日志里 1.1.44 的 s_lastGoodMetal 无时间戳、永久复用同一张旧图，
   导致 12 分钟里真实画面再没进过识别；这个上限就是那类静默死锁的硬闸门。 */
#define JJ_FRAME_MAX_AGE        4.0

/* Metal 读帧间隔（秒）：在专用低优先级队列里执行，不占游戏渲染调用栈。
   与上层是否处理解耦，避免 1.1.44「上层一退避就再也不读新帧」的死锁。
   2.1.77：这个值是「未标定阶段」的兜底间隔。标定完成后改用下面的
   JJ_METAL_PEEK_INTERVAL（摘要轮询），不再受这里限制。 */
#define JJ_METAL_READ_INTERVAL  1.5

/* ---- 2.1.77 摘要轮询（变化驱动抓帧） ----
   为什么加：旧逻辑每 1.5 秒无条件拷 14MB 出一帧，这 1.5 秒就是「对方走完到
   我们看见」的固定延迟下界（用户感知「有点滞后」），而每帧 14MB 分配 + memcpy
   + BGRA→RGBA 逐字交换的代价并不小。
   新逻辑：每 0.15 秒只锁 surface 采 90 个棋盘点算摘要（约 810 像素，微秒级），
   摘要没变就整帧丢掉；变了才拷 14MB。延迟降到约 0.15 秒，拷贝次数反而下降。
   采样必须限定棋盘内 —— 整屏采样会被倒计时/落子动画/提示高亮带偏，等于白改。 */
#define JJ_METAL_PEEK_INTERVAL  0.15
/* 2.0.0r9 抓帧分档：等对方走子时用宽档（对手落子动画期间少拷 14MB），
   轮到我方用窄档保证建议出得够快。 */
#define JJ_PEEK_WAIT_OPPONENT   0.35
#define JJ_PEEK_OUR_TURN        0.15
/* 单点差值达到这个值算「这一格明显变了」（B/G/R 三通道差值之和，0~765）。
   取 40：一个棋子出现/消失通常 60~200；木色棋盘轻微亮度漂移只有 2~6。 */
#define JJ_PEEK_POINT_DELTA     40
/* 单点剧变阈值：一个点就变了这么多（强信号，单独也算变化，兜住「只动一格」的边角情况） */
#define JJ_PEEK_POINT_STRONG    90
/* 心跳：画面真的长时间静止也要隔这么久出一帧，否则上层认为没有可用帧。
   必须小于 JJ_FRAME_MAX_AGE（4.0）。 */
#define JJ_PEEK_HEARTBEAT       3.0

/* 画面指纹阈值：90 个交叉点 × 3 通道的累计绝对差低于此值就认为「画面没变」，
   整轮跳过 JS 识别与引擎搜索（静态局面零开销，根治间歇性卡顿）。
   取偏低值：误触发只是多跑一次识别，漏检会直接导致「对方走完不给提示」。 */
#define JJ_FRAME_DIFF_THRESHOLD 260
/* 2.1.77：单点跳变阈值（B+G+R 三通道差值之和）。
   累加差会被 270 个值的基数稀释：低对比度的子移动每点只差 30 左右，
   累加约 180 < 260 就被判「画面没变」而整轮跳过。
   单点差不会被稀释 —— 任一格跳变 45 以上就认为画面确实变了。 */
#define JJ_FP_POINT_DELTA       45

/* process 调用节流（秒）。2.0 起帧序号 + 指纹已经保证不重复喂同一帧，
   这里只留一道很小的保险，防止回调刚落地又立刻发下一轮。
   2.1.76 卡顿优化：0.2 → 0.35。每轮 process 要 memcpy 14MB 进 JS 再跑全盘
   模板匹配，5 次/秒在 iOS 上和游戏抢 CPU；3 次/秒肉眼无差别。
   注意：真实走子靠帧指纹识别，降频不影响「对方走完给提示」的及时性
   （指纹变了就立刻处理，不看这个间隔）。 */
/* 2.1.77：0.35 → 0.25。抓帧已经改成「摘要变了才拷」，JS 只会为真实变化跑，
   这道保险不再需要压得那么狠；0.25 让落子响应更快一点。 */
#define JJ_PROCESS_MIN_GAP      0.25
/* 盘面彻底不可信（JS 明确 skipAnalyze）时才退避，正常噪声帧不再退避：
   噪声帧由 JS 侧锚盘覆盖并命中结论缓存，退避只会拖慢真实走子的响应。 */
/* 2.1.77：2.5 → 分级。旧值是一刀切的黑洞：只要某帧识别出垃圾就 2.5 秒
   什么都不看（tick 在入口直接 return），对手正好在这段时间落子就彻底漏掉，
   这是「对方下了棋但没反应」最直接的原因。
   现在：偶发一帧垃圾 0.4 秒就重试；连续垃圾才逐步拉长到 1.2 秒。 */
#define JJ_PROCESS_ILLEGAL_GAP  0.4
#define JJ_PROCESS_ILLEGAL_GAP_LONG 1.2
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

/* 顶部信息条高度（point） */
#define JJ_HUD_TOP_HEIGHT       54.0

/* 箭头线宽（point） */
#define JJ_ARROW_WIDTH          4.0

/* 建议走法箭头颜色 */
/* 2.1.90：建议箭头/网格改用**青蓝色**。
   原因：识别侧新增了「上一步标记」检测（sc.vision 的 sampleRing），它靠
   「高饱和红 / 亮金」找游戏自己画的落子高亮圈。原来的箭头是纯红 (255,51,51)，
   正好落进那个判据 —— 自己的箭头会被当成"游戏刚在这里落子"，直接带偏轮次。
   换到青蓝色后两边彻底分开：红/金 = 游戏的标记，青蓝 = 我们的建议。 */
#define JJ_COLOR_ARROW          [UIColor colorWithRed:0.10 green:0.72 blue:1.00 alpha:0.28]
#define JJ_COLOR_ARROW_HEAD     [UIColor colorWithRed:0.05 green:0.62 blue:1.00 alpha:0.38]
#define JJ_CHEAT_VERSION        @"2.0.0r49"   /* 与 deb control 版本保持一致 */
#define JJ_COLOR_BOARD_LINE     [UIColor colorWithRed:0.25 green:0.78 blue:1.00 alpha:0.42]
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
/* 2.0.0r5：当前生效的内置标定预设（0=人机对战 1=排位赛） */
#define JJ_KEY_CALIB_SCHEME     @"JJCheat.calibScheme"
#define JJ_KEY_HUD_VISIBLE      @"JJCheat.hudVisible"

#define JJ_KEY_THINK_MS         @"JJCheat.thinkMs"
/* 思考时间的一次性迁移标记：2.0.x 存下来的 200ms 是给 JS 引擎调的值，
   对 Pikafish 太短，首次启动时抬到新默认值，只做一次。 */
#define JJ_KEY_THINK_MS_V2      @"JJCheat.thinkMsV2"

/* ============================================================
 *  2.0.0r5 内置标定预设
 *
 *  为什么不再让用户点四角：
 *    手动四点标定是整条链路上唯一需要人参与、也最容易点偏的一步。
 *    2026-11-19 两次「盘面读错 → 整帧作废 → 轮次错位」，根因都是四角
 *    偏了 30~40pt（下边点在 660/697，真值 659/707）。
 *
 *  坐标怎么来的：
 *    真机截图逐像素投影，取棋盘最外圈九条竖线、十条横线的首末交点。
 *    参考分辨率 428x926 point，运行时按实际 bounds 等比缩放。
 *
 *  两套只差纵向：
 *    排位赛顶部多一条对手头像 + 大盘计时，棋盘整体下移约 50pt；
 *    列方向和列距两块板完全一致（28~400 / 46.3）。
 * ============================================================ */
#define JJ_PRESET_REF_W         428.0
#define JJ_PRESET_REF_H         926.0
/* 方案 0：人机对战（顶部没有对手计时条） */
#define JJ_PRESET_AI_L          28.0
#define JJ_PRESET_AI_T          257.0
#define JJ_PRESET_AI_R          398.0
#define JJ_PRESET_AI_B          659.0
/* 方案 1：排位赛 / 棋力评测 / 锦标赛
 *
 * 2.0.0r10 实测修正：原来这套按截图投影量的是 307~707，但真机反馈
 * 「排位预设差很多，用人机那套反而能用」。说明那块板和人机其实是同一位置，
 * 之前量到的是木框/头像区。现在直接与人机对齐：棋盘位置一致，
 * 入口保留（以后真有差异再改这里即可），微调交给 alignGridToOpening。 */
#define JJ_PRESET_RANK_L        JJ_PRESET_AI_L
#define JJ_PRESET_RANK_T        JJ_PRESET_AI_T
#define JJ_PRESET_RANK_R        JJ_PRESET_AI_R
#define JJ_PRESET_RANK_B        JJ_PRESET_AI_B


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
/* 哈希表 MB。手机别给太大：进程内内存，与游戏共用地址空间但独立分配。
   2.1.76：64 → 48。iOS 上 64MB 连续大块分配不保证成功，失败时 Pikafish 原生
   会 exit（已用补丁改成降级），但降级后哈希变小、搜索变弱。
   48MB 对齐象棋每步 800ms 的搜索量已经绰绰有余，分配成功率明显更高。 */
#define JJ_PIKA_HASH_MB         48
/* 引擎状态小圆点刷新间隔（秒） */
#define JJ_ENGINE_DOT_GAP       2.0
/* 2.0.0r9：学习失败帧落盘（14MB JPEG 编码 + 写盘，会明显卡一下）。
   只在排查识别问题时开，默认关。 */
#define JJ_DUMP_LEARN_FAIL      0

#endif /* JJConfig_h */
