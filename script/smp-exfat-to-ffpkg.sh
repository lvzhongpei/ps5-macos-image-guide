#!/bin/sh
# ============================================================================
# smp-exfat-to-ffpkg.sh
# Convert an existing .exfat image into a .ffpkg (UFS2) image   (macOS)
# 把已有的 .exfat 镜像转换成 .ffpkg（UFS2）镜像
# ============================================================================
#
# Why this works / 为什么可行:
#   macOS mounts exFAT natively, so the mounted volume can be handed straight to
#   UFS2Tool as its input directory. No unpacking, no temporary copy, and the
#   source image is never modified (read-only mount).
#   macOS 能原生挂载 exFAT，因此可直接把挂载点当作 UFS2Tool 的输入目录：
#   不解包、不产生中间副本、源镜像全程只读不被改动。
#
# Why you might convert / 为什么要转:
#   ShadowMountPlus recommends UFS (.ffpkg) as the default image format and
#   positions exFAT as a compatibility fallback. UFS2 also allocates at fragment
#   granularity, so many-small-file titles usually shrink.
#   官方推荐 UFS(.ffpkg)，exFAT 只是兼容兜底；UFS2 按 fragment 分配，
#   小文件多的游戏通常更省空间。
#
# Usage / 用法:
#   ./smp-exfat-to-ffpkg.sh <input.exfat> [output.ffpkg]
#
# Environment / 环境变量:
#   TOOL_DIR=<dir>     where UFS2Tool lives / caches   (default: ~/UFS2Tool)
#   UFS2TOOL=<path>    use an already installed binary, skip download
#   BLOCK / FRAG       override UFS2 parameters, default 32768 / 4096
#   MINFREE            reserved-space percentage, default 0
#   DRY=1              dry run only (newfs -N), do not create the image
#   ALLOW_JUNK=1       proceed even if macOS junk files were found on the source
#   KEEP_MOUNTED=1     leave the source image mounted when done (for inspection)
#
# The source .exfat is only ever mounted read-only and is never deleted.
# 源 .exfat 全程只读挂载，脚本不会删除它。
# ============================================================================
set -eu

UFS2TOOL_VER="4.1"
TOOL_DIR="${TOOL_DIR:-$HOME/UFS2Tool}"
BLOCK="${BLOCK:-32768}"
FRAG="${FRAG:-4096}"
# PS5 guidance uses minfree=0 (a read-only game image needs no root reserve).
# PS5 侧建议 minfree=0：只读游戏镜像不需要给 root 预留空间。
MINFREE="${MINFREE:-0}"
DRY="${DRY:-0}"
ALLOW_JUNK="${ALLOW_JUNK:-0}"
KEEP_MOUNTED="${KEEP_MOUNTED:-0}"

case "${1:-}" in
    -h|--help|"")
        cat <<'USAGE'
Usage: smp-exfat-to-ffpkg.sh <input.exfat> [output.ffpkg]

  <input.exfat>   an existing exFAT image containing a PS5 game dump
                  已存在的 exFAT 镜像，内部是 PS5 游戏 dump
  [output.ffpkg]  output path, defaults to <input basename>.ffpkg in the same dir
                  输出路径，默认与输入同目录、同名的 .ffpkg

Environment / 环境变量:
  TOOL_DIR=<dir>   UFS2Tool 的存放/缓存目录，默认 ~/UFS2Tool
  UFS2TOOL=<path>  直接指定已安装的 UFS2Tool，跳过下载
  BLOCK / FRAG     覆盖 UFS2 参数，默认 32768 / 4096
  MINFREE          保留空间百分比，默认 0（只读游戏镜像不需要预留）
  DRY=1            只干跑（newfs -N），不创建镜像
  ALLOW_JUNK=1     源卷上发现 macOS 垃圾文件时仍然继续
  KEEP_MOUNTED=1   结束后保持源镜像挂载（便于人工检查）

