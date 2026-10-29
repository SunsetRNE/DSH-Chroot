#!/system/bin/sh
# service.sh —— 壳的**唯一执行者**（ADR-013 决定 A）
#
# 动词: boot | start | stop | restart | status | bootstrap [--offline] | install <file> | logs [--tail N] | diag | help
# 退出码: 0 成功 · 10 已是当前状态 · 20 停止失败 · 30 payload 缺失/校验失败 · 40 切换失败 · 50 版本闸门拒绝
#         · 60 运行时未就绪（容器起不来 / dsh 没在超时内报出端口；ADR-029）
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

json_num() { # $1=file $2=key —— 取数字字段（json_field 只认带引号的值）
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" 2>/dev/null | head -n1
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
# P2（ADR-029）：real = 真 chroot + 两层 bind(ro) + 端口从 stdout 启动行取
#
# 挂载表（最小集：够把 DSH 起起来就够，其余按功能落地再加，见 ADR-029 决定 C）
#   base/node      ro → <rootfs>/opt/dsh/node
#   base/dsh-<ver> ro → <rootfs>/opt/dsh/current
#   data/.dsh      rw → <rootfs>/root/.dsh      ← DSH_HOME（0700）
#   proc              → <rootfs>/proc
#   tmpfs             → <rootfs>/dev            ← 每次起容器重建
#   devpts            → <rootfs>/dev/pts
#
# 为什么 /dev 要自己建：rootfs 来自 tarball，/dev 里可能只有"普通文件"。
# 真机实测这个 rootfs 的 /dev/null 是 23 字节的普通文件、/dev/ptmx 根本不存在
# → 哈希对、功能死（PTY 直接不可用）。所以这里按 init 的做法建最小 devtmpfs。
RT_ROOT=/opt/dsh
RT_NODE=$RT_ROOT/node
RT_DSH=$RT_ROOT/current
RT_HOME_IN=/root/.dsh
RT_READY_TIMEOUT=${RT_READY_TIMEOUT:-45}
DSH_HOME_HOST="$DSH_ROOT/data/.dsh"

rt_container_rootfs() {
    if [ -n "${DSH_CONTAINER_ROOTFS:-}" ]; then printf '%s\n' "$DSH_CONTAINER_ROOTFS"; return 0; fi
    _r=""
    [ -n "$MANIFEST_FILE" ] && _r=$(json_field "$MANIFEST_FILE" container_rootfs)
    [ -n "$_r" ] || _r="/data/local/chroot-distro/ubuntu"
    printf '%s\n' "$_r"
}

rt_busybox() {
    for _b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        [ -x "$_b" ] && { printf '%s\n' "$_b"; return 0; }
    done
    command -v busybox 2>/dev/null && return 0
    return 1
}

rt_is_ro() { # $1=挂载点 -> 0=确实 ro
    _f=$(grep " $1 " /proc/mounts 2>/dev/null | head -n1 | cut -d' ' -f4)
    case ",$_f," in *,ro,*) return 0 ;; esac
    return 1
}

rt_make_ro() { # $1=挂载点
    # toybox 的 `-o bind,ro` 与 `-o remount,ro,bind` 都是**静默失败**（实测仍 rw），
    # 只有 busybox 的 `remount,ro,bind` 真的生效 → 必须挂完再验，不信返回值。
    mount -o remount,ro,bind "$1" 2>/dev/null || true
    rt_is_ro "$1" && return 0
    mount -o remount,ro "$1" 2>/dev/null || true
    rt_is_ro "$1" && return 0
    _bb=$(rt_busybox) || _bb=""
    if [ -n "$_bb" ]; then
        "$_bb" mount -o remount,ro,bind "$1" 2>/dev/null || true
        rt_is_ro "$1" && return 0
    fi
    return 1
}

rt_bind() { # $1=src $2=dst $3=ro|rw
    _s=$1; _d=$2; _m=$3
    mkdir -p "$_s" "$_d" 2>/dev/null || true
    if ! mount -o bind "$_s" "$_d" 2>/dev/null; then
        log "runtime: bind 失败（$_s → $_d）"
        return 1
    fi
    if [ "$_m" = "ro" ]; then
        if ! rt_make_ro "$_d"; then
            log "runtime: ⚠️ 只读挂载失败（$_d 仍是 rw）—— 版本层完整性保护缺失，记在 run/layers-rw"
            : >"$RUN_DIR/layers-rw" 2>/dev/null || true
        fi
    fi
    return 0
}

