//
//  JJPikafish.m
//  JJCheat
//

#import "JJPikafish.h"
#import "JJPikafishInstaller.h"
#import "JJMoveCodec.h"
#import "JJConfig.h"
#import <dispatch/dispatch.h>
#import <spawn.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>
#import <os/lock.h>
#import <sys/wait.h>

static NSString *const kPikaLog = @"[JJCheat][Pika]";

/* 握手超时：spawn 后等 uciok/readyok 的上限 */
#define KIKA_HANDSHAKE_TIMEOUT 12.0
/* go 之后 bestmove 的宽限（叠加在 movetime 上） */
#define KIKA_BESTMOVE_GRACE_MS 3000
/* 连续崩溃退避（秒） */
#define KIKA_RESPAWN_BACKOFF 30.0
/* 连续失败多少次后退避 */
#define KIKA_FAIL_LIMIT 3

@interface JJPikafish ()
@property (nonatomic, strong) dispatch_queue_t pikaQueue;
@property (nonatomic, assign) JJPikaState state;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) int stdinFd;
@property (nonatomic, assign) int stdoutFd;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) NSMutableData *lineBuf;
/* 当前搜索 */
@property (nonatomic, copy) NSString *searchingFen;
@property (nonatomic, assign) NSInteger searchingMovetime;
@property (nonatomic, copy) JJPikaResultBlock searchingCb;
@property (nonatomic, strong) NSDictionary *lastInfo;
@property (nonatomic, strong) dispatch_block_t watchdog;
/* 排队的下一个请求（新局面来了先 stop 旧的） */
@property (nonatomic, copy) NSString *pendingFen;
@property (nonatomic, assign) NSInteger pendingMovetime;
@property (nonatomic, copy) JJPikaResultBlock pendingCb;
/* 握手 */
@property (nonatomic, assign) BOOL sawUciok;
@property (nonatomic, strong) dispatch_block_t handshakeTimer;
/* 生命周期 */
@property (nonatomic, assign) NSInteger failCount;
@property (nonatomic, assign) NSTimeInterval backoffBefore;
@property (nonatomic, assign) BOOL wantRunning;
/* 实际跑起来的二进制路径（诊断/取同目录权重用，不一定是容器副本） */
@property (nonatomic, copy) NSString *launchedBin;
/* 被系统拒掉的路径（exec 返回 0 但子进程立刻死 = 签名/沙盒拒绝）：
   下次 spawn 直接跳过，别在同一条路径上反复撞墙 */
@property (nonatomic, strong) NSMutableSet<NSString *> *badBins;
@property (nonatomic, assign) NSTimeInterval lastSpawnTs;
@property (nonatomic, assign) BOOL sawReadyok;
@end

@implementation JJPikafish

/* 如果 getter 与 setter 都由我们实现，clang 就不会自动合成 _state 这个 ivar。
   init 里要写 _state，所以这里显式 @synthesize 一次。 */
@synthesize state = _state;

/* 状态用自旋锁保护，**绝不能**用 dispatch_sync 回到 _pikaQueue：
   start / analyzeFen 的 block 本身就跑在 _pikaQueue 上，串行队列同步等自己
   就是死锁；队列一卡死，主线程随后读状态也会被一起拖住，几秒后被系统
   看门狗杀掉。2.1.50 真机「activate 后 6 秒进程重启、[Pika] 一条日志都没有」
   就是这条路径。（锁只保护一个 enum 的读写，纳秒级，不会阻塞主线程。） */
static os_unfair_lock sPikaStateLock = OS_UNFAIR_LOCK_INIT;

+ (instancetype)shared {
    static JJPikafish *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JJPikafish alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pikaQueue = dispatch_queue_create("com.fujiang.jjcheat.pikafish", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_pikaQueue,
                                  dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        _state = JJPikaStateIdle;
        _pid = -1;
        _stdinFd = -1;
        _stdoutFd = -1;
        _lineBuf = [NSMutableData data];
        _wantRunning = NO;
        _badBins = [NSMutableSet set];
    }
    return self;
}

