#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在本地把 libhook.dylib 注入到无畏契约（CodeV）的 IPA 里
输出一个新的可签名 IPA

用法：
    python inject_ipa.py <原版.ipa> <libhook.dylib> <输出.ipa>

要求：
    pip install lief

特点：
    流式处理，不会把 3.5 GB 一次性读进内存
    只重写 Payload/CodeV.app/CodeV 这一个条目
"""
import os
import sys
import shutil
import zipfile
import stat
import tempfile

DYLIB_NAME = "libhook.dylib"
LOAD_PATH = "@executable_path/" + DYLIB_NAME
EXE_ENTRY = "Payload/CodeV.app/CodeV"


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)

    src_ipa, dylib, out_ipa = sys.argv[1], sys.argv[2], sys.argv[3]
    for f in (src_ipa, dylib):
        if not os.path.isfile(f):
            raise SystemExit("文件不存在: %s" % f)
        print("  %s  %.1f MB" % (f, os.path.getsize(f) / 1048576))

    try:
        import lief
    except ImportError:
        raise SystemExit("缺 lief，先跑: pip install lief")

    # 1) 用 lief 给 CodeV 主程序加 LC_LOAD_DYLIB（先解到临时文件）
    tmpdir = tempfile.mkdtemp(prefix="codev_inject_")
    exe_path = os.path.join(tmpdir, "CodeV")

    print("\n[1/3] 从 IPA 里解出 CodeV 主程序 ...")
    with zipfile.ZipFile(src_ipa) as zin:
        try:
            info = zin.getinfo(EXE_ENTRY)
        except KeyError:
            raise SystemExit("IPA 里找不到 %s" % EXE_ENTRY)
        print("      %s  %.1f MB" % (EXE_ENTRY, info.file_size / 1048576))
        with zin.open(info) as fsrc, open(exe_path, "wb") as fdst:
            shutil.copyfileobj(fsrc, fdst, 1024 * 1024)

    print("\n[2/3] 给主程序加 LC_LOAD_DYLIB ...")
    b = lief.parse(exe_path)
    if b is None:
        raise SystemExit("lief 解析 CodeV 失败")

    have = any(DYLIB_NAME in getattr(lib, "name", "") for lib in b.libraries)
    if have:
        print("      已经有 %s，跳过" % DYLIB_NAME)
    else:
        b.add_library(LOAD_PATH)
        print("      已添加: %s" % LOAD_PATH)
        b.write(exe_path)
        print("      写回完成: %.1f MB" % (os.path.getsize(exe_path) / 1048576))

    # 2) 重新打包（流式）
    print("\n[3/3] 重新打包 IPA（3.5 GB，需要几分钟）...")
    if os.path.exists(out_ipa):
        os.remove(out_ipa)

    with zipfile.ZipFile(src_ipa) as zin, \
         zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as zout:

        total = len(zin.infolist())
        for idx, info in enumerate(zin.infolist(), 1):
            name = info.filename
            if name.endswith("/"):
                continue

            zi = zipfile.ZipInfo(name, date_time=info.date_time)
            mode = (info.external_attr >> 16) & 0o777
            if not mode:
                mode = 0o644
            zi.external_attr = (stat.S_IFREG | mode) << 16
            zi.compress_type = zipfile.ZIP_STORED if name.endswith((".mp4", ".mp3", ".car")) else zipfile.ZIP_DEFLATED

            if name == EXE_ENTRY:
                # 用改过的版本
                with open(exe_path, "rb") as f:
                    zout.writestr(zi, f.read())
                print("      [%d/%d] %s  <- 已替换" % (idx, total, name))
            else:
                with zin.open(info) as fsrc:
                    zout.writestr(zi, fsrc.read())
                if idx % 50 == 0:
                    print("      [%d/%d] ..." % (idx, total))

        # 加 dylib
        zi = zipfile.ZipInfo("Payload/CodeV.app/" + DYLIB_NAME, date_time=(2026, 1, 1, 0, 0, 0))
        zi.external_attr = (stat.S_IFREG | 0o755) << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(dylib, "rb") as f:
            zout.writestr(zi, f.read())
        print("      [+] Payload/CodeV.app/%s" % DYLIB_NAME)

    shutil.rmtree(tmpdir, ignore_errors=True)

    print("\n完成: %s  (%.1f MB)" % (out_ipa, os.path.getsize(out_ipa) / 1048576))
    print("""
下一步：
  1. 用全能签导入 p12 + mobileprovision
  2. 选这个 IPA 签名
  3. 装到 iPad
  4. 打开游戏，等 12 秒
  5. 日志写到 /var/mobile/Documents/vesp_license.log
""")


if __name__ == "__main__":
    main()
