#!/system/bin/sh
# service.sh —— 壳的**唯一执行者**（ADR-013 决定 A）
#
# 动词: boot | start | stop | restart | status | bootstrap [--offline] | install <file> | logs [--tail N] | help
# 退出码: 0 成功 · 10 已是当前状态 · 20 停止失败 · 30 payload 缺失/校验失败 · 40 切换失败 · 50 版本闸门拒绝
#
# 契约（ADR-013 决定 B）:
#   ① 非交互（stdin 钉 /dev/null）② 环境钉死 ③ 幂等 ④ 先停后换 ⑤ 默认离线 ⑥ 状态+标记+退出码
#
# 版本闸门（ADR-026）:
#   判定 = lib/semver-gate.sh 的 semver_decide（纯函数，不读盘）
#   处置 = 本文件：低于 floor 先试回落 baked，回落不了才 50；alpha 只标记安全模式
#
# 两层布局（research §4.2；2026-10-18 裁决：两层优于单层）:
#   base/node/             Node 层（node + npm + pnpm），不随 DSH 版本变
#   base/dsh-<baked>/      DSH 层（dsh 树 + bin wrapper），每个 baked 一份
#   active                 一行：DSH 层名（= payload 的 baked）
#   inbox/                 node-<ver>.tar.gz + node.json · dsh-<baked>.tar.gz + dsh.json
#
# 测试缝（只给 tools/test-service.sh 用）: DSH_ROOT / DSH_RUNTIME=fake / DSH_FAULT=stop|switch

exec 0</dev/null
set -u

if [ -d /system/bin ]; then
    PATH=/system/bin:/data/adb/ksu/bin
else
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fi
# 测试缝：容器里若同时存在 /system/bin（本容器就跑在手机上），强制用宿主工具集，避免每个命令都走 Android toybox
if [ -n "${DSH_PATH_OVERRIDE:-}" ]; then PATH="$DSH_PATH_OVERRIDE"; fi
export PATH
unset CDPATH ENV 2>/dev/null || true

DSH_ROOT=${DSH_ROOT:-/data/local/dsh}
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
STATE_DIR="$DSH_ROOT/state"
BASE_DIR="$DSH_ROOT/base"
INBOX_DIR="$DSH_ROOT/inbox"
RUN_DIR="$DSH_ROOT/run"
LOG_DIR="$DSH_ROOT/log"
ACTIVE_FILE="$DSH_ROOT/active"
PID_FILE="$RUN_DIR/dsh.pid"
BOOT_FILE="$RUN_DIR/bootstrap.json"
LOG_FILE="$LOG_DIR/service.log"
NODE_DIR="$BASE_DIR/node"
DSH_RUNTIME=${DSH_RUNTIME:-fake}
DSH_FAULT=${DSH_FAULT:-}

mkdir -p "$STATE_DIR" "$BASE_DIR" "$INBOX_DIR" "$RUN_DIR" "$LOG_DIR" "$RUN_DIR/tmp" 2>/dev/null || true
TMPDIR="$RUN_DIR/tmp"; HOME="$RUN_DIR"; export TMPDIR HOME

# 版本闸门的两件输入：manifest 与库。先找模块域（运行时 / 测试缝），再找脚本同级（仓库里跑）
MANIFEST_FILE=""
for _cand in "$DSH_ROOT/manifest.json" "$SELF_DIR/manifest.json"; do
    if [ -f "$_cand" ]; then MANIFEST_FILE=$_cand; break; fi
done
GATE_LIB=""
for _cand in "$SELF_DIR/lib/semver-gate.sh" "$DSH_ROOT/lib/semver-gate.sh"; do
    if [ -f "$_cand" ]; then GATE_LIB=$_cand; break; fi
done

log() {
    _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-")
    printf '[%s] %s\n' "$_ts" "$*" >>"$LOG_FILE" 2>/dev/null || true
    printf '%s\n' "$*"
}
mark() { printf 'DSH_SERVICE_%s\n' "$*"; }

