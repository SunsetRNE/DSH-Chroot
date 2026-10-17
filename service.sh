#!/system/bin/sh
# service.sh —— 壳的**唯一执行者**（ADR-013 决定 A）
#
# 四个入口（开机 / Root 管理器 / MT 管理器 / 终端）都只 exec 它，保证"四条路径跑的是同一份代码"。
# 公开入口是 dsh-ctl（ADR-019）。
#
# 用法:
#     service.sh <verb> [args]
#
# 动词:
#     boot                  开机路径：需要时先自举，然后 start
#     start                 启动 DSH（幂等：已在跑 -> 10）
#     stop                  优雅停止（幂等：没在跑 -> 10；停不掉 -> 20）
#     restart               stop + start（stop 的 10 不算失败）
#     status                打印状态（层 / 指针 / 进程 / 自举阶段 / mode）
#     bootstrap [--offline] 自举 payload（ADR-024）：离线优先；已就绪 -> 10
#     install <file>        把 payload 投递进 inbox（校验 sha256）
#     logs [--tail N]       运维日志
#     help                  打印本帮助
#
# 退出码（ADR-013 决定 B.6）:
#     0  成功
#     10 已是当前状态（幂等路径）
#     20 停止失败（仍有活跃实例）
#     30 payload 缺失 / 校验失败 / 空间不足
#     40 切换失败（换层 / 切指针）
#
# 测试缝（只给 tools/test-service.sh 用，生产环境不该设）:
#     DSH_ROOT=<dir>        根目录（默认 /data/local/dsh）
#     DSH_RUNTIME=fake      用 sleep 冒充 DSH 进程
#     DSH_FAULT=stop|switch 注入故障，验证 20 / 40 分支

# ---------- 契约① 非交互：stdin 直接钉成 /dev/null ----------
exec 0</dev/null

set -u

# ---------- 契约② 环境钉死：不继承调用者的 PATH / HOME / TMPDIR ----------
if [ -d /system/bin ]; then
    PATH=/system/bin:/data/adb/ksu/bin
else
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fi
export PATH
unset CDPATH ENV 2>/dev/null || true

DSH_ROOT=${DSH_ROOT:-/data/local/dsh}
STATE_DIR="$DSH_ROOT/state"
BASE_DIR="$DSH_ROOT/base"
INBOX_DIR="$DSH_ROOT/inbox"
RUN_DIR="$DSH_ROOT/run"
LOG_DIR="$DSH_ROOT/log"
ACTIVE_FILE="$DSH_ROOT/active"
PID_FILE="$RUN_DIR/dsh.pid"
BOOT_FILE="$RUN_DIR/bootstrap.json"
LOG_FILE="$LOG_DIR/service.log"
DSH_RUNTIME=${DSH_RUNTIME:-fake}
DSH_FAULT=${DSH_FAULT:-}

mkdir -p "$STATE_DIR" "$BASE_DIR" "$INBOX_DIR" "$RUN_DIR" "$LOG_DIR" "$RUN_DIR/tmp" 2>/dev/null || true
TMPDIR="$RUN_DIR/tmp"
HOME="$RUN_DIR"
export TMPDIR HOME

# ---------- 契约⑥ 日志 + 机器可读标记 ----------
log() {
    _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-")
    _line="[$_ts] $*"
    printf '%s\n' "$_line" >>"$LOG_FILE" 2>/dev/null || true
    printf '%s\n' "$*"
}

mark() { printf 'DSH_SERVICE_%s\n' "$*"; }

# ---------- 通用 ----------
pid_of() { cat "$PID_FILE" 2>/dev/null; }

pid_alive() {
    _p=$(pid_of)
    [ -n "$_p" ] || return 1
    kill -0 "$_p" 2>/dev/null
}

active_layer() {
    [ -f "$ACTIVE_FILE" ] || return 1
    sed -n '1p' "$ACTIVE_FILE" 2>/dev/null | tr -d ' \r\n'
}

layer_ok() {
    _l=${1:-}
    [ -n "$_l" ] || return 1
    [ -d "$BASE_DIR/$_l" ] || return 1
    [ -f "$BASE_DIR/$_l/.layer" ] || return 1
    return 0
}

boot_state() {
    [ -f "$BOOT_FILE" ] || { echo "idle"; return 0; }
    sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BOOT_FILE" 2>/dev/null | head -n1
}

