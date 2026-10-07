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

> **其实还有两种格式**：`.ffpfs`（未压缩 PFS 镜像）和 `.ffpfsc`（压缩 PFS 容器），官方都标着 **Experimental**。它们不是 `.ffpkg` 的升级版，而是「用速度换空间」——`.ffpfsc` 的读取吞吐只有约 150–250 MB/s，**约为内置盘速度的 1/10**，适合体积大但读取强度低的游戏。制作要用 [PSBrew/MkPFS](https://github.com/PSBrew/MkPFS)（Python，macOS 可用）。详见教程 [3.4 节](https://lvzhongpei.github.io/ps5-macos-image-guide/index.html#pfs)。

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

### 格式互转：已有的 `.exfat` → `.ffpkg`

如果手上已经有一个做好的 `.exfat` 镜像，**不需要重新打包游戏**：

```bash
curl -fsSL -o ~/bin/smp-exfat-to-ffpkg.sh \
  https://raw.githubusercontent.com/lvzhongpei/ps5-macos-image-guide/main/script/smp-exfat-to-ffpkg.sh
chmod +x ~/bin/smp-exfat-to-ffpkg.sh

~/bin/smp-exfat-to-ffpkg.sh /Volumes/MYSSD/homebrew/PPSA12345.exfat
```

原理：macOS 能原生挂载 exFAT，所以直接把**只读挂载的卷**交给 UFS2Tool 当输入目录——不解包、不产生中间副本、**源镜像内容全程只读、不会被改动或删除**。脚本会自动校验结构、扫描 macOS 垃圾文件、跑 `fsck_ufs` 自检，并在源小于 2 GiB 时额外做一次全量解包比对。

> **源文件的 mtime 会变，这是正常的**：macOS 在 attach 磁盘镜像时会更新源文件的修改时间，纯只读挂载也一样。**文件内容与大小不变**（实测：转换前后 366 个文件的字节总数与 `eboot.bin` 的 SHA-256 逐位一致）。想自己验证就转换前后各跑一次 `shasum -a 256`。

> **注意体积**：UFS2Tool 的自动尺寸会额外加约 13.5% 的元数据开销，所以转出来的 `.ffpkg` **可能比原来的 `.exfat` 更大**（实测一个 600 MiB 的镜像转成 668 MiB）。格式本身仍优于 exFAT（随机读性能、元数据更规整），但如果你在意的是省空间，这一步不一定划算。

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
│   ├── smp-mkffpkg.sh         UFS2 (.ffpkg) 构建脚本
│   ├── smp-mkexfat.sh         exFAT (.exfat) 构建脚本
│   └── smp-exfat-to-ffpkg.sh  已有 .exfat → .ffpkg 格式转换
└── .nojekyll
```

## 两个必须知道的硬性要求

| 要求 | 说明 |
|---|---|
| **exFAT 必须用 64 KiB 簇** | 官方 README：*"If you create an exFAT (.exfat) image manually, use a 64 KB cluster size. Smaller clusters can cause a noticeable performance loss."* |
| **目录不多套一层** | 游戏根下必须直接是 `eboot.bin` 与 `sce_sys/param.json`。多一层子目录 PS5 就识别不到。 |

| 放在哪块盘 | 放哪个目录 |
|---|---|
| PS5 主机自带硬盘 | `/data/homebrew/` |
| PS5 内置 M.2 扩展槽 | `/mnt/ext1/homebrew/` |
| USB 外接盘（含 M.2 硬盘盒） | `/mnt/usb0/homebrew/` |

注意：**主机盘和 M.2 由 PS5 用自己的独占格式管理，Mac 读不了**——要先把 M.2 装进 PS5 并由主机格式化，再用 FTP 或 U 盘中转传文件，不能像外置盘那样直接从 Mac 拷。详见教程第 05 节。

## 踩过的坑（都写在教程里）

- macOS 的 `od` 在数据行后会多输出一个空行，`od ... | awk` 必须加 `NR==1` 守卫
- `newfs_exfat` 只认 `/dev/diskn` 设备节点，不能直接格式化文件
- 新系统上 `mount -t exfat` 会失败，必须用 `diskutil mount`
- `rsync` 加 `-ltDHh` 会触发 AppleDouble `._*` 影子文件，用官方的 `rsync -r` 反而干净
- `.fseventsd` / `.Trashes` 无法根除，删除顺序有讲究
- ShadowMountPlus 仓库里的 `mkufs2.sh` 是 **FreeBSD 专用**，macOS 上不能跑
- MkPFS 的 `--block-size` 默认 `65536`，小文件多的目录会产生块对齐浪费，极端情况下镜像比源还大

## 参考资料

- [drakmor/ShadowMountPlus](https://github.com/drakmor/ShadowMountPlus) —— 镜像格式规范、官方 macOS 构建脚本、运行时配置
- [SvenGDK/UFS2Tool](https://github.com/SvenGDK/UFS2Tool) —— 跨平台 UFS2 工具（BSD-2-Clause）
- [EchoStretch/kstuff-lite](https://github.com/EchoStretch/kstuff-lite/releases) —— 所需的内核层 payload

## 免责声明

本仓库**只讨论文件系统与磁盘镜像的格式转换技术**，所有内容都可在 macOS 上用系统自带命令或开源工具复现。

它**不提供、不托管、不链接、不索引**任何游戏内容、游戏下载链接或破解资源。

请仅对你**自己合法拥有**的游戏备份使用本项目。是否对你的设备进行越狱、以及如何使用生成的镜像，完全由你自行决定并承担全部后果。请遵守你所在国家和地区的法律。

越狱与镜像挂载本身存在风险。官方原文提醒：*"Mounting images can cause shutdown problems and data corruption on **internal drives**"* ——**内置存储（主机盘和 M.2）比外置盘更容易出问题，老固件尤其明显**。缓解手段是默认开启的 `mount_read_only=1`（别关掉），并请务必先备份重要数据。

---

<sub>站内教程与终端输出均来自真实运行记录（exFAT 路线实测 232.94 GiB / 105 文件；UFS2 路线在 Apple Silicon 上实测构建 + fsck + 哈希比对），路径与标题 ID 已脱敏。</sub>