- (JJPikaState)state {
    os_unfair_lock_lock(&sPikaStateLock);
    JJPikaState st = _state;
    os_unfair_lock_unlock(&sPikaStateLock);
    return st;
}

- (void)setState:(JJPikaState)state {
    os_unfair_lock_lock(&sPikaStateLock);
    _state = state;
    os_unfair_lock_unlock(&sPikaStateLock);
}

- (NSString *)stateText {
    switch (self.state) {
        case JJPikaStateIdle:      return @"未启动";
        case JJPikaStateStarting:  return @"启动中";
        case JJPikaStateReady:     return @"就绪";
        case JJPikaStateSearching: return @"思考中";
        case JJPikaStateDead:      return @"不可用（崩溃退避）";
    }
}

- (BOOL)isReadyOrStarting {
    JJPikaState st = self.state;
    return st == JJPikaStateReady || st == JJPikaStateSearching ||
           st == JJPikaStateStarting;
}

/* 实际在用的可执行文件：优先报告真正 spawn 成功的那个，退回容器副本 */
- (NSString *)enginePathInUse {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (self.launchedBin.length && [fm isExecutableFileAtPath:self.launchedBin]) {
        return self.launchedBin;
    }
    return [JJPikafishInstaller enginePathInContainer];
}

/* 与二进制同目录的 NNUE 权重：Pikafish 就是按「二进制所在目录」找它。
   从改 deb 源位直接启动时权重也在那儿，不必等容器复制完。 */