boot_write() {
    _p5=${5-}
    printf '{"state":"%s","stage":"%s","progress":%s,"error":"%s","payload":"%s"}\n' \
        "$1" "$2" "$3" "$4" "$_p5" >"$BOOT_FILE" 2>/dev/null || true
}

# ---------- 运行时适配层：换容器实现只改这两个函数 ----------
runtime_start() {
    if [ "$DSH_RUNTIME" = "fake" ]; then
        setsid sleep 600 >/dev/null 2>&1 &
        echo $! >"$PID_FILE"
        return 0
    fi
    # TODO(runtime): 真起 DSH：chroot 内 dsh web --port 0，端口从 stdout 解析后写 run/dsh.json
    log "runtime=real 尚未实现"
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
    if kill -0 "$_p" 2>/dev/null; then
        kill -KILL "$_p" 2>/dev/null || true
        sleep 1
    fi
    if kill -0 "$_p" 2>/dev/null; then
        return 20
    fi
    rm -f "$PID_FILE"
    return 0
}

# ---------- 动词 ----------
do_start() {
    if pid_alive; then
        log "already running (pid $(pid_of))"
        mark "START already-running"
        return 10
    fi
    _layer=$(active_layer) || _layer=""
    if ! layer_ok "$_layer"; then
        log "payload 未就绪（active=${_layer:-空}）：先 bootstrap 或 install"
        mark "START payload-missing"
        return 30
    fi
    runtime_start || { mark "START runtime-failed"; return 30; }
    log "started (pid $(pid_of), layer $_layer)"
    mark "START ok"
    return 0
}

do_stop() {
    if [ "$DSH_FAULT" = "stop" ]; then
        log "fault injected: stop 失败"
        mark "STOP failed"
        return 20
    fi
    if ! pid_alive; then
        rm -f "$PID_FILE" 2>/dev/null || true
        log "already stopped"
        mark "STOP already-stopped"
        return 10
    fi
    runtime_stop
    if [ $? -eq 20 ]; then
        log "stop 失败：仍有活跃实例"
        mark "STOP failed"
        return 20
    fi
    log "stopped"
    mark "STOP ok"
    return 0
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
    if pid_alive; then _proc="running pid $(pid_of)"; else _proc="stopped"; fi
    printf 'root      : %s\n' "$DSH_ROOT"
    printf 'path      : %s\n' "$PATH"
    printf 'home      : %s\n' "$HOME"
    printf 'layer     : %s (%s)\n' "$_layer" "$_lstate"
    printf 'dsh       : %s\n' "$_proc"
    printf 'bootstrap : %s\n' "$(boot_state)"
    printf 'mode      : local\n'
    mark "STATUS ok"
    return 0
}

