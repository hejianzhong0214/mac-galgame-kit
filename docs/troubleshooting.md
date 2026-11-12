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
