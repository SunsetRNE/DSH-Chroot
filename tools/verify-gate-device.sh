#!/bin/sh
# ============================================================
# verify-gate-device.sh —— 版本闸门 · 真机自检（单文件，自包含）
#
# 由 tools/build-device-selftest.py 从下面两处生成，**不要手改**：
#   - lib/semver-gate.sh        （实现正文，逐字复制）
#   - spec/gate-vectors.json    （向量，逐条内联）
#
# 用法（在手机上，root 或普通用户都行）:
#     sh verify-gate-device.sh
#
# 期望最后一行:  RESULT ok 95/95
# 如果出现 FAIL，把那几行连同上面的"环境"一起贴回来即可定位。
#
# 万一报 "then: not found" / "Syntax error" 之类：文件八成被转成了 CRLF
# （Windows 编辑器、某些分享通道会干这事），先转过再跑：
#     tr -d '\r' < verify-gate-device.sh > /tmp/v.sh && sh /tmp/v.sh
# ============================================================

# 关掉路径名展开：向量里可能有意料之外的字符，不该被当成 glob 展开
set -f

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

# 策略层的输出（ADR-026）；semver_decide 之后读这三个变量
SEMVER_VERDICT=
SEMVER_REASON=
SEMVER_SAFE_MODE=0

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


# 策略层：verdict(ok|deny) · reason · safe_mode(0|1)，见 ADR-026
# 纯判定：不读盘、不改指针 —— 回落 baked / 退出码 / 日志由壳负责
semver_decide() {
    SEMVER_VERDICT=
    SEMVER_REASON=
    SEMVER_SAFE_MODE=0

    if ! semver_check "${1-}"; then
        SEMVER_VERDICT=deny; SEMVER_REASON=invalid-installed; return 0
    fi
    if ! semver_check "${2-}" || ! semver_check "${3-}"; then
        SEMVER_VERDICT=deny; SEMVER_REASON=invalid-manifest; return 0
    fi

    # floor > baked：清单自相矛盾，宁可不跑
    if semver_cmp "${2-}" "${3-}"; then
        if [ "$SEMVER_CMP" = 1 ]; then
            SEMVER_VERDICT=deny; SEMVER_REASON=invalid-manifest; return 0
        fi
    fi

    if semver_cmp "${1-}" "${2-}"; then
        if [ "$SEMVER_CMP" = -1 ]; then
            SEMVER_VERDICT=deny; SEMVER_REASON=below-floor; return 0
        fi
    fi

    if semver_cmp "${1-}" "${3-}"; then
        if [ "$SEMVER_CMP" = -1 ]; then
            SEMVER_VERDICT=ok; SEMVER_REASON=older-than-baked; return 0
        fi
        if [ "$SEMVER_CMP" = 0 ]; then
            SEMVER_VERDICT=ok; SEMVER_REASON=baked; return 0
        fi
    fi

    # installed > baked：看通道。重新解析 installed，才能拿到它自己的 prerelease
    semver_check "${1-}"
    case $SG_PRE in
        '') SEMVER_VERDICT=ok; SEMVER_REASON=user-upgraded ;;
        rc|rc.*) SEMVER_VERDICT=ok; SEMVER_REASON=user-upgraded ;;
        alpha|alpha.*) SEMVER_VERDICT=ok; SEMVER_REASON=user-upgraded-alpha; SEMVER_SAFE_MODE=1 ;;
        *) SEMVER_VERDICT=ok; SEMVER_REASON=user-upgraded-prerelease; SEMVER_SAFE_MODE=1 ;;
    esac
    return 0
}

# 批量：TSV 每行「compare<TAB>a<TAB>b」「check<TAB>v」或「decide<TAB>i<TAB>f<TAB>b」，输出同样行数
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
            decide)
                case $_sg_rest in
                    *"$_sg_tab"*) ;;
                    *) echo error; continue ;;
                esac
                _sg_i=${_sg_rest%%"$_sg_tab"*}
                _sg_rest2=${_sg_rest#*"$_sg_tab"}
                case $_sg_rest2 in
                    *"$_sg_tab"*) ;;
                    *) echo error; continue ;;
                esac
                _sg_fl=${_sg_rest2%%"$_sg_tab"*}
                _sg_bk=${_sg_rest2#*"$_sg_tab"}
                semver_decide "$_sg_i" "$_sg_fl" "$_sg_bk"
                echo "$SEMVER_VERDICT $SEMVER_REASON $SEMVER_SAFE_MODE"
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
        decide)
            if [ "$#" -lt 4 ]; then
                echo "用法: sh lib/semver-gate.sh decide INSTALLED FLOOR BAKED" >&2
                return 2
            fi
            semver_decide "$2" "$3" "$4"
            echo "$SEMVER_VERDICT $SEMVER_REASON $SEMVER_SAFE_MODE"
            return 0
            ;;
        batch)
            semver_batch "${2-}"
            return $?
            ;;
        *)
            echo "用法: sh lib/semver-gate.sh compare A B | check V | decide I F B | batch FILE" >&2
            return 2
            ;;
    esac
}

