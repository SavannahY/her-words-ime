# 第三方与词语来源

本仓库提供 Rime 用户方案、独立 Lua 过滤器和语言包，没有打包鼠须管应用、librime、OpenCC 或朙月拼音的完整字典。

iPhone 版本另含经筛选的 Rime 简体拼音文本数据，来源与 Apache-2.0 许可见 [iOS 第三方说明](ios/THIRD_PARTY_NOTICES.md)。该数据的许可独立于根目录 MIT License，随 App 提供原始署名及许可证。

- [Squirrel / 鼠须管](https://github.com/rime/squirrel)：macOS 输入法前端，按其上游 GPL-3.0 等许可分发。
- [librime](https://github.com/rime/librime)：输入引擎，按其上游 BSD-3-Clause 许可分发。
- [librime-lua](https://github.com/hchunhui/librime-lua)：Lua 扩展，按其上游 BSD-3-Clause 许可分发。
- [OpenCC](https://github.com/BYVoid/OpenCC)：使用鼠须管提供的简繁转换进行显示及屏蔽比较，按上游 Apache-2.0 许可分发。
- [Luna Pinyin / 朙月拼音](https://github.com/rime/rime-luna-pinyin)：通过 `__include` 与 `import_tables` 使用用户已有安装的方案和词典；原作者及字典来源保留上游署名和许可。

每个语言包的 `sources` 与 `source_ids` 指向其用词依据。机构语言指南、字典、署名文章、社群用例与项目自己的编辑建议分开记录。公开用例只能说明有人使用某种表达，不能证明它是统一规范、标准读音或普遍认同的替换。

爱女词库的用例记录在 `packs/love-women-sources.json`。词语本身与本项目编写的简短注解不等于复制来源文章；本项目的 MIT 许可不覆盖这些外部网页。

公共人物姓名、成语、品牌名及网络常用词由项目独立选编，逐条出处见 `data/public-lexicon/*.json` 的 `sources` 与 `source_ids`。只整理词头、读音和简短事实说明，未复制传记、词典释义或第三方完整词表。链接网页仍属于其权利人；本项目 MIT 许可只适用于原创选编、注解和生成代码，不为外部网页重新授权。人物或品牌的收录不表示来源机构支持本项目。

西语学习资料记录在 `data/spanish-learning.json`，保留 RAE／ASALE、Instituto Cervantes 等公开核对来源、适用范围和核对方式。中文释义、输入码、例句选择及提示由本项目独立编辑，未复制完整课程或第三方词表。部分 Cervantes 页面核对时处于维护状态，来源记录注明仅核对官方索引片段；A1／A2 是编者的粗略学习提示，不代表机构逐句认证。


## 原生语音运行时与可选模型

- [sherpa-onnx v1.13.8](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8)：Apache-2.0；以 SwiftPM 依赖接入主 App 与 Mac 命令行工具，不放入键盘扩展。
- [ONNX Runtime](https://github.com/microsoft/onnxruntime)：MIT；由上游 SwiftPM 二进制依赖引入，保留其许可证。依赖解析版本见 `Package.resolved`。
- [小型中英 Zipformer 模型](https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t/blob/e2382758de9a0219b4efe682b95af30b399db3b8/README.md)：该固定模型卡标记 Apache-2.0。模型由用户主动下载，不提交进 Git；精确文件、来源、大小与 SHA-256 见 `speech/asr-model.json`。

上述依赖和模型不受本项目根目录 MIT 许可重新授权。Apple Speech 属于系统框架；浏览器语音服务属于浏览器提供者。

## 产品与交互设计参考

本轮研究了 [FEKB／Feminist eKeyboard](https://github.com/enenmia/fekb)、[VoiceInk](https://github.com/Beingpax/VoiceInk)、[Wispr Flow](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary)、[SwiftKey](https://support.microsoft.com/en-us/swiftkey-keyboard/how-to-use-the-microsoft-swiftkey-keyboard)、[Gboard](https://support.google.com/gboard/answer/7421372?co=GENIE.Platform%3DiOS&hl=en) 与 [LanguageTool](https://languagetool.org/mac-desktop) 的公开文档和产品行为。它们作为设计研究的引用来源，未在本轮导入其代码、词库、字体或模型，不列为运行依赖。

已实现的行为与后续参考方向分别记录在[参考项目与设计依据](docs/references.md)。外部仓库、文档及品牌仍归各自作者；引用不表示对方参与、认可或为本项目背书。
