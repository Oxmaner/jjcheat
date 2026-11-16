//
//  jjpika_shim.h
//  JJCheat —— Pikafish 进程内运行（2.1.52 起）
//
//  为什么不再 spawn 独立进程：
//    真机日志（2.1.51）显示 4 条 deb 源位与 1 条容器副本全部被判「不可执行」，
//    一条 posix_spawn 都没发出去。iOS App 沙盒不允许对自己数据容器与 jbroot
//    下的二进制做 exec（access(X_OK) 直接 EPERM），这条架构在 roothide 上
//    走不通。改为把 Pikafish 编译成静态库链进 dylib，在进程内跑 UCI 循环。
//
//  通信方式：
//    引擎的 UCIEngine::loop() 用 std::getline(std::cin) 读命令、用 std::cout 写
//    输出。本 shim 把两个流的 rdbuf 换成内存队列：ObjC 侧 jjpika_send() 入队
//    一行命令，jjpika_recv() 取一行输出。对引擎而言它仍在跟一个「终端」说话。
//
//  权重定位：
//    Engine 构造函数用 argv[0] 的所在目录找 pikafish.nnue。我们把 argv[0]
//    设成权重文件本身的绝对路径（它一定存在），目录就是权重所在目录。
//

#ifndef JJPikaShim_h
#define JJPikaShim_h

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 在当前线程跑引擎主循环（阻塞，直到 quit 或 EOF）。
 * @param argv0_path 引擎用来定位 pikafish.nnue 的路径；传权重文件的绝对路径。
 * @return 0 = 正常退出；-1 = 参数无效；-2 = 已有实例在跑。
 * 调用前请确保 argv0_path 可读，否则 Network::load 会直接 exit(EXIT_FAILURE)。
 */
int jjpika_start(const char *argv0_path);

/** 请求退出（等价于发送 quit）。引擎线程会在处理完当前命令后返回。 */
void jjpika_stop(void);

/** 发一行命令（无需自带换行）。返回 0 成功，-1 引擎未运行。 */
int jjpika_send(const char *line);

/**
 * 取一行引擎输出。
 * @param buf 输出缓冲（UTF-8，已含结尾 '\n'，保证有 '\0'）
 * @param cap 缓冲大小
 * @param timeout_ms 最多等待毫秒数
 * @return 1 = 取到一行；0 = 超时；-1 = 引擎已退出且队列已空
 */
int jjpika_recv(char *buf, int cap, int timeout_ms);

/** 引擎线程是否在跑（1/0）。 */
int jjpika_running(void);

#ifdef __cplusplus
}
#endif

#endif /* JJPikaShim_h */
