#!/usr/bin/env python3
# ============================================================
#  Pikafish 源码补丁（JJCheat 2.1.68 起随构建自动应用）
#
#  为什么必须打这个补丁：
#    Pikafish 的 Network::verify() 在「网络没加载成功」时唯一动作是
#    exit(EXIT_FAILURE)，而 Engine::go() 的第一句就是 verify_network()。
#    我们是把引擎静态链进 dylib、和宿主 App 同进程，所以这个 exit
#    不是「引擎退出」，而是「把整个 JJ象棋杀掉」。真机 .ips 证据（thread 91）：
#        jjpika_start → UCIEngine::loop → Engine::go
#        → Engine::verify_network → Network::verify → exit → 全局析构
#    主线程当时正在 CA::Display::DisplayLink 里渲染，撞上被析构的
#    TuanjieFramework 静态对象 → thread 0 报 0x0 SIGSEGV。
#    所以历次「思考中→闪退」都不是搜索里的空指针，是这一行 exit。
#
#  补丁做三件事：
#    1. verify() 改返回 bool，删掉 exit；失败只跳过本次搜索（进程存活）
#    2. 失败原因逐条落到 TU 级静态量（Network 必须保持 trivially-copyable，
#       不能加 std::string 成员），再由 Engine 通过 onVerifyNetwork 上报，
#       带上 decompressed 字节数 / fileHash / engineHash，一眼定位根因
#    3. 日志文本保持 ASCII：dylib 里混中文会让 syslog 检索变麻烦
#
#  设计原则：每一处替换都要求「原文本恰好出现 1 次」，否则直接退出码 1。
#  源码漂移时构建立刻变红，而不是静默产出一个「补丁没打上」的坏包。
#  幂等：已替换过的（目标文本已在）会跳过，可反复运行。
# ============================================================
import sys
import pathlib

MARK = "[jj-patch]"
errors = []


def patch(path: pathlib.Path, label: str, pairs):
    """对单个文件按 (old, new) 列表做替换。返回是否有改动。"""
    if not path.is_file():
        errors.append(f"{path}: 文件不存在（源码结构与预期不符）")
        return False
    src = path.read_bytes()
    # 归一化：Pikafish 在 macOS 上 clone 出来是 LF，但我们容忍 CRLF
    crlf = b"\r\n" in src
    text = src.replace(b"\r\n", b"\n").decode("utf-8")
    changed = False

    for i, (old, new) in enumerate(pairs, 1):
        tag = f"{label} #{i}"
        if new in text:
            print(f"{MARK} {tag}: 已是目标状态，跳过")
            continue
        n = text.count(old)
        if n != 1:
            errors.append(
                f"{tag}: 期望原文本出现 1 次，实际 {n} 次\n"
                f"  文件: {path}\n"
                f"  片段: {old.strip().splitlines()[0][:100]!r}"
            )
            continue
        text = text.replace(old, new, 1)
        changed = True
        print(f"{MARK} {tag}: 已替换 ({len(old)} -> {len(new)} 字节)")

    if changed:
        out = text.encode("utf-8")
        if crlf:
            out = out.replace(b"\n", b"\r\n")
        path.write_bytes(out)
    return changed


# ---------------------------------------------------------------
# 1) network.h —— verify 签名改 bool + 暴露诊断访问器
# ---------------------------------------------------------------
NETWORK_H_VERIFY_OLD = """    void verify(const std::function<void(std::string_view)>& f,
                const EvalFile&                              evalFile,
                std::filesystem::path                        evalfilePath) const;"""

NETWORK_H_VERIFY_NEW = """    // JJCheat: 原来是 void，且失败时 exit(EXIT_FAILURE)。改成返回是否可用，
    // 由 Engine::go() 决定「跳过本次搜索」，绝不终止宿主进程。
    bool verify(const std::function<void(std::string_view)>& f,
                const EvalFile&                              evalFile,
                std::filesystem::path                        evalfilePath) const;"""

NETWORK_H_ACCESSORS = """
// ---------------------------------------------------------------------------
// JJCheat: 网络加载诊断。
// Network 必须保持 trivially-copyable（官方注释：它要被放进共享内存，
// 不能有析构函数），所以失败原因不能做成 Network 的成员，只能放 TU 级静态量，
// 再通过下面这几个 free function 读取。定义在 network.cpp。
// ---------------------------------------------------------------------------
const char*        jj_last_network_load_error();
unsigned           jj_last_network_file_hash();
unsigned           jj_last_network_want_hash();
unsigned long long jj_last_network_bytes();
const char*        jj_last_network_path();

}  // namespace Stockfish::Eval::NNUE"""