rt_mounts_down() {
    _r=$(rt_container_rootfs)
    [ -n "$_r" ] || return 0
    for _m in "$_r$RT_HOME_IN" "$_r$RT_DSH" "$_r$RT_NODE" "$_r/dev/pts" "$_r/dev" "$_r/proc"; do
        umount -l "$_m" 2>/dev/null || true
    done
    return 0
}

rt_mounts_up() { # $1=rootfs
    _r=$1
    rt_bind "$NODE_DIR" "$_r$RT_NODE" ro || return 1
    rt_bind "$(dsh_dir_of "$_layer")" "$_r$RT_DSH" ro || return 1
    rt_bind "$DSH_HOME_HOST" "$_r$RT_HOME_IN" rw || return 1
    mount -t proc proc "$_r/proc" 2>/dev/null || true    # 已被别人挂上是常态，不算错

    mount -t tmpfs tmpfs "$_r/dev" 2>/dev/null || { log "runtime: 挂 tmpfs 到 $_r/dev 失败"; return 1; }
    mkdir -p "$_r/dev/pts" "$_r/dev/shm" 2>/dev/null || true
    for _n in null:1:3 zero:1:5 full:1:7 random:1:8 urandom:1:9 tty:5:0 ptmx:5:2; do
        _nm=${_n%%:*}; _rest=${_n#*:}; _mj=${_rest%%:*}; _mn=${_rest#*:}
        if [ ! -c "$_r/dev/$_nm" ]; then
            rm -f "$_r/dev/$_nm" 2>/dev/null
            mknod "$_r/dev/$_nm" c "$_mj" "$_mn" 2>/dev/null || log "runtime: mknod $_nm 失败"
        fi
        chmod 666 "$_r/dev/$_nm" 2>/dev/null || true
    done
    ln -sf /proc/self/fd "$_r/dev/fd" 2>/dev/null || true
    ln -sf /proc/self/fd/0 "$_r/dev/stdin" 2>/dev/null || true
    ln -sf /proc/self/fd/1 "$_r/dev/stdout" 2>/dev/null || true
    ln -sf /proc/self/fd/2 "$_r/dev/stderr" 2>/dev/null || true
    mount -t devpts devpts "$_r/dev/pts" 2>/dev/null || { log "runtime: 挂 devpts 失败（PTY 会不可用）"; return 1; }
    return 0
}

# 启动行搬运工：只把含 http://127.0.0.1: 的那一行写到结果 fifo，然后把剩余输出吸干。
# 吸干是为了不让 dsh 的下一次写撞 EPIPE；全程不落盘 —— token 不进任何文件（ADR-022）。
rt_reader() { # $1=数据 fifo $2=结果 fifo
    exec 3<"$1" || exit 1
    while IFS= read -r _l <&3; do
        case $_l in
            *http://127.0.0.1:*) printf '%s\n' "$_l" >"$2" 2>/dev/null; break ;;
        esac
    done
    cat >/dev/null 2>&1 <&3
}

rt_parse_port() { printf '%s' "$1" | sed -n 's#.*127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' | head -n1; }
rt_parse_token() { printf '%s' "$1" | sed -n 's#.*[?&]token=\([A-Za-z0-9._~-]*\).*#\1#p' | head -n1; }

rt_fail() { # $1=原因
    _p=$(pid_of)
    if [ -n "$_p" ]; then
        kill -TERM "-$_p" 2>/dev/null || kill -TERM "$_p" 2>/dev/null || true
        sleep 1
        kill -KILL "-$_p" 2>/dev/null || kill -KILL "$_p" 2>/dev/null || true
    fi
    rm -f "$PID_FILE" "$RUN_DIR/.boot.fifo" "$RUN_DIR/.boot.res" 2>/dev/null || true
    [ "$DSH_RUNTIME" = "real" ] && rt_mounts_down
    log "runtime: 起不来（$1）"
    return 1
}

rt_real_start() {
    _r=$(rt_container_rootfs)
    if [ ! -d "$_r" ]; then
        log "runtime: 容器 rootfs 不存在（$_r）—— 先 chroot-distro install <distro>"
        return 1
    fi
    if [ ! -x "$_r/bin/sh" ]; then
        log "runtime: $_r 不像 rootfs（缺 /bin/sh）"
        return 1
    fi
    mkdir -p "$DSH_HOME_HOST" 2>/dev/null || true
    chmod 700 "$DSH_HOME_HOST" 2>/dev/null || true
    mkdir -p "$_r$RT_NODE" "$_r$RT_DSH" "$_r$RT_HOME_IN" "$_r/proc" 2>/dev/null || true

    rt_mounts_down                     # 清上一次的残留（幂等）
    rm -f "$RUN_DIR/layers-rw" 2>/dev/null || true
    rt_mounts_up "$_r" || { rt_mounts_down; return 1; }

    rm -f "$RUN_DIR/.boot.fifo" "$RUN_DIR/.boot.res" 2>/dev/null || true
    ( umask 077; mkfifo "$RUN_DIR/.boot.fifo" "$RUN_DIR/.boot.res" ) 2>/dev/null || {
        log "runtime: mkfifo 失败"; rt_mounts_down; return 1
    }

    _dshlog="$LOG_DIR/dsh.log"
    : >"$_dshlog" 2>/dev/null || true
    chmod 600 "$_dshlog" 2>/dev/null || true

    # pid 由子 shell 自己写（setsid 可能会 fork，$! 不一定等于 dsh 的 pid）
    setsid sh -c 'printf "%s\n" "$$" >"$1"; shift; exec "$@"' sh "$PID_FILE" \
        chroot "$_r" /usr/bin/env -i \
        PATH="$RT_NODE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        HOME=/root DSH_HOME="$RT_HOME_IN" TMPDIR=/tmp SHELL=/bin/bash LANG=C.UTF-8 TERM=xterm-256color \
        "$RT_DSH/bin/dsh" web --port 0 --no-open --host 127.0.0.1 \
        </dev/null >"$RUN_DIR/.boot.fifo" 2>>"$_dshlog" &
    rt_reader "$RUN_DIR/.boot.fifo" "$RUN_DIR/.boot.res" &

    _line=$(timeout "$RT_READY_TIMEOUT" sh -c 'IFS= read -r l <"$1" && printf "%s" "$l"' sh "$RUN_DIR/.boot.res" 2>/dev/null)
    if [ -z "$_line" ]; then
        rt_fail "dsh 在 ${RT_READY_TIMEOUT}s 内没报出端口（看 $LOG_DIR/dsh.log）"
        return 1
    fi

    _port=$(rt_parse_port "$_line")
    _token=$(rt_parse_token "$_line")
    case $_port in ''|*[!0-9]*) rt_fail "启动行里没解析出端口"; return 1 ;; esac
    if [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then rt_fail "端口越界：$_port"; return 1; fi
    if [ -z "$_token" ]; then rt_fail "启动行里没有 token"; return 1; fi

    _pid=$(pid_of)
    if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then rt_fail "dsh 进程没起来"; return 1; fi

    _tmp="$RUN_DIR/.dsh.json.tmp"
    ( umask 077
      printf '{"schema":1,"port":%s,"url":"http://127.0.0.1:%s/","token":"%s","pid":%s,"layer":"%s","runtime":"real","started_at":"%s"}\n' \
          "$_port" "$_port" "$_token" "$_pid" "$_layer" "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo -)" >"$_tmp" )
    chmod 600 "$_tmp" 2>/dev/null || true
    if ! mv "$_tmp" "$RUN_DIR/dsh.json" 2>/dev/null; then rt_fail "写 run/dsh.json 失败"; return 1; fi

    log "runtime: dsh 就绪 pid=$_pid port=$_port（token 只进 run/dsh.json，不进日志）"
    return 0
}

runtime_start() {
    if [ "$DSH_RUNTIME" = "fake" ]; then
        setsid sleep 600 >/dev/null 2>&1 &
        echo $! >"$PID_FILE"
        return 0
    fi
    rt_real_start
}

runtime_stop() {
    _p=$(pid_of)
    if [ -z "$_p" ]; then
        [ "$DSH_RUNTIME" = "real" ] && rt_mounts_down
        return 10
    fi
    # 先按进程组杀（setsid 起的会话首进程 = pgid），再兜底单杀
    kill -TERM "-$_p" 2>/dev/null || kill -TERM "$_p" 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 10 ]; do
        kill -0 "$_p" 2>/dev/null || break
        sleep 1
        _i=$((_i + 1))
    done
    kill -0 "$_p" 2>/dev/null && { kill -KILL "-$_p" 2>/dev/null || kill -KILL "$_p" 2>/dev/null || true; sleep 1; }
    kill -0 "$_p" 2>/dev/null && return 20
    rm -f "$PID_FILE" "$RUN_DIR/dsh.json" 2>/dev/null || true
    [ "$DSH_RUNTIME" = "real" ] && rt_mounts_down
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
    runtime_start || { mark "START runtime-failed"; return 60; }
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
    printf 'runtime   : %s\n' "$DSH_RUNTIME"
    if [ -f "$RUN_DIR/layers-rw" ]; then
        printf 'layers    : rw（只读挂载失败：版本层完整性保护缺失，见 ADR-009/ADR-029）\n'
    fi
    if [ -f "$RUN_DIR/dsh.json" ]; then
        printf 'port      : %s\n' "$(json_num "$RUN_DIR/dsh.json" port)"
    fi
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

# ---------- diag：把「证据 → 结论」搬到设备侧（ADR-030） ----------
# 退出码: 0 没发现已知问题 / 1 命中了已知问题 / 2 无法判读（缺 lib/errors.sh）
# 纪律: 只读 —— 不改任何状态、不起进程、不 mount/umount。
DIAG_HIT=""

diag_add() {
    case " $DIAG_HIT " in
        *" $1 "*) ;;
        *) DIAG_HIT="$DIAG_HIT${DIAG_HIT:+ }$1" ;;
    esac
}

