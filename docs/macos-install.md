# Mac 安装与日常使用

「她说」的 Mac 键盘是运行在[鼠须管 Squirrel／Rime](https://rime.im/)上的输入方案。安装后，从系统输入菜单选中鼠须管，即可在支持第三方输入法的应用中使用。

## 1. 准备鼠须管和 Python

准备以下两项：

- **官方鼠须管**：从 [Squirrel 官方发布页](https://github.com/rime/squirrel/releases)下载安装包。本项目已验证 **Squirrel 1.1.2／librime 1.16.0**；该版本要求 **macOS 13.0 或以上**，见[上游说明](https://github.com/rime/squirrel/blob/1.1.2/README.md)。
- **独立安装的 Python 3.14 正式版**：可在 [python.org 的 Mac 下载页](https://www.python.org/downloads/macos/)选择 3.14 系列安装包。本机验收使用过 Python 3.14.6，项目 CI 另验证 Python 3.12。安装完 Python 后，新开一个终端窗口，让更新后的命令路径生效。官方的[Mac 安装说明](https://docs.python.org/3/using/mac.html)也说明了证书安装步骤。

只安装键盘和使用网页版词库管理器，不需要完整 Xcode、语音模型或 Swift 编译器。macOS 的 `/usr/bin/python3` 可能来自 Apple 开发工具；如果运行它出现安装开发工具的提示，可先安装上述独立 Python，再新开终端。

**首次安装鼠须管后，先保存正在做的工作，再注销当前 Mac 用户并重新登录。** 这是 [Squirrel 1.1.2 官方发布说明](https://github.com/rime/squirrel/releases/tag/1.1.2)给出的步骤。

## 2. 下载「她说」源码

在[项目 GitHub 页面](https://github.com/SavannahY/her-words-ime)点击 **Code → Download ZIP**，下载后解压。默认文件夹名通常为 `her-words-ime-main`。

推荐第一次使用的人选择 ZIP 下载，整个安装过程可以不使用 Git。Mac 第一次运行系统 Git 时，可能提示安装 Command Line Tools，见 [Git 官方安装说明](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)。

目前项目通过公开源码分发，尚无正式 GitHub Release 安装包或 App Store 版本。GitHub Actions 中的临时构建产物有保留期限，日常安装请按本指南进行。

## 3. 在终端安装

打开「终端」，进入刚才解压的文件夹。若解压到了默认下载位置，可以使用下面的第一行；位置不同，请把它改成实际路径。也可以先输入 `cd `，再把文件夹从 Finder 拖进终端，按回车。

```sh
cd "$HOME/Downloads/her-words-ime-main"
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python scripts/install_macos.py --dry-run
```

最后一条命令会显示准备安装的文件和配置位置，只做检查。确认没有报错后，执行实际安装：

```sh
.venv/bin/python scripts/install_macos.py
```

安装器先验证语言包、公共词库和西语资料，再备份受影响的配置，添加中文、English 和 Español 三个方案并重新部署。其他已有 Rime 方案继续保留；已有主题默认保留。原 YAML 的排版和注释可能变化，安装前原件会保存在备份中。

默认配置位置为 `~/Library/Rime`。安装成功时，终端会显示「配置已部署」以及本次备份位置。

## 4. 在系统中启用

1. 打开 **系统设置 → 键盘 → 文字输入 → 编辑**。
2. 点击添加输入源，在简体中文中找到 **鼠须管／Squirrel**，完成添加；英文界面可能显示为 **Squirrel - Simplified**。
3. 从 Mac 菜单栏的系统输入菜单选择鼠须管。
4. 按 **Control＋反引号（`）** 打开方案菜单，选择 **她说 · 女性优先全拼**、**她说 · English** 或 **她说 · Español 西班牙语**。也可尝试 **F4**；如果功能键由系统功能占用，可使用 **Fn＋F4**。

中文方案可能把选项折叠成「中／半／汉／。／友／关」一行。先选这一行展开，再切换措辞或「中文查西语」。菜单显示的是当前状态，旁边的箭头表示选中后的新状态。

三种措辞模式为：

- **友好表达**：默认使用中性、较通用的替代表达。
- **社群写法**：主动启用已收录的社群借字或拆字表达。
- **保留措辞**：保留词汇原写法，适合引用或专业语境。

三种模式都把「她／她们」优先展示，也保留「他／他们」供主动选择。语音工具另有自己的代词整理行为，见[语音工具说明](voice.md)。

## 5. 用几组输入确认安装结果

| 方案 | 试着输入 | 应看到的结果 |
|---|---|---|
| 中文 | `ta` | 靠前出现「她、他」；主动选择「他」后，上屏仍为「他」 |
| 中文 | `tamen` | 靠前出现「她们、他们」 |
| 中文 | `qingxujiazhi` | 候选中可找到「情绪价值」；公共词不会强行抢走正常首项 |
| English | `Hello, GitHub!` | 英文、大小写和标点直接输入 |
| Español | `ma;nana`，再按空格 | 输入 `mañana`，并保留一个真实空格 |
| Español | `;?C;omo est;as?` | 输入 `¿Cómo estás?` |

西语中，`;a ;e ;i ;o ;u ;n ;v` 分别输入 `á é í ó ú ñ ü`；大写同理。Tab 或上下键可选择候选，空格确认后保留实际空格。

西语候选的中文释义首次默认开启；中文方案里的「中文查西语」首次默认关闭。打开后，输入 `nihao` 可在原有中文候选之外选择 `Hola.`。两个开关可以分别设置，并在切换方案时保存选择。完整例子见[Mac 三语与西语学习](spanish-learning.md)。

## 个人词库：先用无需编译的管理页

在已解压的项目目录中运行：

```sh
.venv/bin/python scripts/manage_word_memory.py
```

保持这个终端窗口运行，在浏览器打开 **http://127.0.0.1:8767**。可以添加人名、英文词和输入码，也可以搜索、忘记、设为「不再推荐」或恢复。

例如，手动添加词语 `GitHub`，输入码设为 `gh`，之后在**中文方案**中输入 `gh` 选词。English 直输和西语输入不会自动成为中文词库的输入关联。

默认会在确认中文短词后进行本地记忆；可以在管理页关闭自动记忆。「忘记」撤销个人记忆，「不再推荐」还保留一条本地隐藏偏好，避免继续推荐和重新学习。完整含义和匹配范围见[本地词库说明](local-memory.md)。

在终端按 **Control＋C** 可以关闭管理服务；键盘会继续使用已经保存的词库。服务只监听本机，个人词库保存在 `~/Library/Rime`，与源码目录分开。

如果希望使用独立的「她说词库」窗口，可在安装 Apple Command Line Tools 后，从项目目录构建：

```sh
.venv/bin/python scripts/build_macos_word_memory_app.py
open "dist/她说词库.app"
```

原生窗口属于可选工具，构建它才需要 Swift 和 macOS SDK。需要时可参考 [Apple 开发工具下载说明](https://developer.apple.com/xcode/resources/)。

## 更新版本

ZIP 安装的用户可以重新下载、解压最新源码，在新文件夹里重复第 3 步。安装器会重新生成资源、建立新备份，并保留已有其他方案、主题、个人词库和已保存的西语开关选择。

使用 Git 的贡献者可以在自己的项目目录更新后，再运行相同的安装命令。有本地修改时，先处理好自己的修改；个人词库不在 Git 仓库中。

## 停用与恢复原配置

暂时停用只需从系统输入菜单切到 Apple 中文输入法、ABC 或其他输入源；个人词库仍保留。

每次安装的配置备份位于：

```text
~/Library/Application Support/HerWordsIME/backups/<时间戳>/
```

终端会打印本次的确切路径。备份目录中的 `backup.json` 记录：

- `target`：当时的配置目录。
- `files_preexisting`：安装前已经存在、因此保存了原件的文件。
- `files_touched`：安装器可能涉及的配置文件清单。

目前没有一键卸载或自动回滚脚本。需要还原时，可按以下步骤人工核对：

1. 切到其他输入源，并先保存当前配置的副本，留住安装后自己新增的设置。
2. 选定要回到的那次备份，按 `files_preexisting` 将原件还原到 `target` 的对应相对路径。
3. 对清单中安装前本来不存在的新文件，核对当前用途后移到另一个备份文件夹；清单之外的文件保持原样。
4. 从鼠须管菜单执行「重新部署」，使还原后的方案和设置生效。备份不含完整 `build` 目录，编译产物通过重新部署生成。

个人数据 `her_memory_learned.tsv`、`her_memory_policy.tsv` 和 `her_memory_policy.lock` 不在安装器的覆盖或配置备份清单中。恢复输入方案时保留这些文件；如果希望保存个人词库的额外副本，请单独备份前两份 TSV。安装器的备份也不代表整套鼠须管应用或其他软件的数据备份。

## 常见问题

| 情况 | 处理方式 |
|---|---|
| 提示找不到 `python3`，或弹出开发工具安装提示 | 安装 python.org 的独立 Python 后新开终端，再运行第 3 步；ZIP 路线不要求先装 Git |
| 提示缺少 `yaml`／PyYAML | 在项目目录运行 `.venv/bin/python -m pip install -r requirements.txt`，并继续使用同一个 `.venv/bin/python` 安装 |
| pip 报证书错误 | 按 Python 官方 Mac 指南完成实际安装版本目录中的 `Install Certificates.command`，再重试 |
| 本地词库网页端口 8767 被占用 | 先关闭自己之前启动的管理服务，或运行 `.venv/bin/python scripts/manage_word_memory.py --port 8768`，再打开 `http://127.0.0.1:8768` |
| 提示找不到鼠须管 | 先安装官方 Squirrel；安装器自动查找用户级或系统级 `Library/Input Methods` 中的应用。非标准位置可用 `--app "/实际路径/Squirrel.app"` 指定 |
| 系统输入源里没有鼠须管，或部分应用无法输入 | 完成首次安装后的注销、重登，再检查系统设置中的输入源并重开目标应用 |
| 按快捷键没出现「她说」 | 先确认当前系统输入源已选鼠须管；检查安装器是否显示「配置已部署」，再打开方案菜单 |
| 现有 Rime 配置有符号链接或 YAML 报错 | 安装器会在写入前停止。先核对终端所指的路径或配置；保留现有文件，处理后重试 |
| 忘记一个词后，基础词典仍有它 | 「忘记」只撤销个人记忆；希望持续隐藏时使用「不再推荐」，详见本地词库说明 |

需要反馈时，可到[项目 Issues](https://github.com/SavannahY/her-words-ime/issues)说明 macOS、Squirrel、Python 版本和报错。请只提供必要的错误内容，个人词库文件留在自己电脑上。
