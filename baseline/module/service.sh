#!/system/bin/sh
# 模块开机钩子：KernelSU / Magisk 在 late_start 执行本文件（不带参数）
#
# 真正的执行者是 /data/local/dsh/service.sh（ADR-013）；这里只转交，不复制任何逻辑。
# 找不到执行者说明 install.sh 没跑成 —— 静默退出，别把 boot 卡住。

DSH_ROOT=${DSH_ROOT:-/data/local/dsh}

[ -x "$DSH_ROOT/service.sh" ] || exit 1
exec "$DSH_ROOT/service.sh" boot
