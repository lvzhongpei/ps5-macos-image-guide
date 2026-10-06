#!/bin/sh
# ============================================================================
# smp-mkexfat.sh
# PS5 folder-format game dump  ->  mountable .exfat image   (macOS)
# 把 PS5「文件夹格式」游戏 dump 打包成 ShadowMountPlus 可挂载的 .exfat 镜像
# ============================================================================
#
# Based on / 基准: drakmor/ShadowMountPlus  ->  mkexfat_macos.sh
#
# Differences from the official script / 相对官方脚本的增量:
#   1. Forces a 64 KiB cluster size. The official README requires it:
#      "If you create an exFAT (.exfat) image manually, use a 64 KB cluster size.
#       Smaller clusters can cause a noticeable performance loss."
#      强制 64 KiB 簇——官方 README 明确要求，小簇会显著掉性能。
#   2. Filters macOS / scene-release junk files (.DS_Store, ._*, _DUPLEX_, ...).
#      过滤 macOS 与发布组夹带的垃圾文件。
#   3. Verifies file count and byte count after copying.
#      复制后校验文件数与字节数。
#
# Usage / 用法:
#   ./smp-mkexfat.sh <game_dir> [output_file]
#   REUSE=1 ./smp-mkexfat.sh <game_dir> [output_file]   # resume / 断点续传
#
# No sudo required. / 全程不需要 sudo。
# ============================================================================
set -eu

case "${1:-}" in
    -h|--help|"")
        cat <<'USAGE'
Usage: smp-mkexfat.sh <game_dir> [output_file]

  <game_dir>     PS5 folder dump, must contain eboot.bin and sce_sys/param.json
                 PS5 文件夹格式游戏目录，根下必须有 eboot.bin 与 sce_sys/param.json
  [output_file]  output image path, defaults to ./<game_dir_basename>.exfat
                 输出镜像路径，默认 ./<目录名>.exfat

Environment / 环境变量:
  REUSE=1        reuse an already formatted image and resume the copy
                 复用已格式化好的镜像，断点续传

Example / 示例:
  ./smp-mkexfat.sh "/Volumes/MYSSD/downloads/ps5/PPSA12345" "/Volumes/MYSSD/homebrew/PPSA12345.exfat"
USAGE
        exit 0
        ;;
esac

INPUT_DIR="${1%/}"
OUTPUT="${2:-$PWD/$(basename "$INPUT_DIR").exfat}"
REUSE="${REUSE:-0}"

CLUSTER_SIZE=65536                  # 64 KiB -- required by ShadowMountPlus / 官方要求
META_FIXED=$((32 * 1024 * 1024))    # boot region, upcase table, root dir, misc
MIN_SLACK=$((64 * 1024 * 1024))
SPARE_MIN=$((64 * 1024 * 1024))
SPARE_MAX=$((512 * 1024 * 1024))
ENTRY_META_BYTES=256

phase() { echo; echo "[$(date '+%H:%M:%S')] ==== $* ===="; }

# ---------------------------------------------------------------------------
# 0. Pre-flight checks / 前置校验
# ---------------------------------------------------------------------------
phase "0 Pre-flight / 前置校验"
if [ ! -d "$INPUT_DIR" ]; then echo "FAIL 游戏目录不存在 / game dir not found: $INPUT_DIR"; exit 1; fi
if [ ! -f "$INPUT_DIR/eboot.bin" ]; then echo "FAIL 缺少 eboot.bin / missing eboot.bin"; exit 1; fi
if [ ! -f "$INPUT_DIR/sce_sys/param.json" ]; then echo "FAIL 缺少 sce_sys/param.json / missing sce_sys/param.json"; exit 1; fi
echo "源目录 source  : $INPUT_DIR"
echo "eboot.bin      : $(stat -f '%z' "$INPUT_DIR/eboot.bin") bytes"

mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
LABEL="$(basename "$OUTPUT" .exfat)"
echo "镜像 image     : $OUTPUT"
echo "卷标 label     : $LABEL"

SIZES_FILE=$(mktemp)
MNT=""
DEV=""

# The same exclusion list is applied to both the size scan and rsync.
# 体积统计与 rsync 使用完全一致的排除清单。
find "$INPUT_DIR" \
    -name '.DS_Store' -prune -o \
    -name '._*' -prune -o \
    -name '.fseventsd' -prune -o \
    -name '.Trashes' -prune -o \
    -name '.Spotlight-V100' -prune -o \
    -name 'GKinto.com.txt' -prune -o \
    -name '_DUPLEX_' -prune -o \
    -type f -print0 | xargs -0 stat -f '%z' 2>/dev/null > "$SIZES_FILE" || true

