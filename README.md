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
| Unity | `UnityPlayer.dll`、`*_Data/` | Wine + D3DMetal（CrossOver 或 Sikarugir） |
| Wolf RPG | `*.wolf` | Wine：`gal run` |

各引擎的具体做法见 [docs/engines.md](docs/engines.md)。

## Wine 层怎么选

| 方案 | 费用 | 说明 |
| --- | --- | --- |
| **Homebrew Wine**（本仓库脚本默认） | 免费 | 2D galgame 足够，命令行可脚本化 |
| **Sikarugir** | 免费 | 把游戏打包成独立 `.app`，可选 D3DMetal / DXVK，适合 Unity 等 3D 游戏 |
| **CrossOver** | 付费，有试用 | 兼容性和省心程度最好，自带 D3DMetal 和 msync；预算允许就选它 |

不推荐 Whisky（已停止维护）。

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

`gal setup` 会安装 Rosetta 2、Wine、winetricks，并建一个带中日韩字体的默认容器（bottle）。`gal run` 默认用日文区域启动，等价于 Windows 上的 Locale Emulator。

常用命令：

| 命令 | 作用 |
| --- | --- |
| `gal doctor` | 检查环境 |
| `gal setup` | 一次性安装依赖 |
| `gal detect <目录>` | 识别引擎并给出路线 |
| `gal run [-b 容器] [-l ja\|zh\|tw\|ko\|none] <exe>` | 用 Wine 启动 |
| `gal nw <目录>` | 用原生 NW.js 启动 MV / MZ / Tyrano 游戏 |
| `gal bottle <名字>` | 新建独立容器（给需要特殊组件的游戏用） |
| `gal cfg [-b 容器]` | 打开 winecfg |
| `gal kill [-b 容器]` | 结束容器里所有进程 |

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

脚本在 Windows 上编写，只做过语法检查，**还没有在真机上跑过**。第一次用请先执行 `gal doctor`，遇到问题看 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 许可

MIT