- (NSString *)netPathInUse {
    if (self.launchedBin.length) {
        NSString *p = [[self.launchedBin stringByDeletingLastPathComponent]
                       stringByAppendingPathComponent:JJ_PIKA_NET_NAME];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return [JJPikafishInstaller netPathInContainer];
}

#pragma mark - 生命周期

- (void)start {
    /* 先在调用线程把状态置为 Starting：首次激活要把 48MB 权重复制进容器，
       这段时间状态点该是「黄 · 启动中」，不该是「红 · 不可用」。
       真正的复制 / spawn / 握手仍全部在 _pikaQueue 上做，主线程不参与。 */
    JJPikaState st = self.state;
    if (st == JJPikaStateReady || st == JJPikaStateSearching ||
        st == JJPikaStateStarting) {
        return;
    }
    self.state = JJPikaStateStarting;
    dispatch_async(_pikaQueue, ^{
        self.wantRunning = YES;
        /* 二次确认：排队期间可能已经握上手了 */
        JJPikaState cur = self.state;
        if (cur == JJPikaStateReady || cur == JJPikaStateSearching) return;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (self.backoffBefore > now) {
            self.state = JJPikaStateDead;
            NSLog(@"%@ 退避中，还剩 %.0fs", kPikaLog, self.backoffBefore - now);
            return;
        }
        [self spawnOnQueue];
    });
}

- (void)shutdown {
    dispatch_async(_pikaQueue, ^{
        self.wantRunning = NO;
        [self teardownOnQueue:@"shutdown"];
    });
}

- (void)notifyNewGame {
    dispatch_async(_pikaQueue, ^{
        if (self.state == JJPikaStateReady || self.state == JJPikaStateSearching) {
            NSLog(@"%@ ucinewgame（新对局）", kPikaLog);
            [self writeLine:@"ucinewgame"];
            [self writeLine:@"isready"];
        }
    });
}

#pragma mark - spawn / teardown

/* 候选可执行路径：按「沙盒最可能放行」排序。
   只读的 deb 源位（bundle/.jbroot、jbroot()、/var/jb、/）优先——不少机型禁止
   从可写容器 exec，而从安装目录直接跑既能过沙盒、又省掉 48MB 权重的一次性复制；
   全都起不来时才退回容器副本（安装器自带 4 级源回退）。
   无论从哪儿起，pikafish.nnue 就在二进制旁边，引擎按「二进制所在目录」找得到。 */
- (NSArray<NSString *> *)binaryCandidatesOnQueue {
    NSMutableArray<NSString *> *bins = [NSMutableArray array];
    NSString *containerBin = [JJPikafishInstaller enginePathInContainer];
    for (NSString *p in [JJPikafishInstaller candidateSources]) {
        if (![p.lastPathComponent isEqualToString:JJ_PIKA_BIN_NAME]) continue;
        /* 容器副本单独放最后兜底，不参与这一轮 */
        if (containerBin.length && [p isEqualToString:containerBin]) continue;
        if ([bins containsObject:p]) continue;
        [bins addObject:p];
    }
    /* 之前被系统拒掉的路径先跳过；全都拒过就清空重来（可能是重装/重签了） */
    if (self.badBins.count) {
        NSMutableArray *keep = [NSMutableArray array];
        for (NSString *p in bins) if (![self.badBins containsObject:p]) [keep addObject:p];
        if (keep.count) bins = keep;
        else [self.badBins removeAllObjects];
    }
    return bins;
}

/** 起一个引擎进程并发出 uci（pikaQueue 上）。成功返回 YES，失败时管道已收拾干净。 */
- (BOOL)spawnBinaryOnQueue:(NSString *)bin {
    int inPipe[2], outPipe[2];
    if (pipe(inPipe) != 0 || pipe(outPipe) != 0) {
        NSLog(@"%@ pipe 失败: %s", kPikaLog, strerror(errno));
        return NO;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, inPipe[0]);
    posix_spawn_file_actions_addclose(&actions, inPipe[1]);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);
    posix_spawn_file_actions_addclose(&actions, outPipe[1]);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    /* 子进程只保留必要的 fd，别把游戏的句柄漏给引擎 */
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);

    char *argv[] = {(char *)bin.fileSystemRepresentation, NULL};
    /* 给一个最小环境：空 envp 也能跑，但真机上缺 PATH 时 dyld 与
       C++ 运行时的边角路径偶尔出意外，填上不改变任何行为。 */
    char *envp[] = {(char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    pid_t pid = -1;
    int rc = posix_spawn(&pid, bin.fileSystemRepresentation, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(inPipe[0]);
    close(outPipe[1]);
    if (rc != 0) {
        close(inPipe[1]);
        close(outPipe[0]);
        NSLog(@"%@ 无法执行 rc=%d: %s（bin=%@）", kPikaLog, rc, strerror(rc), bin);
        return NO;
    }

    self.pid = pid;
    self.stdinFd = inPipe[1];
    self.stdoutFd = outPipe[0];
    self.sawUciok = NO;
    self.sawReadyok = NO;
    self.lastSpawnTs = [NSDate timeIntervalSinceReferenceDate];
    self.failCount = 0;
    self.launchedBin = bin;
    [self.lineBuf setLength:0];
    NSLog(@"%@ 进程已启动 pid=%d bin=%@", kPikaLog, pid, bin);

    [self installReadSource];
    [self writeLine:@"uci"];
    return YES;
}

- (void)spawnOnQueue {
    self.state = JJPikaStateStarting;
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *launched = nil;
    for (NSString *bin in [self binaryCandidatesOnQueue]) {
        if (![bin length] || ![fm isExecutableFileAtPath:bin]) {
            NSLog(@"%@ 跳过不可执行: %@", kPikaLog, bin.length ? bin : @"(nil)");
            continue;
        }
        if ([self spawnBinaryOnQueue:bin]) { launched = bin; break; }
    }

    if (!launched) {
        /* 源位全都 exec 不了 → 复制进可写容器再试一次（首次约 48MB，几秒） */
        NSLog(@"%@ 源位都起不来，改走容器副本", kPikaLog);
        NSError *err = nil;
        if (![JJPikafishInstaller ensureInstalledWithError:&err]) {
            NSLog(@"%@ 容器安装失败（%@）", kPikaLog, err.localizedDescription ?: @"?");
        }
        NSString *cbin = [JJPikafishInstaller enginePathInContainer];
        if (cbin.length && [fm isExecutableFileAtPath:cbin] &&
            [self spawnBinaryOnQueue:cbin]) {
            launched = cbin;
        }
    }

    if (!launched) {
        NSLog(@"%@ 所有候选都启动失败，放弃本次（连续 %d 次后退避 %.0fs）",
              kPikaLog, KIKA_FAIL_LIMIT, (double)KIKA_RESPAWN_BACKOFF);
        [self noteFailureOnQueue];
        return;
    }

    /* 握手计时器统一在这里挂：spawn 成功时 uci 已经写出去了 */
    self.handshakeTimer = dispatch_block_create(0, ^{
        if (self.state == JJPikaStateStarting) {
            NSLog(@"%@ 握手超时（%.0fs 无 uciok/readyok），杀掉重来", kPikaLog,
                  (double)KIKA_HANDSHAKE_TIMEOUT);
            [self killOnQueue];
            [self scheduleRespawnOnQueue];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                     (int64_t)(KIKA_HANDSHAKE_TIMEOUT * NSEC_PER_SEC)),
                   _pikaQueue, self.handshakeTimer);
}

/** 关管道、杀进程、清状态（pikaQueue 上执行）。reason 只用于日志。 */
- (void)teardownOnQueue:(NSString *)reason {
    if (self.handshakeTimer) {
        dispatch_block_cancel(self.handshakeTimer);
        self.handshakeTimer = nil;
    }
    if (self.watchdog) {
        dispatch_block_cancel(self.watchdog);
        self.watchdog = nil;
    }
    if (self.readSource) {
        dispatch_source_cancel(self.readSource);
        self.readSource = nil;
    }
    if (self.stdinFd >= 0) { close(self.stdinFd); self.stdinFd = -1; }
    if (self.stdoutFd >= 0) { close(self.stdoutFd); self.stdoutFd = -1; }
    if (self.pid > 0) {
        kill(self.pid, SIGKILL);
        /* 收尸：不阻塞等待 */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            pid_t p = self.pid;
            if (p > 0) {
                int st = 0;
                for (int i = 0; i < 20; i++) {
                    if (waitpid(p, &st, WNOHANG) == p) return;
                    usleep(100000);
                }
                kill(p, SIGKILL);
                waitpid(p, &st, 0);
            }
        });
        self.pid = -1;
    }
    self.state = JJPikaStateIdle;
    self.searchingFen = nil;
    self.searchingCb = nil;
    self.pendingFen = nil;
    self.pendingCb = nil;
    self.lastInfo = nil;
    (void)reason;
}

- (void)killOnQueue {
    [self teardownOnQueue:@"kill"];
}

- (void)scheduleRespawnOnQueue {
    if (!self.wantRunning) return;
    self.failCount++;
    if (self.failCount >= KIKA_FAIL_LIMIT) {
        self.backoffBefore = [NSDate timeIntervalSinceReferenceDate] + KIKA_RESPAWN_BACKOFF;
        self.failCount = 0;
        self.state = JJPikaStateDead;
        NSLog(@"%@ 连续失败 %ld 次，退避 %.0fs", kPikaLog, (long)KIKA_FAIL_LIMIT,
              (double)KIKA_RESPAWN_BACKOFF);
        return;
    }
    self.state = JJPikaStateDead;
    [self spawnOnQueue];
}

- (void)noteFailureOnQueue {
    self.state = JJPikaStateDead;
    [self scheduleRespawnOnQueue];
}

#pragma mark - 管道 I/O

- (void)installReadSource {
    int fd = self.stdoutFd;
    if (fd < 0) return;
    dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _pikaQueue);
    dispatch_source_set_event_handler(src, ^{
        char buf[16384];
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            /* EOF / 错误：引擎退出（崩溃或被杀） */
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
                dispatch_source_cancel(self.readSource);
                self.readSource = nil;
                [self handleEngineExitOnQueue];
            }
            return;
        }
        [self.lineBuf appendBytes:buf length:(NSUInteger)n];
        [self drainLinesOnQueue];
    });
    dispatch_source_set_cancel_handler(src, ^{
        /* fd 由 teardown 统一关闭 */
    });
    dispatch_resume(src);
    self.readSource = src;
}

