# 中英夹杂语音：后端选择与边界

本轮架构为**可选 Sherpa 原生主 App / Mac 文件工具，Apple 及浏览器后端保留**。Sherpa 的双语模型值得试用，因为官方提供同句中英混合样例，选定文件较小，也能覆盖项目的 iOS 16 目标。这里记录选型依据；尚不能据此声称真实录音准确率已经提高，设备性能与听写质量须分别实测。

处理流程：音频 → 所选识别后端 → 可编辑原文 → 共用文字规则 → 可复制结果。识别后端与中性／社群措辞模式分别选择。

## 可复现的选择

| 方案 | 固定参考版本与接入 | Apple 平台条件 | 本项目定位与许可 |
| --- | --- | --- | --- |
| Sherpa-ONNX + 小型双语 Zipformer | [v1.13.8 的 SwiftPM 清单](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/Package.swift)，产品 `sherpa-onnx`、模块 `SherpaOnnx`，Swift tools 5.9 | 清单最低 iOS 15 / macOS 10.15；本项目仍使用 iOS 16 / macOS 13 | 首选可选原生后端；[代码 Apache-2.0](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/LICENSE)，所选模型卡也标记 Apache-2.0 |
| WhisperKit | [v1.1.1 的 SwiftPM 清单](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Package.swift)，只选 `WhisperKit` 产品即可，Swift tools 5.10 | 运行目标最低 iOS 16 / macOS 13；上游 README 的开发工具条件另须满足 | 备选，暂不同时引入；[代码 MIT](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/LICENSE)，Core ML 模型须另行下载 |
| whisper.cpp | [v1.9.5](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5)，C/C++ API 与 Apple 示例 | 此版本[官方 XCFramework 构建脚本](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/build-xcframework.sh)最低 iOS 16.4 / macOS 13.3；不能当作支持所有 iOS 16 手机 | 可作后续原生对照，需要桥接与模型管理；[代码 MIT](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/LICENSE) |
| MLX Whisper | [`mlx-whisper` 0.4.3 对应官方示例快照](https://github.com/ml-explore/mlx-examples/tree/e52c128d113f10546f0fa391f87edcc58d3880cb/whisper)，Python 接口 | 当前 [MLX 0.32.4 安装文档](https://ml-explore.github.io/mlx/build/html/install.html)要求 Apple Silicon、macOS 14+、原生 Python 3.10+ | 适合 Mac 离线实验；这个 Python 示例不是可直接装入 iOS 16 的 SwiftPM 产品；[代码 MIT](https://github.com/ml-explore/mlx-examples/blob/e52c128d113f10546f0fa391f87edcc58d3880cb/LICENSE) |

Sherpa 代码固定提交为 `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`；可查阅[固定版 Swift API](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/swift-api-examples/SherpaOnnx.swift)与[文件解码示例](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/swift-api-examples/decode-file.swift)。模型固定为 [k2fsa-zipformer-bilingual-zh-en-t，修订 e2382758](https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t/tree/e2382758de9a0219b4efe682b95af30b399db3b8)，只取以下五个文件：

- `exp/32/encoder-epoch-99-avg-1.int8.onnx`
- `exp/32/decoder-epoch-99-avg-1.onnx`
- `exp/32/joiner-epoch-99-avg-1.int8.onnx`
- `data/lang_char_bpe/tokens.txt`
- `data/lang_char_bpe/bpe.vocab`

上述文件合计 60,155,435 字节，约 60.2 MB / 57.4 MiB；这是下载文件大小，**不是运行内存**，也不是整个模型仓库的大小。模型加载、音频缓存、ONNX Runtime 与线程会额外占用内存。下载版本和校验应以项目模型清单为准。

[Sherpa 官方双语小模型文档](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html#sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16-bilingual-chinese-english)包含同句中文与英文的解码样例，其中也有误识别。这证明存在可复现的混合用例，不证明它优于 Apple 或适合所有人的口音。

WhisperKit 的[官方 Core ML 模型仓库](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482)标记 MIT。该修订的多语 `tiny` 约 76.6 MB、`base` 约 146.7 MB、`small_216MB` 约 217.4 MB，均为各模型目录文件总大小；分词器、设备编译缓存和运行内存另计。名称带 `.en` 的模型只面向英语，不适合本需求。SwiftPM 锁定代码版本并不会自动锁定下载的模型版本。

## 转写、中英切换与「她」

本项目做**识别／转写**：尽量保留说出的中英文。翻译会改变语言和措辞；Whisper 类后端应明确使用 `task: .transcribe`，不用 `.translate`。WhisperKit 的参数与调用应以 [v1.1.1 `DecodingOptions`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/WhisperKit/Core/Configurations.swift)和 [`transcribe` 实现](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/WhisperKit/Core/WhisperKit.swift)为准。

支持中文和英文、自动判断主要语种，都不等于保证一句话内的每次语种切换。Whisper 的自动检测会参考开头音频，不能将一个语言标签当作混合识别质量保证。固定中文或自动语言检测，哪种更适合个人录音，需要用同一批音频比较。

WhisperKit 可将简短术语表编码为 `promptTokens`，如「她们，GitHub，Swift，Python，API，Xcode」。这是帮助拼写的上下文提示，不是必须遵守的指令。Sherpa 的[热词功能](https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html)也只调整解码偏好；所选双语模型需要匹配 CJK 字符与 BPE 词表，并使用支持热词的 `modified_beam_search`，`greedy_search` 不会因此获得热词效果。提示与热词可能引入新的误识别，应允许关闭。

普通话「他／她／它」同音，不能只靠声音保证字形。默认「她」由**最终文字处理**保证：保护 URL、邮箱和显式代码区域后，将其余中文「他／它」改为「她」；英文 `he`、`him`、`it` 保持原样。原文仍可编辑和校对；这里的保证是已输出文字的替换规则，不是保证识别不漏字、不错听，也不代表模型已学会女性友好措辞。

## 静音、幻觉与权限

录音只在明确点击并授权后开始；停止、取消、离开 App 时结束采集，过期回调不得覆盖新会话。模型下载应由用户主动开始，校验完成后才启用本地后端；可用性不足时显示原因，由用户选择其他后端，不静默切换到联网服务。

VAD 用来判断何时有声音、何时分段，不能保证理解内容。应过滤静音、限制录音时长并保留取消入口，避免将噪声反复送入模型。WhisperKit 的长音频 `.vad` 分块不能代替短录音的静音检查；`noSpeechThreshold` 也不是单独生效的可靠开关。[OpenAI Whisper 模型卡](https://github.com/openai/whisper/blob/main/model-card.md)说明模型可能生成音频中没有的文字，因此所有后端都应保留原文与人工校对。

Apple 设备端识别应先检查支持情况；不支持时须明确选择联网模式。浏览器语音是否联网由浏览器及其识别服务决定，详见[现有语音说明](voice.md)。

## Mac 文件工具

在仓库根目录、安装可用的 Swift 5.9+ 工具链后运行。首次构建需要获取 SwiftPM 依赖；主动下载模型后，文件识别在本机进行，不请求麦克风权限。

```sh
swift run --disable-keychain --disable-netrc her-transcribe --download-model
swift run --disable-keychain --disable-netrc her-transcribe --audio "/音频所在目录/中英录音.m4a" --hotword "GitHub" --hotword "Swift" --json
```

单独 `--audio` 不会自动下载模型。可加 `--model-directory "/模型目录"` 指定模型位置；只下载时也可使用。普通输出显示原文与结果，`--json` 输出 `rawText`、`text`、模型修订、音频时长和处理耗时。系统支持的本地音频通过 `AVAudioFile` / `AVAudioConverter` 分块转换为 16 kHz 单声道浮点数据，不把整段解码音频一次性载入内存。

## SenseVoice 的许可与接入

SenseVoice 可以作为后续对照，但必须区分代码和权重：[当前官方代码使用 MIT](https://github.com/QwenAudio/SenseVoice/blob/main/LICENSE)，[SenseVoiceSmall 固定模型卡](https://huggingface.co/FunAudioLLM/SenseVoiceSmall/blob/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/README.md)却声明 `model-license`，并链接 FunASR 的自定义模型许可（[固定参考版本](https://github.com/modelscope/FunASR/blob/58830eca4012644aac0c3218c3ccc7d98f003fda/MODEL_LICENSE)）。不能把代码的 MIT 或 Sherpa 的 Apache-2.0 自动套到这些权重上；增加下载或再分发前，应逐项记录所用权重版本与实际许可条件。

[Sherpa 的 SenseVoice 文档](https://k2-fsa.github.io/sherpa/onnx/sense-voice/index.html)提供原生接入路径；该离线模型配合 VAD 分段，与增量流式 Zipformer 的行为不同。本轮不捆绑 SenseVoice 权重，也不因选用 Sherpa 运行时而默认启用它。

## iPhone 的系统边界与验收

[Apple 自定义键盘文档](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)明确键盘扩展不能访问麦克风。语音放在「她说」主 App 中，用户将结果复制到目标 App；不能统一接管其他 App 的听写、替换系统听写引擎或自动向任意 App 注入文字。键盘输入功能与语音后端分别运行。

验收应同时记录后端／模型修订、设备与系统、录音时长、耗时、峰值内存、识别原文及最终文字。至少覆盖官方混合样本、本人中英技术词录音、静音／噪声、停止／取消，以及 `他/它`、英文代词、URL、邮箱、代码的保护用例。官方样例跑通与个人真实语音质量是两项独立结果；实际结果另记，不预先承诺改进幅度。
