#!/system/bin/sh
# install.sh —— 安装期钩子（由 customize.sh source；ADR-017 / ADR-018 的安装期约定）
#
# 职责：
#   1) 拒绝降级（ADR-018：versionCode 严格小于已装版本 → 拒绝）
#   2) 把壳（service.sh / dsh-ctl / lib）与 manifest 落到 DSH_ROOT
#   3) 只建空目录，绝不碰已有数据（ADR-017 决定 C 的红线）
#
# 测试缝：DSH_ROOT / DSH_MODULES_DIR 只在本地测试里覆盖；真机上用默认值。

DSH_ROOT=${DSH_ROOT:-/data/local/dsh}
DSH_MODULES_DIR=${DSH_MODULES_DIR:-/data/adb/modules}

abort() { echo "! $*" >&2; exit 1; }

[ -n "${MODPATH:-}" ] || abort "install.sh: 需要 MODPATH（应被 customize.sh source）"
[ -f "$MODPATH/module.prop" ] || abort "install.sh: 找不到 module.prop"

_old_prop="$DSH_MODULES_DIR/$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1)/module.prop"
if [ -f "$_old_prop" ]; then
    _old=$(sed -n 's/^versionCode=//p' "$_old_prop" | head -n1)
    _new=$(sed -n 's/^versionCode=//p' "$MODPATH/module.prop" | head -n1)
    case $_old in ''|*[!0-9]*) _old= ;; esac
    case $_new in ''|*[!0-9]*) _new= ;; esac
    if [ -n "$_old" ] && [ -n "$_new" ] && [ "$_new" -lt "$_old" ]; then
        abort "拒绝降级：已装 versionCode=$_old，本包 versionCode=$_new（ADR-018：降级只能卸载后重装）"
    fi
fi

mkdir -p "$DSH_ROOT/lib" || abort "建目录失败: $DSH_ROOT"
cp -f "$MODPATH/bin/service.sh" "$DSH_ROOT/service.sh" || abort "复制 service.sh 失败"
cp -f "$MODPATH/bin/dsh-ctl" "$DSH_ROOT/dsh-ctl" || abort "复制 dsh-ctl 失败"
cp -f "$MODPATH/lib/semver-gate.sh" "$DSH_ROOT/lib/semver-gate.sh" || abort "复制 semver-gate.sh 失败"
cp -f "$MODPATH/manifest.json" "$DSH_ROOT/manifest.json" || abort "复制 manifest.json 失败"
chmod 0755 "$DSH_ROOT/service.sh" "$DSH_ROOT/dsh-ctl"
chmod 0644 "$DSH_ROOT/lib/semver-gate.sh" "$DSH_ROOT/manifest.json"

mkdir -p "$DSH_ROOT/state" "$DSH_ROOT/base" "$DSH_ROOT/inbox" "$DSH_ROOT/run" "$DSH_ROOT/log"
chmod 0700 "$DSH_ROOT/run" "$DSH_ROOT/log" 2>/dev/null || true

echo "- 壳已落到 $DSH_ROOT（version=$(sed -n 's/^version=//p' "$MODPATH/module.prop" | head -n1)）"
echo "- 重启后由模块 service.sh 转交 /data/local/dsh/service.sh boot；现在可先跑 dsh-ctl status"
