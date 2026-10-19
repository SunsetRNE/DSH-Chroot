#!/system/bin/sh
# customize.sh —— 模块安装钩子（KernelSU / Magisk 的安装器 source 本文件）
#
# 为什么逻辑全在这里、而不是单独一个 install.sh：
#   Magisk / KernelSU 的安装器用「包根是否存在 install.sh」判断 legacy 模块；
#   命中就只解压 module.prop / install.sh / uninstall.sh / common/*（见 KernelSU installer.sh
#   的 is_legacy_script），不会解 bin/ 与 lib/ —— 于是 install.sh 在空 MODPATH 里必然失败。
#   坑记在 docs/pitfalls.md A23。
#
# 职责：
#   1) 拒绝降级（ADR-018：versionCode 严格小于已装版本 → 拒绝）
#   2) 把壳（service.sh / dsh-ctl / lib）与 manifest 落到 DSH_ROOT
#   3) 只建空目录，绝不碰已有数据（ADR-017 决定 C 的红线）
#
# 测试缝：DSH_ROOT / DSH_MODULES_DIR 只在本地测试里覆盖；真机上用默认值。

DSH_ROOT=${DSH_ROOT:-/data/local/dsh}
DSH_MODULES_DIR=${DSH_MODULES_DIR:-/data/adb/modules}

_fail() {
    if command -v abort >/dev/null 2>&1; then
        abort "$@"
    fi
    echo "! $*" >&2
    exit 1
}

[ -n "${MODPATH:-}" ] || _fail "customize.sh: 安装器未提供 MODPATH"
[ -f "$MODPATH/module.prop" ] || _fail "customize.sh: 找不到 module.prop"

# 安装器解包后会把所有文件设成 0644，这里补回可执行位（开机钩子 / 卸载钩子）
set_perm 0 0 0755 "$MODPATH/service.sh" 2>/dev/null || chmod 0755 "$MODPATH/service.sh" 2>/dev/null || true
set_perm 0 0 0755 "$MODPATH/uninstall.sh" 2>/dev/null || chmod 0755 "$MODPATH/uninstall.sh" 2>/dev/null || true

_old_prop="$DSH_MODULES_DIR/$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1)/module.prop"
if [ -f "$_old_prop" ]; then
    _old=$(sed -n 's/^versionCode=//p' "$_old_prop" | head -n1)
    _new=$(sed -n 's/^versionCode=//p' "$MODPATH/module.prop" | head -n1)
    case $_old in ''|*[!0-9]*) _old= ;; esac
    case $_new in ''|*[!0-9]*) _new= ;; esac
    if [ -n "$_old" ] && [ -n "$_new" ] && [ "$_new" -lt "$_old" ]; then
        _fail "拒绝降级：已装 versionCode=$_old，本包 versionCode=$_new（ADR-018：降级只能卸载后重装）"
    fi
fi

mkdir -p "$DSH_ROOT/lib" || _fail "建目录失败: $DSH_ROOT"
cp -f "$MODPATH/bin/service.sh" "$DSH_ROOT/service.sh" || _fail "复制 service.sh 失败"
cp -f "$MODPATH/bin/dsh-ctl" "$DSH_ROOT/dsh-ctl" || _fail "复制 dsh-ctl 失败"
cp -f "$MODPATH/lib/semver-gate.sh" "$DSH_ROOT/lib/semver-gate.sh" || _fail "复制 semver-gate.sh 失败"
cp -f "$MODPATH/manifest.json" "$DSH_ROOT/manifest.json" || _fail "复制 manifest.json 失败"
chmod 0755 "$DSH_ROOT/service.sh" "$DSH_ROOT/dsh-ctl"
chmod 0644 "$DSH_ROOT/lib/semver-gate.sh" "$DSH_ROOT/manifest.json"

mkdir -p "$DSH_ROOT/state" "$DSH_ROOT/base" "$DSH_ROOT/inbox" "$DSH_ROOT/run" "$DSH_ROOT/log"
chmod 0700 "$DSH_ROOT/run" "$DSH_ROOT/log" 2>/dev/null || true

echo "- 壳已落到 $DSH_ROOT（version=$(sed -n 's/^version=//p' "$MODPATH/module.prop" | head -n1)）"
echo "- 重启后由模块 service.sh 转交 /data/local/dsh/service.sh boot；现在可先跑 dsh-ctl status"
