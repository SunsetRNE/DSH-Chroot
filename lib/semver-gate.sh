#!/bin/sh
# lib/semver-gate.sh —— 版本闸门的 POSIX sh 实现（Android 侧 / 容器内共用）
#
# 三份实现（Python / POSIX sh / Node）必须与 spec/gate-vectors.json 逐条一致：
#     python3 tools/check-gate.py
#
# 用法（执行）:
#     sh lib/semver-gate.sh compare 0.2.1-rc.1 0.2.0-rc.2    # -> -1 | 0 | 1（非法 -> invalid, 退出 2）
#     sh lib/semver-gate.sh check 0.2.0-rc.2                 # -> ok | invalid
#     sh lib/semver-gate.sh batch /tmp/vectors.tsv           # 每行一条，输出同样行数
#
# 用法（库，推荐在脚本里 source，省掉 fork）:
#     . /path/to/lib/semver-gate.sh
#     if semver_cmp "$installed" "$floor"; then
#         [ "$SEMVER_CMP" -ge 0 ] || deny
#     else
#         deny   # 版本串本身非法
#     fi
#
# 严格性（与 Python / Node 实现完全一致）:
#   - 不做 trim；核心三段数字不许前导零；必须恰好三段
#   - prerelease 只允许 [0-9A-Za-z-]，纯数字段不许前导零
#   - build 元数据允许前导零，且不参与比较
#   - 字符串比较固定在 C locale（调用方的 LC_ALL 会被临时接管再还原）
#
# 设计约束（ADR-013）: 纯 POSIX sh，不用 local / 数组 / [[ ]] / 花括号替换，
# 因为设备侧是 Android 的 sh，不是 bash。

SG_MAJOR=
SG_MINOR=
SG_PATCH=
SG_PRE=
SG_CMP=

# 字符串比较：在 C locale 下按字节序
_sg_strcmp() { # $1 $2 -> SG_CMP
    if [ "$1" = "$2" ]; then
        SG_CMP=0
    elif [ "$1" \< "$2" ]; then
        SG_CMP=-1
    else
        SG_CMP=1
    fi
}

# 数字比较：先比长度再比字典序，避开 shell 整型 64 位溢出
_sg_numcmp() { # $1 $2 -> SG_CMP
    if [ ${#1} -lt ${#2} ]; then
        SG_CMP=-1
    elif [ ${#1} -gt ${#2} ]; then
        SG_CMP=1
    elif [ "$1" = "$2" ]; then
        SG_CMP=0
    elif [ "$1" \< "$2" ]; then
        SG_CMP=-1
    else
        SG_CMP=1
    fi
}

# 核心数字段：非空、全数字、不许多于一位的前导零
_sg_isnum() {
    case $1 in
        ''|*[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
    esac
    return 0
}

# 解析版本串；合法返回 0 并设置 SG_MAJOR/MINOR/PATCH/PRE，非法返回 1
_sg_parse() {
    _sg_v=$1
    case $_sg_v in
        ''|*[!0-9A-Za-z.+-]*) return 1 ;;
    esac

    # build 元数据：至多一个 +，内容非空、无空段
    case $_sg_v in
        *+*)
            _sg_build=${_sg_v#*+}
            _sg_v=${_sg_v%%+*}
            case $_sg_build in
                ''|.*|*.|*..*) return 1 ;;
                *[!0-9A-Za-z.-]*) return 1 ;;
            esac
            ;;
    esac

    # prerelease：按 core 里的第一个 - 切开
    case $_sg_v in
        *-*)
            SG_PRE=${_sg_v#*-}
            _sg_core=${_sg_v%%-*}
            case $SG_PRE in
                ''|.*|*.|*..*) return 1 ;;
                *[!0-9A-Za-z.-]*) return 1 ;;
            esac
            ;;
        *)
            SG_PRE=
            _sg_core=$_sg_v
            ;;
    esac

    # core 必须恰好三段
    case $_sg_core in
        *.*.*) ;;
        *) return 1 ;;
    esac
    _sg_a=${_sg_core%%.*}
    _sg_rest=${_sg_core#*.}
    _sg_b=${_sg_rest%%.*}
    _sg_c=${_sg_rest#*.}
    case $_sg_c in
        *.*) return 1 ;;
    esac
    _sg_isnum "$_sg_a" || return 1
    _sg_isnum "$_sg_b" || return 1
    _sg_isnum "$_sg_c" || return 1
    SG_MAJOR=$_sg_a
    SG_MINOR=$_sg_b
    SG_PATCH=$_sg_c

    # prerelease 的纯数字段不许前导零
    _sg_rest=$SG_PRE
    while [ -n "$_sg_rest" ]; do
        _sg_id=${_sg_rest%%.*}
        case $_sg_rest in
            *.*) _sg_rest=${_sg_rest#*.} ;;
            *) _sg_rest= ;;
        esac
        case $_sg_id in
            *[!0-9]*) continue ;;      # 字母数字段，跳过
            0) continue ;;
            0*) return 1 ;;
        esac
    done
    return 0
}

# 合法性检查：0 = 合法，1 = 非法
semver_check() {
    _sg_parse "$1"
}

