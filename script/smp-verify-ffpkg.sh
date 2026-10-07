#!/bin/sh
# ============================================================================
# smp-verify-ffpkg.sh
# Verify a .ffpkg (UFS2) image against its source   (macOS)
# 用源头（文件夹或 .exfat 镜像）校验 .ffpkg 镜像的内容
# ============================================================================
#
# Why this exists / 为什么需要它:
#   A successful build only proves the tool did not crash. This script proves the
#   image actually holds the same files, at the same paths, with the same sizes —
#   and, for every file small enough, the same bytes.
#   构建成功只说明工具没崩。本脚本证明镜像里的文件路径、大小一致，并在可行范围内
#   逐个比对内容哈希。
#
# The 2 GiB limit / 关于 2 GiB 上限:
#   UFS2Tool's `extract` reads a whole file into memory and refuses anything above
#   2,147,483,647 bytes, so files larger than that cannot be content-verified by
#   any userland tool. This script therefore verifies:
#     * structure          -> fsck_ufs -fn
#     * every path + size  -> UFS2Tool find '*'  (no data read, fast)
#     * content            -> SHA-256 on every file below the limit
#   and reports exactly how much data could NOT be checked. Those files still
#   need a real console test.
#   UFS2Tool 的 extract 会把整个文件读进内存，超过 2 GiB 一律拒绝，所以更大的文件
#   无法用用户态工具做内容校验。脚本会明确报告「未能校验的数据量」。
#
# Usage / 用法:
#   ./smp-verify-ffpkg.sh <image.ffpkg> <source>     # 顺序不限 / either order
#   source 可以是游戏文件夹，也可以是 .exfat 镜像（会自动只读挂载）
#
# Environment / 环境变量:
#   TOOL_DIR=<dir>     UFS2Tool 存放/缓存目录，默认 ~/UFS2Tool
#   UFS2TOOL=<path>    直接指定已安装的 UFS2Tool
#   QUICK=1            跳过内容哈希，只校验结构 + 路径/大小（秒级）
#   MAX_HASH_MIB=<n>   内容哈希的总字节上限（MiB），默认 0 = 不限制
#   WORKDIR=<dir>      解包临时目录，默认用系统临时目录
#
# Exit code / 退出码: 0 = 全部通过；1 = 发现差异或无法完成
# ============================================================================
set -eu

UFS2TOOL_VER="4.1"
TOOL_DIR="${TOOL_DIR:-$HOME/UFS2Tool}"
QUICK="${QUICK:-0}"
MAX_HASH_MIB="${MAX_HASH_MIB:-0}"

usage() {
    cat <<'USAGE'
Usage: smp-verify-ffpkg.sh <image.ffpkg> <source>

  <image.ffpkg>  要校验的 UFS2 镜像
  <source>       源头：游戏文件夹，或 .exfat 镜像（会自动只读挂载）
                 两个参数的顺序不限，脚本按扩展名/类型自动识别

Environment:
  TOOL_DIR=<dir>   UFS2Tool 的存放/缓存目录，默认 ~/UFS2Tool
  UFS2TOOL=<path>  直接指定已安装的 UFS2Tool
  QUICK=1          跳过内容哈希，只校验结构 + 路径/大小
  MAX_HASH_MIB=<n> 内容哈希的总字节上限（MiB），默认 0 = 不限制
  WORKDIR=<dir>    解包临时目录

Exit code: 0 = 全部通过；1 = 发现差异或无法完成

Example:
  ./smp-verify-ffpkg.sh /Volumes/T7/homebrew/PPSA12345.ffpkg \
                        /Volumes/MYSSD/homebrew/PPSA12345.exfat
  ./smp-verify-ffpkg.sh PPSA12345.ffpkg ./PPSA12345-app
USAGE
}

case "${1:-}" in
    -h|--help|"") usage; exit 0 ;;
esac
[ $# -ge 2 ] || { usage; exit 1; }

# Accept the two arguments in either order.
A="$1"; B="$2"
case "$A" in
    *.ffpkg) FFPKG="$A"; SRC="$B" ;;
    *)       FFPKG="$B"; SRC="$A" ;;
esac

phase() { echo; echo "[$(date '+%H:%M:%S')] ==== $* ===="; }
fail()  { echo "FAIL $*"; exit 1; }