NETWORK_H_NS_END_OLD = """
}  // namespace Stockfish::Eval::NNUE"""


# ---------------------------------------------------------------
# 2) network.cpp —— 诊断状态 + 逐条失败原因 + verify 不 exit
# ---------------------------------------------------------------
NETWORK_CPP_INCLUDE_OLD = """#include <cstdlib>
#include <fstream>"""

NETWORK_CPP_INCLUDE_NEW = """#include <cstdio>
#include <cstdlib>
#include <fstream>"""

NETWORK_CPP_GLOBALS_OLD = """namespace fs = std::filesystem;
"""

NETWORK_CPP_GLOBALS_NEW = """namespace fs = std::filesystem;

// ---------------------------------------------------------------------------
// JJCheat: 网络加载诊断状态（见 network.h 的说明）。
// 全部用常量初始化的 POD：无动态初始化、无析构，跨静态初始化阶段也安全。
// ---------------------------------------------------------------------------
namespace {
const char*        g_jjLoadError    = "";
unsigned           g_jjFileHash     = 0;
unsigned           g_jjWantHash     = 0;
unsigned long long g_jjNetBytes     = 0;
char               g_jjNetPath[512] = {0};
}  // namespace

const char*        jj_last_network_load_error() { return g_jjLoadError; }
unsigned           jj_last_network_file_hash() { return g_jjFileHash; }
unsigned           jj_last_network_want_hash() { return g_jjWantHash; }
unsigned long long jj_last_network_bytes() { return g_jjNetBytes; }
const char*        jj_last_network_path() { return g_jjNetPath; }
"""

NETWORK_CPP_HEADER_OLD = """    if (!stream || version != Version)
        return false;"""

NETWORK_CPP_HEADER_NEW = """    // JJCheat: 拆开判断，把「读不出来」和「版本不符」区分开 —— 这两种
    // 在真机上的修法完全不同（前者查沙盒路径/解压，后者查权重与源码是否配套）。
    if (!stream)
    {
        g_jjLoadError = "header unreadable (file missing, empty or not zstd)";
        return false;
    }
    if (version != Version)
    {
        g_jjLoadError = "format Version mismatch (net file vs engine build)";
        return false;
    }"""

NETWORK_CPP_DESC_OLD = """        if (got != want)
            return false;
        remaining -= want;"""

NETWORK_CPP_DESC_NEW = """        if (got != want)
        {
            g_jjLoadError = "description truncated";
            return false;
        }
        remaining -= want;"""

NETWORK_CPP_READPARAMS_OLD = """bool Network::read_parameters(std::istream& stream, std::string& netDescription) {
    u32 hashValue;
    if (!read_header(stream, &hashValue, &netDescription))
        return false;
    if (hashValue != Network::hash)
        return false;
    if (!Detail::read_parameters(stream, featureTransformer))
        return false;
    for (usize i = 0; i < LayerStacks; ++i)
    {
        if (!Detail::read_parameters(stream, network[i]))
            return false;
    }
    return stream && stream.peek() == std::ios::traits_type::eof();
}"""

NETWORK_CPP_READPARAMS_NEW = """bool Network::read_parameters(std::istream& stream, std::string& netDescription) {
    u32 hashValue;
    g_jjLoadError = "";

    if (!read_header(stream, &hashValue, &netDescription))
    {
        if (*g_jjLoadError == '\\0')
            g_jjLoadError = "header rejected";
        return false;
    }

    // 文件里的架构哈希 vs 本引擎编出来的哈希：不一致就说明权重和源码不配套
    // （scripts/net.sh 拉的是滚动发布 master-net，而源码钉在某个 tag 上，
    //  这是本项目最可能踩的坑，所以把两个值都原样报出去）。
    g_jjFileHash = unsigned(hashValue);
    g_jjWantHash = unsigned(Network::hash);
    if (hashValue != Network::hash)
    {
        g_jjLoadError = "architecture hash mismatch (net not built for this engine)";
        return false;
    }

    if (!Detail::read_parameters(stream, featureTransformer))
    {
        g_jjLoadError = "feature-transformer parameters unreadable";
        return false;
    }
    for (usize i = 0; i < LayerStacks; ++i)
    {
        if (!Detail::read_parameters(stream, network[i]))
        {
            g_jjLoadError = "layer-stack parameters unreadable";
            return false;
        }
    }
    if (!stream || stream.peek() != std::ios::traits_type::eof())
    {
        g_jjLoadError = "trailing bytes or bad stream state";
        return false;
    }
    return true;
}"""