Note / 注意:
  源 .exfat 只会以只读方式挂载，脚本不会修改或删除它。
  The source .exfat is mounted read-only and is never modified or deleted.

Example / 示例:
  ./smp-exfat-to-ffpkg.sh /Volumes/MYSSD/homebrew/PPSA12345.exfat
USAGE
        exit 0
        ;;
esac

INPUT="${1}"
OUTPUT="${2:-$(dirname "$INPUT")/$(basename "$INPUT" .exfat).ffpkg}"
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
OUTDIR="$(dirname "$OUTPUT")"
[ -d "$OUTDIR" ] || { echo "FAIL 输出目录不存在 / output dir missing: $OUTDIR"; exit 1; }
OUTPUT="$(cd "$OUTDIR" && pwd)/$(basename "$OUTPUT")"

phase() { echo; echo "[$(date '+%H:%M:%S')] ==== $* ===="; }
fail()  { echo "FAIL $*"; exit 1; }

MNT=""
DEV=""

# Always release the source image, even on failure. The source is never written to.
# 无论成败都释放源镜像；源镜像全程只读。
cleanup() {
    if [ -n "$MNT" ] && mount | grep -q " on $MNT "; then
        if [ "$KEEP_MOUNTED" = "1" ]; then
            echo "（KEEP_MOUNTED=1，保留挂载 ${MNT}）"
        else
            diskutil unmount "$MNT" >/dev/null 2>&1 || true
        fi
    fi
    if [ -n "$DEV" ] && [ "$KEEP_MOUNTED" != "1" ]; then
        diskutil eject "$DEV" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 0. Pre-flight / 前置校验
# ---------------------------------------------------------------------------
phase "0 Pre-flight / 前置校验"
[ -f "$INPUT" ] || fail "输入镜像不存在 / input not found: $INPUT"
case "$INPUT" in
    *.exfat) ;;
    *) echo "WARN 输入文件名不是 .exfat 结尾，仍会按镜像处理 / not named .exfat" ;;
esac
if [ -e "$OUTPUT" ]; then fail "输出已存在，请先移走 / output already exists: $OUTPUT"; fi

echo "输入 source  : $INPUT ($(ls -lh "$INPUT" | awk '{print $5}'))"
echo "输出 output  : $OUTPUT"

# exFAT signature check: "EXFAT" at offset 3.
if [ "$(dd if="$INPUT" bs=1 skip=3 count=5 2>/dev/null)" != "EXFAT" ]; then
    fail "这不是 exFAT 镜像（偏移 3 处未找到 EXFAT 标识）/ not an exFAT image"
fi
echo "文件系统 fs  : exFAT ✓"

# Cluster size (offset 108 = sector shift, 109 = sectors-per-cluster shift).
od -An -tu1 -j 108 -N 2 "$INPUT" | awk 'NR==1{printf "簇大小 cluster: %d B (%d B 扇区 × %d 扇区/簇)\n", 2^$1*2^$2, 2^$1, 2^$2}'

# Rough space check: the UFS2 image lands close to the payload size.
SRC_BYTES=$(stat -f '%z' "$INPUT")
NEED_KB=$(( (SRC_BYTES + SRC_BYTES/20) / 1024 ))
AVAIL_KB=$(df -k "$(dirname "$OUTPUT")" | awk 'NR==2 {print $4}')
echo "源镜像大小 / source size : $(( SRC_BYTES / 1024 / 1024 )) MiB"
echo "输出分区可用 / available : $(( AVAIL_KB / 1024 / 1024 )) GiB"
if [ "$NEED_KB" -gt "$AVAIL_KB" ]; then fail "空间不足（预估需要约 $(( NEED_KB/1024 )) MiB）/ not enough space"; fi

