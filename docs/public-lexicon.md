# 公共姓名、成语与品牌词库

首批包含 **101 条女性人物姓名词形、100 条常用成语和 12 个品牌名**。同一个人的已有译名可分别收录，因此姓名词形数量不等于人物数量。词条与来源保存在 [`data/public-lexicon/`](../data/public-lexicon/)，Mac 与 iPhone 从同一份数据生成。

| 输入全拼 | 候选示例 |
| --- | --- |
| `yangjiang` | 杨绛 |
| `tuyouyou` | 屠呦呦 |
| `shangyeqianhezi` | 上野千鹤子 |
| `sunyingsha` | 孙颖莎 |
| `ziqiangbuxi` | 自强不息 |
| `neiwai` | 内外 |
| `bobbibrown` | 芭比波朗（英文品牌别名） |

在中文全拼模式输入拼音或收录的品牌英文别名时，公共词条在原有正常第一候选后提供；不会为了推广某个人或品牌改高上游词频。三种措辞模式都可以使用公共词库，仍经过各模式的改写及本地「不再推荐」过滤。人物名字不会自动加入私人记忆，只有用户确认输入后才按本地记忆设置处理。已有的普通同音词仍可选择。Mac 西文直输与 iPhone 英文模式不查询这套公共别名。

姓名覆盖作家、科学家、教育工作者、运动员及艺术工作者，记录姓名和领域，收录不代表人物排名或对其全部观点的认同。成语覆盖学习、工作、坚持、合作、运动与日常表达，不把这些词认定为某一性别专属。

品牌词条提供输入便利，并逐条写明收录依据：例如女性创办历史、面向女性的设计定位，或公开的女性支持项目。**品牌自述与创办历史不等于独立的企业行为评价**；收录不保证其当前所有产品、政策或营销均女性友好，也不是购买推荐。存在变更或争议时，可提交来源更新说明、调整标签或移除词条。

## 贡献一个词

可以直接[在 GitHub 提议公共词条](https://github.com/SavannahY/her-words-ime/issues/new?template=public-word-proposal.yml)，不需要写代码。提供词形、全拼、类别及公开来源即可。多音姓名应有本人、机构或出版方的读音依据；外文姓名使用已有中文译名，不自行创造译名。

通过 PR 编辑三个 JSON 文件之一：`women.json`、`idioms.json`、`brands.json`。最小示例：

```json
{
  "version": 1,
  "sources": [{
    "id": "women-example-official",
    "title": "机构公开人物页",
    "url": "https://example.org/people/example"
  }],
  "entries": [{
    "text": "屠呦呦",
    "pinyin": "tu you you",
    "category": "woman",
    "source_ids": ["women-example-official"],
    "tags": ["scientist"]
  }]
}
```

示例链接仅展示格式，提交时必须换成真实依据。`category` 使用 `woman`、`idiom` 或 `brand`；`source_ids` 引用同一文件的来源。`pinyin` 用小写音节与空格，每个汉字对应一个音节，ü 写作 `v`，不标声调。姓名中间的「·」没有音节。可选的 `tags` 是小写分类标签，`note` 是最多 240 字的简短依据说明。

品牌可增加 `aliases`：仅收录其正式英文名称的输入形式，转小写，去掉空格、标点及重音符号，例如 `bobbibrown`、`esteelauder`。这属于输入别名，不是中文词的拼音；不添加任意缩写、竞争品牌名称或促销关键词。个人常用缩写可在本地词库管理。

只整理词头、读音、事实标签与来源链接，不复制人物传记、词典释义或未经授权的完整词表。公共贡献不得包含联系人、聊天记录、私人姓名列表或本地记忆文件。

## 生成与验证

从仓库根目录执行：

```sh
python3 scripts/compile_public_lexicon.py
python3 scripts/compile_ios_data.py
python3 scripts/compile_public_lexicon.py --check
python3 scripts/compile_ios_data.py --check
python3 -m unittest discover -s tests -p 'test_*.py'
```

提交原始 JSON、生成的 `rime/her_public.dict.yaml`、`rime/lua/her_public_aliases.lua` 和更新后的 iPhone 资源。生成的 Rime 字典便于审阅和导出；实际候选通过数据表加入，因此不需要抬高词频或改变基础字典排名。生成器不联网、不读取个人词库；来源说明不作为代码执行。

修改后重新运行 Mac 安装器即可更新电脑上的词库。iPhone 数据随键盘扩展打包，需要重新构建、签名并安装；GitHub 更新不会自动修改手机键盘。
