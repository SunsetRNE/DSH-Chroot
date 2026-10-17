#!/bin/sh
# ============================================================
# verify-gate-device.sh —— 版本闸门 · 真机自检（单文件，自包含）
#
# 由 tools/build-device-selftest.py 从下面两处生成，**不要手改**：
#   - lib/semver-gate.sh        （实现正文，逐字复制）
#   - spec/gate-vectors.json    （向量，逐条内联）
#
# 用法（在手机上，root 或普通 shell 都能跑）:
#     sh verify-gate-device.sh
#
# 期望最后一行:  RESULT ok 76/76
# 如果出现 FAIL，把那几行连同上面的"环境"一起贴回来即可定位。
#
# 万一报 "then: not found" / "Syntax error" 之类：文件八成被转成了 CRLF
# （Windows 编辑器、某些分享通道会干这事），先转过再跑：
#     tr -d '\r' < verify-gate-device.sh > /tmp/v.sh && sh /tmp/v.sh
# ============================================================

echo "== 环境"
_shell="unknown"
if [ -n "${KSH_VERSION-}" ]; then
    _shell=$KSH_VERSION
elif [ -n "${BASH_VERSION-}" ]; then
    _shell="bash $BASH_VERSION"
elif [ -n "${ZSH_VERSION-}" ]; then
    _shell="zsh $ZSH_VERSION"
fi
echo "shell    : $_shell"
echo "argv0    : $0"
if command -v uname >/dev/null 2>&1; then
    echo "uname    : $(uname -sm)"
fi
if command -v getprop >/dev/null 2>&1; then
    echo "android  : $(getprop ro.build.version.release 2>/dev/null) / $(getprop ro.product.model 2>/dev/null)"
fi
echo "uid      : $(id -u 2>/dev/null)"
if [ -r /system/bin/sh ]; then
    echo "system sh: $(ls -l /system/bin/sh 2>/dev/null | tr -s ' ' | cut -d' ' -f5,9-)"
fi
echo

# ---------- 以下为实现正文（来自 lib/semver-gate.sh） ----------
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
    # 先落到具名变量：${#1} 不是 POSIX 写法，mksh 上可能不认（Android 的 /system/bin/sh 就是 mksh）
    _sg_na=$1
    _sg_nb=$2
    if [ "${#_sg_na}" -lt "${#_sg_nb}" ]; then
        SG_CMP=-1
    elif [ "${#_sg_na}" -gt "${#_sg_nb}" ]; then
        SG_CMP=1
    elif [ "$_sg_na" = "$_sg_nb" ]; then
        SG_CMP=0
    elif [ "$_sg_na" \< "$_sg_nb" ]; then
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

# ---------- 以下为向量与跑分（来自 spec/gate-vectors.json） ----------
echo "== 逐条比对（共 76 条）"
_TOTAL=0
_PASS=0
_FAIL=0
_CR=$(printf '\r')

while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    case $_line in
        *"$_CR") _line=${_line%"$_CR"} ;;
    esac
    _kind=${_line%%|*}
    _rest=${_line#*|}
    _a=${_rest%%|*}
    _rest=${_rest#*|}
    case $_kind in
        compare)
            _b=${_rest%%|*}
            _want=${_rest#*|}
            _label="compare $_a $_b"
            if semver_cmp "$_a" "$_b"; then
                _got=$SEMVER_CMP
            else
                _got=invalid
            fi
            ;;
        check)
            _b=
            _want=$_rest
            _label="check [$_a]"
            if semver_check "$_a"; then _got=ok; else _got=invalid; fi
            ;;
        *)
            _b=
            _want=?
            _got=error
            _label=unknow
            ;;
    esac
    _TOTAL=$((_TOTAL + 1))
    if [ "$_got" = "$_want" ]; then
        _PASS=$((_PASS + 1))
    else
        _FAIL=$((_FAIL + 1))
        printf 'FAIL %s -> 期望 %s 实得 %s
' "$_label" "$_want" "$_got"
    fi
