# 参考项目与设计依据

核对日期：**2026-10-22**。

「她说」感谢输入法、语音识别和语言工具社区。本页将实际使用的组件与本轮调研的产品分开记录，便于使用者核对来源，也便于贡献者判断哪些功能已经实现、哪些仍是后续方向。

## 实际使用的组件与数据

| 上游项目 | 在「她说」中的用途 | 本仓库的接入记录 |
| --- | --- | --- |
| [Rime／librime](https://github.com/rime/librime) 与 [Squirrel／鼠须管](https://github.com/rime/squirrel) | Mac 系统输入法引擎与前端。「她说」在鼠须管中提供中文、English、Español 三个方案 | [中文方案](../rime/her_words.schema.yaml)继承朙月拼音；安装器向已有鼠须管配置添加方案，不重新分发鼠须管应用 |
| [Luna Pinyin／朙月拼音](https://github.com/rime/rime-luna-pinyin) | Mac 中文基础方案与词典 | [词典导入](../rime/her_pinyin.dict.yaml)和方案继承；iPhone 随包文本数据另见 [iOS 第三方说明](../ios/THIRD_PARTY_NOTICES.md) |
| [librime-lua](https://github.com/hchunhui/librime-lua) 与 [OpenCC](https://github.com/BYVoid/OpenCC) | 在鼠须管内运行候选过滤、可管理记忆和西语组成；进行简繁显示与屏蔽比较 | [过滤器](../rime/lua/her_filter.lua)、[本地记忆](../rime/lua/her_memory.lua)使用鼠须管提供的运行环境 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8) 与 [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 可选原生中英语音识别 | [Package.swift](../Package.swift)固定 sherpa-onnx 1.13.8；传递依赖由 [Package.resolved](../Package.resolved)锁定。语音运行时独立于键盘扩展 |
| [中英 Zipformer Small 模型](https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t/tree/e2382758de9a0219b4efe682b95af30b399db3b8) | 用户主动下载后的本机中英转写 | [模型清单](../speech/asr-model.json)记录修订、五个文件的大小及 SHA-256；当前语音识别范围是中英，Mac 三语键盘不代表三语声学识别 |

上述组件和数据保留各自的作者、许可与分发条件，详见 [第三方说明](../NOTICE.md)和[语音后端选型](asr-options.md)。本项目自行编写的代码、规则及注解采用根目录 [MIT License](../LICENSE)；该许可不为外部软件、模型或链接网页重新授权。

中文公共词、西语词句与措辞规则各有来源记录，参见[公共词库](public-lexicon.md)、[西语资料](spanish-learning.md)和[语言包格式](language-packs.md)。这些词义或公开用例来源与下面的软件设计调研也分别记录。

## 本轮设计调研

以下为公开仓库及官方产品文档的核对结果，未安装竞品做手感、兼容性或识别准确率对照。本轮没有从这些项目导入代码、词库、字体或模型。「她说」已有功能以最后一列为准，其实现早于本次调研；参考的产品行为不等于已经接入本项目。

| 参考项目 | 官方资料中可核对的做法 | 值得参考的设计 | 「她说」当前状态与后续方向 |
| --- | --- | --- | --- |
| [FEKB／Feminist eKeyboard](https://github.com/enenmia/fekb) | 女性友好 Rime 配置和词库，提供 Mac 安装说明；女字旁自造字使用 PUA 码位，显示依赖配套字体 | 记录语言实验的意图、适用语境和接收方显示条件，让使用者了解每种字形选择 | 已有友好表达、社群写法、保留措辞三种模式。日常默认采用已有汉字表达，正常女字旁用词保留；没有引入 FEKB 自造字或字体 |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | [Vocabulary](https://tryvoiceink.com/docs/vocabulary)引导专名识别；[Word Replacements](https://tryvoiceink.com/docs/word-replacements)在转写后做明确替换。两者可编辑删除；[导入导出](https://tryvoiceink.com/docs/import-export-dictionary)提供预览、合并和覆盖选择 | 把“识别偏好”与“确定替换”分清；导入前显示条目数量、重复和冲突 | 已将语音热词提示与最终文字整理分开，个人词可管理。个人词库的可视化导入预览和冲突处理仍是后续参考方向 |
| [Wispr Flow](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary) | 个人词典有编辑、删除和自动学习开关；官方明确说明桌面端删除的词不会被自动学习重新加回。[识别在云端处理](https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq) | 说明删除对后续学习的影响，并将学习、同步和云端处理分别解释 | 个人词库保存在本机，已有忘记、不再推荐、恢复及学习开关；不再推荐名单持续参与候选过滤。语音本地后端与浏览器听写的联网范围分别说明 |
| [Microsoft SwiftKey](https://support.microsoft.com/en-us/swiftkey-keyboard/how-to-use-the-microsoft-swiftkey-keyboard) | 手机键盘允许长按移除单个预测词；官方说明重新手动输入该词后可再次学习 | 把临时移除与持续隐藏区分清楚，操作说明直接回答“以后会不会再出现” | 已区分“忘记”和“不再推荐”；忘记允许日后主动选用时重新学习，不再推荐持续过滤并可主动恢复 |
| [Gboard](https://support.google.com/gboard/answer/7421372?co=GENIE.Platform%3DiOS&hl=en) | 官方 iPhone／iPad 说明提供源语言与目标语言选择、翻译预览，再由用户主动选中插入 | 让学习者看清原文、释义和将要发送的文字，主动确认结果 | Mac 西语候选只把西语文字上屏，中文释义留在候选注释；中文拼音查询只覆盖已收录词句。当前没有接入通用翻译服务 |
| [LanguageTool](https://languagetool.org/mac-desktop) | Mac 写作助手提供拼写、语法、风格建议及个人词典；支持西语，官方 Mac 检查需要联网 | 将错误原因解释给学习者，让拼写、性数配合等反馈可理解且可关闭 | 当前西语学习是离线词句、释义和提示。整句语法检查与纠错解释仍是后续方向，没有接入 LanguageTool 服务 |

FEKB 的仓库声明 [GPL-3.0](https://github.com/enenmia/fekb/blob/main/LICENSE)，VoiceInk 的仓库声明 [GPL-3.0](https://github.com/Beingpax/VoiceInk/blob/main/LICENSE)。这里记录设计研究出处，不将它们列为本仓库的代码依赖，也不暗示它们或其作者认可「她说」。

## 如何把参考转成可审阅的改进

1. **先写清使用者能得到什么。** 安装、语言切换、候选确认与两个西语学习开关放在面向使用者的说明中；实现细节留在开发文档。
2. **让词库由使用者控制。** 任何新增学习或导入能力都应说明保存什么、如何删除、哪些设置会持续生效。当前行为以[本地词库指南](local-memory.md)为准。
3. **让语言建议可以解释。** 新措辞仍需独立提供出处、语境、应改例子和保护例子，按[贡献指南](../CONTRIBUTING.md)提交。参考其他项目发现一个方向，并不替代词义、字形和误改检查。
4. **把后续想法与已交付功能分开。** 通用翻译、西语整句语法检查、个人词库可视化导入预览暂未实现；它们不作为当前安装说明中的功能承诺。

若后续确实移植某个项目的代码或数据，应在对应变更中记录具体文件、固定版本和原始许可，并同步更新 [NOTICE.md](../NOTICE.md)。本页不替代实际依赖与数据的署名记录。