do_bootstrap() {
    _offline=0
    for a in "$@"; do
        [ "$a" = "--offline" ] && _offline=1
    done

    if [ "$(boot_state)" = "ready" ]; then
        log "bootstrap already ready"
        mark "BOOTSTRAP already-ready"
        return 10
    fi

    boot_write running downloading 0 "" ""

    _payload=""
    for f in "$INBOX_DIR"/payload*.tar.gz "$INBOX_DIR"/payload*.tar.xz; do
        if [ -f "$f" ]; then _payload=$f; break; fi
    done

    if [ -z "$_payload" ]; then
        if [ "$_offline" -eq 1 ]; then
            boot_write failed failed 0 "payload-missing" ""
            log "payload 缺失，且 --offline 禁止联网"
            mark "BOOTSTRAP payload-missing"
            return 30
        fi
        # TODO(net): busybox wget -c 从 GitHub Releases 下载（ADR-024 决定 E.1）
        boot_write failed downloading 0 "download-not-implemented" ""
        log "联网自举尚未实现：请用 install <file> 投递到 inbox"
        mark "BOOTSTRAP payload-missing"
        return 30
    fi

    boot_write running verifying 50 "" "$(basename "$_payload")"

    _ver=""
    _sum=""
    _pj="$INBOX_DIR/payload.json"
    if [ -f "$_pj" ]; then
        _ver=$(sed -n 's/.*"baked"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_pj" | head -n1)
        _sum=$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_pj" | head -n1)
    fi
    [ -n "$_ver" ] || _ver="0.0.0-unknown"

    if [ -n "$_sum" ]; then
        _got=$(sha256sum "$_payload" 2>/dev/null | cut -d' ' -f1)
        if [ "$_got" != "$_sum" ]; then
            boot_write failed verifying 50 "sha256-mismatch" ""
            log "payload 校验失败：期望 $_sum 实得 ${_got:-无}"
            mark "BOOTSTRAP verify-failed"
            return 30
        fi
    fi

    # 契约④ 先停后换
    if pid_alive; then
        log "有活跃实例，先停再换层"
        do_stop >/dev/null 2>&1
        if pid_alive; then
            boot_write failed unpacking 60 "stop-failed" ""
            mark "BOOTSTRAP stop-failed"
            return 20
        fi
    fi

    boot_write running unpacking 70 "" "$_ver"
    _stage="$BASE_DIR/.staging-$_ver"
    rm -rf "$_stage" 2>/dev/null || true
    mkdir -p "$_stage" 2>/dev/null || true

    if [ "$DSH_FAULT" = "switch" ]; then
        boot_write failed unpacking 80 "switch-failed" ""
        log "fault injected: 切换失败"
        mark "BOOTSTRAP switch-failed"
        return 40
    fi

    # v0：payload 是空壳 tar（测试用）；真实解压等 payload 规范定稿
    tar -xzf "$_payload" -C "$_stage" 2>/dev/null || true
    : >"$_stage/.layer"

    if [ -d "$BASE_DIR/$_ver" ]; then
        rm -rf "$BASE_DIR/$_ver.old" 2>/dev/null || true
        mv "$BASE_DIR/$_ver" "$BASE_DIR/$_ver.old" 2>/dev/null || true
    fi
    if ! mv "$_stage" "$BASE_DIR/$_ver" 2>/dev/null; then
        boot_write failed unpacking 90 "switch-failed" ""
        mark "BOOTSTRAP switch-failed"
        return 40
    fi
    if ! printf '%s\n' "$_ver" >"$ACTIVE_FILE" 2>/dev/null; then
        boot_write failed unpacking 90 "pointer-failed" ""
        mark "BOOTSTRAP switch-failed"
        return 40
    fi

    boot_write ready ready 100 "" "$_ver"
    log "bootstrap 完成：layer $_ver"
    mark "BOOTSTRAP ok"
    return 0
}

do_install() {
    _f=${1:-}
    if [ -z "$_f" ] || [ ! -f "$_f" ]; then
        log "install: 文件不存在: ${_f:-<空>}"
        mark "INSTALL bad-arg"
        return 30
    fi
    cp "$_f" "$INBOX_DIR/" || { mark "INSTALL copy-failed"; return 30; }
    if [ -f "$INBOX_DIR/payload.json" ]; then
        _sum=$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$INBOX_DIR/payload.json" | head -n1)
        _got=$(sha256sum "$INBOX_DIR/$(basename "$_f")" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$_sum" ] && [ "$_got" != "$_sum" ]; then
            log "install: sha256 不匹配"
            mark "INSTALL verify-failed"
            return 30
        fi
    fi
    log "installed: $(basename "$_f") -> inbox"
    mark "INSTALL ok"
    return 0
}

do_logs() {
    _n=40
    while [ "$#" -gt 0 ]; do
        case $1 in
            --tail)
                _n=${2:-40}
                shift 2 2>/dev/null || shift
                ;;
            *) shift ;;
        esac
    done
    if [ ! -f "$LOG_FILE" ]; then mark "LOGS empty"; return 0; fi
    tail -n "$_n" "$LOG_FILE"
    mark "LOGS ok"
    return 0
}

usage() {
    sed -n '2,36p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
    mark "HELP ok"
    return 0
}

main() {
    _verb=${1:-}
    [ "$#" -gt 0 ] && shift
    case $_verb in
        boot)
            if [ "$(boot_state)" = "ready" ]; then
                do_start; return $?
            fi
            do_bootstrap "$@"
            _rc=$?
            [ "$_rc" -eq 0 ] || [ "$_rc" -eq 10 ] || return "$_rc"
            do_start; return $?
            ;;
        start) do_start ;;
        stop) do_stop ;;
        restart)
            do_stop >/dev/null 2>&1
            _rc=$?
            if [ "$_rc" -eq 20 ]; then
                log "restart 中止：停不掉"
                return 20
            fi
            do_start ;;
        status) do_status ;;
        bootstrap) do_bootstrap "$@" ;;
        install) do_install "$@" ;;
        logs) do_logs "$@" ;;
        help|--help|-h|"") usage ;;
        *)
            log "未知动词: $_verb"
            mark "ERROR bad-verb"
            return 2
            ;;
    esac
}

main "$@"
