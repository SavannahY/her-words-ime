# 第三方与词语来源

本仓库提供 Rime 用户方案、独立 Lua 过滤器和语言包，没有打包鼠须管应用、librime、OpenCC 或朙月拼音的完整字典。

iPhone 版本另含经筛选的 Rime 简体拼音文本数据，来源与 Apache-2.0 许可见 [iOS 第三方说明](ios/THIRD_PARTY_NOTICES.md)。该数据的许可独立于根目录 MIT License，随 App 提供原始署名及许可证。

- [Squirrel / 鼠须管](https://github.com/rime/squirrel)：macOS 输入法前端，按其上游 GPL-3.0 等许可分发。
- [librime](https://github.com/rime/librime)：输入引擎，按其上游 BSD-3-Clause 许可分发。
- [librime-lua](https://github.com/hchunhui/librime-lua)：Lua 扩展，按其上游许可分发。
- [Luna Pinyin / 朙月拼音](https://github.com/rime/rime-luna-pinyin)：通过 `__include` 与 `import_tables` 使用用户已有安装的方案和词典；原作者及字典来源保留上游署名和许可。

每个语言包的 `sources` 与 `source_ids` 指向其用词依据。机构语言指南、字典、署名文章、社群用例与项目自己的编辑建议分开记录。公开用例只能说明有人使用某种表达，不能证明它是统一规范、标准读音或普遍认同的替换。

爱女词库的用例记录在 `packs/love-women-sources.json`。词语本身与本项目编写的简短注解不等于复制来源文章；本项目的 MIT 许可不覆盖这些外部网页。


## 原生语音运行时与可选模型

- [sherpa-onnx v1.13.8](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8)：Apache-2.0；以 SwiftPM 依赖接入主 App 与 Mac 命令行工具，不放入键盘扩展。
- [ONNX Runtime](https://github.com/microsoft/onnxruntime)：MIT；由上游 SwiftPM 二进制依赖引入，保留其许可证。依赖解析版本见 `Package.resolved`。
- [小型中英 Zipformer 模型](https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t/blob/e2382758de9a0219b4efe682b95af30b399db3b8/README.md)：该固定模型卡标记 Apache-2.0。模型由用户主动下载，不提交进 Git；精确文件、来源、大小与 SHA-256 见 `speech/asr-model.json`。

上述依赖和模型不受本项目根目录 MIT 许可重新授权。Apple Speech 属于系统框架；浏览器语音服务属于浏览器提供者。
