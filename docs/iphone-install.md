# iPhone 个人试装

使用 Mac 上的完整 Xcode，将「她说」签名后安装到自己的 iPhone。可以先用免费 Apple Account 对应的 **Personal Team**，不必先购买开发者会员。本项目的试装方案是主 App 加 Custom Keyboard Extension，键盘不请求完全访问，也不使用 App Groups。Apple 允许 Personal Team 在个人设备测试 App；键盘扩展随主 App 一起构建和安装。首次真机签名与运行仍需在自己的 Xcode 和手机上完成，CI 编译通过不能替代这一步。[Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)、[键盘扩展创建说明](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)

工程：`ios/HerWords.xcodeproj`；运行 scheme：`HerWords`。主 App 显示为「她说」，第三方键盘显示为「她说键盘」。项目最低支持 iOS 16；Xcode 还需要支持手机当前安装的 iOS 版本。

## 1. 安装并打开 Xcode

1. 在 Mac 安装 Apple 官方完整 [Xcode](https://developer.apple.com/xcode/)，预留下载、展开、iOS SDK 和构建所需空间。只有 Command Line Tools 或 Swift 命令行工具还不够。
2. 首次打开 Xcode，按提示完成组件安装，并安装 iOS 平台支持。
3. 下载或克隆完整仓库，然后在 Xcode 打开 `ios/HerWords.xcodeproj`。首次打开时 SwiftPM 会从官方仓库下载语音依赖，需要网络；不要只拷贝 `ios` 子目录。
4. 在 **Xcode → Settings → Accounts** 登录自己的 Apple Account。此操作在本机 Xcode 完成，无需把密码、验证码或签名证书交给项目维护者，也不需要上传到 GitHub。

## 2. 给主 App 和键盘都设置签名

在 Xcode 左侧点击工程，依次检查主 App target 和键盘扩展 target 的 **Signing & Capabilities**：

1. 勾选 **Automatically manage signing**。
2. 两个 target 的 **Team** 都选择自己的 **Personal Team**。
3. 如果默认 Bundle Identifier 已被占用，为两个 target 设置自己的唯一标识，例如主 App 用 `com.yourname.herwords`，扩展用 `com.yourname.herwords.keyboard`。把 `yourname` 换成自己的唯一前缀，并保持扩展与主 App 的前缀对应。
4. 等待 Xcode 解决签名状态；本项目的键盘试装不需要添加 App Groups 或其他额外能力。

主 App 和扩展都需要有效签名，只给主 App 选择 Team 不够。Apple 推荐由 Xcode 自动管理设备注册、证书和 provisioning profile。[Apple 签名流程](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html)、[Apple 扩展签名与测试说明](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)

也可以在不提交到 GitHub 的 `ios/Local.xcconfig` 中保存本地设置：

```xcconfig
DEVELOPMENT_TEAM = 你的十位TeamID
HER_BUNDLE_PREFIX = com.yourname.herwords
```

工程会将第二行同时用于主 App 和 `.keyboard` 扩展，避免两个标识前缀不一致。不要提交账号、私钥或 provisioning profile。工程由 `scripts/generate_ios_project.py` 生成，新增源码文件时可重建；个人签名覆盖放在此本地文件中以免被重建覆盖。

## 3. 连接手机，开启开发者模式并运行

1. 用数据线连接 Mac 与 iPhone，解锁手机；出现“要信任此电脑吗”时，在手机确认并输入设备密码。
2. 在 Xcode 顶部选择 **HerWords** scheme，并将运行目标选为自己的真实 iPhone。
3. 如果提示需要开发者模式，在手机打开 **设置 → 隐私与安全性 → 开发者模式**，按提示重启，重启后再次确认开启并输入设备密码。若看不到此选项，先在 Xcode 中发起设备配对，再检查设置。
4. 回到 Xcode，点击 **Run**（三角形，或 Command + R）。等待构建、签名、安装及启动主 App「她说」。
5. 若出现“不受信任的开发者”等提示，在手机打开 **设置 → 通用 → VPN 与设备管理**，找到自己 Apple Account 对应的开发者 App，按屏幕提示信任或验证，再回 Xcode 运行。不同 iOS 版本的确认文字可能不同；没有该提示时不必额外寻找或安装描述文件。

“信任此电脑”、开发者模式、开发者证书信任是不同步骤。账号登录、设备密码和信任确认由设备所有者在自己的屏幕上完成。[Apple 真机运行说明](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)、[开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)、[Apple Personal Team 示例中的证书信任步骤](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app)

## 4. 启用「她说键盘」

1. 主 App 成功打开后，前往 **设置 → 通用 → 键盘 → 键盘 → 添加新键盘**。
2. 在第三方键盘中选择 **她说键盘**。
3. 打开备忘录中的普通文本输入框，长按地球图标，切换到 **她说键盘**，再试拼音输入。

本项目键盘无需打开“允许完全访问”；正常打字也不需要麦克风权限。默认使用中性表达，社群写法由你在键盘里主动切换。密码框、部分电话号码输入框，以及禁止第三方键盘的 App 会使用系统键盘，这是 iOS 的限制。[Apple 添加与切换键盘说明](https://support.apple.com/zh-cn/guide/iphone/-iph73b71eb/ios)、[第三方键盘使用限制](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)、[完全访问说明](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)

点击键盘顶部「词库」可管理本地人名、英文词和拼音／缩写；长按候选可忘记或设为不再推荐。隐藏偏好也过滤基础词典及组合候选，防止被重新学回；隐藏名单默认折叠，可主动恢复。仅记录本键盘确认的短词，不读取聊天上下文。英文组成词后空格确认，点击候选才补全。详见 [本地词库说明](local-memory.md)。

`ta` 默认先显示「她、他」，`tamen` 默认先显示「她们、他们」。三种措辞模式均可明确选择男性代词，选择后不会强制改成女性字形；「其他、吉他、他人」等普通词保持原样。此处是键盘候选排序，主 App 的语音整理采用独立的默认代词偏好。

## 5. 语音转文字在主 App 使用

录音与语音识别放在主 App「她说」，不放进第三方键盘扩展。Apple 的键盘沙箱不允许键盘访问麦克风，开启完全访问也不能据此获得录音能力。使用主 App 的语音功能时，再按系统提示授予麦克风和语音识别权限；完成后检查文字并复制到目标 App。[Apple 键盘限制](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)、[键盘扩展与麦克风说明](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)、[语音与麦克风权限说明](https://developer.apple.com/documentation/bundleresources/protected-resources)

主 App 默认显示「离线中英」：先点「下载离线中英模型」，约 60 MB，只下载模型文件；校验成功后点击开始录音，仅申请麦克风权限，识别时不上传音频。可在「常规／中文与英文／技术词」间选择提示，常规关闭热词。提示可能造成误识别，请核对结果。

也可主动切换到「Apple 识别」，再选择仅设备端或允许联网。此引擎会额外请求系统语音识别权限。原文保留供编辑；三种措辞模式的整理结果都默认「他／它 → 她」，英文保持原文，网址、邮箱与显式代码片段保留。这个偏好只作用于本项目的整理结果，不能接管其他 App 的系统听写。

键盘不联网与语音识别是否联网是两件事。Apple Speech 能否离线识别取决于设备、语言及可用模型；未提供可用的设备端识别时，不能承诺语音完全离线。请以主 App 显示的识别模式和权限说明为准。[Apple 设备端识别能力](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)、[设备端识别请求](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

## 6. 七天到期后继续使用

免费 Personal Team 的安装配置从签发起 **7 天后到期**。到期后，把手机连接到同一台 Mac，在 Xcode 中打开同一工程、保持同一 Team 和 Bundle Identifier，再对手机点击 **Run**，重新构建并安装。不要为续签先删除 App，以免删除本地数据；重新安装后检查键盘是否仍在已启用列表中。

Apple 当前说明的免费额度为最多 10 个 App ID、3 台设备、每台设备最多 3 个 App。扩展有自己的标识，遇到额度错误时以 Xcode 的具体提示为准，不要连续修改标识来尝试解决。免费个人试装需要定期重新部署，不是永久安装或向其他人分发的渠道。[Apple Personal Team 限制与七天期限](https://developer.apple.com/help/account/basics/about-your-developer-account)

## 下载构建产物意味着什么

| 产物或状态 | 可以做什么 |
| --- | --- |
| CI 的模拟器 `.app` | 在 Mac 的 iOS Simulator 中测试；不能装到真实 iPhone |
| CI 的未签名 iPhone 构建 | 验证设备架构能够编译；仍需自己的开发签名与配置才能在手机运行 |
| Xcode 为个人设备签名并安装成功 | 才能在该设备试用主 App，并在设置中启用键盘 |

把未签名构建压成 ZIP、改名为 IPA，或下载到手机，都不会变成可安装版本。本页采用从源码用 Xcode 自动签名的路线。Apple 要求在 iPhone 运行的 App 具有有效的签名和 provisioning profile。[Apple 真机签名要求](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)

如果失败，先查看 Xcode 的具体签名或设备错误：确认选中真实手机、两个 target 的 Team 一致、Bundle Identifier 唯一、Xcode 支持手机系统、开发者模式已开启。只有 CI 构建成功时，项目会标为“已编译”，不会据此标为“已在你的 iPhone 安装”。

以上 Apple 文档核对日期：2026-10-20。账号额度和系统界面可能调整，以链接中的当前官方说明及 Xcode 提示为准。
