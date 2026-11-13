# 常见问题

## 乱码、方块字、启动即闪退

1. 确认用了正确的区域：日文游戏 `-l ja`（默认），简体汉化版通常是 `-l zh`，但有些汉化补丁仍然要求日文区域，两个都试一下。
2. 文字是方块说明游戏要的字体名没有映射。映射表在 `share/gal-defaults.reg`，按同样格式加一行（左边是游戏要的 Windows 字体名，右边是 macOS 上有的字体），然后重新执行 `gal bottle default` 导入。

3. 游戏路径里不要有 Wine 当前区域无法表示的字符。最稳妥是把游戏放在纯英文路径下。

## 片头动画或过场视频黑屏、跳过、卡死

老 galgame 常用 WMV / MPEG-1 视频，依赖 Windows 的解码器。按顺序尝试：

1. 确认装了 GStreamer 运行库：

   ```bash
   brew install --cask gstreamer-runtime
   ```

2. 给这个游戏单独建一个容器，用 winetricks 装解码组件（会影响其他游戏，所以不要装进 default）：

   ```bash
   ./bin/gal bottle video-fix
   ```

   ```bash
   brew install winetricks
   ```

   ```bash
   WINEPREFIX=~/Games/gal/bottles/video-fix winetricks -q quartz lavfilters
   ```

3. 仍然不行就换 CrossOver，它对媒体播放的修补最多。
4. 很多游戏的设置里可以关闭片头动画，或者视频文件就在游戏目录里，可以单独用播放器看。

## “无法打开，因为无法验证开发者”

对被拦截的应用执行一次：

```bash
xattr -dr com.apple.quarantine "/Applications/Wine Stable.app"
```

## `gal setup` 装 Wine 失败

Homebrew 的 Wine 包从 GitHub 下载，连不上 GitHub 就会失败。按 README 的离线安装方式，用 `gal setup --wine-tarball` 安装。

## 想直接用 `wine` 命令

`gal` 会自己找到 Wine，不需要它在 PATH 里。想手动调用的话，离线安装的 Wine 在 `~/Games/gal/runtimes/Wine Stable.app/Contents/Resources/wine/bin/`。

## 游戏窗口极小或模糊

Retina 模式关闭时由系统放大，属于正常。窗口太小就用游戏自带的全屏；想让文字更锐利可以打开 Retina 模式再在 winecfg 的显示里把 DPI 调到 192，但 3D 游戏会明显变慢：

```bash
WINEPREFIX=~/Games/gal/bottles/default wine reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d y /f
```

## 从 SSH 启动报 “no driver could be loaded”

SSH 会话连不到 Mac 的窗口系统。用启动器在桌面会话里运行：

```bash
./bin/gal launcher 游戏名 -b 容器 /path/to/game.exe
```

```bash
./bin/gal start 游戏名
```

## Unity 游戏报 “Failed to initialize graphics” / “d3d11: failed to create device”

Wine 自带的 D3D11 底层是 macOS 的 OpenGL 4.1，功能不够，较新的 Unity（2021 以后，尤其 Unity 6）会直接初始化失败。加 `-force-vulkan` 参数只对打包了 Vulkan 渲染器的游戏有效，日志里出现 “was not built from editor” 就说明没打包。

先试 DXVK-macOS（免费）：它把 D3D11 翻译成 Vulkan，再经 MoltenVK 转成 Metal。从 [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS/releases) 下载不带 `-builtin` 的包，给这个游戏单独建容器后装进去：

```bash
./bin/gal dxvk -b 容器 /path/to/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz
```

已验证：Unity 6（6000.3）的「シグレ・メロウタイム」体验版在 M3 上用 DXVK 1.10.3 能以 D3D11 FL 11.0 初始化并持续渲染。

DXVK 也不行时用 D3DMetal：苹果的 D3D→Metal 翻译层，兼容性最好。CrossOver 自带；免费途径是 Sikarugir 等打包工具。

## 画面超出屏幕，上下被菜单栏、刘海或 Dock 挡住

Unity 游戏全屏时按整块屏幕出图（MacBook Air 13 寸是 1470×956，包括菜单栏和刘海那一条、以及 Dock 的位置），在 Mac 上会被菜单栏和 Dock 盖住一截。

先试**全屏**：游戏默认按自己的设置启动，多数情况下切到全屏（游戏设置里，或 Unity 游戏按 Alt+Enter）就能完整显示。

全屏也不行时，在游戏的“…”菜单里勾选“画面适应屏幕”：Unity 游戏启动时会加上 `-screen-fullscreen 0 -screen-width … -screen-height …`，改成窗口模式，窗口正好等于菜单栏和 Dock 之间的可用区域。命令行：

```bash
./bin/gal display 游戏名 fit
```

改回默认用 `native`。有的游戏会无视这些启动参数、自己把窗口设成整块屏幕大小，这种只能靠全屏或游戏内的分辨率设置。

注意：macOS 版 Wine 不支持虚拟桌面（`explorer /desktop=…` 会被忽略），所以没法用虚拟桌面来限制画面大小；非 Unity 游戏如果也出现这个问题，在游戏自己的设置里改成窗口模式或较小的分辨率。

## Unity 游戏画面正常但鼠标点不动

Unity 6 等较新版本会调用 `EnableMouseInPointer`，改用“指针消息”接收鼠标。Wine 11.0 稳定版只有空实现，`Player.log` 里会有 `EnableMouseInPointer failed`，游戏收不到点击（[Wine bug 53847](https://bugs.winehq.org/show_bug.cgi?id=53847)）。Wine 开发分支在 2026 年 2–7 月补上了这部分，11.15 以后的开发版都包含。

解决：装 Wine 开发版（与稳定版并存），只让 Unity 游戏的容器改用它。

1. 从 [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds/releases) 下载 `wine-devel-*-osx64.tar.xz`，然后：

   ```bash
   ./bin/gal setup --wine-tarball /path/to/wine-devel-11.21-osx64.tar.xz
   ```

2. 已导入的游戏切过去（会顺带升级容器，存档不受影响）。GalBox 里在游戏的“…”菜单勾选“使用 Wine 开发版”即可，命令行是：

   ```bash
   ./bin/gal wine -b 容器名 devel
   ```

装了开发版之后，`gal import` / GalBox 新导入的 Unity 游戏会自动用开发版。查看某个容器用的版本：`gal wine -b 容器名`。

已验证（2026-11-13，MacBook Air M3）：Unity 6 游戏换到 Wine 11.21 后鼠标点击恢复正常，不再报 `EnableMouseInPointer failed`，DXVK 照常工作。

## 游戏卡住、关不掉

```bash
./bin/gal kill
```

## RPG Maker MV 游戏用 `gal nw` 打不开

- `package.json` 的 `"name"` 为空：改成非空。
- 白屏：游戏太老，和新版 NW.js 不兼容。用 `NWJS_VERSION=v0.60.0 ./bin/gal nw-install` 换一个旧一些的版本再试。
- 报找不到 `.node` 或 `.dll`：游戏用了 Windows 原生插件，改用 `gal run Game.exe`。

## 正版游戏的认证 / DRM 通不过

Wine 对各家认证程序的支持不一致。优先选 Steam 版或 DLsite 的无 DRM 版本；实在不行用 Windows ARM 虚拟机。

## 存档在哪

- Wine 游戏：游戏目录内，或 `~/Games/gal/bottles/<容器>/drive_c/users/<用户名>/` 下的 `Documents`、`AppData`、`Saved Games`。
- 原生路线：通常在游戏目录内。

备份存档只需要拷这些目录，不用备份整个容器。
