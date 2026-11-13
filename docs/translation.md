# 机翻

GalBox 内置机翻：在游戏的“…”菜单里点“开启机翻”，下次启动游戏就生效。命令行等价于：

```bash
./bin/gal translate <名字> on
```

## 先填翻译服务

机翻用 DeepSeek 的大模型接口，gal 对话的口吻比传统机翻自然得多，价格也低。

1. 在 [platform.deepseek.com](https://platform.deepseek.com) 申请 API key。
2. GalBox 右上角齿轮 → 设置 → 填 API key → “保存并测试翻译”。

key 只存在本机的 `~/Games/gal/config/translate.json`（权限 600）。兼容 OpenAI 格式的其他服务也能用，在“高级”里改接口地址和模型。

## 工作方式

所有游戏的翻译都经过本机的 **GalTranslator**（`~/Games/gal/kit/GalTranslator.app`，菜单栏显示“译”）：

- 只监听 `127.0.0.1:47011`，不对外开放。
- 带缓存（`~/Games/gal/cache/`），同一句话只请求一次，重玩、回看不花钱。
- 翻译失败时游戏显示原文，不会卡住。
- 日志在 `~/Games/gal/logs/translator.log`。

## 各引擎的做法

| 引擎 | 方式 | 效果 | 实测情况 |
| --- | --- | --- | --- |
| Unity（Mono） | BepInEx 5 + XUnity.AutoTranslator | 游戏里的文字直接换成中文 | 已在 Unity 6 游戏上验证整条链路 |
| Unity（IL2CPP，目录里有 `GameAssembly.dll`） | BepInEx 6 IL2CPP + XUnity | 同上；第一次启动要生成互操作程序集，黑屏一两分钟 | 未实测 |
| Ren'Py | 往 `game/` 放一个翻译脚本和中文字体 | 对白、选项直接显示中文 | 未用真实游戏实测 |
| RPG Maker MV/MZ | 整包离线翻译 `data/*.json`，原文件备份到 `data_galbox_original` | 对白、选项、名字、物品、系统用语都换成中文，之后不用联网 | 已用构造的数据验证，关闭后逐字节恢复 |
| 吉里吉里、SiglusEngine、CatSystem2、BGI、Wolf RPG、RGSS、NScripter 等 | **屏幕识别**：框住对话框，macOS 自带文字识别读出日文 | 译文显示在悬浮字幕窗 | 文字识别已验证；截屏需要你授权后实测 |

关闭机翻会删除装进去的文件、恢复原文件，游戏回到原样。

### 屏幕识别怎么用

1. 第一次启动开了机翻的游戏时，macOS 会询问是否允许 GalTranslator 录制屏幕，选允许（或到 系统设置 → 隐私与安全性 → 屏幕与系统录音 里打开 GalTranslator），然后重启游戏。
2. 屏幕上会出现一个橙色框，把它拖到游戏的对话框上，拖边角调整大小。
3. 菜单栏“译” → “锁定识别框”，框变成细线并且鼠标可以穿透，不影响点游戏。
4. 译文显示在悬浮字幕窗里，字幕窗可以拖到任何位置；菜单栏“译”里也能锁定字幕窗、暂停识别。

每个游戏的识别框位置单独记住。文字逐字出现的打字机效果会等文字停下来再识别。

注意：GalTranslator 是本机临时签名的，**每次重新编译（`app/build.sh`）后 macOS 可能要求重新授权屏幕录制**。

### 为什么不用 Textractor / MTool

- **MTool** 不支持 Unity，而且是闭源的 Windows 程序。
- **Textractor** 在 macOS 版 Wine（新式 WoW64）里实测不可用：32 位游戏注入后进程申请约 3 GB 内存失败并退出；64 位能注入，但通用绘字钩子取不到文字。绝大多数视觉小说是 32 位，所以默认改用屏幕识别。代码还保留着，想试可以设环境变量 `GAL_TRANSLATE_MODE=textractor` 再开机翻。

## 组件来源

所有组件都固定版本，下载后按 sha256 校验（`gal fetch` 可以单独下载）。GitHub 连不上时自动走 `gh-proxy.com` 镜像，校验不过就拒绝使用。

| 组件 | 版本 | 来源 |
| --- | --- | --- |
| BepInEx | 5.4.23.6 / 6.0.0-be.793（IL2CPP） | GitHub / builds.bepinex.dev |
| XUnity.AutoTranslator | 5.6.3.1 | GitHub |
| Textractor | 5.2.0 | GitHub（实验选项） |
