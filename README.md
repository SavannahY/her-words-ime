# 她说 · Her Words IME

女性友好的中文输入法，包含 **iPhone 原生键盘扩展**、macOS Rime 方案与语音转文字工具。iPhone 版目前用于个人试装，需要用自己的 Apple 账户签名。

默认以「她」为第三人称，按具体词语提供更友好的表达。正常的女字旁用词与正常同音词保留。**语言包可以通过 Pull Request 共同维护；社群借字包单独收录，手动启用。**

同一仓库也包含本地打开的中文语音转文字工具，与系统输入法共用语言包。

## iPhone 个人试用

打开 [`ios/HerWords.xcodeproj`](ios/HerWords.xcodeproj)，选择 **HerWords** scheme，用 Xcode 给主 App 和键盘扩展设置自己的 Team，连接 iPhone 后运行。免费 Personal Team 可用于个人试装，通常每七天需要重新签名安装。完整步骤见 **[iPhone 安装说明](docs/iphone-install.md)**。

安装后，在 iPhone「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」启用 **她说键盘**，输入时长按地球键切换。

- 离线全拼，47,084 条读音数据，支持候选横向滚动、分词、中英文、数字与常用标点。
- 默认中性表达，键盘顶部可切换社群写法或保留措辞；三种模式都保留「他 → 她」。
- 键盘无需「允许完全访问」，不联网、不记录打字内容，也不读取剪贴板。
- 语音转文字在主 App 中使用：可下载约 60 MB 的离线中英模型，也可选择 Apple 设备端／联网识别。整理结果默认「他／它 → 她」，英文保留原文。检查结果后复制到目标 App。

这是首个试用版本，采用本地词频和有限拼句，没有商业输入法的云端预测或自适应学习。密码框等系统限制场景会回到系统键盘。设备签名、触摸手感和内存表现需要继续在真机试用；CI 编译通过不能代替安装验收。

第三方拼音数据来自固定版本的 Rime 简体拼音词典，按 Apache-2.0 分发，详见 [iOS 数据与许可](ios/THIRD_PARTY_NOTICES.md)。手机规则直接从同一社区语言包生成：

```sh
python3 scripts/compile_ios_data.py
python3 scripts/generate_ios_project.py
```

## 输入体验

| 输入意图 | 默认友好表达 | 可选社群写法 |
| --- | --- | --- |
| 他／他们 | 她／她们 | 她／她们 |
| 奸诈 | 狡诈 | 仠诈 |
| 嫉妒 | 忮忌（zhì jì，书面近义词） | 男疾男户 |
| 贪婪 | 贪心 | 贪㑣 |
| 妇人之仁 | 心慈手软 | 心慈手软 |
| 剩女 | 单身女性 | 单身女性 |

这是个人措辞偏好，不把所有原词都判作厌女，也不把社群借字说成规范字。部分改写是表达建议，含义不保证逐字相同。默认包目前含 **45 组规则**；可选社群包有 **13 组覆盖规则**，另收录女性友好词语。

改写发生在候选与上屏阶段：候选中的原问题词在原位置变成友好表达，原本正常的第一候选保持位置。例如 `jidu` 的正常首项「极度」保留，「嫉妒」对应候选则改成「忮忌」。拼音别名不会抢占正常首项。

「好、妈妈、姐姐、婚姻、小姐、嫌疑人、妲己、嫉恶如仇、奴隶制、强奸罪」等保持原有词形。不全局改「女、妈、娘、嫌、奸」等单字，不把竞争改成互助，也不把性别化辱骂直接换成另一种性别辱骂。

## macOS 安装

