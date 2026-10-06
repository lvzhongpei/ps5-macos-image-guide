#!/bin/sh
# ============================================================================
# smp-mkffpkg.sh
# PS5 folder-format game dump  ->  UFS2 image (.ffpkg)   (macOS)
# 把 PS5「文件夹格式」游戏 dump 打包成 ShadowMountPlus 推荐的 .ffpkg 镜像
# ============================================================================
#
# Backend / 后端: SvenGDK/UFS2Tool  (BSD-2-Clause, cross-platform)
#   Downloads the official *self-contained* release, which already bundles the
#   .NET 8 runtime — you do NOT need to install dotnet.
#   下载官方 self-contained 包，已内置 .NET 运行时，无需另装 dotnet。
#
# Why prefer this over .exfat / 为什么优于 exFAT 路线:
#   * No filesystem is mounted, so macOS never writes AppleDouble "._*" files,
#     ".fseventsd" or ".Trashes" into the image. No cleanup needed.
#     全程不挂载，因此不会产生 ._* / .fseventsd / .Trashes，无需清理。
#   * No sudo. One command. And you get a real filesystem check (fsck_ufs).
#     不需要 sudo，一条命令，而且有真正的文件系统自检。
#
# Usage / 用法:
#   ./smp-mkffpkg.sh <game_dir> [output_file]
#
# Environment / 环境变量:
#   TOOL_DIR=<dir>        where UFS2Tool lives / caches   (default: ~/UFS2Tool)
#   UFS2TOOL=<path>       use an already installed binary, skip download
#   BLOCK=32768 FRAG=4096 override UFS2 parameters
#   DRY=1                 dry run only, do not create the image
#
# No sudo required. / 全程不需要 sudo。
# ============================================================================
set -eu

UFS2TOOL_VER="4.1"
TOOL_DIR="${TOOL_DIR:-$HOME/UFS2Tool}"
BLOCK="${BLOCK:-32768}"
FRAG="${FRAG:-4096}"

case "${1:-}" in
    -h|--help|"")
        cat <<'USAGE'
Usage: smp-mkffpkg.sh <game_dir> [output_file]

  <game_dir>     PS5 folder dump, must contain eboot.bin and sce_sys/param.json
                 PS5 文件夹格式游戏目录，根下必须有 eboot.bin 与 sce_sys/param.json
  [output_file]  output image path, defaults to ./<game_dir_basename>.ffpkg
                 输出镜像路径，默认 ./<目录名>.ffpkg

Environment / 环境变量:
  TOOL_DIR=<dir>   UFS2Tool 的存放/缓存目录，默认 ~/UFS2Tool
  UFS2TOOL=<path>  直接指定已安装的 UFS2Tool，跳过下载
  BLOCK / FRAG     覆盖 UFS2 参数，默认 32768 / 4096
  DRY=1            只做干跑（newfs -N），不真正创建镜像

Example / 示例:
  ./smp-mkffpkg.sh "/Volumes/MYSSD/downloads/ps5/PPSA12345" \
                   "/Volumes/MYSSD/homebrew/PPSA12345.ffpkg"
USAGE
        exit 0
        ;;
esac

INPUT_DIR="${1%/}"
OUTPUT="${2:-$PWD/$(basename "$INPUT_DIR").ffpkg}"
DRY="${DRY:-0}"

phase() { echo; echo "[$(date '+%H:%M:%S')] ==== $* ===="; }
fail()  { echo "FAIL $*"; exit 1; }

# ---------------------------------------------------------------------------
# 0. Pre-flight / 前置校验
# ---------------------------------------------------------------------------
phase "0 Pre-flight / 前置校验"
[ -d "$INPUT_DIR" ] || fail "游戏目录不存在 / game dir not found: $INPUT_DIR"
[ -f "$INPUT_DIR/eboot.bin" ] || fail "缺少 eboot.bin / missing eboot.bin"
[ -f "$INPUT_DIR/sce_sys/param.json" ] || fail "缺少 sce_sys/param.json / missing sce_sys/param.json"
echo "源目录 source  : $INPUT_DIR"
echo "eboot.bin      : $(stat -f '%z' "$INPUT_DIR/eboot.bin") bytes"

# Warn if the dump looks nested — the most common reason a PS5 will not see the game.
# 如果看起来多套了一层目录，给出警告——这是 PS5 认不出游戏最常见的原因。
if find "$INPUT_DIR" -mindepth 2 -maxdepth 2 -name eboot.bin 2>/dev/null | grep -q .; then
    echo "WARN 目录里似乎还有一层含 eboot.bin 的子目录，请确认源目录选对了 / possible extra nesting level"
fi

mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
echo "镜像 image     : $OUTPUT"
echo "UFS2 参数      : -O 2 -b $BLOCK -f $FRAG -D &lt;源&gt;"

# ---------------------------------------------------------------------------
# 1. Resolve UFS2Tool / 准备工具
# ---------------------------------------------------------------------------
phase "1 UFS2Tool / 准备工具"
TOOL=""
if [ -n "${UFS2TOOL:-}" ]; then
    [ -x "$UFS2TOOL" ] || fail "UFS2TOOL 指定但不可执行 / not executable: $UFS2TOOL"
    TOOL="$UFS2TOOL"
    echo "使用指定工具 / using provided binary: $TOOL"