pid_of() { cat "$PID_FILE" 2>/dev/null; }
pid_alive() { _p=$(pid_of); [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; }

active_layer() {
    [ -f "$ACTIVE_FILE" ] || return 1
    sed -n '1p' "$ACTIVE_FILE" 2>/dev/null | tr -d ' \r\n'
}

dsh_dir_of() { printf '%s/dsh-%s\n' "$BASE_DIR" "${1-}"; }

layer_ok() {
    _l=${1:-}
    [ -n "$_l" ] || return 1
    [ -d "$(dsh_dir_of "$_l")" ] || return 1
    [ -f "$(dsh_dir_of "$_l")/.layer" ] || return 1
    return 0
}

node_ok() { [ -d "$NODE_DIR" ] && [ -f "$NODE_DIR/.layer" ]; }

boot_state() {
    [ -f "$BOOT_FILE" ] || { echo "idle"; return 0; }
    sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BOOT_FILE" 2>/dev/null | head -n1
}

boot_write() {
    _p5=${5-}
    printf '{"state":"%s","stage":"%s","progress":%s,"error":"%s","payload":"%s"}\n' \
        "$1" "$2" "$3" "$4" "$_p5" >"$BOOT_FILE" 2>/dev/null || true
}

json_field() { # $1=file $2=key
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -n1
}

first_match() { # $1=glob -> 第一个真实存在的文件
    for _f in $1; do
        if [ -f "$_f" ]; then printf '%s\n' "$_f"; return 0; fi
    done
    return 1
}

# ---------- 版本闸门（ADR-026）：判定在库，处置在这里 ----------
version_gate() {
    if [ -z "$GATE_LIB" ]; then
        log "版本闸门缺失：找不到 lib/semver-gate.sh（模块装坏了？）"
        mark "START version-library-missing"
        return 50
    fi
    if [ -z "$MANIFEST_FILE" ]; then
        log "版本闸门缺失：找不到 manifest.json（先找 $DSH_ROOT，再找 $SELF_DIR）"
        mark "START version-manifest-missing"
        return 50
    fi

    _vg_floor=$(json_field "$MANIFEST_FILE" floor)
    _vg_baked=$(json_field "$MANIFEST_FILE" baked)
    _vg_installed=$(json_field "$(dsh_dir_of "$_layer")/.layer" version)

    . "$GATE_LIB"
    semver_decide "$_vg_installed" "$_vg_floor" "$_vg_baked"

    if [ "$SEMVER_VERDICT" = "ok" ]; then
        if [ "$SEMVER_SAFE_MODE" = "1" ]; then
            log "版本闸门：installed=${_vg_installed:-空} 属非 rc 预发布（$SEMVER_REASON）→ 需要安全模式（尚未实现，仅标记）"
        fi
        log "版本闸门：ok reason=$SEMVER_REASON installed=${_vg_installed:-空} floor=$_vg_floor baked=$_vg_baked"
        mark "START version-ok"
        return 0
    fi

    # deny：低于 floor 时先试回落 baked —— 这是 floor-only 的正确处置，不是拒绝
    if [ "$SEMVER_REASON" = "below-floor" ]; then
        if layer_ok "$_vg_baked" && semver_cmp "$_vg_baked" "$_vg_floor"; then
            if [ "$SEMVER_CMP" -ge 0 ]; then
                _vg_tmp="$ACTIVE_FILE.tmp"
                if printf '%s\n' "$_vg_baked" >"$_vg_tmp" 2>/dev/null && mv "$_vg_tmp" "$ACTIVE_FILE" 2>/dev/null; then
                    _layer=$_vg_baked
                    log "版本闸门：installed=$_vg_installed 低于 floor=$_vg_floor → 已回落 baked=$_vg_baked"
                    mark "START version-fallback"
                    return 0
                fi
                log "版本闸门：回落失败（active 指针写不进去）"
                mark "START version-fallback-failed"
                return 40
            fi
        fi
    fi

    log "版本闸门拒绝启动：reason=$SEMVER_REASON installed=${_vg_installed:-空} floor=$_vg_floor baked=$_vg_baked"
    mark "START version-denied"
    return 50
}

# 只读版（给 status）：不切指针、不启动，只回答"现在这一层允不允许跑"
version_state() {
    if [ -z "$MANIFEST_FILE" ]; then echo "manifest-missing"; return 0; fi
    if [ -z "$GATE_LIB" ]; then echo "library-missing"; return 0; fi
    _vs_layer=$(active_layer) || _vs_layer=""
    _vs_floor=$(json_field "$MANIFEST_FILE" floor)
    _vs_baked=$(json_field "$MANIFEST_FILE" baked)
    _vs_installed=$(json_field "$(dsh_dir_of "$_vs_layer")/.layer" version)
    . "$GATE_LIB"
    semver_decide "$_vs_installed" "$_vs_floor" "$_vs_baked"
    printf '%s (%s) · installed=%s floor=%s baked=%s safemode=%s' \
        "$SEMVER_VERDICT" "$SEMVER_REASON" "${_vs_installed:-空}" "${_vs_floor:-?}" "${_vs_baked:-?}" "$SEMVER_SAFE_MODE"
}

# ---------- 运行时适配层（换容器实现只改这两个函数） ----------
runtime_start() {
    if [ "$DSH_RUNTIME" = "fake" ]; then
        setsid sleep 600 >/dev/null 2>&1 &
        echo $! >"$PID_FILE"
        return 0
    fi
    log "runtime=real 尚未实现（要 bind 两层 + 从 stdout 解析端口）"
    return 30
}

runtime_stop() {
    _p=$(pid_of)
    [ -n "$_p" ] || return 10
    kill -TERM "$_p" 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 10 ]; do
        kill -0 "$_p" 2>/dev/null || break
        sleep 1
        _i=$((_i + 1))
    done
    kill -0 "$_p" 2>/dev/null && { kill -KILL "$_p" 2>/dev/null || true; sleep 1; }
    kill -0 "$_p" 2>/dev/null && return 20
    rm -f "$PID_FILE"
    return 0
}

