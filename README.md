<div align="center">

<img src="assets/AppIcon.png" width="80" alt="NotesCopilot 图标" />

# NotesCopilot

**选中一句话，双按 M，直接把译文写回原处。**<br>
**没有选中文字？双按 M 起草，继续追问，再把满意的回答插入光标处。**

Apple 备忘录与其他 Mac 应用里的原生写作工具，可连接自己的云端或本地模型。

[下载 v2.12.0 · Apple Silicon](https://github.com/m0nkee/notescopilot/releases/download/v2.12.0/NotesCopilot-2.12.0-arm64.dmg) · [发布说明与 SHA-256](https://github.com/m0nkee/notescopilot/releases/tag/v2.12.0) · [English](README.en.md)

</div>

## 双按 M 能做什么？

| 你正在做什么 | 怎么用 |
| --- | --- |
| **改写已有文字** | 在备忘录正文或支持的输入框里选中一句话，快速按两次 `M`，按 `T` 翻译。看过结果后，按 `R` 直接替换这句话，或按 `A` 把译文追加到选区末尾。 |
| **从光标处起草** | 光标放在可编辑区域，不选中文字，双按 `M`，输入「帮我写一封确认会议时间的邮件」并回车。按 `F` 追问「改成周五下午，语气轻松些」，回车后按 `I` 把新版草稿插回原光标。 |
| **读网页或聊天回复** | 选中一段只读正文，双按 `M`，选择总结、解释或翻译。按 `O` 对照原文，按 `C` 复制正在查看的版本。 |

**默认在 Apple 备忘录中启用。** 要在 Orca 聊天输入框、浏览器或其他应用使用，打开「设置 → 斜杠与文本扩展 → 选区写作工具」，把「应用范围」改为「全局」。可设置允许或排除的应用，或临时暂停全局工具。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/selection-launcher-dark.png">
  <img src="docs/images/selection-launcher-light.png" width="198" height="32" alt="选区旁的 Copilot 写作阅读助手浮钮，标有 MM 快捷键">
</picture>

### 工具和结果面板

- 选中文字后，可以双按 `M` 或点击浮钮打开菜单。校对、润色、精简、总结、翻译和解释各有快捷键，也可以按 `I` 输入自定义指令。默认翻译方向为中文译英文、其他语言译简体中文。要指定目标语言，可输入「翻译成日文」。
- 结果页的底部操作默认排成一行，**复制位于最右侧**。可以先编辑生成稿，再追加、替换或插入。点击写入按钮或按对应快捷键后即执行。`G` 重新生成当前回答。
- 通用指令的「追问」会带上此前的问题和回答。比如先生成邮件，再要求缩短。若编辑过上一条回答，追问会使用编辑后的版本。按 `B` 可返回编辑指令，重新开始。
- 在备忘录正文里，「Notes 格式」还可使用原生标题、列表等格式。支持 macOS 文本服务的应用也可从「服务 → 用 NotesCopilot 处理选中文本」打开工具。[选区交互与宿主兼容性](docs/WRITING-TOOLS.md)

![精简后的结果面板，底部从左至右为换个工具、重新生成、追加、替换选区和复制结果](docs/images/selection-review.png)

## 安装与第一次使用

1. 准备一台运行 **macOS 13 或更高版本的 Apple Silicon Mac**。下载上方 DMG，将 `NotesCopilot.app` 拖入「应用程序」，从那里打开。首次启动遇到安全提示时，见本文末尾。
2. 在应用设置中选择模型服务商，按需填写 API Key 并点击「保存配置」。支持 DeepSeek、Kimi、通义千问、OpenAI、OpenRouter、硅基流动和自定义 OpenAI 兼容端点。也可连接本机的 Ollama、LM Studio、llama.cpp 或 vLLM。
3. 打开「系统设置 → 隐私与安全性 → 辅助功能」，允许 NotesCopilot 读取选区并响应快捷键。然后在备忘录正文中选一句话，试试 `M`、`M`、`T`。

菜单栏可以打开 AI 面板、笔记库或设置。「设置 → 通用与诊断」可测试模型连接、查看权限，并切换简体中文、English 或跟随系统。菜单栏的「检查更新…」支持下载新版 DMG，应用会先核对 SHA-256，再在 Finder 中显示下载文件。默认每天检查一次更新。

## 备忘录与菜单栏功能

| 功能 | 适合用来做什么 |
| --- | --- |
| **AI 面板** · `⇧⌘Space` | 围绕当前笔记、选中文字或附件连续提问。支持流式生成、Markdown 预览与原文切换、代码块、表格、清单及富文本写回。可按模型设置温度、输出上限和推理强度。面板会保存最近会话与停止时的部分输出。切换笔记来源或模型配置时会开始新会话。 |
| **斜杠命令与文本扩展** | 在 Notes 正文输入 `/` 呼出命令，按 `/ai`、`/markdown`、`/templates` 或 `/tools` 筛选，用方向键和回车执行。常用文字还可保存为关键词展开。 |
| **模板** | 从备忘录的「Templates」文件夹或本地模板插入固定格式，可带日期、选区、输入询问和 AI 变量。Notes 模板变更后会刷新，同名模板优先使用 Notes 版本。 |
| **笔记库** | 在本机搜索笔记正文，按文件夹或标签筛选，查看高亮匹配和 Markdown 预览，或导出笔记。 |
| **网页标题链接** | 在 Notes 中粘贴网址并输入空格，可将裸链接转成以网页标题为文字的超链接。 |

![NotesCopilot 模型设置，可添加云端或本地服务商](docs/images/preview-magpie.png)

## 权限与数据

- **辅助功能**用于读取选区、识别可编辑光标、响应快捷键和写回。**自动化**用于通过 Apple Events 确认笔记身份、创建或修改笔记。使用本地笔记库和 Notes 模板时，需开启**完全磁盘访问**来读取 Notes 数据库。
- 点工具或提交指令时才向所配置的模型发送请求。选区请求使用指令和选中的文字，通用指令使用你输入的问题，追问会附上本次对话的相关轮次。主 AI 面板可按所选上下文附带笔记内容、近期对话或附件。API Key 随模型配置保存在本机偏好设置中。
- 开启 URL 标题转换时，应用会访问对应网页以获取标题，必要时尝试使用本机共享 Cookie 或已打开的浏览器标签页。[使用手册](docs/USAGE.md)

## 从源码构建

使用 Xcode 命令行工具构建原生应用。默认产物为 `build/NotesCopilot.app`。用 `NC_BUILD_OUTPUT` 可指定输出路径，`NC_CODESIGN_IDENTITY` 可指定签名身份。

```bash
git clone https://github.com/m0nkee/notescopilot.git
cd notescopilot
./build.sh
scripts/run-tests.sh
scripts/check-ui.sh
scripts/check-startup.sh
```

在已授予辅助功能权限的图形会话中，可进一步验证跨应用输入框、系统服务及发布包。

```bash
NC_TEST_INPUT_FIELDS=1 NC_TEST_SYSTEM_SERVICE=1 scripts/check-startup.sh
NC_BUILD_OUTPUT=build/release/NotesCopilot.app ./build.sh
scripts/package-dmg.sh
```

[架构说明](docs/ARCHITECTURE.md) · [验证记录](docs/VALIDATION.md) · [版本历史](CHANGELOG.md) · [MIT 许可证](LICENSE)

## 常见问题与当前限制

**首次打开时，macOS 提示「无法检查是否包含恶意软件」。** 当前发布包使用 Apple Development 证书签名，尚未经过 Apple 公证。若确认 DMG 来自本项目的 GitHub 发布页，且 SHA-256 与同版校验文件一致，可先点「完成」，再到「系统设置 → 隐私与安全性」，在安全性区域找到 NotesCopilot，点「仍要打开」并按系统提示确认。该选项会在尝试打开应用后出现。[Apple 官方说明](https://support.apple.com/zh-cn/102445)

**在其他应用按 MM 没反应。** 检查「应用范围」是否为「全局」、目标应用是否在允许范围内，以及「辅助功能」中授权的是否为当前安装的 NotesCopilot。单按 `M` 会正常打字。使用系统拼音时，先结束当前组词或候选词选择，再双按 `M`。密码等安全输入框会跳过。

**结果能复制，但没有「追加」「替换」或「插入」。** 网页正文、聊天回复等只读内容支持阅读和复制。写入需要宿主提供可核对的原输入框、正文及选区或光标。切换窗口、移动光标或修改原文后，写入可能失效。可先复制现有结果，或回到目标位置重新打开工具。部分自绘编辑器仅提供有限的 macOS 辅助功能信息。

**菜单栏图标找不到。** 可按 `⇧⌘Space` 呼出 AI 面板，或在「应用程序」中再次打开 NotesCopilot 恢复窗口。