/** 按行切分并逐行处理（pikaQueue 上） */
- (void)drainLinesOnQueue {
    NSRange nl;
    while ((nl = [self.lineBuf rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0
                                    range:NSMakeRange(0, self.lineBuf.length)]).length > 0) {
        NSData *lineData = [self.lineBuf subdataWithRange:NSMakeRange(0, nl.location)];
        NSString *line = [[NSString alloc] initWithData:lineData
                                               encoding:NSUTF8StringEncoding];
        if (!line) line = @"";
        [self.lineBuf replaceBytesInRange:NSMakeRange(0, nl.location + nl.length)
                                withBytes:NULL length:0];
        line = [line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length) [self handleLineOnQueue:line];
    }
}

- (void)writeLine:(NSString *)line {
    if (self.stdinFd < 0) return;
    NSString *s = [line stringByAppendingString:@"\n"];
    const char *p = s.UTF8String;
    size_t len = strlen(p);
    ssize_t off = 0;
    while (off < (ssize_t)len) {
        ssize_t n = write(self.stdinFd, p + off, len - (size_t)off);
        if (n > 0) { off += n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        NSLog(@"%@ 写管道失败（引擎死了？）: %s", kPikaLog, strerror(errno));
        dispatch_source_cancel(self.readSource);
        self.readSource = nil;
        [self handleEngineExitOnQueue];
        return;
    }
}

#pragma mark - UCI 行处理

- (void)handleLineOnQueue:(NSString *)line {
    if ([line hasPrefix:@"uciok"]) {
        self.sawUciok = YES;
        /* 手机资源画像：单线程、小哈希。
           EvalFile 必须显式指定：Pikafish 2026 版已取消编译期内嵌 NNUE
           （network.cpp 里没有 INCBIN 分支），只在 {cwd, 二进制所在目录}
           里按默认名 pikafish.nnue 找。安装器把两个文件放在同一目录，
           理论上不设也能找到；这里再显式设一次绝对路径，把「spawn 时
           argv[0] 是相对路径 / 容器被重定向」这类边角情况一起堵掉。 */
        NSString *netPath = [self netPathInUse];
        if (netPath.length) {
            [self writeLine:[NSString stringWithFormat:@"setoption name EvalFile value %@", netPath]];
        }
        [self writeLine:@"setoption name Threads value 1"];
        [self writeLine:[NSString stringWithFormat:@"setoption name Hash value %d",
                         JJ_PIKA_HASH_MB]];
        [self writeLine:@"setoption name Move Overhead value 0"];
        [self writeLine:@"setoption name UCI_ShowWDL value true"];
        [self writeLine:@"isready"];
        return;
    }
    if ([line hasPrefix:@"readyok"]) {
        if (self.handshakeTimer) {
            dispatch_block_cancel(self.handshakeTimer);
            self.handshakeTimer = nil;
        }
        if (self.state == JJPikaStateStarting) {
            NSLog(@"%@ 握手完成（uciok=%d），引擎就绪", kPikaLog, self.sawUciok);
        }
        self.sawReadyok = YES;
        self.state = JJPikaStateReady;
        [self flushPendingOnQueue];
        return;
    }
    if ([line hasPrefix:@"info "]) {
        self.lastInfo = [self parseInfoLine:line];
        return;
    }
    if ([line hasPrefix:@"bestmove"]) {
        [self handleBestmoveOnQueue:line];
        return;
    }
    if ([line hasPrefix:@"id name"]) {
        NSLog(@"%@ 引擎自报: %@", kPikaLog, line);
    }
}

- (NSDictionary *)parseInfoLine:(NSString *)line {
    NSArray *tok = [line componentsSeparatedByString:@" "];
    NSMutableDictionary *d = self.lastInfo ? [self.lastInfo mutableCopy]
                                             : [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i + 1 < tok.count; i++) {
        NSString *k = tok[i];
        if ([k isEqualToString:@"depth"]) d[@"depth"] = @([tok[i + 1] integerValue]);
        else if ([k isEqualToString:@"score"]) {
            /* score cp N [lowerbound|upperbound] 或 score mate N */
            if (i + 3 <= tok.count && [tok[i + 1] isEqualToString:@"mate"]) {
                d[@"mate"] = @([tok[i + 2] integerValue]);
                d[@"score"] = nil;
            } else {
                d[@"score"] = @([tok[i + 2] integerValue]);
                d[@"mate"] = nil;
            }
        }
        else if ([k isEqualToString:@"wdl"]) {
            /* wdl W D L（千分数，走子方视角） */
            if (i + 3 < tok.count) {
                d[@"wdlW"] = @([tok[i + 1] integerValue]);
                d[@"wdlD"] = @([tok[i + 2] integerValue]);
                d[@"wdlL"] = @([tok[i + 3] integerValue]);
            }
        }
        else if ([k isEqualToString:@"nodes"]) d[@"nodes"] = @([tok[i + 1] integerValue]);
        else if ([k isEqualToString:@"nps"]) d[@"nps"] = @([tok[i + 1] integerValue]);
        else if ([k isEqualToString:@"pv"]) {
            NSMutableArray *pv = [NSMutableArray array];
            for (NSUInteger j = i + 1; j < tok.count; j++) [pv addObject:tok[j]];
            d[@"pv"] = pv;
        }
    }
    return d;
}

- (void)handleBestmoveOnQueue:(NSString *)line {
    if (self.watchdog) {
        dispatch_block_cancel(self.watchdog);
        self.watchdog = nil;
    }
    NSArray *tok = [line componentsSeparatedByString:@" "];
    NSString *mv = tok.count > 1 ? tok[1] : @"";
    if ([mv isEqualToString:@"(none)"]) mv = @"";

    JJPikaResultBlock cb = self.searchingCb;
    NSString *fen = self.searchingFen;
    self.state = JJPikaStateReady;
    self.searchingFen = nil;
    self.searchingCb = nil;

    if (cb) {
        NSDictionary *info = self.lastInfo ?: @{};
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"bestmove"] = mv;
        out[@"ponder"] = (tok.count > 3 && [tok[2] isEqualToString:@"ponder"]) ? tok[3] : @"";
        out[@"from"] = @(mv.length >= 4 ? JJSqFromICCS(mv, 0) : -1);
        out[@"to"] = @(mv.length >= 4 ? JJSqFromICCS(mv, 1) : -1);
        out[@"depth"] = info[@"depth"] ?: @0;
        out[@"score"] = info[@"score"] ?: @0;
        out[@"mate"] = info[@"mate"] ?: @0;
        out[@"nodes"] = info[@"nodes"] ?: @0;
        out[@"nps"] = info[@"nps"] ?: @0;
        out[@"pv"] = info[@"pv"] ?: @[];
        /* 胜率：UCI_ShowWDL 的 wdl 千分数（走子方视角）；没有就按 cp 估 */
        NSInteger w = [info[@"wdlW"] integerValue];
        NSInteger dr = [info[@"wdlD"] integerValue];
        if (w + dr > 0) {
            out[@"winrate"] = @((w + dr / 2) / 10.0);
        } else {
            double cp = [info[@"score"] doubleValue];
            double wr = 100.0 * (2.0 / (1.0 + exp(-cp / 200.0)) - 1.0) / 2.0 + 50.0;
            out[@"winrate"] = @(MAX(1.0, MIN(99.0, wr)));
        }
        out[@"searchFen"] = fen ?: @"";
        out[@"engine"] = @"pikafish";
        dispatch_async(dispatch_get_main_queue(), ^{ cb([out copy]); });
    }
    [self flushPendingOnQueue];
}