# ---------- 动词 ----------
do_start() {
    if pid_alive; then
        log "already running (pid $(pid_of))"; mark "START already-running"; return 10
    fi
    _layer=$(active_layer) || _layer=""
    if ! layer_ok "$_layer"; then
        log "DSH 层未就绪（active=${_layer:-空}）：先 bootstrap"; mark "START payload-missing"; return 30
    fi
    if ! node_ok; then
        log "Node 层未就绪（base/node）：先 bootstrap"; mark "START payload-missing"; return 30
    fi
    version_gate || return $?
    runtime_start || { mark "START runtime-failed"; return 30; }
    log "started (pid $(pid_of), dsh=$_layer)"; mark "START ok"; return 0
}

do_stop() {
    if [ "$DSH_FAULT" = "stop" ]; then
        log "fault injected: stop 失败"; mark "STOP failed"; return 20
    fi
    if ! pid_alive; then
        rm -f "$PID_FILE" 2>/dev/null || true
        log "already stopped"; mark "STOP already-stopped"; return 10
    fi
    runtime_stop || { log "stop 失败：仍有活跃实例"; mark "STOP failed"; return 20; }
    log "stopped"; mark "STOP ok"; return 0
}

do_status() {
    _layer=$(active_layer) || _layer=""
    if [ -z "$_layer" ]; then
        _lstate="none"
    elif layer_ok "$_layer"; then
        _lstate="ok"
    else
        _lstate="missing"
    fi
    if node_ok; then _nstate="ok"; else _nstate="missing"; fi
    if pid_alive; then _proc="running pid $(pid_of)"; else _proc="stopped"; fi
    printf 'root      : %s\n' "$DSH_ROOT"
    printf 'path      : %s\n' "$PATH"
    printf 'home      : %s\n' "$HOME"
    printf 'node      : %s\n' "$_nstate"
    printf 'layer     : %s (%s)\n' "$_layer" "$_lstate"
    printf 'manifest  : %s\n' "${MANIFEST_FILE:-missing}"
    printf 'version   : %s\n' "$(version_state)"
    printf 'dsh       : %s\n' "$_proc"
    printf 'bootstrap : %s\n' "$(boot_state)"
    printf 'mode      : local\n'
    mark "STATUS ok"; return 0
}

