# JJCheat · roothide 适配版

上游工程：[lichengyang51/jjcheat](https://github.com/lichengyang51/jjcheat) → `ios/tweak/`（越狱 Tweak 路线）

本仓库只做**适配与云编译**，`Tweak.xm / JJController.m / JJEngineBridge.m / JJScreenGrabber.m / JJHUDWindow.m` 与上游**完全一致，零改动**。

- 设备：iPhone 13 Pro Max / iOS 15.1 / **roothide 越狱**（Bootstrap）
- 目标 App Bundle ID：`cn.jj.chinachess`
- 产物：`com.fujiang.jjcheat_1.0.1_iphoneos-arm64e.deb`

---

## 一、适配改了什么（只有构建/打包层）

| 位置 | 改动 | 原因 |
|---|---|---|
| `ios/tweak/Makefile` | 新增 `THEOS_PACKAGE_SCHEME = roothide` | roothide 的 dylib 必须用 `@loader_path/.jbroot/...` 作为 install_name；没有这一行编出来的包在 roothide 上 dyld 直接找不到依赖 |
| `ios/tweak/Makefile` | `TARGET := iphone:clang:16.5:14.0`（沿用上游）+ 保留 `-I$(THEOS_PROJECT_DIR)/include` | CI 里补了 theos 的 16.5 SDK，和上游编译环境一致；`include/IOSurface` 是手写的最小私有头（iOS SDK 只有二进制没有头文件） |
| `ios/tweak/Makefile` | `DISABLE_ROOTLESS_COMPAT_WARNING = 1` | 消掉 roothide/theos 的 rootless 兼容告警（本工程不用 `/var/jb` 宏） |
| `ios/tweak/control` | `Architecture: iphoneos-arm64e`，`Version: 1.0.1` | roothide 的包架构名；版本号区分上游 rootful 包 |
| `ios/tweak/JJCheat.plist` | 过滤列表加入 `cn.jj.chinachess` | 你的 JJ象棋 实际包名 |
| `ios/tweak/postinst` + `layout/usr/bin/jjcheat-fix` | 新增 | 解决 engine.js 在 roothide 里找不到的问题（见第二节） |
| `ios/tweak/prerm` | 新增 | 卸载时把塞进 .app 的 engine.js 撤掉 |
| `.github/workflows/build-roothide-deb.yml` | 新增 | macOS runner + roothide/theos 云编译 |

引擎内核 `src/` 与打包器 `tools/bundle.js` 原样搬过来，CI 里用 `node tools/bundle.js` 生成 `dist/engine.js`（这一步是上游原有流程）。

---

## 二、roothide 上最关键的坑：engine.js 路径

上游 Tweak 加载引擎的顺序（`JJEngineBridge.m` 的 `locateEngineScript`，源码没动）：

1. `/var/jb/Library/Application Support/JJCheat/engine.js`  ← rootless 路径
2. `/Library/Application Support/JJCheat/engine.js`        ← rootful / jbroot 路径
3. `[[NSBundle mainBundle] pathForResource:@"engine" ofType:@"js"]`  ← 目标 App 的 .app 根目录

roothide 把越狱根（jbroot）随机化到 `/var/containers/Bundle/Application/.jbroot-XXXXXXXX/`，
并且**不给注入进程做透明的路径映射**（官方做法是让代码里调 `jbroot()`）。
所以第 1、2 条在 roothide 上都会 `ENOENT` —— deb 里那份 engine.js 装进了 jbroot，但 Tweak 用 Foundation 的
`fileExistsAtPath:` 去查 `/Library/...`，那是系统根目录，压根没有。

既然不改源码，就走作者自己留的**第 3 条回退**：把 `engine.js` 复制到目标 App 的 `.app` 里。

- `postinst` 安装时自动做一次（扫 `/rootfs/var/containers/Bundle/Application/*/*.app`，用 `Info.plist` 里的 bundle id 匹配）
- App Store 更新/重装 JJ象棋 会把 `.app` 换掉，engine.js 随之丢失 → 重新跑一次修复：

```sh
jjcheat-fix        # 在越狱 shell（NewTerm / SSH）里，root 身份
jjcheat-fix -v     # 想看扫描过程
```

`.app` 里只多一个 `engine.js`（0644），不动可执行文件、不动 Info.plist，不影响签名校验；
卸载时 `prerm` 会把它删掉（仅当内容与本包一致）。

> 顺带说明：deb 里同时保留了一份 `<jbroot>/Library/Application Support/JJCheat/engine.js`。
> 以后若把 Tweak 改成 `jbroot()` 写法，或改用 symredirect/libvroot 方案，这份就能直接生效。

---

## 三、云编译

仓库 → **Actions** → 左侧 `build-roothide-deb` → **Run workflow**（`main` 分支）。

流水线做的事：

1. `git clone --recursive https://github.com/roothide/theos.git`（**必须是 roothide 版 theos**，官方 theos 没有 `roothide` 打包方案）
2. `brew install ldid dpkg`
3. `node tools/bundle.js` → 写入 `ios/tweak/layout/Library/Application Support/JJCheat/engine.js`
4. `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide`
   - `dpkg-deb` 用包装脚本加 `--root-owner-group`（macOS 没有 fakeroot，否则包内属主会是 runner 用户）
   - 压缩用 `xz`（设备端 dpkg/Sileo 都吃，比 lzma 稳）
5. 校验：解包检查 `JJCheat.dylib` / `JJCheat.plist` / `engine.js` / `jjcheat-fix`，
   `otool -D` 确认 install_name 是 `@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/JJCheat.dylib`
6. 产物：`JJCheat-roothide-deb` artifact + Release 附件（手机浏览器直接下 deb 最省事）

---

## 四、安装

1. **Bootstrap → App List → 打开 JJ象棋（cn.jj.chinachess）的注入开关**（roothide 默认不注入任何第三方 App，这步不做 Tweak 根本不会加载）
2. 装 deb：Sileo/Zebra 点开安装；或 Filza 点 deb 选 Install；或命令行
   ```sh
   dpkg -i com.fujiang.jjcheat_1.0.1_iphoneos-arm64e.deb
   ```
3. postinst 会自动把 engine.js 写进 `.app`；如果那时 App 还没装好，装完 App 后执行 `jjcheat-fix`
4. 完全退出 JJ象棋再启动（必要时 `killall -9 SpringBoard`）

## 五、验证 / 排错

```sh
# 1) Tweak 有没有被注入（能看到 [JJCheat] tweak 已加载 就对了）
log stream --predicate 'eventMessage CONTAINS "[JJCheat]"' --style compact

# 2) engine.js 到底找没找到，看这两行
#    [JJCheat] engine.js 加载成功   ← 成功
#    [JJCheat] 找不到 engine.js ...  ← 失败，跑 jjcheat-fix

# 3) 抓帧通道（三选一，自动降级）
#    [JJCheat] CARenderServer: render=... port=... usable=1
```

常见问题：

- **游戏里没有任何反应**：Bootstrap App List 的注入开关没开 / 没重启 App。
- **日志有 tweak 已加载但没有引擎日志**：engine.js 没进 `.app` → `jjcheat-fix -v`。
- **引擎加载成功但识别乱**：四点标定没做（上游逻辑：进棋盘界面后标定一次，结果存 `NSUserDefaults`）。
- **游戏白屏/闪退**：把 `.app` 里的 `engine.js` 删掉恢复原状（`rm <App>.app/engine.js`），并把日志发出来。

## 六、卸载

```sh
dpkg -r com.fujiang.jjcheat
```
`prerm` 会删掉注入的 `engine.js`；`/Library/Application Support/JJCheat/` 与偏好设置可用 `jjcheat` 相关 key 手动清。
