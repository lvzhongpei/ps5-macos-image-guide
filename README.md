# ps5-macos-image-guide

**在 macOS 上把 PS5「文件夹格式」游戏 dump 做成 ShadowMountPlus 可挂载的镜像——两种格式都讲清楚。**

**Turn a PS5 folder-format game dump into a mountable image on macOS — both formats covered.**

小白向 · 中英双语 · 含一键脚本与故障排查

> **[阅读完整教程 →](https://lvzhongpei.github.io/ps5-macos-image-guide/)**

---

## 两种格式，先选一个

ShadowMountPlus 官方把 **UFS2（`.ffpkg`）列为推荐格式**，把 `exFAT` 定位为「给那些不按外置盘方式处理就跑不正常的游戏用」。

| | `.ffpkg`（UFS2） | `.exfat` |
|---|---|---|
| 官方定位 | **常规首选** | 外置盘兼容场景 |
| 制作步骤 | 一条命令，不挂载 | 八步，需要挂载写文件 |
| macOS 残留文件 | **完全不会产生** | 会带出 `._*`，需 `dot_clean` 清理 |
| 空间效率 | 更高 | 簇末填充浪费更多 |
| 需要装额外工具 | 需要（UFS2Tool，40 MB 自包含） | **不需要**，macOS 自带命令 |
| 能否手工改内容 | 要用 UFS2Tool | **可以挂载后用 Finder 改** |

**默认走 `.ffpkg`。** 只有当某个游戏确实「只有按外置盘方式处理才正常」时，才为它改做 `.exfat`。

教程首页有一个**交互式决策器**，三个问题直接给结论：[lvzhongpei.github.io/ps5-macos-image-guide](https://lvzhongpei.github.io/ps5-macos-image-guide/)

## 快速开始

### UFS2（`.ffpkg`，官方推荐）

```bash
mkdir -p ~/bin
curl -fsSL -o ~/bin/smp-mkffpkg.sh \
  https://raw.githubusercontent.com/lvzhongpei/ps5-macos-image-guide/main/script/smp-mkffpkg.sh
chmod +x ~/bin/smp-mkffpkg.sh

~/bin/smp-mkffpkg.sh \
  "/Volumes/MYSSD/downloads/ps5/PPSA12345" \
  "/Volumes/MYSSD/homebrew/PPSA12345.ffpkg"
```

脚本会自动按你的架构下载官方 UFS2Tool、比对 sha256、解压去隔离，然后构建镜像并跑 `fsck_ufs` 自检与哈希抽验。**不需要 sudo，也不需要安装 .NET。**

### exFAT（`.exfat`，兼容场景）

```bash
curl -fsSL -o ~/bin/smp-mkexfat.sh \
  https://raw.githubusercontent.com/lvzhongpei/ps5-macos-image-guide/main/script/smp-mkexfat.sh
chmod +x ~/bin/smp-mkexfat.sh

~/bin/smp-mkexfat.sh \
  "/Volumes/MYSSD/downloads/ps5/PPSA12345" \
  "/Volumes/MYSSD/homebrew/PPSA12345.exfat"
```

支持 `REUSE=1` 断点续传。**全程只用 macOS 自带命令。**

## 仓库结构

```
.
├── index.html          总览：名词 / 前置检查 / 格式决策器 / PS5 部署 / 公共排错 / 原理对比
├── exfat.html          exFAT 完整教程：八步命令 + 四项校验 + 专属排错
├── ffpkg.html          UFS2 完整教程：安装 UFS2Tool + 参数详解 + fsck 自检
├── assets/
│   ├── style.css       三个页面共用样式（终端/极客风，深色默认 + 浅色切换）
│   └── app.js          主题 / 中英切换 / 复制按钮 / 决策器 / 尺寸计算器
├── script/
│   ├── smp-mkffpkg.sh  UFS2 (.ffpkg) 构建脚本
│   └── smp-mkexfat.sh  exFAT (.exfat) 构建脚本
└── .nojekyll
```

## 两个必须知道的硬性要求

| 要求 | 说明 |
|---|---|
| **exFAT 必须用 64 KiB 簇** | 官方 README：*"If you create an exFAT (.exfat) image manually, use a 64 KB cluster size. Smaller clusters can cause a noticeable performance loss."* |
| **目录不多套一层** | 游戏根下必须直接是 `eboot.bin` 与 `sce_sys/param.json`。多一层子目录 PS5 就识别不到。 |

镜像做好后放进 `<盘根>/homebrew/`（外置盘）或 `/data/homebrew/`（内置存储），具体见教程第 05 节。

## 踩过的坑（都写在教程里）

- macOS 的 `od` 在数据行后会多输出一个空行，`od ... | awk` 必须加 `NR==1` 守卫
- `newfs_exfat` 只认 `/dev/diskn` 设备节点，不能直接格式化文件
- 新系统上 `mount -t exfat` 会失败，必须用 `diskutil mount`
- `rsync` 加 `-ltDHh` 会触发 AppleDouble `._*` 影子文件，用官方的 `rsync -r` 反而干净
- `.fseventsd` / `.Trashes` 无法根除，删除顺序有讲究
- ShadowMountPlus 仓库里的 `mkufs2.sh` 是 **FreeBSD 专用**，macOS 上不能跑

## 参考资料

- [drakmor/ShadowMountPlus](https://github.com/drakmor/ShadowMountPlus) —— 镜像格式规范、官方 macOS 构建脚本、运行时配置
- [SvenGDK/UFS2Tool](https://github.com/SvenGDK/UFS2Tool) —— 跨平台 UFS2 工具（BSD-2-Clause）
- [EchoStretch/kstuff-lite](https://github.com/EchoStretch/kstuff-lite/releases) —— 所需的内核层 payload

## 免责声明

本仓库**只讨论文件系统与磁盘镜像的格式转换技术**，所有内容都可在 macOS 上用系统自带命令或开源工具复现。

它**不提供、不托管、不链接、不索引**任何游戏内容、游戏下载链接或破解资源。

请仅对你**自己合法拥有**的游戏备份使用本项目。是否对你的设备进行越狱、以及如何使用生成的镜像，完全由你自行决定并承担全部后果。请遵守你所在国家和地区的法律。

越狱与镜像挂载本身存在风险。官方文档明确提醒：在部分固件上挂载镜像可能导致关机异常或数据损坏，请务必备份重要数据。

---

<sub>站内教程与终端输出均来自真实运行记录（exFAT 路线实测 232.94 GiB / 105 文件；UFS2 路线在 Apple Silicon 上实测构建 + fsck + 哈希比对），路径与标题 ID 已脱敏。</sub>
