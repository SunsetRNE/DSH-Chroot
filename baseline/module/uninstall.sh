#!/system/bin/sh
# uninstall.sh —— 卸载钩子（ADR-017）
#
# ADR-017 决定 C 第 4 条明确：uninstall.sh 的确切执行时机尚待确认，
# 「不确定时只写标记不删数据」。所以第一版只做两件事：
#   1) 尽力停掉在跑的实例
#   2) 把"还剩什么"如实打出来（退出码 0 = 没有可清理的在跑进程）
#
# 真正的"卸载即清空模块域"留给 dsh-ctl purge（尚未实现），见 docs/module.md。

DSH_ROOT=${DSH_ROOT:-/data/local/dsh}

if [ -x "$DSH_ROOT/service.sh" ]; then
    "$DSH_ROOT/service.sh" stop >/dev/null 2>&1 || true
fi

echo "DSH_CHROOT_UNINSTALL residual=$DSH_ROOT"
echo "- 模块域 $DSH_ROOT 仍然保留（ADR-017 决定 C 第 4 条：删除时机未确认前不删数据）"
echo "- 用户空间 /sdcard/Download/dsh/ 未被触碰"
exit 0