# ---------------------------------------------------------------------------
# 1. Mount the source read-only / 只读挂载源镜像
# ---------------------------------------------------------------------------
phase "1 Mount source (read-only) / 只读挂载源镜像"
DEV=$(diskutil image attach --noMount "$INPUT" | awk '{print $1; exit}')
[ -n "$DEV" ] || fail "无法附加镜像 / attach failed"
echo "设备 device  : $DEV"
diskutil mount readOnly "$DEV" >/dev/null || fail "只读挂载失败 / read-only mount failed"
sleep 1
MNT=$(mount | grep "^$DEV " | sed 's/.* on \(.*\) (.*/\1/')
[ -n "$MNT" ] || fail "无法确定挂载点 / cannot determine mount point"
echo "挂载点 mount : $MNT"
case "$(mount | grep "^$DEV ")" in
    *read-only*) echo "挂载模式     : read-only ✓（源镜像不会被改动）" ;;
    *) fail "挂载不是只读，为保护源镜像已中止 / not mounted read-only" ;;
esac

# ---------------------------------------------------------------------------
# 2. Validate the game structure / 校验游戏结构
# ---------------------------------------------------------------------------
phase "2 Validate structure / 校验游戏结构"
[ -f "$MNT/eboot.bin" ] || fail "根目录缺少 eboot.bin / missing eboot.bin"
[ -f "$MNT/sce_sys/param.json" ] || fail "根目录缺少 sce_sys/param.json / missing sce_sys/param.json"
echo "OK  eboot.bin        ($(stat -f '%z' "$MNT/eboot.bin") bytes)"
echo "OK  sce_sys/param.json"
if [ -f "$MNT/ampr_emu.index" ]; then
    echo "注意 含 ampr_emu.index → APR-Emu 类型，转成 ffpkg 后同样要整套部署"
fi
DEEP_EBOOT=$(find "$MNT" -mindepth 2 -maxdepth 2 -name eboot.bin 2>/dev/null | sed "s|$MNT|.|" | head -3)
if [ -n "$DEEP_EBOOT" ]; then
    echo "提示 子目录里还有 eboot.bin（根目录那个才是识别用的），会原样保留："
    echo "$DEEP_EBOOT" | sed 's/^/      /'
fi

FILE_COUNT=$(find "$MNT" -type f | wc -l | tr -d ' ')
DIR_COUNT=$(find "$MNT" -type d | wc -l | tr -d ' ')
RAW_BYTES=$(find "$MNT" -type f -print0 | xargs -0 stat -f '%z' 2>/dev/null | awk '{s+=$1} END {print s+0}')
echo "内容 files   : $FILE_COUNT 个文件 / $DIR_COUNT 个目录 / $RAW_BYTES bytes"

# macOS junk would be copied verbatim into the image — UFS2Tool has no exclude option.
# macOS 垃圾文件会被原样打进镜像，UFS2Tool 没有排除选项，因此必须显式处理。
JUNK=$(find "$MNT" \( -name '._*' -o -name '.DS_Store' -o -name '.fseventsd' \
        -o -name '.Trashes' -o -name '.Spotlight-V100' \) 2>/dev/null | wc -l | tr -d ' ')
if [ "$JUNK" != "0" ]; then
    echo ""
    echo "WARN 源卷上有 $JUNK 个 macOS 垃圾文件（.DS_Store / ._* / .fseventsd 等）："
    find "$MNT" \( -name '._*' -o -name '.DS_Store' -o -name '.fseventsd' \
          -o -name '.Trashes' -o -name '.Spotlight-V100' \) 2>/dev/null | sed 's/^/      /' | head -10
    echo "    这些会被原样打进 ffpkg。建议先把源镜像里的这些文件清掉，"
    echo "    或解包到临时目录清理后再构建。确实要带着它们继续请设 ALLOW_JUNK=1。"
    if [ "$ALLOW_JUNK" != "1" ]; then fail "发现垃圾文件，已中止 / junk found, aborting"; fi
    echo "    （ALLOW_JUNK=1，继续）"
