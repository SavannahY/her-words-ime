## 改动

说明修改了哪个语言包，以及“原词 → 建议表达”。若是社群写法，说明对应的中性回退条目。

## 来源与边界

列出来源链接或 `source_ids`，说明它们支持什么。写清读音、义项或语体差异，以及至少一个不应误改的例子。

## 验证

```sh
python3 scripts/validate_packs.py --manifest language-packs.json
python3 scripts/compile_packs.py --manifest language-packs.json --output generated/her_rewrite_rules.lua
```

填写运行结果；如涉及输入法行为，补充实际输入与候选结果。

- [ ] 每条新增或修改的规则有来源、正向测试和反误伤测试；未加入全局单字替换。
- [ ] 替换保留原句事实；借字或近义表达的读音、含义差异已说明。
- [ ] 默认保持中性风格；社群写法仅手动切换后使用，且有对应中性回退。
- [ ] 已重新生成相关文件；若涉及候选排序，正常同音词仍保留首项。
- [ ] 我同意将本次原创贡献按 MIT 许可发布，外部来源以链接和简短说明引用。
