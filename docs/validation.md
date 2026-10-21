# 真实输入引擎验收

本项目的集成测试直接加载鼠须管附带的 librime 和 Lua 插件，发送实际按键、枚举全部候选，再用空格选词上屏。它验证输入引擎的实际结果；桌面应用中的菜单、麦克风听写和系统权限需要另外验证。

当前固定验收矩阵展开后为 **150 项**，包含：

- 「保留措辞／友好表达／社群写法」三态，以及独立进程重启后默认回到友好表达。
- 三态都保留「他→她」；原词模式恢复原措辞候选。
- 友好措辞、社群借字、候选注释、候选去重和所有候选的禁止词检查。
- 「极度／圣女」等正常同音词的首项排序，以及「坚韧」等正常候选保留。
- 好、妈妈、姐姐、婚姻、涉嫌、嫌疑人、嫉恶如仇、奴隶制、强奸罪、妲己。
- 「你妈的生日／她妈的名字」的完整句子保护。
- 纯繁体替换，以及长词匹配后不出现「的人子／的人行为」等拼接错误。
- 先确认「她」，再继续输入其他词的分段上屏。

2026-10-19 的本地验收使用官方鼠须管附带的 **librime 1.16.0**，150 项全部通过。常规用例枚举了 61,958 个候选，没有截断、重复或禁止词泄漏；分段用例另行枚举候选。输入配置目录在运行前后的 SHA-256 完全一致。候选数量和正常词排序可能随鼠须管词典版本变化，测试会与同一引擎的原词模式基线比较。

## 本地复现

需要 macOS、Python 3 和官方鼠须管的完整 `Squirrel.app`，其中应包含 `librime.1.dylib`、`librime-lua.dylib` 及共享词典。无需 Homebrew librime、C/C++ 头文件或额外 Python 包。

从仓库根目录编译语言包，再运行集成测试：

```sh
python3 scripts/compile_packs.py --output rime/lua/her_rewrite_rules.lua
python3 tests/integration_rime.py
```

脚本默认查找用户级和系统级 Input Methods 目录中的 `Squirrel.app`。也可以传入尚未安装、从官方安装包展开的应用：

```sh
python3 tests/integration_rime.py \
  --app /path/to/Squirrel.app \
  --config rime \
  --report /tmp/her-words-integration.json
```

测试只复制仓库配置到新的系统临时目录；真实 Rime 用户目录不会被打开或修改。临时用户词库、编译产物、引擎日志和默认报告也都留在该临时目录，结束时打印位置，便于排查失败。脚本在运行前后校验源配置目录的 SHA-256；若内容变化，即判为失败。

默认 JSON 报告保留每项首候选、提交文本、计数、选项状态、原词基线和失败原因。需要完整候选列表时追加 `--include-candidates`；完整报告体积较大，应留在本地或 CI 构建产物中，不提交到仓库。失败或候选枚举达到上限时，脚本返回非零状态。

## 修改测试与 CI

`tests/integration-cases.json` 是独立的预期结果矩阵，116 个定义按输入模式展开，再加两项分段测试和一项重启测试，共 150 项。它不通过读取过滤器的实际输出生成预期结果。添加语言包规则时，请同步补充输入码、期望候选、正常同音词或受保护用法。

`forbidden` 中的字符串按子串检查；带 `match: "exact"` 的对象只检查整个候选相等，不会把正常长句中的相关字串误判为违规。`expectedAny` 要求友好表达仍在候选中；仅在有明确排序要求时使用 `expectedFirst`。

```sh
python3 tests/integration_rime.py --print-cases
python3 tests/integration_rime.py --casesJSON /path/to/cases.json
```

CI 应使用 macOS runner，下载固定版本的官方安装包、校验 SHA-256、展开到 runner 的临时目录，编译语言包后将展开的应用路径传给 `--app`。不需要安装或启用系统输入法。其他平台可以运行语言包静态检查；这些真实引擎用例依赖 macOS 动态库，文件名也有意避开 `test_`，防止被通用 Python 测试发现流程自动执行。

底层封装通过 [librime 公开 C API](https://github.com/rime/librime/blob/1.16.0/src/rime_api.h) 的版本与结构大小检查绑定函数，不依赖私有实现接口。


## 2026-10-20：离线中英语音

在 [bad5118 的 GitHub Actions](https://github.com/SavannahY/her-words-ime/actions/runs/39525536501) 的 macOS 26 arm64 runner 上，真实 SwiftPM 原生构建、公开混合音频推理及 iPhone 模拟器／设备无签名构建均通过。键盘扩展不链接语音运行时。文字层另有 Swift 71 项与 JavaScript 63 项，检查三种模式、网址／邮箱／代码保护；这些文字测试不代表声学识别质量。

真实推理使用 `speech/test-audio.json` 中固定修订、固定大小和 SHA-256 的上游公开 `0.wav`，以及 `speech/asr-model.json` 的五个文件。没有打开用户麦克风或读取私人录音。greedy 与热词 beam 两种解码输出相同：

> 昨天是 MONDAY TODAY IS THEY AFTER TOMORROW是星期三

该例保留了中英文，但英语部分仍存在误识别，不能据此宣称准确率优于 Apple。真实测试还验证了结束幂等、结束后拒绝追加音频、重建流后结果一致。公开样例及模型文件下载与真人口音、噪声环境、真机速度和麦克风生命周期验收分开记录；用户自己的录音尚未实测。