else
    ARCH="$(uname -m)"
    case "$ARCH" in
        arm64)  RID="osx-arm64"; SHA="3b2eb0044e62210f88a44432f0d64301a1f810d6ef7720f68281f565651ef10b" ;;
        x86_64) RID="osx-x64";   SHA="d354d8444e6da8fb682a6fb5d7067dd9d5750b8a8088cddac51a3eefec25f778" ;;
        *) fail "不支持的架构 / unsupported architecture: $ARCH" ;;
    esac
    RID_DIR="$TOOL_DIR/$RID-selfcontained"
    TOOL="$RID_DIR/UFS2Tool"
    echo "架构 arch      : $ARCH → $RID"

    if [ -x "$TOOL" ]; then
        echo "复用已安装的工具 / reusing installed tool: $TOOL"
    else
        ZIP="$TOOL_DIR/ufs2-$UFS2TOOL_VER-$RID.zip"
        mkdir -p "$TOOL_DIR"
        URL="https://github.com/SvenGDK/UFS2Tool/releases/download/v$UFS2TOOL_VER/$RID-selfcontained.zip"
        echo "下载 download  : $URL"
        curl -fL --progress-bar -o "$ZIP" "$URL" || fail "下载失败 / download failed"

        echo "校验校验和 / verifying sha256…"
        if ! echo "$SHA  $ZIP" | shasum -a 256 -c - >/dev/null 2>&1; then
            rm -f "$ZIP"
            fail "sha256 不匹配，已删除下载文件 / checksum mismatch, download removed"
        fi
        echo "OK sha256 匹配 / checksum OK"

        unzip -q -o "$ZIP" -d "$TOOL_DIR" || fail "解压失败 / unzip failed"
        chmod +x "$RID_DIR/UFS2Tool" "$RID_DIR/UFS2Tool.GUI" 2>/dev/null || true
        # Gatekeeper quarantine must be removed or macOS refuses to run it.
        # 必须去掉 Gatekeeper 隔离标记，否则会被拒绝执行。
        xattr -r -d com.apple.quarantine "$RID_DIR" 2>/dev/null || true
        [ -x "$TOOL" ] || fail "解压后找不到可执行文件 / executable not found: $TOOL"
        echo "安装完成 / installed: $TOOL"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Dry run / 干跑确认参数与尺寸
# ---------------------------------------------------------------------------
phase "2 Dry run / 参数与尺寸"
"$TOOL" newfs -N -O 2 -b "$BLOCK" -f "$FRAG" -D "$INPUT_DIR" "$OUTPUT" 2>&1 | sed 's/^/    /'

if [ "$DRY" = "1" ]; then
    phase "Done / 完成"
    echo "DRY=1，未创建镜像 / dry run only, no image created"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Build / 构建镜像
# ---------------------------------------------------------------------------
phase "3 Build / 构建镜像"
START=$(date +%s)
rm -f "$OUTPUT"
"$TOOL" newfs -O 2 -b "$BLOCK" -f "$FRAG" -D "$INPUT_DIR" "$OUTPUT" 2>&1 | sed 's/^/    /'
[ -f "$OUTPUT" ] || fail "镜像未生成 / image was not created"
echo "构建耗时 elapsed: $(( $(date +%s) - START )) s"

# ---------------------------------------------------------------------------
# 4. fsck / 文件系统一致性自检
# ---------------------------------------------------------------------------
phase "4 fsck / 文件系统自检"
FSCK_OUT="$("$TOOL" fsck_ufs -fn "$OUTPUT" 2>&1 || true)"
echo "$FSCK_OUT" | sed 's/^/    /'
if echo "$FSCK_OUT" | grep -q "is clean"; then
    echo "OK 文件系统干净 / filesystem is clean"
else
    echo "FAIL 文件系统检查未通过，请勿使用该镜像 / fsck did not report clean"
fi

# ---------------------------------------------------------------------------
# 5. Verify a large file / 抽验大文件哈希
# ---------------------------------------------------------------------------
phase "5 Verify / 哈希抽验"
TMP="$(mktemp -d)"
if "$TOOL" extract "$OUTPUT" "$TMP" eboot.bin >/dev/null 2>&1 && [ -f "$TMP/eboot.bin" ]; then
    SRC_HASH=$(shasum -a 256 "$INPUT_DIR/eboot.bin" | awk '{print $1}')
    OUT_HASH=$(shasum -a 256 "$TMP/eboot.bin" | awk '{print $1}')
    echo "源   source: $SRC_HASH"
    echo "镜像 image : $OUT_HASH"
    if [ "$SRC_HASH" = "$OUT_HASH" ]; then
        echo "OK eboot.bin 与源完全一致 / matches the source"
    else
        echo "FAIL eboot.bin 哈希不一致 / hash mismatch"
    fi
else
    echo "WARN 无法抽取 eboot.bin 做校验 / could not extract eboot.bin"
fi
rm -rf "$TMP"

# ---------------------------------------------------------------------------
# 6. Report / 结果
# ---------------------------------------------------------------------------
phase "Done / 完成"
ls -lh "$OUTPUT"
echo "镜像就绪 / image ready: $OUTPUT"
echo "把它放进 <盘根>/homebrew/ 或 /data/homebrew/ 即可 / place it in <drive>/homebrew/"