SRC_MNT=""
DEV=""
W=""
cleanup() {
    if [ -n "$SRC_MNT" ] && mount | grep -q " on $SRC_MNT "; then
        diskutil unmount "$SRC_MNT" >/dev/null 2>&1 || true
    fi
    if [ -n "$DEV" ]; then
        diskutil eject "$DEV" >/dev/null 2>&1 || true
    fi
    [ -n "$W" ] && rm -rf "$W"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 0. Pre-flight / 前置校验
# ---------------------------------------------------------------------------
phase "0 Pre-flight / 前置校验"
[ -e "$FFPKG" ] || fail "找不到 .ffpkg 镜像 / image not found: $FFPKG"
[ -e "$SRC" ]   || fail "找不到源头 / source not found: $SRC"
case "$FFPKG" in
    *.ffpkg) ;;
    *) echo "WARN $FFPKG 不是 .ffpkg 结尾，仍按 UFS2 镜像处理 / not named .ffpkg" ;;
esac
echo "镜像 image  : $FFPKG ($(ls -lh "$FFPKG" | awk '{print $5}'))"

# ---------------------------------------------------------------------------
# 1. Resolve UFS2Tool / 准备工具
# ---------------------------------------------------------------------------
phase "1 UFS2Tool / 准备工具"
TOOL=""
if [ -n "${UFS2TOOL:-}" ]; then
    [ -x "$UFS2TOOL" ] || fail "UFS2TOOL 指定但不可执行 / not executable: $UFS2TOOL"
    TOOL="$UFS2TOOL"
    echo "使用指定工具 / using provided binary"
else
    ARCH="$(uname -m)"
    case "$ARCH" in
        arm64)  RID="osx-arm64"; SHA="3b2eb0044e62210f88a44432f0d64301a1f810d6ef7720f68281f565651ef10b" ;;
        x86_64) RID="osx-x64";   SHA="d354d8444e6da8fb682a6fb5d7067dd9d5750b8a8088cddac51a3eefec25f778" ;;
        *) fail "不支持的架构 / unsupported architecture: $ARCH" ;;
    esac
    RID_DIR="$TOOL_DIR/$RID-selfcontained"
    TOOL="$RID_DIR/UFS2Tool"
    if [ -x "$TOOL" ]; then
        echo "复用已安装的工具 / reusing installed tool"
    else
        ZIP="$TOOL_DIR/ufs2-$UFS2TOOL_VER-$RID.zip"
        mkdir -p "$TOOL_DIR"
        URL="https://github.com/SvenGDK/UFS2Tool/releases/download/v$UFS2TOOL_VER/$RID-selfcontained.zip"
        echo "下载 download: $URL"
        curl -fL --progress-bar -o "$ZIP" "$URL" || fail "下载失败 / download failed"
        echo "校验 sha256 / verifying…"
        if ! echo "$SHA  $ZIP" | shasum -a 256 -c - >/dev/null 2>&1; then
            rm -f "$ZIP"; fail "sha256 不匹配 / checksum mismatch"
        fi
        echo "OK sha256 匹配 / checksum OK"
        unzip -q -o "$ZIP" -d "$TOOL_DIR" || fail "解压失败 / unzip failed"
        chmod +x "$RID_DIR/UFS2Tool" "$RID_DIR/UFS2Tool.GUI" 2>/dev/null || true
        xattr -r -d com.apple.quarantine "$RID_DIR" 2>/dev/null || true
        [ -x "$TOOL" ] || fail "解压后找不到可执行文件 / executable not found"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Resolve the source / 准备源头
# ---------------------------------------------------------------------------
phase "2 Source / 准备源头"
if [ -d "$SRC" ]; then
    SRC_MNT="$(cd "$SRC" && pwd)"
    echo "源头类型 : 文件夹 / directory"
elif [ -f "$SRC" ]; then
    if [ "$(dd if="$SRC" bs=1 skip=3 count=5 2>/dev/null)" != "EXFAT" ]; then
        fail "源文件不是 exFAT 镜像 / source is not an exFAT image"
    fi
    echo "源头类型 : exFAT 镜像（只读挂载）/ exFAT image (read-only mount)"
    DEV=$(diskutil image attach --noMount "$SRC" | awk '{print $1; exit}')
    [ -n "$DEV" ] || fail "无法附加镜像 / attach failed"
    diskutil mount readOnly "$DEV" >/dev/null || fail "只读挂载失败 / mount failed"
    sleep 1
    SRC_MNT=$(mount | grep "^$DEV " | sed 's/.* on \(.*\) (.*/\1/')
    [ -n "$SRC_MNT" ] || fail "无法确定挂载点 / cannot determine mount point"