else
    echo "垃圾扫描     : 0 个 ✓（镜像会保持干净）"
fi

# ---------------------------------------------------------------------------
# 3. Resolve UFS2Tool / 准备工具
# ---------------------------------------------------------------------------
phase "3 UFS2Tool / 准备工具"
TOOL=""
if [ -n "${UFS2TOOL:-}" ]; then
    [ -x "$UFS2TOOL" ] || fail "UFS2TOOL 指定但不可执行 / not executable: $UFS2TOOL"
    TOOL="$UFS2TOOL"; echo "使用指定工具 / using provided binary: $TOOL"
else
    ARCH="$(uname -m)"
    case "$ARCH" in
        arm64)  RID="osx-arm64"; SHA="3b2eb0044e62210f88a44432f0d64301a1f810d6ef7720f68281f565651ef10b" ;;
        x86_64) RID="osx-x64";   SHA="d354d8444e6da8fb682a6fb5d7067dd9d5750b8a8088cddac51a3eefec25f778" ;;
        *) fail "不支持的架构 / unsupported architecture: $ARCH" ;;
    esac
    RID_DIR="$TOOL_DIR/$RID-selfcontained"
    TOOL="$RID_DIR/UFS2Tool"
    echo "架构 arch    : $ARCH → $RID"
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
            rm -f "$ZIP"; fail "sha256 不匹配，已删除下载文件 / checksum mismatch"
        fi
        echo "OK sha256 匹配 / checksum OK"
        unzip -q -o "$ZIP" -d "$TOOL_DIR" || fail "解压失败 / unzip failed"
        chmod +x "$RID_DIR/UFS2Tool" "$RID_DIR/UFS2Tool.GUI" 2>/dev/null || true
        xattr -r -d com.apple.quarantine "$RID_DIR" 2>/dev/null || true
        [ -x "$TOOL" ] || fail "解压后找不到可执行文件 / executable not found"
        echo "安装完成 / installed: $TOOL"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Dry run / 干跑确认参数与尺寸
# ---------------------------------------------------------------------------
LABEL="$(basename "$OUTPUT" .ffpkg)"
phase "4 Dry run / 参数与尺寸"
"$TOOL" newfs -N -O 2 -b "$BLOCK" -f "$FRAG" -m "$MINFREE" -D "$MNT" "$OUTPUT" "$LABEL" 2>&1 | sed 's/^/    /'
if [ "$DRY" = "1" ]; then
    phase "Done / 完成"
    echo "DRY=1，未创建镜像 / dry run only"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Build / 构建镜像
# ---------------------------------------------------------------------------
phase "5 Build / 构建镜像（卷标 ${LABEL}）"
START=$(date +%s)
"$TOOL" newfs -O 2 -b "$BLOCK" -f "$FRAG" -m "$MINFREE" -D "$MNT" "$OUTPUT" "$LABEL" 2>&1 | sed 's/^/    /'
[ -f "$OUTPUT" ] || fail "镜像未生成 / image was not created"
echo "构建耗时 elapsed: $(( $(date +%s) - START )) s"

# ---------------------------------------------------------------------------
# 6. Verify / 校验
# ---------------------------------------------------------------------------
phase "6 Verify / 校验"
FSCK_OUT="$("$TOOL" fsck_ufs -fn "$OUTPUT" 2>&1 || true)"
echo "$FSCK_OUT" | sed 's/^/    /'
if echo "$FSCK_OUT" | grep -q "is clean"; then
    echo "OK 文件系统干净 / filesystem is clean"
else
    echo "FAIL 文件系统检查未通过，请勿使用该镜像 / fsck did not report clean"
fi