# ---------- 以下为向量与跑分（来自 spec/gate-vectors.json） ----------
echo "== 逐条比对（共 95 条）"
_TOTAL=0
_PASS=0
_FAIL=0
_CR=$(printf '\r')

# 解析一条向量。为什么不写 ${_line%%|*}：mksh（Android 的 /system/bin/sh）里
# 未加引号的 | 在 ${...} 模式里的行为与 dash/bash 不同 —— 实测会整段吞成空串。
# 改用 IFS 拆分，三种 shell 上行为一致（2026-10-17 真机/容器双端验证）。
_gate_one() {
    _raw=$1
    _ol=$IFS
    IFS='|'
    set -- $_raw
    IFS=$_ol
    _kind=${1-}
    case $_kind in
        compare)
            _a=${2-}
            _b=${3-}
            _want=${4-}
            _label="compare $_a $_b"
            if semver_cmp "$_a" "$_b"; then
                _got=$SEMVER_CMP
            else
                _got=invalid
            fi
            ;;
        check)
            _a=${2-}
            _want=${3-}
            _label="check [$_a]"
            if semver_check "$_a"; then _got=ok; else _got=invalid; fi
            ;;
        decide)
            _i=${2-}
            _f=${3-}
            _b=${4-}
            _want=${5-}
            _label="decide $_i $_f $_b"
            semver_decide "$_i" "$_f" "$_b"
            _got="$SEMVER_VERDICT $SEMVER_REASON $SEMVER_SAFE_MODE"
            ;;
        *)
            _label=unknow
            _got=error
            _want=?
            ;;
    esac
    _TOTAL=$((_TOTAL + 1))
    if [ "$_got" = "$_want" ]; then
        _PASS=$((_PASS + 1))
    else
        _FAIL=$((_FAIL + 1))
        printf 'FAIL %s -> 期望 %s 实得 %s | 原始行: %s\n' "$_label" "$_want" "$_got" "$_raw"
    fi
}

while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    case $_line in
        *"$_CR") _line=${_line%"$_CR"} ;;
    esac
    _gate_one "$_line"
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
decide||0.2.0-rc.2|0.2.1-rc.2|deny invalid-installed 0
decide|0.2|0.2.0-rc.2|0.2.1-rc.2|deny invalid-installed 0
decide|0.2.0-rc.2|0.2|0.2.1-rc.2|deny invalid-manifest 0
decide|0.2.0-rc.2|0.2.0-rc.2|x|deny invalid-manifest 0
decide|0.2.0-rc.1|0.2.0-rc.2|0.2.1-rc.2|deny below-floor 0
decide|0.2.0-rc.2|0.2.0-rc.2|0.2.1-rc.2|ok older-than-baked 0
decide|0.2.0|0.2.0-rc.2|0.2.1-rc.2|ok older-than-baked 0
decide|0.2.1-rc.2|0.2.0-rc.2|0.2.1-rc.2|ok baked 0
decide|0.2.1|0.2.0-rc.2|0.2.1-rc.2|ok user-upgraded 0
decide|0.2.1-rc.10|0.2.0-rc.2|0.2.1-rc.9|ok user-upgraded 0
decide|0.2.2-alpha.5|0.2.0-rc.2|0.2.1-rc.2|ok user-upgraded-alpha 1
decide|0.2.2-beta.1|0.2.0-rc.2|0.2.1-rc.2|ok user-upgraded-prerelease 1
decide|0.2.0-rc.2|0.2.1-rc.2|0.2.0-rc.2|deny invalid-manifest 0
decide|0.2.0-alpha.1|0.2.0-rc.1|0.2.0-rc.2|deny below-floor 0
decide|0.2.0-rc.2|0.2.0-rc.2|0.2.0-rc.2|ok baked 0
decide|0.2.0-rc.2|0.2.0-rc.1|0.2.0-rc.2|ok baked 0
decide|0.3.0-rc.1|0.2.0-rc.2|0.2.1-rc.2|ok user-upgraded 0
decide|0.1.9|0.2.0-rc.1|0.2.0-rc.2|deny below-floor 0
decide|0.2.1-rc.2+build.7|0.2.0-rc.2|0.2.1-rc.2|ok baked 0
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
_dprobe() {
    semver_decide "$1" "$2" "$3"
    printf '  decide %-14s floor %-11s baked %-11s -> %s %s safe=%s
'         "$1" "$2" "$3" "$SEMVER_VERDICT" "$SEMVER_REASON" "$SEMVER_SAFE_MODE"
}
_dprobe 0.2.0-rc.2 0.2.0-rc.2 0.2.0-rc.2
_dprobe 0.2.2-alpha.5 0.2.0-rc.2 0.2.1-rc.2

echo
if [ "$_FAIL" -eq 0 ] && [ "$_TOTAL" -eq 95 ]; then
    echo "RESULT ok $_PASS/$_TOTAL"
    exit 0
fi
echo "RESULT fail $_PASS/$_TOTAL (fail=$_FAIL)"
exit 1