else
    fail "源头既不是目录也不是文件 / source is neither a directory nor a file"
fi
echo "挂载点   : $SRC_MNT"

[ -f "$SRC_MNT/eboot.bin" ] || echo "WARN 源头根目录没有 eboot.bin（不一定是错误）"
[ -f "$SRC_MNT/sce_sys/param.json" ] || echo "WARN 源头根目录没有 sce_sys/param.json"

# ---------------------------------------------------------------------------
# 3. Source inventory / 源头清单
# ---------------------------------------------------------------------------
phase "3 Inventory / 源头清单"
W="$(mktemp -d "${WORKDIR:-/tmp}/smpverify.XXXXXX")"
LIST="$W/src.txt"
X="$W/x"; mkdir -p "$X"

find "$SRC_MNT" -type f -print0 | xargs -0 stat -f '%z|%N' 2>/dev/null \
  | while IFS='|' read -r sz f; do printf '%s|%s\n' "$sz" "${f#$SRC_MNT/}"; done \
  | sort -t'|' -k2 > "$LIST"

SRC_FILES=$(wc -l < "$LIST" | tr -d ' ')
[ "$SRC_FILES" -gt 0 ] || fail "源头里没有文件 / no files in source"
SRC_DIRS=$(find "$SRC_MNT" -type d | wc -l | tr -d ' ')
SRC_BYTES=$(awk -F'|' '{s+=$1} END {print s+0}' "$LIST")
echo "文件数 files : $SRC_FILES"
echo "目录数 dirs  : $SRC_DIRS  (含根目录)"
echo "总字节 bytes : $SRC_BYTES"

# ---------------------------------------------------------------------------
# 4. Structure / 文件系统一致性
# ---------------------------------------------------------------------------
phase "4 Structure / fsck_ufs"
FSCK="$("$TOOL" fsck_ufs -fn "$FFPKG" 2>&1 || true)"
echo "$FSCK" | sed 's/^/  /'
RC=0
if echo "$FSCK" | grep -q "is clean"; then
    echo "OK 文件系统干净 / filesystem is clean"
else
    echo "FAIL 文件系统检查未通过"; RC=1
fi

EXPECT=$((SRC_FILES + SRC_DIRS))
GOT=$(echo "$FSCK" | sed -n 's/^\([0-9][0-9]*\) files,.*/\1/p' | head -1)
echo "条目数 entries: 源 $EXPECT / 镜像 ${GOT:-未知}"
if [ -n "$GOT" ] && [ "$GOT" != "$EXPECT" ]; then
    echo "FAIL 条目数不一致"; RC=1
fi

# ---------------------------------------------------------------------------
# 5. Path + size of every entry / 逐条比对路径与大小
# ---------------------------------------------------------------------------
phase "5 Paths & sizes / 路径与大小（全部条目）"
"$TOOL" find "$FFPKG" '*' 2>/dev/null \
  | awk '$1=="FILE"{p=$3; sub(/^\//,"",p); print $2"|"p}' \
  | sort -t'|' -k2 > "$W/img.txt"
IMG_FILES=$(wc -l < "$W/img.txt" | tr -d ' ')
echo "源 $SRC_FILES 个文件 / 镜像 $IMG_FILES 个文件"
if diff -u "$LIST" "$W/img.txt" > "$W/diff.txt" 2>&1; then
    echo "OK 全部 $SRC_FILES 个文件的路径与字节大小完全一致"
else
    echo "FAIL 路径或大小存在差异："
    head -30 "$W/diff.txt" | sed 's/^/    /'
    RC=1
fi

# ---------------------------------------------------------------------------
# 6. Content hashes / 内容哈希（仅 < 2 GiB 的文件）
# ---------------------------------------------------------------------------
LIMIT=2147483647
HASHABLE=$(awk -F'|' -v L="$LIMIT" '$1<L' "$LIST" | wc -l | tr -d ' ')
HASH_BYTES=$(awk -F'|' -v L="$LIMIT" '$1<L{s+=$1} END{print s+0}' "$LIST")
SKIP_COUNT=$(awk -F'|' -v L="$LIMIT" '$1>=L' "$LIST" | wc -l | tr -d ' ')
SKIP_BYTES=$(awk -F'|' -v L="$LIMIT" '$1>=L{s+=$1} END{print s+0}' "$LIST")