FILE_COUNT=$(wc -l < "$SIZES_FILE" | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then echo "FAIL 未采集到任何文件 / no files collected"; exit 1; fi
DIR_COUNT=$(find "$INPUT_DIR" -type d -name '_DUPLEX_' -prune -o -type d -print | wc -l | tr -d ' ')
RAW_BYTES=$(awk '{s+=$1} END {print s+0}' "$SIZES_FILE")
echo "纳入 files     : $FILE_COUNT files / $DIR_COUNT dirs / $RAW_BYTES bytes"

# ---------------------------------------------------------------------------
# 1. Calculate image size / 计算镜像尺寸
# ---------------------------------------------------------------------------
phase "1 Sizing / 计算尺寸"
DATA_BYTES=$(awk -v cls="$CLUSTER_SIZE" '{s += int(($1 + cls - 1) / cls) * cls} END {print s + 0}' "$SIZES_FILE")
DATA_CLUSTERS=$(( (DATA_BYTES + CLUSTER_SIZE - 1) / CLUSTER_SIZE ))
FAT_BYTES=$((DATA_CLUSTERS * 4))
BITMAP_BYTES=$(( (DATA_CLUSTERS + 7) / 8 ))
ENTRY_BYTES=$(( (FILE_COUNT + DIR_COUNT) * ENTRY_META_BYTES ))
BASE_TOTAL=$((DATA_BYTES + FAT_BYTES + BITMAP_BYTES + ENTRY_BYTES + META_FIXED))
SPARE_BYTES=$((BASE_TOTAL / 200))
if [ "$SPARE_BYTES" -lt "$SPARE_MIN" ]; then SPARE_BYTES=$SPARE_MIN; fi
if [ "$SPARE_BYTES" -gt "$SPARE_MAX" ]; then SPARE_BYTES=$SPARE_MAX; fi
TOTAL=$((BASE_TOTAL + SPARE_BYTES))
MIN_TOTAL=$((RAW_BYTES + MIN_SLACK))
if [ "$TOTAL" -lt "$MIN_TOTAL" ]; then TOTAL=$MIN_TOTAL; fi
MB=$(( (TOTAL + 1048576 - 1) / 1048576 ))
rm -f "$SIZES_FILE"

IMG_GIB=$((MB / 1024))
AVAIL_MB=$(( $(df -k "$(dirname "$OUTPUT")" | awk 'NR==2 {print $4}') / 1024 ))
AVAIL_GIB=$((AVAIL_MB / 1024))
echo "簇大小 cluster : $CLUSTER_SIZE bytes"
echo "数据区 data    : $DATA_BYTES bytes"
echo "镜像大小 image : ${MB} MB (~${IMG_GIB} GiB)"
echo "可用空间 free  : ${AVAIL_GIB} GiB"
if [ "$MB" -ge "$AVAIL_MB" ]; then echo "FAIL 磁盘空间不足 / not enough free space"; exit 1; fi

# ---------------------------------------------------------------------------
# 2. Create the image file / 创建镜像文件
# ---------------------------------------------------------------------------
phase "2 Create image / 创建镜像文件"
SKIP_FORMAT=0
if [ "$REUSE" = "1" ] && [ -f "$OUTPUT" ] && [ "$(dd if="$OUTPUT" bs=1 skip=3 count=5 2>/dev/null)" = "EXFAT" ]; then
    echo "复用已格式化的镜像 / reusing formatted image: $(du -h "$OUTPUT" | cut -f1)"
    SKIP_FORMAT=1
else
    rm -f "$OUTPUT"
    mkfile -n "${MB}m" "$OUTPUT"   # sparse file, instant / 稀疏文件，瞬间完成
    echo "已创建稀疏镜像 / sparse image created: $(ls -lh "$OUTPUT" | awk '{print $5}')"
fi

# ---------------------------------------------------------------------------
# 3. Attach as a block device and format / 挂成块设备并格式化
# ---------------------------------------------------------------------------
phase "3 Attach + format / 挂载设备 + 格式化（64 KiB 簇）"
if [ "$SKIP_FORMAT" = "1" ]; then
    echo "已跳过格式化 / format skipped"
else
    # newfs_exfat needs a /dev node -- it cannot format a plain file.
    # newfs_exfat 只认 /dev 设备节点，不能直接对文件操作。
    DEV=$(diskutil image attach --noMount "$OUTPUT" | awk '{print $1; exit}')
    if [ -z "$DEV" ]; then
        DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$OUTPUT" | awk 'NR==1 {print $1; exit}')
    fi
    if [ -z "$DEV" ]; then echo "FAIL 镜像挂载为设备失败 / attach failed"; exit 1; fi
    echo "设备节点 device: $DEV"
    # -b takes bytes-per-cluster directly (not sectors).
    # -b 直接传【字节/簇】，不是扇区数。
    newfs_exfat -b "$CLUSTER_SIZE" -v "$LABEL" "/dev/r${DEV##*/}" 2>&1 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# 4. Mount / 挂载
# ---------------------------------------------------------------------------
phase "4 Mount / 挂载"
if [ -z "$DEV" ]; then
    DEV=$(diskutil image attach --noMount "$OUTPUT" | awk '{print $1; exit}')
fi
if [ -z "$DEV" ]; then echo "FAIL 无法挂载镜像设备 / cannot attach"; exit 1; fi
# Use diskutil mount, NOT `mount -t exfat` (broken on recent macOS).
# 必须用 diskutil mount，新系统上 `mount -t exfat` 会失败。
diskutil mount "$DEV" >/dev/null
sleep 1
MNT=$(mount | grep "^$DEV " | sed 's/.* on \(.*\) (.*/\1/')
if [ -z "$MNT" ]; then echo "FAIL 挂载失败 / mount failed"; exit 1; fi
echo "挂载点 mount   : $MNT"
echo "卷信息 volume  : $(mount | grep "^$DEV ")"

# ---------------------------------------------------------------------------
# 5. Copy / 拷贝
# ---------------------------------------------------------------------------
phase "5 Copy / 开始拷贝（$FILE_COUNT 个文件）"
START=$(date +%s)
# Keep the official flag set: `rsync -r` alone does NOT create AppleDouble ._* files.
# 保持官方参数：只用 `rsync -r` 不会产生 ._* 影子文件（加上 -ltDHh 才会）。
rsync -r --progress \
    --exclude='.DS_Store' \
    --exclude='._*' \
    --exclude='.fseventsd' \
    --exclude='.Trashes' \
    --exclude='.Spotlight-V100' \
    --exclude='GKinto.com.txt' \
    --exclude='_DUPLEX_' \
    "$INPUT_DIR"/ "$MNT"/
echo "拷贝耗时 elapsed: $(( $(date +%s) - START )) s"

# ---------------------------------------------------------------------------
# 6. Clean macOS leftovers / 清理 macOS 残留
# ---------------------------------------------------------------------------
phase "6 Cleanup / 清理 macOS 残留"
dot_clean -m "$MNT" 2>/dev/null || true
rm -rf "$MNT/.fseventsd" "$MNT/.Spotlight-V100" 2>/dev/null || true
# Order matters: deleting .fseventsd sends it to the trash, recreating .Trashes.
# 顺序有讲究：删 .fseventsd 会进废纸篓，所以 .Trashes 必须最后删。
rm -rf "$MNT/.Trashes" 2>/dev/null || true
find "$MNT" -name '._*' -delete 2>/dev/null || true
echo "镜像根目录 image root:"
ls -a "$MNT" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 7. Verify / 校验
# ---------------------------------------------------------------------------
phase "7 Verify / 校验文件数与字节数"
OUT_COUNT=$(find "$MNT" -type f | wc -l | tr -d ' ')
OUT_BYTES=$(find "$MNT" -type f -print0 | xargs -0 stat -f '%z' 2>/dev/null | awk '{s+=$1} END {print s+0}')
echo "源   source: $FILE_COUNT files / $RAW_BYTES bytes"
echo "镜像 image : $OUT_COUNT files / $OUT_BYTES bytes"
if [ "$FILE_COUNT" = "$OUT_COUNT" ] && [ "$RAW_BYTES" = "$OUT_BYTES" ]; then
    echo "OK 校验通过 / verification passed"
else
    echo "FAIL 校验不一致，请勿使用该镜像 / mismatch, do not use this image"
fi
echo "关键文件 key files:"
for f in eboot.bin sce_sys/param.json ampr_emu.index; do
    if [ -f "$MNT/$f" ]; then echo "    OK  $f"; else echo "    --  $f (无 / absent)"; fi
done

# ---------------------------------------------------------------------------
# 8. Flush and unmount / 落盘并卸载
# ---------------------------------------------------------------------------
phase "8 Sync + unmount / 同步并卸载"
sync
if diskutil unmount "$MNT" >/dev/null 2>&1; then echo "已卸载 unmounted: $MNT"; else echo "警告 warn: 卸载失败，请手动检查 / unmount failed"; fi
if diskutil eject "$DEV" >/dev/null 2>&1; then echo "已弹出 ejected: $DEV"; fi

phase "Done / 完成"
ls -lh "$OUTPUT"
echo "镜像就绪 / image ready: $OUTPUT"