promote_layer() { # $1=staging $2=target
    _stage=$1; _tgt=$2
    if [ "$DSH_FAULT" = "switch" ]; then
        log "fault injected: 切换失败（${_tgt}）"
        return 1
    fi
    rm -rf "${_tgt}.old" 2>/dev/null || true
    if [ -d "$_tgt" ]; then mv "$_tgt" "${_tgt}.old" 2>/dev/null || return 1; fi
    mv "$_stage" "$_tgt" 2>/dev/null || return 1
    return 0
}

install_node_layer() {
    _sn="$BASE_DIR/.staging-node"
    rm -rf "$_sn" 2>/dev/null || true
    mkdir -p "$_sn" 2>/dev/null || true
    tar -xzf "$1" -C "$_sn" 2>/dev/null || return 1
    printf '{"layer":"node","version":"%s"}\n' "$2" >"$_sn/.layer" 2>/dev/null || true
    promote_layer "$_sn" "$NODE_DIR"
}

do_bootstrap() {
    _offline=0
    for a in "$@"; do [ "$a" = "--offline" ] && _offline=1; done

    if [ "$(boot_state)" = "ready" ]; then
        log "bootstrap already ready"; mark "BOOTSTRAP already-ready"; return 10
    fi

    boot_write running downloading 0 "" ""

    _node_tar=$(first_match "$INBOX_DIR/node-*.tar.gz") || _node_tar=""
    _dsh_tar=$(first_match "$INBOX_DIR/dsh-*.tar.gz") || _dsh_tar=""
    if [ -z "$_node_tar" ] || [ -z "$_dsh_tar" ]; then
        if [ "$_offline" -eq 1 ]; then
            boot_write failed failed 0 "payload-missing" ""
            log "缺 payload 层（node 与 dsh 都要），且 --offline 禁止联网"
            mark "BOOTSTRAP payload-missing"; return 30
        fi
        boot_write failed downloading 0 "download-not-implemented" ""
        log "缺 payload 层；联网自举尚未实现（curl 已确认可用，见 ADR-024），请先用 install 投递"
        mark "BOOTSTRAP payload-missing"; return 30
    fi

    boot_write running verifying 40 "" ""
    _want=$(json_field "$INBOX_DIR/node.json" sha256)
    if [ -n "$_want" ]; then
        _got=$(sha256sum "$_node_tar" 2>/dev/null | cut -d' ' -f1)
        if [ "$_got" != "$_want" ]; then
            boot_write failed verifying 40 "sha256-mismatch" ""
            log "node 层校验失败：期望 $_want 实得 ${_got:-无}"; mark "BOOTSTRAP verify-failed"; return 30
        fi
    fi
    _want=$(json_field "$INBOX_DIR/dsh.json" sha256)
    if [ -n "$_want" ]; then
        _got=$(sha256sum "$_dsh_tar" 2>/dev/null | cut -d' ' -f1)
        if [ "$_got" != "$_want" ]; then
            boot_write failed verifying 40 "sha256-mismatch" ""
            log "dsh 层校验失败：期望 $_want 实得 ${_got:-无}"; mark "BOOTSTRAP verify-failed"; return 30
        fi
    fi

    _ver=$(json_field "$INBOX_DIR/dsh.json" baked)
    if [ -z "$_ver" ]; then
        _ver=$(basename "$_dsh_tar" .tar.gz)
        _ver=${_ver#dsh-}
    fi
    _node_ver=$(json_field "$INBOX_DIR/node.json" version)
    [ -n "$_node_ver" ] || _node_ver="unknown"

    # 契约④ 先停后换
    if pid_alive; then
        log "有活跃实例，先停再换层"
        do_stop >/dev/null 2>&1
        if pid_alive; then
            boot_write failed unpacking 50 "stop-failed" ""; mark "BOOTSTRAP stop-failed"; return 20
        fi
    fi

    # --- Node 层：已装且版本相同则复用（两层的收益就在这） ---
    boot_write running unpacking 60 "" "$_ver"
    _cur_ver=$(json_field "$NODE_DIR/.layer" version)
    if node_ok && [ -n "$_cur_ver" ] && [ "$_cur_ver" = "$_node_ver" ]; then
        log "Node 层已是 $_cur_ver，复用（不重装）"
    else
        if ! install_node_layer "$_node_tar" "$_node_ver"; then
            boot_write failed unpacking 60 "switch-failed" ""; mark "BOOTSTRAP switch-failed"; return 40
        fi
    fi

    # --- DSH 层 ---
    boot_write running unpacking 80 "" "$_ver"
    _sd="$BASE_DIR/.staging-dsh-$_ver"
    rm -rf "$_sd" 2>/dev/null || true
    mkdir -p "$_sd" 2>/dev/null || true
    if ! tar -xzf "$_dsh_tar" -C "$_sd" 2>/dev/null; then
        boot_write failed unpacking 80 "unpack-failed" ""; mark "BOOTSTRAP unpack-failed"; return 30
    fi
    printf '{"layer":"dsh","version":"%s"}\n' "$_ver" >"$_sd/.layer" 2>/dev/null || true
    if ! promote_layer "$_sd" "$(dsh_dir_of "$_ver")"; then
        boot_write failed unpacking 90 "switch-failed" ""; mark "BOOTSTRAP switch-failed"; return 40
    fi

    if ! printf '%s\n' "$_ver" >"$ACTIVE_FILE" 2>/dev/null; then
        boot_write failed unpacking 90 "pointer-failed" ""; mark "BOOTSTRAP switch-failed"; return 40
    fi

    boot_write ready ready 100 "" "$_ver"
    log "bootstrap 完成：node=$_node_ver dsh=$_ver"
    mark "BOOTSTRAP ok"; return 0
}

do_install() {
    _f=${1:-}
    if [ -z "$_f" ] || [ ! -f "$_f" ]; then
        log "install: 文件不存在: ${_f:-<空>}"; mark "INSTALL bad-arg"; return 30
    fi
    case $_f in
        *node-*.tar.gz|*dsh-*.tar.gz|*.json) ;;
        *) log "install: 只接受 node-*.tar.gz / dsh-*.tar.gz / *.json"; mark "INSTALL bad-arg"; return 30 ;;
    esac
    # inbox 只保留"下一份待装"的同类产物：否则 bootstrap 会挑到旧的那个
    case $_f in
        *node-*.tar.gz) rm -f "$INBOX_DIR"/node-*.tar.gz 2>/dev/null || true ;;
        *dsh-*.tar.gz)  rm -f "$INBOX_DIR"/dsh-*.tar.gz 2>/dev/null || true ;;
    esac
    cp "$_f" "$INBOX_DIR/" || { mark "INSTALL copy-failed"; return 30; }
    log "installed: $(basename "$_f") -> inbox"; mark "INSTALL ok"; return 0
}