done <<'GATE_VECTORS'
compare|0.2.1-rc.1|0.2.0-rc.2|1
compare|0.2.0|0.2.0-rc.2|1
compare|0.2.1-rc.1|0.2.0|1
compare|0.2.0|0.2.1-rc.1|-1
compare|0.2.0-rc.2|0.2.0-rc.2|0
compare|0.2.0-rc.10|0.2.0-rc.9|1
compare|0.2.0-rc.2|0.2.0-rc.10|-1
compare|1.0.0-alpha|1.0.0-alpha.1|-1
compare|1.0.0-alpha.1|1.0.0-alpha.beta|-1
compare|1.0.0-alpha.beta|1.0.0-beta|-1
compare|1.0.0-beta|1.0.0-beta.2|-1
compare|1.0.0-beta.2|1.0.0-beta.11|-1
compare|1.0.0-beta.11|1.0.0-rc.1|-1
compare|1.0.0-rc.1|1.0.0|-1
compare|1.0.0+build.1|1.0.0|0
compare|1.0.0+a|1.0.0+b|0
compare|1.0.0-rc.1|1.0.0-rc.1+build.9|0
compare|2.0.0|10.0.0|-1
compare|0.9.9|1.0.0|-1
compare|20261017.1.0|20261016.99.99|1
compare|1.0.0-1|1.0.0-2|-1
compare|1.0.0-2|1.0.0-10|-1
compare|1.0.0-10|1.0.0-a|-1
compare|1.0.0-a|1.0.0-a0|-1
compare|1.0.0-alpha|1.0.0-alpha.0|-1
compare|1.2.3|1.2.3-0|1
compare|0.0.0|0.0.0|0
compare|0.1.0|0.2.0-alpha.1|-1
compare|0.2.0-alpha.1|0.2.0-alpha.beta|-1
compare|0.2.0-alpha.beta|0.2.0-beta|-1
compare|0.2.0-beta|0.2.0-beta.2|-1
compare|0.2.0-beta.2|0.2.0-beta.11|-1
compare|0.2.0-beta.11|0.2.0-rc.1|-1
compare|0.2.0-rc.1|0.2.0-rc.2|-1
compare|0.2.0-rc.2|0.2.0-rc.10|-1
compare|0.2.0-rc.10|0.2.0|-1
compare|0.2.0|0.2.1-rc.1|-1
compare|0.2.1-rc.1|0.2.1-rc.2|-1
compare|0.2.1-rc.2|0.2.1|-1
compare|0.2.1|0.3.0-rc.1|-1
compare|0.3.0-rc.1|1.0.0|-1
check||invalid
check| |invalid
check| 1.2.3|invalid
check|1.2.3 |invalid
check|1|invalid
check|1.2|invalid
check|1.2.3.4|invalid
check|v1.2.3|invalid
check|-1.2.3|invalid
check|01.2.3|invalid
check|1.02.3|invalid
check|1.2.03|invalid
check|1.2.3-|invalid
check|1.2.3+|invalid
check|1.2.3-01|invalid
check|1.2.3-0.|invalid
check|1.2.3..1|invalid
check|1.2.3-a_b|invalid
check|1.2.3-测试|invalid
check|1.2.3-a b|invalid
check|1.2.3+a..b|invalid
check|1.2.3+a+b|invalid
check|0.0.0|ok
check|1.2.3|ok
check|1.2.3-alpha|ok
check|1.2.3-alpha.1|ok
check|1.2.3-0.3.7|ok
check|1.2.3-x.7.z.92|ok
check|1.2.3+build|ok
check|1.2.3-rc.1+build.5|ok
check|1.2.3--|ok
check|1.2.3-a-b|ok
check|1.2.3-rc.1-|ok
check|10.20.30|ok
check|0.2.0-rc.2|ok
GATE_VECTORS

echo
echo "== 典型陷阱（人眼复核）"
_probe() {
    if semver_cmp "$1" "$2"; then _g=$SEMVER_CMP; else _g=invalid; fi
    if [ "$_g" = "$3" ]; then _s=ok; else _s=MISMATCH; fi
    printf '  %-16s vs %-12s -> %-4s (期望 %s) %s\n' "$1" "$2" "$_g" "$3" "$_s"
}
_probe 0.2.1-rc.1 0.2.0-rc.2 1
_probe 0.2.0 0.2.0-rc.2 1
_probe 0.2.0-rc.10 0.2.0-rc.9 1

echo
if [ "$_FAIL" -eq 0 ] && [ "$_TOTAL" -eq 76 ]; then
    echo "RESULT ok $_PASS/$_TOTAL"
    exit 0
fi
echo "RESULT fail $_PASS/$_TOTAL (fail=$_FAIL)"
exit 1