NETWORK_CPP_LOADEXT_OLD = """void Network::load_external(const fs::path& dir, const fs::path& evalfilePath, EvalFile& evalFile) {
    std::stringstream stream(read_compressed_nnue(dir / evalfilePath));
    auto              description = load(stream);
"""

NETWORK_CPP_LOADEXT_NEW = """void Network::load_external(const fs::path& dir, const fs::path& evalfilePath, EvalFile& evalFile) {
    const fs::path    full = dir / evalfilePath;
    std::stringstream stream(read_compressed_nnue(full));

    // 解压后剩多少字节，是判断「文件没找到 / 不是 zstd / 解压中途失败」最直接的证据。
    // read_compressed_nnue 任何失败都返回空 stream，这里就记 0。
    stream.seekg(0, std::ios::end);
    const std::streamoff sz = stream.tellg();
    stream.seekg(0, std::ios::beg);
    g_jjNetBytes = sz > 0 ? (unsigned long long) sz : 0ull;
    std::snprintf(g_jjNetPath, sizeof(g_jjNetPath), "%s", full.string().c_str());

    auto description = load(stream);
"""

NETWORK_CPP_VERIFY_OLD = """void Network::verify(const std::function<void(std::string_view)>& f,
                     const EvalFile&                              evalFile,
                     fs::path                                     evalfilePath) const {
    if (evalfilePath.empty())
        evalfilePath = evalFile.defaultName;

    if (evalFile.current != evalfilePath)
    {
        if (f)
        {
            std::string msg1 =
              "Network evaluation parameters compatible with the engine must be available.";
            std::string msg2 =
              "The network file " + evalfilePath.string() + " was not loaded successfully.";
            std::string msg3 = "The UCI option EvalFile might need to specify the full path, "
                               "including the directory name, to the network file.";
            std::string msg4 =
              "The default net can be downloaded from: "
              "https://github.com/official-pikafish/Networks/releases/download/master-net/"
              + std::string(evalFile.defaultName);
            std::string msg5 = "The engine will be terminated now.";

            std::string msg = "ERROR: " + msg1 + '\\n' + "ERROR: " + msg2 + '\\n' + "ERROR: " + msg3
                            + '\\n' + "ERROR: " + msg4 + '\\n' + "ERROR: " + msg5 + '\\n';

            f(msg);
        }

        exit(EXIT_FAILURE);
    }
"""

NETWORK_CPP_VERIFY_NEW = """bool Network::verify(const std::function<void(std::string_view)>& f,
                     const EvalFile&                              evalFile,
                     fs::path                                     evalfilePath) const {
    if (evalfilePath.empty())
        evalfilePath = evalFile.defaultName;

    if (evalFile.current != evalfilePath)
    {
        // JJCheat: 这里原本是 exit(EXIT_FAILURE)。我们是进程内引擎，
        // 那个 exit 会把宿主 App 一起拆掉（真机 .ips: thread 91 就停在这一行），
        // 然后把主线程渲染循环带崩。改成返回 false，由调用方跳过本次搜索。
        if (f)
        {
            char detail[768];
            std::snprintf(detail, sizeof(detail),
                          "JJ-NNUE FAIL reason=%s | path=%s | decompressed=%llu B | "
                          "fileHash=0x%08X engineHash=0x%08X | requested=%s",
                          g_jjLoadError[0] ? g_jjLoadError : "(unknown)", g_jjNetPath,
                          g_jjNetBytes, g_jjFileHash, g_jjWantHash,
                          evalfilePath.string().c_str());
            f(detail);
        }
        return false;
    }
"""

NETWORK_CPP_VERIFY_TAIL_OLD = """          + ", 1))");
    }
}"""

NETWORK_CPP_VERIFY_TAIL_NEW = """          + ", 1))");
    }

    return true;
}"""


# ---------------------------------------------------------------
# 3) engine.h / engine.cpp —— 校验失败只跳过搜索
# ---------------------------------------------------------------
ENGINE_H_OLD = "    void                                 verify_network() const;"
ENGINE_H_NEW = "    bool                                 verify_network() const;  // JJCheat: 原来是 void"

