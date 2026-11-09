# 不死鸟 HUD 卡密 hook —— 编译与使用

给无畏契约手游（CodeV）注入一个 dylib，hook 掉「不死鸟 HUD」的卡密验证。

---

## 一、原理

`tgpa_wrapper.framework` 里是挂的代码，卡密验证流程：

```
UITextField 输入卡密
  → -confirmButtonTapped
  → URLWithString: + JSONObjectWithData:  (网络验证)
  → 成功 → 调用 _onConfirm block
  → 失败 → 弹窗
```

**hook 策略**（全部用 `method_setImplementation`，不改代码段）：

| hook 点 | 作用 |
|---|---|
| `江雪 -setOnConfirm:` | 把验证成功的 block 存下来 |
| `江雪 -confirmButtonTapped` | 点确认时**直接调用**存下的 block，跳过网络验证 |
| `-stringForKey:` | 兜底，打印读到的键名和值（诊断用） |

**不需要 inline hook、不需要内核读写、不需要越狱。**

---

## 二、三步走

### 第 1 步：推 GitHub，拿 libhook.dylib

把 `app/` 里的内容推到仓库，Actions 跑 `build-hook-dylib`。

跑完 → Artifacts → **libhook-dylib** → 下载解压得到 `libhook.dylib`（几十 KB）。

### 第 2 步：本地注入

```
pip install lief
python tools/inject_ipa.py "<原版无畏契约.ipa>" "<libhook.dylib>" "CodeV_injected.ipa"
```

输入必须是**原版** `无畏契约：源能行动.ipa`（3.56 GB），
不是不死鸟改过的包。我们的 hook 只需要 CodeV 加载 libhook.dylib，
tgpa_wrapper 里的挂代码不动它——等游戏跑起来，dylib 会去 hook 它。

3.5 GB 处理需要几分钟，脚本流式复制，不会爆内存。

### 第 3 步：签名装

```
全能签 → p12 + mobileprovision → 选 CodeV_injected.ipa → 签名 → 装 iPad
```

---

## 三、跑起来看什么

游戏加载后 12 秒弹 alert：

```
license hook
[license] dylib loaded, pid=xxxx
类总数: 2500
发现类: 江雪
  hook setOnConfirm:
  hook confirmButtonTapped:
  hook NSUserDefaults stringForKey:
完成: setOnConfirm=1 confirm=1 stringForKey=1
日志: /var/mobile/Containers/.../tmp/vesp_license.log
```

**A. 三个 hook 都成功** → 进游戏，随便输卡密点确认，应该直接进。

**B. 发现类但没 hook** → 类名可能改了，把 alert 发我。

**C. 没弹 alert** → dylib 没加载，注入失败。

---

## 四、如果 A 也不进

说明 `_onConfirm` 不是「进游戏的开关」。那时日志里的 `stringForKey:` 就有用了，
它会打印验证状态的键名和值，可以直接往 UserDefaults 写。

把弹窗内容发我。

---

## 五、文件

```
app/
├── .github/workflows/build-ipa.yml   编译 libhook.dylib
├── project.yml                       XcodeGen（library.dynamic）
├── Sources/
│   ├── hook_license.m                ★ 核心：卡密 hook
│   ├── ProbeClient.h/.m              （给 Via 用的，一起编译，不影响）
│   └── DumpOffsets.c/.h              （同上）
└── tools/
    └── inject_ipa.py                 ★ 本地注入
```
