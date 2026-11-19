//
//  JJRootPath.h
//  JJCheat —— roothide 的 jbroot() 运行时解析（2.0.0r2）
//
//  为什么不再 #import <roothide.h> + 直呼 jbroot()：
//    theos 构建里是靠 `JJCheat_LIBRARIES = roothide` 链接 libroothide 才拿到这个
//    符号的。Dylix（手机端自建工程）没有这份 stub 库，一链接就 undefined symbol
//    `_jbroot`，整个包出不来 —— 而 jbroot 只用来拼三条「非主路径」的备选地址。
//
//  改成运行时 dlsym：
//    roothide 环境里 libroothide 早已随注入加载进本进程，RTLD_DEFAULT 一定能取到，
//    行为与直接调用完全一致；取不到（rootless / rootful / Dylix 自建包）就返回 nil，
//    调用方原样跳过这一块即可 —— 主路径是 App 沙箱内的容器文件，不依赖 jbroot。
//
//  用 header-only 的 static inline 而不是新加一个 .m：
//    Dylix 的工程文件列表要在手机上手动维护，多一个 .m 就多一处漏加导致
//    undefined symbol 的机会；放进头文件里零配置。
//

#ifndef JJRootPath_h
#define JJRootPath_h

#import <Foundation/Foundation.h>
#import <dlfcn.h>

/* 把 jbroot 内的绝对路径映射成当前越狱环境的真实路径。
   path 传入形如 @"/Library/Application Support/JJCheat/xxx"（以 / 开头）。
   返回 nil = 当前进程没有 roothide（调用方必须判空，不要直接 addObject:）。 */
static inline NSString *JJResolveRootPath(NSString *path) {
    if (!path.length) return nil;
    typedef NSString *(*JJJbrootFn)(NSString *);
    /* 每个编译单元各有一份缓存：只在首次调用查一次符号表，之后直接复用。
       没有加锁 —— 最坏情况是两个线程同时查一次 dlsym，结果相同且幂等。 */
    static JJJbrootFn fn = NULL;
    static BOOL looked = NO;
    if (!looked) {
        looked = YES;
        fn = (JJJbrootFn)dlsym(RTLD_DEFAULT, "jbroot");
        if (!fn) {
            NSLog(@"[JJCheat] 未找到 jbroot 符号（非 roothide 环境），跳过该路径");
        }
    }
    return fn ? fn(path) : nil;
}

#endif /* JJRootPath_h */