需要 Python 3 与[官方鼠须管 Squirrel](https://github.com/rime/squirrel/releases)。当前已验证 Squirrel 1.1.2 / librime 1.16.0。项目不包含鼠须管应用或其二进制词库；它们按上游许可独立分发。

```sh
git clone https://github.com/SavannahY/her-words-ime.git
cd her-words-ime
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
python3 scripts/validate_packs.py
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/install_macos.py --dry-run
python3 scripts/install_macos.py
```

安装脚本会先验证语言包、备份涉及的配置，再添加「她说」方案并重新部署。通过追加配置保留已有 Rime 方案，已有候选窗主题默认保留；`--theme` 可选择应用本项目主题。原配置的排版与注释可能变化，完整原件会保存在备份中。

安装后从 macOS 输入菜单选择 **Squirrel - Simplified / 鼠须管**。如果是第一次安装鼠须管，请在「系统设置 → 键盘 → 文字输入 → 编辑」添加鼠须管；个别应用可能需要重开，或保存工作后注销再登录。

Windows 与 Linux 的 Rime 理论上可使用本项目配置，但本轮只验证了 macOS；不提供未经验证的一键安装承诺。

## 切换措辞

按 **Control + 反引号**（或 F4）打开 Rime 方案菜单，找到本方案的措辞开关：

- **友好表达**：默认使用中性包。
- **社群写法**：手动选择后使用已安装的社群覆盖包；没有覆盖的词回退中性表达。
- **保留措辞**：关闭词汇改写，适合引用或专业语境。「他 → 她」仍按本方案的女性优先约定保留。

部分易歧义词只对完整候选改写。词库不保证识别所有新词、引用、反讽和整句语义。复制粘贴与系统听写直接插入的文本不会经过拼音候选过滤器。

## 语音转文字

原生离线后端采用 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 的小型中英双语 Zipformer，代码、模型修订与每个下载文件的 SHA-256 都已固定。iPhone 主 App 中点击下载后使用；键盘扩展不包含语音运行时。Mac 可以构建可直接打开的录音窗口（需要 Swift 和 macOS SDK，Apple 官方 Command Line Tools 可提供）：

```sh
python3 scripts/build_macos_speech_app.py
open dist/她说语音.app
```

窗口内可开始／停止／取消录音、选择热词提示、编辑原文和复制完整词包整理结果。失焦或退出会结束录音，只有主动点击开始才申请麦克风权限。

Mac 也可从音频文件转写：

```sh
swift run --disable-keychain --disable-netrc her-transcribe --download-model
swift run --disable-keychain --disable-netrc her-transcribe --audio /path/to/recording.wav --hotword GitHub --json
```

下载模型需要网络，识别本身在本机进行，不上传音频；工具不会主动打开麦克风。Mac 命令行版本当前只做代词整理，完整措辞包可在下方语音页面继续处理。中英支持不等于保证每句准确；开源方案比较与调用方式见 [语音后端说明](docs/asr-options.md)。

所有本项目语音输出的整理结果默认将中文「他／它」改为「她」，保护网址、邮箱和 Markdown 代码片段；原始识别文字保留。英文 he/him/it 不翻译，不做英文性别推断。这不会接管其他 App 或系统自带的听写。

浏览器即时听写：

从仓库根目录运行：

```sh
python3 scripts/serve_voice.py
```

在支持语音识别的浏览器中打开 **http://127.0.0.1:8765**，点击「开始听写」。可以校对原文、切换中性或社群表达，再复制结果。服务只监听本机，规则直接从相同语言包生成。

浏览器可能将音频发送给其识别服务，听写可能需要联网；本项目的本地服务不接收音频或文字。语音页不是系统全局听写，精确匹配规则也不会猜测整段话中的语义。支持范围与隐私说明见 [语音工具说明](docs/voice.md)。

## 贡献语言包

不熟悉代码也可以[提议一个词](https://github.com/SavannahY/her-words-ime/issues/new?template=word-proposal.yml)。提供原词、替代建议、真实用例、可能误改的句子即可。

会编辑 JSON 的贡献者可以从以下文件开始：

- [`packs/neutral-zh-CN/pack.json`](packs/neutral-zh-CN/pack.json)：默认中性表达。
- [`packs/community-zh-CN/pack.json`](packs/community-zh-CN/pack.json)：可选借字、拆字表达。
- [`language-packs.json`](language-packs.json)：用户选择的语言包清单。

每条规则都有来源、匹配范围、备注和例句测试；默认中性表达与可选借字分开维护。新语言包需加入清单才会编译，未加入的第三方语言包不会被自动启用。

详细说明见 [贡献指南](CONTRIBUTING.md)、[语言包格式](docs/language-packs.md)及 [JSON Schema](schemas/pack.schema.json)。

## 编译与测试

词包校验与编译只使用 Python 标准库；安装器及其测试需要上述 PyYAML 依赖：

```sh
python3 scripts/validate_packs.py
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/compile_packs.py --output rime/lua/her_rewrite_rules.lua
```

macOS 上还可以使用鼠须管内置的真实引擎进行隔离验收：

```sh
python3 tests/integration_rime.py --config rime
```

引擎验收使用临时目录，不动当前 Rime 用户目录。范围与结果见 [验证记录](docs/validation.md)。GitHub Actions 执行词包校验、编译、单元测试、macOS 真实引擎验收，以及 iPhone 模拟器和设备架构的无签名构建。

## 实现与许可

`rime/lua/her_filter.lua` 在 OpenCC 简繁转换后，以 `ShadowCandidate` 改写候选，保留原候选的学习和分词信息。规则按同位置最长词优先、单趟匹配，避免连锁替换。生成的数据文件不执行语言包提供的代码。

本项目自行编写的代码与词包按 [MIT](LICENSE) 许可。公开网页只作为用例或词义依据，不代表原作者支持本项目全部改写。Rime、Squirrel 及其上游字典保留各自许可，详见 [第三方说明](NOTICE.md)。