/** 引擎进程退出（EOF 或写失败）—— pikaQueue 上 */
- (void)handleEngineExitOnQueue {
    if (!self.wantRunning) return;   /* shutdown 主动关的，不用管 */
    /* 顺手收尸并打印退出方式：被内核以 SIGKILL 干掉（签名/权限被 amfi 拒）
       和自身崩溃（SIGSEGV/SIGABRT）是完全两种病因，日志里必须分得清。 */
    int status = 0;
    pid_t wp = self.pid > 0 ? waitpid(self.pid, &status, WNOHANG) : -1;
    if (wp == self.pid) {
        if (WIFSIGNALED(status)) {
            NSLog(@"%@ 引擎进程退出（pid=%d, 信号 %d: %s）", kPikaLog, self.pid,
                  WTERMSIG(status), strsignal(WTERMSIG(status)));
        } else {
            NSLog(@"%@ 引擎进程退出（pid=%d, 退出码 %d）", kPikaLog, self.pid,
                  WEXITSTATUS(status));
        }
        self.pid = -1;
    } else {
        NSLog(@"%@ 引擎进程退出（pid=%d）", kPikaLog, self.pid);
    }
    /* 起来不到 3 秒就死、还没握上手 → 这条路径被系统拒了（签名/沙盒），
       记下来，下次 spawn 直接跳过，换下一条候选。 */
    if (!self.sawReadyok && self.launchedBin.length &&
        [NSDate timeIntervalSinceReferenceDate] - self.lastSpawnTs < 3.0) {
        [self.badBins addObject:self.launchedBin];
        NSLog(@"%@ 这条路径起不来，换候选：%@", kPikaLog, self.launchedBin);
    }
    JJPikaResultBlock cb = self.searchingCb;
    JJPikaResultBlock pcb = self.pendingCb;
    self.searchingCb = nil;
    self.pendingCb = nil;
    self.searchingFen = nil;
    self.pendingFen = nil;
    self.state = JJPikaStateIdle;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(nil); });
    if (pcb) dispatch_async(dispatch_get_main_queue(), ^{ pcb(nil); });
    /* 崩溃重生（自己带退避） */
    [self scheduleRespawnOnQueue];
}

