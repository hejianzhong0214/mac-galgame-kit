# mac-galgame-kit

在 Apple Silicon MacBook（以 MacBook Air M3 / 16 GB / 1 TB 为基准）上运行 galgame 和轻量小游戏的方案与辅助脚本。

目标只有一个：**每个游戏都走它能走的最快的那条路**。

## 核心原则

性能从高到低只有三档，能用上一档就不要用下一档：

| 档位 | 方式 | 开销 | 适用 |
| --- | --- | --- | --- |
| 1 | **原生 arm64 运行** | 无 | Ren'Py、RPG Maker MV/MZ、RGSS（XP/VX/VA）、NScripter、TyranoScript、自带 Mac 版的游戏 |
| 2 | **Wine 翻译层**（Rosetta 2 + Wine） | CPU 约损失 20–30%，2D 游戏感觉不到 | 吉里吉里、SiglusEngine、CatSystem2、BGI、Unity、Wolf RPG 等只有 Windows 版的游戏 |
| 3 | **Windows ARM 虚拟机**（Parallels / VMware Fusion） | 最大，常驻吃 6–8 GB 内存 | 只在第 2 档被 DRM 或反作弊卡住时才用 |

很多 galgame 引擎本身是跨平台的，只是发行商只打了 Windows 包。把游戏数据交给原生引擎跑，比任何翻译层都快、都省电，这是这套方案比“一律装 CrossOver”多出来的那部分性能。

## 按引擎选路线

先识别引擎：

```bash
./bin/gal detect /path/to/游戏目录
```

| 引擎 | 特征文件 | 推荐路线 |
| --- | --- | --- |
| Ren'Py | `renpy/`、`*.rpa` | 原生：游戏自带 `.app`，或用 Ren'Py SDK 启动 |
| RPG Maker MV / MZ | `js/rpg_core.js`、`js/rmmz_core.js` | 原生：`gal nw <目录>`（arm64 NW.js） |
| RPG Maker XP / VX / VX Ace | `*.rgssad`、`*.rgss2a`、`*.rgss3a` | 原生：mkxp-z |
| NScripter / ONScripter | `nscript.dat`、`arc.nsa` | 原生：ONScripter 系 |
| TyranoScript | `tyrano/` | 原生：`gal nw <目录>` |
| 吉里吉里 2 / Z | `*.xp3` | Wine：`gal run` |
| SiglusEngine / RealLive | `Scene.pck`、`Gameexe.dat` | Wine：`gal run` |
| CatSystem2、BGI、其他日系引擎 | `*.int`、`BGI.exe` 等 | Wine：`gal run` |
| Unity | `UnityPlayer.dll`、`*_Data/` | Wine + DXVK（`gal dxvk`）；不行再用 CrossOver 的 D3DMetal |
| Wolf RPG | `*.wolf` | Wine：`gal run` |

各引擎的具体做法见 [docs/engines.md](docs/engines.md)。

## Wine 层怎么选

| 方案 | 费用 | 说明 |
| --- | --- | --- |
| **Homebrew Wine**（本仓库脚本默认） | 免费 | 2D galgame 足够，命令行可脚本化 |
| **Sikarugir** | 免费 | 把游戏打包成独立 `.app`，可选 D3DMetal / DXVK，适合 Unity 等 3D 游戏 |
| **CrossOver** | 付费，有试用 | 兼容性和省心程度最好，自带 D3DMetal 和 msync；预算允许就选它 |

不推荐 Whisky（已停止维护）。

## GalBox：拖进去就能玩

`app/` 里是一个原生 macOS 小软件 GalBox。把游戏的 exe、游戏文件夹或 zip 拖进窗口（或拖到 Dock 图标上），它会自动：

1. 解压 zip（正确处理中文、日文系统打包的文件名）。
2. 找出主程序 exe，排除崩溃处理器、卸载程序、来路不明的“激活启动器”等；包里有多个游戏时会拒绝并列出。
3. 识别引擎，给这个游戏单独建一个 Wine 容器，并断开容器到你主目录的映射。
4. 把游戏拷进容器；Unity 游戏自动装 DXVK；RPG Maker MV/MZ 走原生 NW.js。
5. 加入游戏库，点“开始”即可。原来的文件不会被改动。

编译安装（需要 Xcode 命令行工具，`xcode-select --install`）：

```bash
./app/build.sh --install
```

装好后在 `~/Applications/GalBox.app`，可以拖到 Dock。第一次用前要先跑过 `gal setup` 装好 Wine；Unity 游戏需要把 [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS/releases) 的 `dxvk-macOS-*.tar.gz`（不带 `-builtin`）放进 `~/Games/gal/downloads/`。

