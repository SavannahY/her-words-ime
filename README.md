# 她说 · Her Words IME

<img src="assets/brand/her-words-logo-v1.png" alt="她说 Logo：梅紫色对话气泡中的她字" width="128">

**女性友好的中文输入法与语音工具，让常用表达和个人词库由你掌握。**

Mac 键盘基于 [Rime／鼠须管](https://github.com/rime/squirrel)，提供中文、English、Español 三个输入方案：`ta` 优先显示「她」，也保留「他」供主动选择；友好措辞可以切换，个人词语可以记住、忘记或设为不再推荐。

[Mac 快速安装](#mac-快速安装) · [使用指南](docs/macos-install.md) · [贡献词库](CONTRIBUTING.md) · [参考项目](docs/references.md) · [问题反馈](https://github.com/SavannahY/her-words-ime/issues)

[![检查与构建](https://github.com/SavannahY/her-words-ime/actions/workflows/checks.yml/badge.svg)](https://github.com/SavannahY/her-words-ime/actions/workflows/checks.yml)
[MIT](LICENSE) · [第三方说明](NOTICE.md) · [Logo 资源](docs/brand.md)

## 现在可以用什么

| 功能 | 当前状态 |
| --- | --- |
| **Mac 键盘** | 可按下面步骤安装；中文全拼、英文直输、西语输入与可选学习提示 |
| **本地词库** | 可查看和管理人名、英文词、拼音／缩写，区分忘记与不再推荐 |
| **Mac 语音工具** | 可从源码构建；下载约 60 MB 模型后在本机转写中英录音 |
| **iPhone** | 实验源码，需要自行签名；尚未完成真机安装和触摸验收，见 [iPhone 说明](docs/iphone-install.md) |

目前通过源码安装，尚无正式安装包或 App Store／TestFlight 发布。Mac 键盘的三语支持与语音工具的中英识别分别提供。

## Mac 快速安装

### 1. 准备鼠须管和 Python

- 安装[官方鼠须管 Squirrel](https://github.com/rime/squirrel/releases/tag/1.1.2)。已验证版本为 **Squirrel 1.1.2／librime 1.16.0**，该鼠须管版本要求 macOS 13 或更新系统。首次安装后按上游说明注销并重新登录。
- 准备独立安装的 **Python 3.14 正式版**，可从 [Python 官方 Mac 下载页](https://www.python.org/downloads/macos/)选择 3.14 系列安装包，安装后新开终端。本机使用 3.14，CI 另验证 Python 3.12。
- 只安装键盘需要鼠须管、Python 和一个 Python 依赖；原生图形管理器与语音工具的构建另需 Apple Command Line Tools。

### 2. 下载并安装「她说」

[下载项目 ZIP](https://github.com/SavannahY/her-words-ime/archive/refs/heads/main.zip)，解压。下面以文件夹位于「下载」为例；放在其他位置时，将第一行改成实际路径：

```sh
cd ~/Downloads/her-words-ime-main
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python scripts/install_macos.py --dry-run
.venv/bin/python scripts/install_macos.py
```

`--dry-run` 先检查并显示计划；最后一行才安装。安装器会验证词包与西语资料、备份涉及的配置、添加三个方案并重新部署，保留其他 Rime 方案、已有主题和个人词库。配置注释与排版可能变化，备份中保留原件。普通使用者无需先编译语音工具或运行整套开发测试。

使用 Git 的贡献者也可以先克隆，再运行相同的安装命令：

```sh
git clone https://github.com/SavannahY/her-words-ime.git
cd her-words-ime
```

### 3. 启用并试打

在 macOS「系统设置 → 键盘 → 文字输入 → 编辑」中添加「简体中文 → Squirrel／鼠须管」，再从系统输入菜单选中鼠须管。

按 **Control＋反引号**（或 F4）打开方案菜单，选 **她说 · 女性优先全拼**：

| 输入 | 可以看到的结果 |
| --- | --- |
| `ta` | 「她」在前，「他」仍可选 |
| `tamen` | 「她们」在前，「他们」仍可选 |
| `yangjiang` | 杨绛 |
| `qingxujiazhi` | 情绪价值 |
| `qubanwei` | 去班味 |

按空格确认中文候选。公共词会补到候选中，保留已有正常首项；如果第一项是其他同音词，继续查看候选即可。

找不到方案、首次无法打字、端口占用、升级或停用，请看[完整安装与排错](docs/macos-install.md)。

## 切换语言与措辞

同一方案菜单中可以选择：

| 方案 | 日常输入 |
| --- | --- |
| **她说 · 女性优先全拼** | 中文全拼、公共词库、个人拼音和缩写 |
| **她说 · English** | 英文原样输入，空格、大小写和标点交给当前应用 |
| **她说 · Español 西班牙语** | 西语原拼写优先，重音与词句建议由你主动选择 |

中文措辞有 **友好表达／社群写法／保留措辞** 三种模式。若菜单把选项折叠成「中／半／汉／…」一行，先选择这一行展开；选项显示当前状态及切换后的状态。

| 候选中的原表达 | 默认友好表达 | 可选社群写法 |
| --- | --- | --- |
| 奸诈 | 狡诈 | 仠诈 |
| 嫉妒 | 忮忌（书面近义词） | 男疾男户 |
| 贪婪 | 贪心 | 贪㑣 |
| 妇人之仁 | 心慈手软 | 心慈手软 |
| 剩女 | 单身女性 | 单身女性 |

这是可选择的措辞偏好。部分近义改写存在语气与词义差异；引用原话或专业语境可以切到「保留措辞」。「好、妈妈、姐姐、婚姻、嫌疑人」等正常表达保留，正常同音词也保留，例如 `jidu` 的「极度」不会被改成「忮忌」。

三种模式都把「她／她们」排前，也保留「他／他们」；明确选中的「他」原样上屏。「其他、吉他、他人」保留原字。规则按具体词条匹配，范围与保护例子见[语言包说明](docs/language-packs.md)。

## 西语输入和学习

西语方案中，`;n` 输入 **ñ**，`;a` 输入 **á**，`;?` 输入 **¿**，大写同理；`;;` 输入分号。例如 `ma;nana` 得到 `mañana`。空格确认当前候选并保留一个真实空格，Tab 或上下键选择其他候选。

两个学习开关分别设置和保存：

- **西语中文释义**：首次默认开启；中文说明只显示在候选旁，确认后只输入西语。
- **中文查西语**：首次默认关闭；在中文方案中打开后，`nihao` 可选 `Hola.`，`xiexie` 可选 `Gracias.`，正常中文首项仍保留。

目前收录 **76 种常用西语输出、86 个中文查询**，用于离线查词句和理解表达。完整字符表、查询示例、性别／称呼变体及收录范围见[三语与西语学习指南](docs/spanish-learning.md)。当前辅助范围是已收录词句，通用翻译和整句语法纠错属于后续方向。

## 个人词库：记住，也能忘记

Mac 在确认中文短词后可以自动记忆。可以手动添加名字或英文词及输入码，例如 `GitHub → gh`，然后在中文方案输入 `gh` 选词。英文直输和西语选词不会自动写入中文记忆。

在项目文件夹另开终端运行：

```sh
.venv/bin/python scripts/manage_word_memory.py
```

浏览器打开 **http://127.0.0.1:8767**，即可添加、搜索、忘记或隐藏词语，也能关闭自动记忆。按 Control＋C 结束管理服务，键盘仍可继续使用保存的词库。

- **忘记**：移除个人记忆和关联；基础词典中的词可能仍会出现，日后主动使用时允许重新学习。
- **不再推荐**：保留本地隐藏偏好，过滤对应候选并阻止自动学回；可随时主动恢复。
- **清空已记住的词**：保留隐藏名单，避免清空后又推荐不想看到的名字。

个人数据保存在本机，项目不会把它上传到 GitHub；隐藏名单也保留在本机，默认折叠。候选屏蔽的范围、数据位置和可选「她说词库」原生窗口见[本地词库指南](docs/local-memory.md)。这些设置作用于本输入方案的候选；宿主已有文字、手动输入和粘贴由使用者控制。

## 公共词库与社区贡献

补充词库共 **550 个公共读音条目**：101 条女性人物姓名词形、100 条成语、12 个品牌名、337 条网络常用词与日常表达。每条记录读音与来源，公共候选也遵从个人「不再推荐」设置。品牌收录依据单独说明，见[公共词库说明](docs/public-lexicon.md)和[网络词完整清单](docs/internet-vocabulary.md)。

不懂代码也可以参与：

- [提议友好表达或社群写法](https://github.com/SavannahY/her-words-ime/issues/new?template=word-proposal.yml)：写出原词、建议、用例和不应误改的句子。
- [补充姓名、成语、品牌或网络词](https://github.com/SavannahY/her-words-ime/issues/new?template=public-word-proposal.yml)：提供公开出处和完整拼音。
- [补充西语词句](https://github.com/SavannahY/her-words-ime/issues/new?template=spanish-phrase-proposal.yml)：提供西语、中文含义、适用语境及核对来源。

会编辑 JSON 的贡献者可从[贡献指南](CONTRIBUTING.md)开始。规则包、公共词和西语资料分开维护；社区写法由使用者主动启用。

## 可选语音转文字

| 入口 | 使用方式 | 识别与数据处理 |
| --- | --- | --- |
| **原生 Mac 语音窗口／文件工具** | 需 Swift 与 macOS SDK，可由 Apple Command Line Tools 提供；见[构建与模型说明](docs/asr-options.md) | 主动下载约 60 MB 的固定中英模型后，在本机识别；热词提示可选，原文可校对 |
| **浏览器听写页** | 运行下方命令后打开 http://127.0.0.1:8765 | 浏览器语音识别可能联网；文字整理在当前页面完成，见[语音指南](docs/voice.md) |

```sh
.venv/bin/python scripts/serve_voice.py
```

语音整理结果默认「他／它 → 她」，识别原文保留供校对；网址、邮箱和 Markdown 代码片段受保护，英文代词保持原文。它与键盘上主动选择「他」的行为分别处理。本项目语音工具处理自己取得的识别结果，不接管其他 App 或系统听写。

原生录音窗口只在主动开始录音时申请麦克风权限；下载模型需要联网，识别本身在本机完成。安装键盘和管理词库不需要语音模型。

## 致谢与参考

Mac 输入方案建立在 [Rime](https://github.com/rime/librime)、[Squirrel](https://github.com/rime/squirrel)、[librime-lua](https://github.com/hchunhui/librime-lua)、[朙月拼音](https://github.com/rime/rime-luna-pinyin)及 [OpenCC](https://github.com/BYVoid/OpenCC)之上；可选原生语音使用 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8)与固定中英模型。具体接入和许可见[第三方说明](NOTICE.md)。

本轮也研究了这些项目的产品设计：

| 参考项目 | 对「她说」有价值的做法 |
| --- | --- |
| [FEKB／Feminist eKeyboard](https://github.com/enenmia/fekb) | 女性友好词库、语言实验的语境记录与字体兼容说明 |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | 识别词典与确定替换分开，词库导入前预览和冲突处理 |
| [Wispr Flow](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary)／[SwiftKey](https://support.microsoft.com/en-us/swiftkey-keyboard/how-to-use-the-microsoft-swiftkey-keyboard) | 明确删除、再次学习和持续隐藏的不同含义 |
| [Gboard](https://support.google.com/gboard/answer/7421372?co=GENIE.Platform%3DiOS&hl=en)／[LanguageTool](https://languagetool.org/mac-desktop) | 翻译预览、主动确认，以及帮助学习者理解语言建议 |

本轮参考用于研究与说明，没有导入这些竞品的代码、词库或字体。哪些行为已经实现、哪些仍是后续方向，以及原始资料链接，详见[参考项目与设计依据](docs/references.md)。

## 开发与验证

按快速安装创建 `.venv` 并安装依赖后，开发者可以运行：

```sh
.venv/bin/python scripts/validate_packs.py
.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
.venv/bin/python scripts/compile_packs.py --output rime/lua/her_rewrite_rules.lua
.venv/bin/python scripts/compile_public_lexicon.py --check
.venv/bin/python scripts/compile_spanish_learning.py --check
```

在 macOS 上，可用官方鼠须管的真实 librime 做隔离验收：

```sh
.venv/bin/python tests/integration_rime.py --config rime
.venv/bin/python tests/integration_word_memory.py
.venv/bin/python tests/integration_trilingual.py
.venv/bin/python tests/integration_public_lexicon.py
```

集成检查使用临时目录，不打开当前个人词库。CI 运行词包与数据检查、真实引擎验收及 iPhone 无签名构建；范围和结果见[验证记录](docs/validation.md)。iPhone 源码、签名步骤及共享数据许可见[iPhone 安装说明](docs/iphone-install.md)和 [iOS 第三方说明](ios/THIRD_PARTY_NOTICES.md)。

本项目原创代码、词包与注解采用 [MIT License](LICENSE)。外部组件、模型、词典和引用网页保留各自许可，记录在 [NOTICE.md](NOTICE.md)。