#pragma mark - 搜索调度

- (void)analyzeFen:(NSString *)fen movetime:(NSInteger)movetime completion:(JJPikaResultBlock)completion {
    if (!fen.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    dispatch_async(_pikaQueue, ^{
        self.wantRunning = YES;
        /* 没起 / 死了：先拉起，请求排队（flushPending 在 readyok 后触发） */
        if (self.state == JJPikaStateIdle || self.state == JJPikaStateDead) {
            [self start];
        }
        if (self.state != JJPikaStateReady && self.state != JJPikaStateSearching) {
            self.pendingFen = fen;
            self.pendingMovetime = movetime;
            self.pendingCb = completion;
            return;
        }
        if (self.state == JJPikaStateSearching) {
            /* 正在搜旧局面：停掉它，结果一到就开新搜索 */
            [self writeLine:@"stop"];
            self.pendingFen = fen;
            self.pendingMovetime = movetime;
            self.pendingCb = completion;
            return;
        }
        [self beginSearchOnQueue:fen movetime:movetime completion:completion];
    });
}

- (void)beginSearchOnQueue:(NSString *)fen
                  movetime:(NSInteger)movetime
                completion:(JJPikaResultBlock)completion {
    if (self.state != JJPikaStateReady) return;
    self.state = JJPikaStateSearching;
    self.searchingFen = fen;
    self.searchingMovetime = MAX(50, movetime);
    self.searchingCb = completion;
    self.lastInfo = nil;
    [self writeLine:[NSString stringWithFormat:@"position fen %@", fen]];
    [self writeLine:[NSString stringWithFormat:@"go movetime %ld",
                     (long)self.searchingMovetime]];

    /* 看门狗：movetime + 宽限期仍无 bestmove → 杀掉重生，丢一次结果 */
    __weak typeof(self) weakSelf = self;
    NSInteger mt = self.searchingMovetime;
    self.watchdog = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || self2.state != JJPikaStateSearching) return;
        NSLog(@"%@ 看门狗超时（movetime=%ldms 无 bestmove），杀掉重生", kPikaLog, (long)mt);
        JJPikaResultBlock cb = self2.searchingCb;
        self2.searchingCb = nil;
        self2.searchingFen = nil;
        [self2 killOnQueue];
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(nil); });
        [self2 scheduleRespawnOnQueue];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                     (int64_t)((mt + KIKA_BESTMOVE_GRACE_MS) * 1000000ull)),
                   _pikaQueue, self.watchdog);
}

- (void)flushPendingOnQueue {
    if (!self.pendingFen.length || self.state != JJPikaStateReady) return;
    NSString *fen = self.pendingFen;
    NSInteger mt = self.pendingMovetime;
    JJPikaResultBlock cb = self.pendingCb;
    self.pendingFen = nil;
    self.pendingMovetime = 0;
    self.pendingCb = nil;
    [self beginSearchOnQueue:fen movetime:mt completion:cb];
}

@end