GalBox 背后调用的是 `gal import`，命令行也能直接用：

```bash
./bin/gal import -l ja /path/to/游戏文件夹或zip
```

## 快速开始

需要先装好 [Homebrew](https://brew.sh)。

```bash
git clone <本仓库地址> && cd mac-galgame-kit
```

```bash
./bin/gal setup
```

```bash
./bin/gal run /path/to/game.exe
```

`gal setup` 会安装 Rosetta 2 和 Wine，并建一个默认容器（bottle），容器里已把 Windows 的中日韩字体名映射到 macOS 自带字体，不需要另外下载字体。`gal run` 默认用日文区域启动，等价于 Windows 上的 Locale Emulator。

Mac 连不上 GitHub 时 Homebrew 装不了 Wine，改用离线安装：在能下载的地方拿到 [Wine 的 macOS 构建](https://github.com/Gcenx/macOS_Wine_builds/releases)（`wine-stable-*-osx64.tar.xz`），然后：

```bash
./bin/gal setup --wine-tarball /path/to/wine-stable-xxx-osx64.tar.xz
```

这种方式装在 `~/Games/gal/runtimes/`，不需要管理员密码。

常用命令：

| 命令 | 作用 |
| --- | --- |
| `gal import [-l 语言] <exe\|文件夹\|zip>` | 一键导入（GalBox 用的就是它） |
| `gal list` / `gal remove <名字>` | 列出 / 删除导入的游戏 |
| `gal doctor` | 检查环境 |
| `gal setup` | 一次性安装依赖 |
| `gal detect <目录>` | 识别引擎并给出路线 |
| `gal run [-b 容器] [-l ja\|zh\|tw\|ko\|none] <exe>` | 用 Wine 启动 |
| `gal nw <目录>` | 用原生 NW.js 启动 MV / MZ / Tyrano 游戏 |
| `gal bottle <名字>` | 新建独立容器（给需要特殊组件的游戏用） |
| `gal cfg [-b 容器]` | 打开 winecfg |
| `gal kill [-b 容器]` | 结束容器里所有进程 |
| `gal launcher <名字> [-b 容器] <exe>` | 生成可双击的启动器 `~/Games/gal/launch/<名字>.command` |
| `gal start <名字>` | 运行启动器（从 SSH 远程启动游戏必须用它） |
| `gal dxvk [-b 容器] <tar.gz>` | 给容器装 DXVK，解决 Unity 等 D3D11 游戏图形初始化失败 |

数据默认放在 `~/Games/gal/`，可用环境变量 `GAL_HOME` 改。

## 性能要点

MacBook Air 没有风扇，持续高负载会降频。详细说明见 [docs/performance.md](docs/performance.md)，最关键的几条：

- 关掉低电量模式，重负载游戏插电玩。
- 游戏全屏运行，macOS 会自动进入游戏模式，给游戏更高的 CPU/GPU 优先级。
- 3D 游戏把帧率锁在 60，分辨率不要超过 1920×1200；Wine 里保持 Retina 模式关闭（脚本默认已关）。
- 16 GB 内存对这类游戏很宽裕，不要为了玩 galgame 常驻一个虚拟机。

## 其他能玩的东西

- **Steam / App Store 原生游戏**：直接装，优先选标了 Apple Silicon 的。
- **iOS / iPadOS 游戏**：M 系列芯片可以原生运行，App Store 没上架 Mac 的可以用 PlayCover 侧载自己购买的应用。
- **主机平台的 galgame**：PSP 用 PPSSPP，PS Vita 用 Vita3K，都有原生 arm64 版本。请使用自己持有的游戏转储。

## 关于上传到 GitHub

这个仓库只放文档和脚本。`.gitignore` 已经排除了游戏本体、容器和存档目录，**不要把游戏文件、破解补丁或汉化包提交进来**。

## 状态

已在 MacBook Air M3 / macOS 15.6 / Wine 11.0 上验证：`gal doctor`、离线 `gal setup`、容器创建、注册表默认设置导入、`gal run` 的日文和中文区域切换。

另外用一个 Unity 6 游戏验证了 `gal launcher` / `gal start` 和 DXVK 路线：画面和日文字体显示正常。GalBox 的编译、通过“打开方式”导入、`gal import` 的文件夹和 zip 导入（含 GBK 文件名、多游戏拒绝）、`list`、`remove` 也在真机上测过。

还没验证：GalBox 窗口里的拖放和按钮（需要人点）、`gal nw` 和 NW.js 路线、游戏内视频播放。遇到问题看 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 许可

MIT