do_logs() {
    _n=40
    while [ "$#" -gt 0 ]; do
        case $1 in
            --tail) _n=${2:-40}; shift 2 2>/dev/null || shift ;;
            *) shift ;;
        esac
    done
    [ -f "$LOG_FILE" ] || { mark "LOGS empty"; return 0; }
    tail -n "$_n" "$LOG_FILE"; mark "LOGS ok"; return 0
}

usage() { sed -n '2,18p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; mark "HELP ok"; return 0; }

main() {
    _verb=${1:-}
    [ "$#" -gt 0 ] && shift
    case $_verb in
        boot)
            if [ "$(boot_state)" = "ready" ]; then do_start; return $?; fi
            do_bootstrap "$@"; _rc=$?
            [ "$_rc" -eq 0 ] || [ "$_rc" -eq 10 ] || return "$_rc"
            do_start; return $?
            ;;
        start) do_start ;;
        stop) do_stop ;;
        restart)
            do_stop >/dev/null 2>&1; _rc=$?
            [ "$_rc" -eq 20 ] && { log "restart 中止：停不掉"; return 20; }
            do_start ;;
        status) do_status ;;
        bootstrap) do_bootstrap "$@" ;;
        install) do_install "$@" ;;
        logs) do_logs "$@" ;;
        help|--help|-h|"") usage ;;
        *) log "未知动词: $_verb"; mark "ERROR bad-verb"; return 2 ;;
    esac
}

main "$@"
