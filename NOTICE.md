# 第三方与词语来源

本仓库提供 Rime 用户方案、独立 Lua 过滤器和语言包，没有打包鼠须管应用、librime、OpenCC 或朙月拼音的完整字典。

- [Squirrel / 鼠须管](https://github.com/rime/squirrel)：macOS 输入法前端，按其上游 GPL-3.0 等许可分发。
- [librime](https://github.com/rime/librime)：输入引擎，按其上游 BSD-3-Clause 许可分发。
- [librime-lua](https://github.com/hchunhui/librime-lua)：Lua 扩展，按其上游许可分发。
- [Luna Pinyin / 朙月拼音](https://github.com/rime/rime-luna-pinyin)：通过 `__include` 与 `import_tables` 使用用户已有安装的方案和词典；原作者及字典来源保留上游署名和许可。

每个语言包的 `sources` 与 `source_ids` 指向其用词依据。机构语言指南、字典、署名文章、社群用例与项目自己的编辑建议分开记录。公开用例只能说明有人使用某种表达，不能证明它是统一规范、标准读音或普遍认同的替换。

爱女词库的用例记录在 `packs/love-women-sources.json`。词语本身与本项目编写的简短注解不等于复制来源文章；本项目的 MIT 许可不覆盖这些外部网页。
