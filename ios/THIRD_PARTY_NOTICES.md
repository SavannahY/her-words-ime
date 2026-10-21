# iOS 离线拼音数据与许可证

外部词典数据**不由仓库根目录的 MIT License 替代**。应用与自编生成器、同项目语言包和第三方拼音数据的许可分别适用。

## Rime 袖珍简化字拼音词典

- 上游：[rime/rime-pinyin-simp](https://github.com/rime/rime-pinyin-simp)。上游 `AUTHORS` 明确说明词典由 Android Pinyin IME 派生，采用 **Apache License 2.0**。
- 固定提交：[`0c6861ef7420ee780270ca6d993d18d4101049d0`](https://github.com/rime/rime-pinyin-simp/tree/0c6861ef7420ee780270ca6d993d18d4101049d0)，提交日期 2024-12-29。
- 原文件：[pinyin_simp.dict.yaml](https://github.com/rime/rime-pinyin-simp/blob/0c6861ef7420ee780270ca6d993d18d4101049d0/pinyin_simp.dict.yaml)。原始文本保存在 `third_party/rime-pinyin-simp/`；没有拷贝上游二进制词库、已安装 App 的编译产物或用户私人词库。
- 原词典 SHA-256：`e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b`。各原文件的地址、大小、SHA-256 和提交信息见 `third_party/rime-pinyin-simp/SOURCE.json`。
- 原始 [LICENSE](third_party/rime-pinyin-simp/LICENSE)、[AUTHORS](third_party/rime-pinyin-simp/AUTHORS) 与 README 保持原文。键盘资源同时附有 `Rime-Pinyin-Simp-LICENSE.txt` 和 `Rime-Pinyin-Simp-AUTHORS.txt`，应随应用分发。

`Keyboard/Resources/lexicon.json` 是本项目对该词典的确定性筛选与 JSON 格式转换，并添加本项目基础词条；**该词典生成文件按 Apache-2.0 分发**。修改包括保留全部上游单字读音、按词频选择多字词、保留规则同码的完整同音词、合并项目词条、去重、排序及格式转换。上游署名与许可继续保留。

## 词库规模与权重

原始词典共 65,125 个读音条目。当前生成词库为 **47,084 个读音条目、46,436 个不同文字词条**，JSON 为 **2,303,287 字节，约 2.20 MiB**：

- 保留上游全部 17,047 个单字读音，涉及 16,472 个不同单字，包括多音字与上游提供的生僻字、繁体字。这里的“全部”指上游原表，不是 Unicode 汉字全集；保留它们是为了不因截取高频词而丢掉字覆盖。
- 选取权重最高的 30,000 个上游多字读音条目；同权重按文字、拼音排序，保证每次构建相同。
- 对 43 个不同的规则别名输入码，保留全部 36 个现有上游完整拼音同音词；其中 10 个低于普通词频截取线，因此额外补回。例如保留「圣女」作为 `shengnv` 的正常完整词候选。
- 纳入本项目 `rime/her_words.dict.yaml` 的全部 42 个读音条目。其中 15 个已在上述选集中，2 个原本低于截取线的上游词条补回，25 个是新条目。

上游词频保持原始非负整数，范围 0～4,828,294，不能理解为概率。已存在的项目词条保留上游频数，不用品牌词库中的一百万权重覆盖；新条目采用种子权重 200，**该种子权重不是语料统计**。例如「你」仍高于「妳」；`jidu` 的原始完整词首项是「季度」，其后有「极度」「嫉妒」。键盘引擎负责候选排序、拼句与独立的「她」优先偏好。

同码补回仅保留上游原本存在的词与频数。例如「圣女」原始频数为 189；上游原表没有「剩女」，不会为它伪造语料频率。词包仍可通过独立的拼音别名提供「单身女性」。

资源大小用于控制首版离线键盘的数据量，不等于 iOS 运行时内存占用。没有神经语言模型、网络词典或用户词频学习数据；新词、专名和长句质量仍需真机试用。不能据此宣称已达到商业输入法的预测质量或已通过真机内存压力测试。

## 同项目措辞规则与拼音别名

`Keyboard/Resources/rules.json` 调用同一 `language-packs.json` 和 `compile_data()` 生成，包含 `rules` 与 `exact_aliases`，没有为 iOS 手抄另一套映射。该文件及本项目生成器继续使用项目的 MIT License。

真正的读音放在 `lexicon.json` 的空格分音节 `pinyin` 字段中，ü 使用 `v`。例如「忮忌」的词典拼音是 `zhi ji`；把 `jidu` 对应到「忮忌」的个人输入偏好只放在 `rules.json` 的 `exact_aliases`，不会伪称它的标准读音是 `ji du`。社群借字也继续附带“借字或拆字”说明。

## 离线重建

仓库包含固定版本的原始文本与许可证。构建不依赖用户安装的鼠须管、不读取真实输入法目录，也不需要联网或额外 Python 包。从仓库根目录运行：

```sh
python3 scripts/compile_ios_data.py
python3 scripts/compile_ios_data.py --check
python3 -m unittest discover -s tests -p 'test_ios_data.py' -v
```

生成器校验固定提交及原始文件 SHA-256，输出确定性的 UTF-8 JSON、资源内许可与 `data-info.json`。`data-info.json` 记录规则包、项目词库、输出资源的散列和实际规模。`--check` 只比较已提交资源，不改写文件；更新词包或基础词库后需重新生成。也可用 `--output-dir` 写到临时目录。

升级外部词典时，应同时更新固定提交、下载地址、原文、SHA-256、许可材料、规模说明和覆盖测试。请保留第三方许可，不要把外部词库改标为 MIT。


主 App 的可选原生语音运行时（sherpa-onnx / ONNX Runtime）及模型来源与独立许可，另见 [根目录第三方说明](../NOTICE.md#原生语音运行时与可选模型)。键盘扩展不链接语音运行时。