ENGINE_CPP_GO_OLD = """void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);
    verify_network();

    threads.start_thinking(pos, states, limits);
}"""

ENGINE_CPP_GO_NEW = """void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);

    // JJCheat: 网络没就绪时绝不能 start_thinking（评估会解引用未初始化的权重），
    // 也绝不能 exit（同进程，宿主 App 会一起死）。只跳过本次搜索。
    if (!verify_network())
    {
        if (onVerifyNetwork)
            onVerifyNetwork("JJ: NNUE not ready, search skipped (process kept alive)");
        return;
    }

    threads.start_thinking(pos, states, limits);
}"""

ENGINE_CPP_PERFT_OLD = """    verify_network();

    return Benchmark::perft(fen, depth);"""

ENGINE_CPP_PERFT_NEW = """    if (!verify_network())
        return u64(0);

    return Benchmark::perft(fen, depth);"""

ENGINE_CPP_VERIFY_HEAD_OLD = """void Engine::verify_network() const {
    const auto file = path_from_utf8(std::string(options["EvalFile"]));
    network->verify(onVerifyNetwork, networkFile, file);"""

ENGINE_CPP_VERIFY_HEAD_NEW = """bool Engine::verify_network() const {
    const auto file = path_from_utf8(std::string(options["EvalFile"]));
    const bool ok   = network->verify(onVerifyNetwork, networkFile, file);"""

ENGINE_CPP_VERIFY_CALL_OLD = """        onVerifyNetwork(message);
    }
}"""

ENGINE_CPP_VERIFY_CALL_NEW = """        if (onVerifyNetwork)
            onVerifyNetwork(message);
    }

    return ok;
}"""


def main():
    if len(sys.argv) < 2:
        print("用法: patch-engine.py <pikafish src 目录>", file=sys.stderr)
        return 2
    src = pathlib.Path(sys.argv[1])
    if not (src / "engine.cpp").is_file():
        print(f"!! {src}/engine.cpp 不存在", file=sys.stderr)
        return 2

    print(f"{MARK} 目标源码: {src}")

    patch(src / "nnue" / "network.h", "network.h", [
        (NETWORK_H_VERIFY_OLD, NETWORK_H_VERIFY_NEW),
        (NETWORK_H_NS_END_OLD, NETWORK_H_ACCESSORS),
    ])

    patch(src / "nnue" / "network.cpp", "network.cpp", [
        (NETWORK_CPP_INCLUDE_OLD, NETWORK_CPP_INCLUDE_NEW),
        (NETWORK_CPP_GLOBALS_OLD, NETWORK_CPP_GLOBALS_NEW),
        (NETWORK_CPP_HEADER_OLD, NETWORK_CPP_HEADER_NEW),
        (NETWORK_CPP_DESC_OLD, NETWORK_CPP_DESC_NEW),
        (NETWORK_CPP_READPARAMS_OLD, NETWORK_CPP_READPARAMS_NEW),
        (NETWORK_CPP_LOADEXT_OLD, NETWORK_CPP_LOADEXT_NEW),
        (NETWORK_CPP_VERIFY_OLD, NETWORK_CPP_VERIFY_NEW),
        (NETWORK_CPP_VERIFY_TAIL_OLD, NETWORK_CPP_VERIFY_TAIL_NEW),
    ])

    patch(src / "engine.h", "engine.h", [
        (ENGINE_H_OLD, ENGINE_H_NEW),
    ])

    patch(src / "engine.cpp", "engine.cpp", [
        (ENGINE_CPP_GO_OLD, ENGINE_CPP_GO_NEW),
        (ENGINE_CPP_PERFT_OLD, ENGINE_CPP_PERFT_NEW),
        (ENGINE_CPP_VERIFY_HEAD_OLD, ENGINE_CPP_VERIFY_HEAD_NEW),
        (ENGINE_CPP_VERIFY_CALL_OLD, ENGINE_CPP_VERIFY_CALL_NEW),
    ])

    if errors:
        print(f"\n{MARK} 失败 {len(errors)} 处：", file=sys.stderr)
        for e in errors:
            print(f"  !! {e}", file=sys.stderr)
        print("\n源码结构与补丁预期不符 —— 拒绝继续构建。", file=sys.stderr)
        return 1

    print(f"{MARK} 全部补丁就位")
    return 0


if __name__ == "__main__":
    sys.exit(main())
