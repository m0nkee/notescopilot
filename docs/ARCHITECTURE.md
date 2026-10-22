# 架构说明

NotesCopilot 为 Swift 单进程应用（`swiftc` 直编，零第三方依赖），通过 macOS Accessibility（AX）与 CGEvent 通道与 Apple Notes 交互。核心交互设计参考了对 [ProNotes](https://github.com/robb/ProNotes) 的逆向取证结论。

## 模块总览

| 文件 | 职责 |
|---|---|
| `main.swift` | 应用主体：菜单栏 StatusItem、AI 面板窗口、全局快捷键 ⇧⌘Space（Carbon EventHotKey）、设置/资料库窗口、应用生命周期 |
| `Chat.swift` | `ChatEngine` + `AIService`：OpenAI 兼容端点 SSE 流式请求、多模型配置、上下文注入 |
| `Slash.swift` | 斜杠命令引擎：`/` 触发、命令注册表（AI/Markdown/模板/工具分组）、`NCLog` 诊断日志、KeywordListener（输入监控通道） |
| `SlashSuggest.swift` | 斜杠命令候选面板 UI（分组列表、键盘导航） |
| `SelectionAI.swift` | **选中加工条**：`SelectionWatcher`（0.2s AX 轮询）、`SelectionAIPanel`（AI/自定义/格式三段分组）、`SelectionKeyPanel`/`ActivatingTextField`（面板键盘焦点）、`NotesFormatButton`（格式按钮纯逻辑，可单测） |
| `NotesBridge.swift` | **Notes 桥接核心**：选区/光标读写、`formatMenuItems`（13 项格式菜单）、AX 菜单枚举与 AXPress、快捷键兜底（AXMenuItemCmdChar/Modifiers → CGEvent）、`selectionSignature` |
| `UrlTitle.swift` | URL → 标题超链：三级抓取（HTTP 直抓 → 共享 Cookie → 浏览器标签页 AppleScript） |
| `FormatBridge.swift` | 格式菜单缓存层：菜单元素查找与快捷键解析 |
| `TemplateEngine.swift` | 模板引擎：模板 = Notes「Templates」文件夹里的笔记（ProNotes 取证结论） |
| `Topotext.swift` | 笔记文本数据结构（Topotext 段落模型） |
| `LiberatorLite.swift` | NotesStore 直读：懒加载 `NoteStore.sqlite`（笔记库浏览），FSEvents 监听自动重索引 |
| `LibraryView.swift` | 资料库窗口 UI：浏览 Notes 笔记并可直接「问 AI」 |
| `Views.swift` | 设置页 UI：服务商预设、本地模型探测（`LocalAIProbe`）、多配置管理 |
| `FrontmostTracker.swift` | 前台应用追踪（判断 Notes 是否前台、记录最后的外部应用） |

## 关键机制

### 1. AX 轮询通道（ProNotes 同款）

- 不依赖「输入监控」权限，仅需辅助功能授权
- `AXSlashWatcher`（0.12s）轮询 Notes 焦点文本区光标前文本，命中 `/` 触发斜杠面板
- `SelectionWatcher`（0.2s）轮询选区，出现稳定选区后弹出加工条
- 选区签名（`selectionSignature`）仅取选区起止位置，避免每次全量读文本

### 2. Notes 菜单 AX 结构（重要取证结论）

- `AXMenuBar` 返回**单元素**（非数组），需 `unsafeBitCast` 后再取 children
- 菜单栏项的 `AXMenu` 属性返回 -25212（不支持）；**菜单必须用「菜单栏项的首个 child」通道读取**
- AX 可在不打开菜单的情况下读取全菜单树（含子菜单）
- 应用格式优先 `AXPress` 菜单项；失败时兜底读 `AXMenuItemCmdChar` / `AXMenuItemCmdModifiers`（bit0=Shift bit1=Option bit2=Control，Command 恒定），用 CGEvent `keyboardSetUnicodeString` 发送

### 3. 键盘事件与输入框焦点

- 全局快捷键用 Carbon `RegisterEventHotKey`（⇧⌘Space）
- 文本插入用 CGEvent `keyboardSetUnicodeString`（纯内存投递，无剪贴板污染/IME 阻塞）
- **borderless NSPanel 键盘焦点三要素**：`canBecomeKey=true` 的 NSPanel 子类 + 应用内激活（`NSApp.activate(ignoringOtherApps:)`，外部 activate 对 UIElement 应用无效）+ `makeFirstResponder`；面板持 key 期间需挂起选区轮询，防止面板被误收起

### 4. URL 三级抓取

```
HTTP 直抓（UA 伪装） → 共享 Cookie（WKWebView 池） → 浏览器标签页（AppleScript，独立 runAppleScriptGetOutput）
```

任一级拿到 `<title>` 即止；全部失败保留原 URL。

### 5. 模板即笔记

ProNotes v0.7.8.2 二进制取证：模板语法 = Templates 文件夹中的普通笔记，无独立模板存储。NotesCopilot 直接复用该约定。

## 测试

四套单测（`scripts/run-tests.sh` 一键回归）：

| 套件 | 覆盖 |
|---|---|
| `selai-tests` | 选中加工条：格式按钮全集/拆行/标签映射、面板逻辑（33 项） |
| `slashgroup-tests` | 斜杠命令分组与匹配（26 项） |
| `template-tests` | 模板引擎解析与编解码（41 项） |
| `urltitle-tests` | URL 抓取解析与误判防护（28 项） |

纯逻辑层（`NotesFormatButton`、模板引擎、URL 解析）与 UI/AX 层解耦，保证可单测性。

## 构建

```bash
./build.sh
```

- `swiftc -O -D NC_APP` 直编 14 个源文件，自动签名（优先本机「NotesCopilot Dev」证书，TCC 授权跨重建稳定；否则 adhoc）
- 产物：`build/NotesCopilot.app`；发布打包 `ditto -c -k --keepParent` 出 zip