if [ "$QUICK" = "1" ]; then
    phase "6 Content / 内容哈希（QUICK=1，已跳过）"
    echo "跳过 $HASHABLE 个文件、$(awk -v b="$HASH_BYTES" 'BEGIN{printf "%.1f", b/1048576}') MiB 的内容校验"
else
    phase "6 Content / 内容哈希（$HASHABLE 个 < 2 GiB 的文件）"
    echo "超出 2 GiB 上限、无法内容校验: $SKIP_COUNT 个文件，合计 $(awk -v b="$SKIP_BYTES" 'BEGIN{printf "%.2f GiB", b/1073741824}')"
    echo ""

    OK=0; BAD=0; ERR=0; DONE_BYTES=0; N=0
    CAPPED=0
    while IFS='|' read -r sz rel; do
        [ "$sz" -lt "$LIMIT" ] || continue
        if [ "$MAX_HASH_MIB" != "0" ]; then
            if [ $(( (DONE_BYTES + sz) / 1048576 )) -gt "$MAX_HASH_MIB" ]; then
                CAPPED=$((CAPPED+1)); continue
            fi
        fi
        N=$((N+1))
        HS=$(shasum -a 256 "$SRC_MNT/$rel" 2>/dev/null | awk '{print $1}')
        rm -f "$X"/* 2>/dev/null || true
        if "$TOOL" extract "$FFPKG" "$X" "$rel" >/dev/null 2>&1; then
            EX=$(find "$X" -type f 2>/dev/null | head -1)
            if [ -n "$EX" ]; then
                HE=$(shasum -a 256 "$EX" 2>/dev/null | awk '{print $1}')
                if [ "$HS" = "$HE" ]; then
                    OK=$((OK+1)); DONE_BYTES=$((DONE_BYTES+sz))
                else
                    BAD=$((BAD+1)); echo "  MISMATCH $rel"
                fi
            else
                ERR=$((ERR+1)); echo "  EXTRACT-EMPTY $rel"
            fi
        else
            ERR=$((ERR+1)); echo "  EXTRACT-FAIL $rel"
        fi
        [ $((N % 25)) -eq 0 ] && echo "  …已比对 $N 个"
    done < "$LIST"

    echo ""
    echo "内容哈希结果 / content summary:"
    echo "  逐位一致 identical : $OK 个文件 ($(awk -v b="$DONE_BYTES" 'BEGIN{printf "%.1f", b/1048576}') MiB)"
    echo "  不一致 mismatched  : $BAD"
    echo "  抽取异常 errors    : $ERR"
    if [ "$CAPPED" != "0" ]; then echo "  因 MAX_HASH_MIB 跳过 : $CAPPED"; fi
    if [ "$BAD" != "0" ] || [ "$ERR" != "0" ]; then RC=1; fi
fi

# ---------------------------------------------------------------------------
# 7. Verdict / 结论
# ---------------------------------------------------------------------------
phase "Verdict / 结论"
echo "  结构 fsck        : $(echo "$FSCK" | grep -q 'is clean' && echo 通过 || echo 未通过)"
echo "  路径+大小        : $(diff -q "$LIST" "$W/img.txt" >/dev/null 2>&1 && echo 全部一致 || echo 存在差异)"
if [ "$QUICK" = "1" ]; then
    echo "  内容哈希         : 已跳过（QUICK=1）"
else
    echo "  内容哈希         : ${OK:-0} 通过 / ${BAD:-0} 不一致 / ${ERR:-0} 异常"
fi
if [ "$SKIP_COUNT" != "0" ]; then
    echo ""
    echo "  注意：$SKIP_COUNT 个文件超过 2 GiB（合计 $(awk -v b="$SKIP_BYTES" 'BEGIN{printf "%.2f GiB", b/1073741824}')）"
    echo "        无法用本工具做内容校验，仍需在真机上验证。"
fi
echo ""
if [ "$RC" = "0" ]; then
    echo "==== 校验通过 / PASS ===="
else
    echo "==== 校验失败 / FAIL ===="
fi
exit "$RC"
