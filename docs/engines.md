# 各引擎的运行方法

## 原生路线

### Ren'Py

1. 游戏目录里有 `.app` 就直接开。
2. 只有 Windows 包时：下载与游戏版本接近的 [Ren'Py SDK](https://www.renpy.org/latest.html)（游戏的 `renpy/__init__.py` 或 `log.txt` 里能看到版本号），把游戏目录放进 SDK 的项目目录，在 SDK 启动器里选中后点 Launch Project。
3. Ren'Py 7 的老游戏用 Ren'Py 7.x 的 SDK，8 的用 8.x，跨大版本容易报错。

### RPG Maker MV / MZ

这两代引擎就是一个网页加 NW.js 外壳，Windows 包里的 `Game.exe` 只是 x86 版的 NW.js。换成 arm64 的 NW.js 就是原生运行：

```bash
./bin/gal nw /path/to/游戏目录
```

第一次运行会下载 arm64 版 NW.js 到 `~/Games/gal/runtimes/`。

注意：

- MV 游戏的 `package.json` 里 `"name"` 常常是空字符串，新版 NW.js 会拒绝启动。脚本会提示，把它改成任意非空值即可。
- 存档在游戏目录的 `www/save/`（MV）或 `save/`（MZ）。
- 少数游戏用了只有 Windows 版的原生插件（`.node`、`.dll`），这种只能退回 Wine。

### RPG Maker XP / VX / VX Ace（RGSS）

用 [mkxp-z](https://github.com/mkxp-z/mkxp-z)，它是 RGSS 的开源重实现，有 Apple Silicon 版本。把 mkxp-z 的可执行文件和配置放到游戏目录，在 `mkxp.json` 里设置对应的 RGSS 版本后启动。

依赖 Win32API 调用的脚本需要打补丁，嫌麻烦可以直接走 Wine，这类游戏负载很低。

### NScripter

用 ONScripter 系的实现（如 ONScripter-jh、ONScripter-Yuri），需要自行编译或找 macOS 构建。游戏目录里要有 `nscript.dat` 或 `0.txt`，以及一个名为 `default.ttf` 的字体文件。

### TyranoScript

同样是网页外壳，`gal nw <目录>` 即可；没有 `package.json` 的发行包，把 `index.html` 所在目录交给 NW.js 之前需要自己补一个最小的 `package.json`：

```json
{ "name": "game", "main": "index.html" }
```

## Wine 路线

```bash
./bin/gal run /path/to/game.exe
```

默认日文区域。中文游戏用 `-l zh`，繁体用 `-l tw`，不需要改区域用 `-l none`。

### 吉里吉里（`.xp3`）

兼容性很好。视频播放不了时见 [troubleshooting.md](troubleshooting.md) 的视频一节。

### SiglusEngine / RealLive（Key、VisualArts 系）

一般能直接运行。部分正版带光盘或在线认证，认证程序在 Wine 里可能通不过，这种情况优先找官方的 Steam 版。

### CatSystem2、BGI、Malie、YU-RIS 等

大多能直接运行，必须用日文区域，否则乱码或直接闪退。

### Unity

较新的 Unity（2021 以后）用 Wine 自带的 D3D11 会初始化失败，先用 `gal dxvk` 装 DXVK（`gal import` 会自动装）。还不行再换带 D3DMetal 的方案：

- **CrossOver**：新建容器后在容器设置里打开 D3DMetal。
- **Sikarugir**：创建 wrapper 时选带 D3DMetal 的引擎。

#### Unity 游戏的中文 / 机翻

先确认游戏是不是自带中文：很多 DLsite / Steam 上的新作都内置简体中文，在游戏设置里切语言即可。只有确实没有中文时才需要机翻。

- **MTool 不支持 Unity**（官网支持列表里没有），别下。
- **XUnity.AutoTranslator** 是 Unity 游戏的通用方案，已验证在 Wine 下可用（Unity 6 + Mono 后端，BepInEx 5.4.23.6 + XUnity 5.6.3.1）。做法：
  1. 把 [BepInEx](https://github.com/BepInEx/BepInEx/releases) 的 `BepInEx_win_x64_*.zip` 和 [XUnity.AutoTranslator](https://github.com/bbepis/XUnity.AutoTranslator/releases) 的 `XUnity.AutoTranslator-BepInEx-*.zip` 解压到游戏目录（exe 所在目录）。
  2. 给容器加 DLL 覆盖，让 BepInEx 能加载：

     ```bash
     WINEPREFIX=~/Games/gal/bottles/容器名 wine reg add 'HKCU\Software\Wine\DllOverrides' /v winhttp /t REG_SZ /d native,builtin /f
     ```

  3. 在 `BepInEx/config/AutoTranslatorConfig.ini` 里设置 `Language=zh-CN`、`FromLanguage=ja` 和 `Endpoint`。
- **翻译接口**：国内网络连不上谷歌；XUnity 内置的 `BingTranslate` 在 2026-11 测试时解析失败（空指针），可试 `PapagoTranslate`、`DeepLTranslate`，或申请百度翻译 API 后用 `BaiduTranslate`。
- IL2CPP 后端的 Unity 游戏（目录里有 `GameAssembly.dll`）要用 BepInEx 6 的 IL2CPP 版本，没测过。

### 需要安装的游戏

安装程序同样用 `gal run setup.exe` 运行，装到容器的 C 盘（`~/Games/gal/bottles/<容器>/drive_c/`）。装完后对着装好的 exe 再 `gal run`。

### 什么时候单独建容器

默认所有游戏共用 `default` 容器。某个游戏需要装会影响其他游戏的组件（特定版本的 .NET、DirectX 运行库、旧版解码器）时单独建：

```bash
./bin/gal bottle 游戏名
```

```bash
./bin/gal run -b 游戏名 /path/to/game.exe
```

## 虚拟机路线

只在 Wine 确实跑不起来时使用。Parallels Desktop 装 Windows 11 ARM，Windows 自带的 x86 模拟可以运行绝大多数 galgame，区域设置和 Windows 真机完全一样。代价是内存和电量，以及带内核级 DRM 的游戏在 ARM 版 Windows 上同样可能无法运行。
