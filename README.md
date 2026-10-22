<div align="center">

# NotesCopilot

**macOS 原生菜单栏 AI 写作助手，深度集成 Apple Notes**

`Swift` · `AppKit/SwiftUI` · `零依赖` · `arm64` · `macOS 13+`

</div>

---

NotesCopilot 常驻菜单栏，为 Apple Notes 提供 AI 加工能力：全局快捷键呼出对话面板、Notes 内 `/` 唤起斜杠命令、选中文本即刻弹出加工条（AI 快捷指令 + 自定义指令 + Notes 原生格式按钮）。所有交互通过辅助功能（Accessibility）通道直达 Notes，无需手动复制粘贴。

> 设计参考 ProNotes 的逆向取证结论：AX 轮询通道、模板即笔记、NotesStore 直读等。

## ✨ 功能特性

![选中加工条](docs/images/panel-format.png)

### 1. 菜单栏 AI 面板（⇧⌘Space 全局呼出）
- 菜单栏常驻，任意应用内按 `⇧⌘Space` 呼出对话面板
- 流式输出，AI 结果一键写入 Notes（自动插入光标处 / 选中替换）
- 无 Dock 图标（LSUIElement），不打断工作流

### 2. 斜杠命令（Notes 内输入 `/`）
- 在 Notes 中输入 `/` 自动唤起命令面板，按分组展示：
  **AI 加工**（润色/总结/翻译/解释/精简）· **Markdown 格式** · **模板** · **工具**
- 自动取光标前上下文，AI 回答不再"凭空瞎答"
- 模板 = Notes「Templates」文件夹里的笔记，直接复用你已有的笔记做模板

### 3. 选中即加工（悬浮加工条）
选中文本后自动弹出，三段式分组：

| 分组 | 内容 |
|---|---|
| **AI** | 润色 · 总结 · 翻译 · 解释 · 精简 |
| **自定义** | 输入任意指令，`⏎` 执行（如：改写成邮件语气） |
| **格式** | 标题 · 小标题 · 副标题 · 正文 · 等宽 · 斜体 · 下划线 · 删除线 · 颜色 · 圆点列表 · 短划线 · 编号列表 · 块引用 |

- 格式按钮动态枚举 Notes「格式」菜单（AXPress 应用，无快捷键的项也能用）
- 自定义指令执行后可「替换选区」或「追加到选区后」
- 面板保持展开，格式可连续叠加

### 4. URL 自动转标题超链
- 在 Notes 粘贴 URL + 空格，约 2 秒内自动替换为「网页标题」超链接
- 三级抓取兜底：HTTP 直抓 → 共享 Cookie → 浏览器标签页

### 5. 任意 OpenAI 兼容模型
- 内置预设：DeepSeek · Kimi · 通义千问 · OpenAI · OpenRouter · 硅基流动
- 本地模型自动探测：**Ollama** · **LM Studio** · llama.cpp · vLLM
- 多配置保存，点选切换，支持自定义端点

![设置页](docs/images/preview-magpie.png)

## 📦 安装

### 下载使用
1. 解压 `NotesCopilot-2.5.0-arm64.zip`，将 `NotesCopilot.app` 拖入「应用程序」
2. 首次启动：系统设置 → 隐私与安全性 → **辅助功能** 中授权 NotesCopilot
3. 菜单栏出现图标，按 `⇧⌘Space` 开始使用

### 从源码构建
```bash
git clone <repo-url> && cd notescopilot
./build.sh          # 产出 build/NotesCopilot.app
scripts/run-tests.sh  # 四套单测回归（128 项）
```
> 零第三方依赖，仅需 Xcode 命令行工具（swiftc）。

## 🔐 权限说明

| 权限 | 用途 |
|---|---|
| 辅助功能（必需） | 读写 Notes 选区/光标、枚举格式菜单、AX 轮询通道、CGEvent 键击投递 |
| 自动化（Apple Events） | 创建临时笔记等脚本操作 |
| 输入监控（可选） | 斜杠命令全局按键监听；未授权时自动降级为 AX 轮询通道 |

所有数据仅在本机处理；AI 请求直接发往你自己配置的服务商端点。

## 🚀 快速上手

1. **配置模型**：菜单栏图标 → 设置 → 选择服务商或本地模型，填入 API Key
2. **对话**：任意应用按 `⇧⌘Space`，输入问题，结果可写入 Notes
3. **斜杠命令**：在 Notes 正文输入 `/`，选择命令
4. **选中加工**：选中一段文字 → 弹出加工条 → 点按钮或输入自定义指令

详细功能说明见 [docs/USAGE.md](docs/USAGE.md)。

## 🧱 项目结构

```
notescopilot/
├── build.sh              # 一键构建脚本（swiftc 直编，产出 .app）
├── Info.plist            # Bundle 配置（v2.5.0，LSUIElement）
├── src/                  # 源码（14 个模块，见 docs/ARCHITECTURE.md）
├── tests/                # 四套单测（selai/slashgroup/template/urltitle）
├── scripts/run-tests.sh  # 测试回归脚本
├── tools/                # 开发期调试工具（AX 探针、渲染工具）
└── docs/                 # 使用说明、架构文档、截图
```

## 🛠 开发

```bash
./build.sh              # 构建
scripts/run-tests.sh    # 单测回归
tail -f ~/Library/Logs/NotesCopilot-debug.log   # 查看诊断日志
```

调试与逆向取证工具位于 `tools/`（AX 探针、离屏渲染等）。

## 📄 License

[MIT](LICENSE)
