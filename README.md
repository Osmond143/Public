# VEspProbe — 编译说明（GitHub Actions）

一个最小的 iOS app，用来在 iPad 上验证 DarkSword 的 KRW 通道并扫描无畏手游的偏移。

---

## 一、你要做的（大约 10 分钟）

### 1. 建一个 GitHub 仓库

```
名字随便，比如 vesp-probe，Private 或 Public 都行
```

### 2. 把 `app/` 目录**里面的内容**推上去

**注意**：GitHub Actions 的 workflow 必须在仓库根目录的 `.github/workflows/`，
所以推的是 `app/` 里面的东西，不是整个 `app/` 文件夹。

```bash
cd F:\Deepseek\dshwork\valorant_mobile\app
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/<你的用户名>/vesp-probe.git
git push -u origin main
```

推完之后仓库根目录应该是这样：

```
.github/workflows/build-ipa.yml
Sources/
project.yml
README.md
```

### 3. 等 Actions 跑完

```
GitHub → 你的仓库 → Actions 标签 → build-ipa
第一次大约 5~8 分钟（要装 xcodegen）
```

### 4. 下载产物

```
Actions 运行页 → 底部 Artifacts → VEspProbe-ipa
解压得到 VEspProbe.ipa
```

### 5. 用全力签/全能签签名装到 iPad

```
选 p12 + mobileprovision（就是之前那两个文件）
给他 VEspProbe.ipa
签名 → 安装
```

**bundle id** 记得改成一个没占用的，比如 `com.vesp.probe`（或者让签名工具自动改）。

---

## 二、装上之后

打开 app，会看到一个「运行探测」按钮和一个日志框。

点一下，会输出：

```
uid=501  pid=xxxxx
设备: iPad 18.6.2

--- 候选枚举 ---
  [image] /var/containers/Bundle/Application/.../VEspProbe.app/VEspProbe  base=0x...
  [file] /var/mobile/Library/Preferences/com.okdemo.dskrw.rw.plist

--- 尝试连接 ---
status=4  bootstrap_look_up(com.okdemo.dskrw.rw) 失败: ...
```

**把这段日志发回来**，我根据它判断：

- 服务能不能 lookup 到
- token 在不在那些路径
- 需不需要 entitlement

---

## 三、现在这个版本能干什么 / 不能干什么

| 能力 | 状态 |
|---|---|
| 编译、签名、装到 iPad | ✅ 现在就能 |
| 枚举 dskrw 相关痕迹 | ✅ 现在就能 |
| 尝试 lookup 服务 | ✅ 现在就能 |
| **真正读写内存** | ❌ 等 M1（协议还没挖出来） |

`ProbeClient.m` 里的 `read:` / `write:` 现在是空壳，
等我把 `com.okdemo.dskrw.rw` 的 mach_msg 协议挖出来，把那两个函数填上就行。

---

## 四、代码结构

```
app/
├── .github/workflows/build-ipa.yml    GitHub Actions（macos-14 编译）
├── project.yml                        XcodeGen 工程描述
└── Sources/
    ├── main.m                         UIApplicationMain
    ├── AppDelegate.h/.m               窗口
    ├── ProbeViewController.h/.m       界面：按钮 + 日志
    ├── ProbeClient.h/.m               连 KRW 服务（协议待填）
    ├── DumpOffsets.h/.c               偏移扫描（纯 C）
    └── Info.plist
```

`DumpOffsets.c` 是平台无关的纯逻辑，跟 PC 侧那份 `dump_offsets.cpp` 一一对应，
只把「内核读」抽象成函数指针 `krw_read_fn`。

---

## 五、常见问题

**Q: Actions 报 xcodegen not found**
```
brew install xcodegen 这一步失败的话，看看 log，通常是 runner 镜像的问题。
换 macos-15 试试（改 workflow 里的 runs-on）。
```

**Q: 编译报 `sandbox_extension_consume` 未定义**
```
它是私有 API，需要自己声明：
  extern int sandbox_extension_consume(const char *);
我已经在 ProbeClient.m 里声明了，不用改。
```

**Q: 装上去闪退**
```
多半是签名 entitlements 不匹配。让全能签自动处理，别手改。
```

**Q: 点按钮没反应**
```
日志框在下面，往下滚。同时 Xcode → Window → Devices 可以看 Console。
```