diag_has() {
    case " $DIAG_HIT " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

do_diag() {
    _lib=""
    for _cand in "$SELF_DIR/lib/errors.sh" "$DSH_ROOT/lib/errors.sh"; do
        [ -f "$_cand" ] && { _lib=$_cand; break; }
    done
    if [ -z "$_lib" ]; then
        log "diag: 找不到 lib/errors.sh（模块装坏了？）"
        mark "DIAG no-table"
        return 2
    fi
    . "$_lib"
    if ! command -v emit_errors >/dev/null 2>&1; then
        log "diag: lib/errors.sh 是旧格式（没有 emit_errors）——重新生成"
        mark "DIAG no-table"
        return 2
    fi

    DIAG_HIT=""
    _rf=$(rt_container_rootfs)
    echo "== 被测对象 =="
    printf 'root      : %s\n' "$DSH_ROOT"
    printf 'rootfs    : %s\n' "$_rf"
    printf 'runtime   : %s\n' "$DSH_RUNTIME"
    echo
    echo "== 证据 =="

    # 1) payload / 层就绪  → E-L3S-PAY-001
    _al=$(active_layer) || _al=""
    if [ -z "$_al" ]; then
        diag_add E-L3S-PAY-001
        printf 'payload   : ✗ active 为空（从未 bootstrap）\n'
    elif ! layer_ok "$_al"; then
        diag_add E-L3S-PAY-001
        printf 'payload   : ✗ 层 %s 不完整（缺目录或 .layer）\n' "$_al"
    elif ! node_ok; then
        diag_add E-L3S-PAY-001
        printf 'payload   : ✗ Node 层 base/node 不完整\n'
    else
        printf 'payload   : ✓ node + layer %s\n' "$_al"
    fi

    if [ -d "$_rf" ]; then
        # 2) /dev 可信  → E-L1C-DEV-001
        if [ -c "$_rf/dev/null" ]; then
            printf 'dev/null  : ✓ 字符设备\n'
        else
            diag_add E-L1C-DEV-001
            printf 'dev/null  : ✗ 不是字符设备（%s）—— 哈希再对，功能也是死的\n' \
                "$(ls -ld "$_rf/dev/null" 2>/dev/null | cut -d' ' -f1)"
        fi

        # 3) devpts  → E-L1C-PTY-001
        if grep -q " $_rf/dev/pts " /proc/mounts 2>/dev/null; then
            printf 'devpts    : ✓ 已挂载\n'
        elif [ -d "$_rf/dev/pts" ] && [ -c "$_rf/dev/ptmx" ]; then
            printf 'devpts    : - 目录与 ptmx 都在，但未见挂载（容器没起时正常）\n'
        else
            diag_add E-L1C-PTY-001
            printf 'devpts    : ✗ 缺 /dev/pts 或 /dev/ptmx（PTY 会报 out of pty devices）\n'
        fi

        # 4) 层只读  → E-L1C-MNT-001
        if grep -q " $_rf$RT_DSH " /proc/mounts 2>/dev/null; then
            if rt_is_ro "$_rf$RT_DSH"; then
                printf 'layers    : ✓ current 是 ro\n'
            else
                diag_add E-L1C-MNT-001
                printf 'layers    : ✗ current 是 rw（完整性保护缺失）\n'
            fi
        else
            printf 'layers    : - current 未挂载（容器没起时正常）\n'
        fi
    else
        diag_add E-L1C-DEV-001
        printf 'dev/null  : ✗ rootfs 不存在（%s）\n' "$_rf"
    fi

    # 5) 版本闸门  → E-L3S-VER-001
    _vs=$(version_state 2>/dev/null || echo "-")
    case $_vs in
        ok*) printf 'version   : ✓ %s\n' "$_vs" ;;
        *) diag_add E-L3S-VER-001; printf 'version   : ✗ %s\n' "$_vs" ;;
    esac

    # 6) 端口 / 运行态  → E-L2D-PORT-001
    if [ -f "$RUN_DIR/dsh.json" ]; then
        _pt=$(json_num "$RUN_DIR/dsh.json" port)
        if [ -n "$_pt" ]; then
            printf 'port      : ✓ %s\n' "$_pt"
        else
            diag_add E-L2D-PORT-001
            printf 'port      : ✗ run/dsh.json 里没有 port\n'
        fi
    elif pid_alive; then
        diag_add E-L2D-PORT-001
        printf 'port      : ✗ 进程在（pid %s）却没有 run/dsh.json\n' "$(pid_of)"
    else
        printf 'port      : - 未运行（没在跑就不算故障）\n'
    fi
    echo

    if [ -z "$DIAG_HIT" ]; then
        echo "== 结论 =="
        echo "没发现已知故障（表里任何一条都没命中）。"
        mark "DIAG clean"
        return 0
    fi

    echo "== 命中 =="
    emit_errors | while IFS='|' read -r _c _l _st _t _exp _fix _probe; do
        [ -n "$_c" ] || continue
        diag_has "$_c" || continue
        printf '%s [%s/%s]\n' "$_c" "$_l" "$_st"
        printf '  症状 : %s\n' "$_t"
        printf '  处置 : %s\n' "$_fix"
        printf '  自证 : %s  → 期望 %s\n' "$_probe" "$_exp"
    done
    echo

    echo "== 结论 =="
    emit_signatures | while IFS='|' read -r _sid _when _vd _nx; do
        [ -n "$_sid" ] || continue
        _miss=""
        for _c in $_when; do
            diag_has "$_c" || _miss=1
        done
        [ -n "$_miss" ] && continue
        printf '%s：%s\n' "$_sid" "$_vd"
        printf '下一步：%s\n' "$_nx"
    done
    echo "（只列命中的签名；一条都没列 = 这些证据的组合还没登记，按「自证」逐条确认，别猜）"
    mark "DIAG hit"
    return 1
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
        diag) do_diag ;;
        bootstrap) do_bootstrap "$@" ;;
        install) do_install "$@" ;;
        logs) do_logs "$@" ;;
        help|--help|-h|"") usage ;;
        *) log "未知动词: $_verb"; mark "ERROR bad-verb"; return 2 ;;
    esac
}

main "$@"
