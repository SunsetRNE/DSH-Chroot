#!/system/bin/sh
# customize.sh —— 模块安装钩子（KernelSU / Magisk 的安装器会 source 本文件）
#
# 这里只做转交：真正的安装逻辑在 install.sh（ADR-018 的"安装期拒绝降级"也在那儿）。
# 保持壳只有一份逻辑，避免"管理器装"与"恢复模式装"走两套。

[ -n "${MODPATH:-}" ] || { echo "! customize.sh: 安装器未提供 MODPATH" >&2; exit 1; }
. "$MODPATH/install.sh"