# 比较：0 = 比出来了（结果在 SEMVER_CMP），2 = 输入非法
semver_cmp() {
    _sg_saved_lc=${LC_ALL-}
    LC_ALL=C
    SG_CMP=
    _sg_impl "$1" "$2"
    _sg_rc=$?
    SEMVER_CMP=$SG_CMP
    LC_ALL=$_sg_saved_lc
    return $_sg_rc
}

_sg_impl() {
    _sg_parse "$1" || return 2
    _sg_amaj=$SG_MAJOR
    _sg_amin=$SG_MINOR
    _sg_apat=$SG_PATCH
    _sg_apre=$SG_PRE

    _sg_parse "$2" || return 2
    _sg_bmaj=$SG_MAJOR
    _sg_bmin=$SG_MINOR
    _sg_bpat=$SG_PATCH
    _sg_bpre=$SG_PRE

    _sg_numcmp "$_sg_amaj" "$_sg_bmaj"
    [ "$SG_CMP" = 0 ] || return 0
    _sg_numcmp "$_sg_amin" "$_sg_bmin"
    [ "$SG_CMP" = 0 ] || return 0
    _sg_numcmp "$_sg_apat" "$_sg_bpat"
    [ "$SG_CMP" = 0 ] || return 0

    if [ -z "$_sg_apre" ] && [ -z "$_sg_bpre" ]; then
        SG_CMP=0
        return 0
    fi
    if [ -z "$_sg_apre" ]; then
        SG_CMP=1
        return 0
    fi
    if [ -z "$_sg_bpre" ]; then
        SG_CMP=-1
        return 0
    fi

    _sg_ra=$_sg_apre
    _sg_rb=$_sg_bpre
    while :; do
        if [ -z "$_sg_ra" ] && [ -z "$_sg_rb" ]; then
            SG_CMP=0
            return 0
        fi
        if [ -z "$_sg_ra" ]; then
            SG_CMP=-1          # A 的 prerelease 段数更少
            return 0
        fi
        if [ -z "$_sg_rb" ]; then
            SG_CMP=1
            return 0
        fi
        _sg_ia=${_sg_ra%%.*}
        case $_sg_ra in
            *.*) _sg_ra=${_sg_ra#*.} ;;
            *) _sg_ra= ;;
        esac
        _sg_ib=${_sg_rb%%.*}
        case $_sg_rb in
            *.*) _sg_rb=${_sg_rb#*.} ;;
            *) _sg_rb= ;;
        esac
        case $_sg_ia in
            *[!0-9]*) _sg_an=0 ;;
            *) _sg_an=1 ;;
        esac
        case $_sg_ib in
            *[!0-9]*) _sg_bn=0 ;;
            *) _sg_bn=1 ;;
        esac
        if [ "$_sg_an" = 1 ] && [ "$_sg_bn" = 1 ]; then
            _sg_numcmp "$_sg_ia" "$_sg_ib"
        elif [ "$_sg_an" = 1 ]; then
            SG_CMP=-1          # 数字段 < 字母段
        elif [ "$_sg_bn" = 1 ]; then
            SG_CMP=1
        else
            _sg_strcmp "$_sg_ia" "$_sg_ib"
        fi
        [ "$SG_CMP" = 0 ] || return 0
    done
}

# 批量：TSV 每行「compare<TAB>a<TAB>b」或「check<TAB>v」，输出同样行数
semver_batch() {
    _sg_file=$1
    if [ ! -f "$_sg_file" ]; then
        echo "semver-gate: 找不到向量文件: $_sg_file" >&2
        return 2
    fi
    _sg_tab=$(printf '\t')
    while IFS= read -r _sg_line; do
        [ -z "$_sg_line" ] && continue
        _sg_kind=${_sg_line%%"$_sg_tab"*}
        _sg_rest=${_sg_line#*"$_sg_tab"}
        case $_sg_kind in
            compare)
                case $_sg_rest in
                    *"$_sg_tab"*) ;;
                    *) echo error; continue ;;
                esac
                _sg_a=${_sg_rest%%"$_sg_tab"*}
                _sg_b=${_sg_rest#*"$_sg_tab"}
                if semver_cmp "$_sg_a" "$_sg_b"; then
                    echo "$SEMVER_CMP"
                else
                    echo invalid
                fi
                ;;
            check)
                if semver_check "$_sg_rest"; then echo ok; else echo invalid; fi
                ;;
            *)
                echo error
                ;;
        esac
    done < "$_sg_file"
    return 0
}

# 显式入口（被 source 时调用它，别依赖 $0 判断）
semver_gate_main() {
    _sg_verb=${1-}
    case $_sg_verb in
        compare)
            if semver_cmp "${2-}" "${3-}"; then
                echo "$SEMVER_CMP"
                return 0
            fi
            echo invalid
            return 2
            ;;
        check)
            if semver_check "${2-}"; then echo ok; return 0; fi
            echo invalid
            return 1
            ;;
        batch)
            semver_batch "${2-}"
            return $?
            ;;
        *)
            echo "用法: sh lib/semver-gate.sh compare A B | check V | batch FILE" >&2
            return 2
            ;;
    esac
}

# 被直接执行时自动进入命令模式；被 source 时什么都不做
case ${0##*/} in
    semver-gate.sh) semver_gate_main "$@" ;;
esac
