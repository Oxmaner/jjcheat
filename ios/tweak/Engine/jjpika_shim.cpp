//
//  jjpika_shim.cpp
//  JJCheat —— Pikafish 进程内 UCI 桥接（2.1.52 起）
//
//  编译期编进 libpikafish.a，由 JJPikafish 在专用线程上调用 jjpika_start()。
//  下面这几个 streambuf 就是「虚拟串口」：把引擎的 stdin/stdout 换成内存队列。
//

#include "jjpika_shim.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <iostream>
#include <memory>
#include <mutex>
#include <streambuf>
#include <string>
#include <utility>

#include "attacks.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

namespace {

/* ------------------------------------------------------------
 *  输入流：命令行队列 → std::cin
 *  UCIEngine::loop() 每轮调 std::getline(std::cin, cmd)，最终落到
 *  underflow()：队列空就阻塞，收到 quit 或 close 后返回 EOF，
 *  引擎把 EOF 当成 quit，循环正常退出。
 * ---------------------------------------------------------- */
class LineInBuf : public std::streambuf {
   public:
    void reset() {
        std::lock_guard<std::mutex> lk(m_);
        q_.clear();
        cur_.clear();
        closed_ = false;
    }

    void push(const std::string &line) {
        {
            std::lock_guard<std::mutex> lk(m_);
            if (closed_) return;
            q_.push_back(line + "\n");
        }
        cv_.notify_all();
    }

    void close() {
        {
            std::lock_guard<std::mutex> lk(m_);
            closed_ = true;
        }
        cv_.notify_all();
    }

   protected:
    int_type underflow() override {
        /* 当前行还有没读完的字符：直接交出去（getline 会在缓冲区里顺序取） */
        {
            std::lock_guard<std::mutex> lk(m_);
            if (gptr() != nullptr && gptr() < egptr())
                return traits_type::to_int_type(*gptr());
        }

        std::unique_lock<std::mutex> lk(m_);
        while (q_.empty() && !closed_) cv_.wait(lk);
        if (q_.empty()) return traits_type::eof();

        cur_ = std::move(q_.front());
        q_.pop_front();
        char *base = &cur_[0];
        setg(base, base, base + cur_.size());
        return traits_type::to_int_type(*base);
    }

   private:
    std::mutex m_;
    std::condition_variable cv_;
    std::deque<std::string> q_;
    std::string cur_;
    bool closed_ = false;
};

/* ------------------------------------------------------------
 *  输出流：std::cout / std::cerr → 行队列
 *  引擎所有输出都走 sync_cout（本质是 std::cout << ... << sync_endl），
 *  按 '\n' 切行入队；objc 侧 jjpika_recv 阻塞取行。
 * ---------------------------------------------------------- */
class LineOutBuf : public std::streambuf {
   public:
    void reset() {
        std::lock_guard<std::mutex> lk(m_);
        lines_.clear();
        partial_.clear();
        closed_ = false;
    }

    void close() {
        {
            std::lock_guard<std::mutex> lk(m_);
            closed_ = true;
            if (!partial_.empty()) {
                lines_.push_back(partial_);
                partial_.clear();
            }
        }
        cv_.notify_all();
    }

    /** 1 = 取到一行；0 = 超时；-1 = 已关闭且取空 */
    int pop(std::string &out, int timeoutMs) {
        std::unique_lock<std::mutex> lk(m_);
        if (lines_.empty() && !closed_ && timeoutMs > 0)
            cv_.wait_for(lk, std::chrono::milliseconds(timeoutMs));
        if (!lines_.empty()) {
            out = std::move(lines_.front());
            lines_.pop_front();
            return 1;
        }
        return closed_ ? -1 : 0;
    }

   protected:
    std::streamsize xsputn(const char *s, std::streamsize n) override {
        std::lock_guard<std::mutex> lk(m_);
        bool gotLine = false;
        for (std::streamsize i = 0; i < n; ++i) {
            const char c = s[i];
            if (c == '\n') {
                lines_.push_back(partial_);
                partial_.clear();
                gotLine = true;
            } else {
                partial_.push_back(c);
            }
        }
        if (gotLine) cv_.notify_all();
        return n;
    }

    int_type overflow(int_type c) override {
        if (traits_type::eq_int_type(c, traits_type::eof()))
            return traits_type::not_eof(c);
        const char ch = traits_type::to_char_type(c);
        {
            std::lock_guard<std::mutex> lk(m_);
            if (ch == '\n') {
                lines_.push_back(partial_);
                partial_.clear();
            } else {
                partial_.push_back(ch);
            }
        }
        if (ch == '\n') cv_.notify_all();
        return c;
    }

    int sync() override { return 0; }

   private:
    std::mutex m_;
    std::condition_variable cv_;
    std::deque<std::string> lines_;
    std::string partial_;
    bool closed_ = false;
};

LineInBuf g_in;
LineOutBuf g_out;
std::atomic<int> g_running{0};
std::once_flag g_streamOnce;

}  // namespace

extern "C" int jjpika_start(const char *argv0_path) {
    if (argv0_path == nullptr || *argv0_path == '\0') return -1;

    if (g_running.load()) return -2;

    /* 把引擎的「终端」换成内存队列。只做一次：rdbuf 是全局状态，
       重复设置会把上一个实例的队列换掉（重启引擎时会走这条路径）。 */
    std::call_once(g_streamOnce, [] {
        std::ios_base::sync_with_stdio(false);
        std::cin.rdbuf(&g_in);
        std::cout.rdbuf(&g_out);
        std::cerr.rdbuf(&g_out);
    });

    /* 先清队列、再置 running=1：调用方靠 jjpika_running()==1 判断「可以发命令了」，
       反过来的话早到的 uci 会被这里抹掉，握手就永远等不到。 */
    g_in.reset();
    g_out.reset();
    int expected = 0;
    if (!g_running.compare_exchange_strong(expected, 1)) return -2;

    /* argv[0] 只用来推导 NNUE 所在目录（Engine 构造函数里 canonical().parent_path()），
       传权重文件本身最稳：它一定存在，目录就是权重目录。argc 保持 1 → 走交互模式。 */
    char *argv[2] = {const_cast<char *>(argv0_path), nullptr};

    Stockfish::CommandLine cli(1, argv);
    Stockfish::Attacks::init();
    Stockfish::Position::init();
    auto uci = std::make_unique<Stockfish::UCIEngine>(std::move(cli));
    Stockfish::Tune::init(uci->engine_options());
    uci->loop();

    g_running = 0;
    g_out.close();
    g_in.close();
    return 0;
}

extern "C" void jjpika_stop(void) {
    if (g_running.load()) g_in.push("quit");
}

extern "C" int jjpika_send(const char *line) {
    if (line == nullptr || !g_running.load()) return -1;
    g_in.push(line);
    return 0;
}

extern "C" int jjpika_recv(char *buf, int cap, int timeout_ms) {
    if (buf == nullptr || cap <= 1) return -1;
    std::string line;
    int rc = g_out.pop(line, timeout_ms);
    if (rc != 1) return rc;
    if (line.size() > (size_t)(cap - 1)) line.resize((size_t)(cap - 1));
    std::memcpy(buf, line.data(), line.size());
    buf[line.size()] = '\0';
    return 1;
}

extern "C" int jjpika_running(void) { return g_running.load(); }