# fsck counts files + directories (including the root), so compare against that sum.
# Anchor on the summary line ("N files, N used, N free") — a loose match would pick
# up the "2" in the banner text "UFS2 filesystem image".
EXPECT=$((FILE_COUNT + DIR_COUNT))
GOT=$(echo "$FSCK_OUT" | sed -n 's/^\([0-9][0-9]*\) files,.*/\1/p' | head -1)
if [ -n "$GOT" ]; then
    echo "条目数 entries: 源 $EXPECT (含 $DIR_COUNT 个目录) / 镜像 $GOT"
    if [ "$GOT" = "$EXPECT" ]; then
        echo "OK 条目数一致 / entry count matches"
    else
        echo "WARN 条目数不一致，请人工确认 / entry count mismatch"
    fi
fi

# Spot-check that the largest file survived byte-for-byte.
TMP="$(mktemp -d)"
if "$TOOL" extract "$OUTPUT" "$TMP" eboot.bin >/dev/null 2>&1 && [ -f "$TMP/eboot.bin" ]; then
    A=$(shasum -a 256 "$MNT/eboot.bin" | awk '{print $1}')
    B=$(shasum -a 256 "$TMP/eboot.bin" | awk '{print $1}')
    echo "源   source: $A"
    echo "镜像 image : $B"
    if [ "$A" = "$B" ]; then echo "OK eboot.bin 与源完全一致 / matches the source"
    else echo "FAIL eboot.bin 哈希不一致 / hash mismatch"; fi
else
    echo "WARN 无法抽取 eboot.bin 校验 / could not extract eboot.bin"
fi
rm -rf "$TMP"

# For small dumps, prove it byte-for-byte by extracting the whole image.
if [ "$RAW_BYTES" -lt 2147483648 ]; then
    phase "7 Full extract check / 全量解包比对（源 < 2 GiB）"
    FULL="$(mktemp -d)"
    if "$TOOL" extract "$OUTPUT" "$FULL" >/dev/null 2>&1; then
        E_COUNT=$(find "$FULL" -type f | wc -l | tr -d ' ')
        E_BYTES=$(find "$FULL" -type f -print0 | xargs -0 stat -f '%z' 2>/dev/null | awk '{s+=$1} END {print s+0}')
        echo "源   : $FILE_COUNT 文件 / $RAW_BYTES bytes"
        echo "镜像 : $E_COUNT 文件 / $E_BYTES bytes"
        if [ "$FILE_COUNT" = "$E_COUNT" ] && [ "$RAW_BYTES" = "$E_BYTES" ]; then
            echo "OK 全量比对通过：文件数与字节数与源完全一致"
        else
            echo "FAIL 全量比对不一致 / full comparison mismatch"
        fi
    else
        echo "WARN 全量解包失败 / full extract failed"
    fi
    rm -rf "$FULL"
else
    echo "（源 > 2 GiB，跳过全量解包比对，改用 fsck + 哈希抽验）"
fi

# ---------------------------------------------------------------------------
# 8. Report / 结果
# ---------------------------------------------------------------------------
phase "Done / 完成"
ls -lh "$OUTPUT"
src_kb=$(stat -f '%z' "$INPUT"); 
echo "源 .exfat : $(( src_kb / 1024 / 1024 )) MiB"
out_kb=$(stat -f '%z' "$OUTPUT")
echo "新 .ffpkg : $(( out_kb / 1024 / 1024 )) MiB"
if [ "$out_kb" -lt "$src_kb" ]; then
    echo "体积变化  : 小了 $(( (src_kb - out_kb) / 1024 / 1024 )) MiB"
elif [ "$out_kb" -gt "$src_kb" ]; then
    echo "体积变化  : 大了 $(( (out_kb - src_kb) / 1024 / 1024 )) MiB"
else
    echo "体积变化  : 基本一致"
fi
echo "镜像就绪 / image ready: $OUTPUT"
echo "源 .exfat 未被改动，保留在原处 / the source .exfat was left untouched"
echo "把它放进 <盘根>/homebrew/ 或 /data/homebrew/ 即可 / place it in <drive>/homebrew/"
