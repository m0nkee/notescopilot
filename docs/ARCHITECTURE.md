# 架构说明

NotesCopilot 为 Swift 单进程应用（`swiftc` 直编，零第三方依赖），通过 macOS Accessibility（AX）与 CGEvent 通道与 Apple Notes 交互。核心交互设计参考了对 [ProNotes](https://github.com/robb/ProNotes) 的逆向取证结论。

## 模块总览

| 文件 | 职责 |
|---|---|
| `main.swift` | 应用主体：菜单栏 StatusItem、AI 面板窗口、全局快捷键 ⇧⌘Space（Carbon EventHotKey）、设置/资料库窗口、应用生命周期 |
| `Chat.swift` | `ChatEngine` + `AIService`：OpenAI 兼容端点 SSE 流式请求、多模型配置、上下文注入 |
| `Slash.swift` | 斜杠命令引擎：`/` 触发、命令注册表（AI/Markdown/模板/工具分组）、`NCLog` 诊断日志、KeywordListener（辅助功能授权的 active event tap） |
| `SlashSuggest.swift` | 斜杠命令候选面板 UI（分组列表、键盘导航） |
| `SelectionAI.swift` | **选中加工条**：`SelectionWatcher`（0.2s AX 轮询）、`SelectionAIPanel`（AI/自定义/格式三段分组）、`SelectionKeyPanel`/`ActivatingTextField`（面板键盘焦点）、`NotesFormatButton`（格式按钮纯逻辑，可单测） |
| `NotesBridge.swift` | **Notes 桥接核心**：选区/光标读写、`formatMenuItems`（13 项格式菜单）、AX 菜单枚举与 AXPress、快捷键兜底（AXMenuItemCmdChar/Modifiers → CGEvent）、`selectionSignature` |
| `UrlTitle.swift` | URL → 标题超链：三级抓取（HTTP 直抓 → 共享 Cookie → 浏览器标签页 AppleScript） |
| `FormatBridge.swift` | 格式菜单缓存层：菜单元素查找与快捷键解析 |
| `TemplateEngine.swift` | 模板变量引擎、串行询问/AI、统一取消与目标绑定 |
| `Topotext.swift` | 笔记文本数据结构（Topotext 段落模型） |
| `LiberatorLite.swift` | NotesStore 直读：懒加载 `NoteStore.sqlite`（笔记库浏览），FSEvents 监听自动重索引 |
| `LibraryView.swift` | 资料库窗口 UI：浏览 Notes 笔记并可直接「问 AI」 |
| `Views.swift` | 设置页 UI：服务商预设、本地模型探测（`LocalAIProbe`）、多配置管理 |
| `AppUpdater.swift` | GitHub 正式发布版本检查、数值版本比较、每日检查与提醒节流、新版本缓存及自动检查开关 |
| `Markdown.swift` | Markdown 分块、原生预览与安全 HTML 写回；不执行原始 HTML |
| `NotesTemplateImporter.swift` | 读取 Notes 的 Templates 文件夹，生成默认可用的 Notes 模板 |
| `FrontmostTracker.swift` | 前台应用追踪（判断 Notes 是否前台、记录最后的外部应用） |

## 关键机制

### 1. AX 轮询通道（ProNotes 同款）

- AX 轮询不依赖「输入监控」权限，需要辅助功能授权；完整快照另通过自动化读取笔记身份，绑定安全的写回目标
- `AXSlashWatcher`（0.12s）是 Notes 正文斜杠/Markdown/URL 的唯一执行通道，各功能独立读取开关；键盘监听只负责命令导航和关键词扩展
- `KeywordListener` 使用 `.defaultTap` 拦截菜单导航键，由辅助功能授权和实际 tap 创建/启用结果决定是否启动；不以 listen-only 的输入监控预检提前阻止启动。撤权时停止旧 tap；创建或重新启用失败后限速重试，超时且授权仍有效时可直接恢复现有 tap。
- 命令删除绑定原 Notes 快照，通过 AX 区间替换并等待删除确认，不向其他应用投递全局退格
- 主面板、选中加工和模板写回均再次校验笔记、正文、选区与操作有效期；取消期间不执行迟到写入
- `SelectionWatcher`（0.2s）轮询选区，出现稳定选区后弹出加工条
- 选区签名（`selectionSignature`）仅取选区起止位置，避免每次全量读文本
- `SelectionPollingState` 仅在完整快照准备成功后提交已展示状态；失败时同一选区限速重试，换选区或取消选区立即清除失败等待。
- `NotesBridge.accessIssue` 区分缺少辅助功能、Notes 自动化拒绝及笔记身份不可用；通过去重通知更新面板和诊断页，不把访问问题混入手动 AI 请求错误。

### 2. Notes 菜单 AX 结构（重要取证结论）

- `AXMenuBar` 返回**单元素**（非数组），需 `unsafeBitCast` 后再取 children
- 菜单栏项的 `AXMenu` 属性返回 -25212（不支持）；**菜单必须用「菜单栏项的首个 child」通道读取**
- AX 可在不打开菜单的情况下读取全菜单树（含子菜单）
- 应用格式优先 `AXPress` 菜单项；失败时兜底读 `AXMenuItemCmdChar` / `AXMenuItemCmdModifiers`（bit0=Shift bit1=Option bit2=Control，Command 恒定），用 CGEvent `keyboardSetUnicodeString` 发送

### 3. 键盘事件与输入框焦点

- 全局快捷键用 Carbon `RegisterEventHotKey`（⇧⌘Space）
- 普通文本优先 AX 选区写入；富文本在主线程由安全 HTML 一次生成带样式内容，同时发布 RTFD、RTF、UTF-8 HTML 和纯文本，并调用 Notes 的“粘贴并保留样式”菜单。在准备剪贴板后及菜单执行前再次校验目标与操作有效期，按 changeCount 恢复完整剪贴板；菜单不可用时明确报错，不静默改为丢失样式的普通粘贴。
- **borderless NSPanel 键盘焦点三要素**：`canBecomeKey=true` 的 NSPanel 子类 + 应用内激活（`NSApp.activate(ignoringOtherApps:)`，外部 activate 对 UIElement 应用无效）+ `makeFirstResponder`；面板持 key 期间需挂起选区轮询，防止面板被误收起

### 4. URL 三级抓取

```
HTTP 直抓（UA 伪装） → 共享 Cookie（WKWebView 池） → 浏览器标签页（AppleScript，独立 runAppleScriptGetOutput）
```

任一级拿到 `<title>` 即止；全部失败保留原 URL。

### 5. 模板即笔记

本地模板存于 UserDefaults；NotesTemplateImporter 读取所有名称匹配 Templates（不区分大小写）的文件夹，筛选可完整解码且非空的笔记。NotesStore 就绪后在后台首次读取，已有 FSEvents 重索引通知触发后续刷新。每次扫描替换独立的内存缓存，修改、移出和删除均随之生效，缓存访问由锁保护；命令构建只读取缓存，不查询数据库。

NotesStore 兼容原生 `Z_PRIMARYKEY.Z_NAME` 与导出数据的 `ZNAME`，按注册表解析实际实体编号。行内标签和笔记链接按当前笔记所属的附件标识、类型和 `ZALTTEXT` 还原显示文字，校验 UTF-16 范围并调整样式长度；图片、表格及缺失元数据继续标记不完整。

Notes 模板以 `TopotextDoc` 第一行作为模板名，去掉该行和紧随的空白分隔行后生成插入载荷；首个内容段落提升为新文档标题，按 UTF-16 裁切并重新对齐样式范围，正文内部空行及后续样式保留，不使用附加标题的导出 Markdown。变量只对插入载荷执行一次并记录 UTF-16 替换范围，展开值继承变量起点样式，随后由 `NativeNoteHTML` 渲染为富文本。本地 Markdown 模板展开后也通过 HTML 写入。Notes 内的模板命令绑定原始目标并一次替换命令范围，避免新笔记标题暂时清空导致身份丢失；自动轮询抑制未变化命令的重复执行，用户显式选择仍可重试。

可用模板列表合并 Notes 与本地来源，同名命令优先使用 Notes 版本，本地内容继续保留。设置页分开展示两种来源，Notes 模板只读，编辑在 Notes 中完成。两种来源均支持日期、选区、剪贴板、ask 与 AI 变量。TemplateRunner 注册任务；停止/新会话取消当前模板，并在异步写回前校验有效期。

## 测试

九套回归（`scripts/run-tests.sh` 对单一源码快照执行）：

| 套件 | 覆盖 |
|---|---|
| `selai-tests` | 选中加工条：格式按钮全集/拆行/标签映射、面板逻辑（33 项） |
| `slashgroup-tests` | 斜杠命令分组与匹配（26 项） |
| `template-tests` | 模板引擎解析与编解码（41 项） |
| `urltitle-tests` | URL 抓取解析与误判防护 |
| `writeback-tests` | 原目标绑定、剪贴板准备期取消、选中结果恢复、延迟操作有效期 |
| `template-runner-tests` | AI 槽串行/失败恢复、配置快照、取消与延迟写回 |
| `chat-tests` | SSE 异常、重试续写、会话边界、Keychain 迁移和失败补偿 |
| `library-tests` | 合成 SQLite、真实 gzip/protobuf、全库中文搜索、并发索引与选择竞态 |
| `product-tests` | Markdown/HTML、模板合并、URL 登录页兜底 |

纯逻辑层（`NotesFormatButton`、模板引擎、URL 解析）与 UI/AX 层解耦，保证可单测性。

## 构建

```bash
./build.sh
```

- `swiftc -O -D NC_APP` 直编 `src/*.swift`，支持独立构建目录。签名优先 `NC_CODESIGN_IDENTITY`，其次有效的「NotesCopilot Dev」或唯一 Apple Development 身份；未找到身份时使用 adhoc，选定开发身份后签名失败不静默回退。
- 产物：`build/NotesCopilot.app`；发布打包 `ditto -c -k --keepParent` 出 zip

## 数据与会话边界

API Key 存于 Keychain，偏好配置仅保存标识。旧明文迁移先写密钥后清理偏好；批量写入失败尽力补偿并明确报告失败。每次请求冻结端点、凭据、模型和参数。更换笔记来源或模型配置会开始新会话，连续对话仅发送最近六轮。SSE 必须提供正常完成信号；截断、错误和空输出不会发布完成确认。

钥匙串默认使用不可交互的 `LAContext`。设置中的“授权钥匙串并保存”在后台使用本次专属的交互 backend，恢复不可读凭据后完成整批保存；UI 保留草稿、暂停编辑，并以已保存列表快照避免成功回填后再次自动保存。模型列表请求按代号及端点/密钥快照校验，授权开始前的迟到回调不会覆盖草稿。配置通知在 UI 的主线程接收。

主动授权并成功提交的凭据在当前进程内缓存，使后续配置加载和模型请求可复用已获授权的值；默认 backend 不保留交互上下文。缓存以短锁保护，在配置通知前同步；清空/删除、替换存储作用域、补偿失败会使相关值失效。常规保存的备份预检仍访问 backend，失败草稿不会进入缓存。

资料库在后台只读打开与建索引；SQLite/索引以递归锁串行访问，重索引事务保证读者不见半成品。正文解码支持独立 ZICNOTEDATA 与内嵌数据、gzip 与 zlib；无法完整还原时明确警告。

`scripts/check-ui.sh` 用隔离配置离屏渲染十四种原生布局，包含最小面板、错误/确认态、深浅设置页、钥匙串恢复卡，以及模拟 Notes 辅助功能/自动化/身份诊断。实际 macOS 权限、焦点和系统版本兼容性仍需真机验收。

`main.swift` 冷启动及 `applicationShouldHandleReopen` 均恢复主入口：未配置模型打开设置，已配置打开 AI 面板。窗口呈现统一解除最小化、恢复到现有屏幕并在应用激活后前置；设置/资料库收起浮动面板以免被遮挡。菜单栏可见状态不代表图标未被系统菜单遮挡，启动诊断同时记录其坐标、屏幕数、窗口及热键注册结果。

状态栏及设置侧栏的“打开 AI 面板”使用幂等 `showPanel`，全局热键保留 `togglePanel`。设置侧栏同时提供笔记库入口，避免仅依赖状态栏。诊断将状态栏窗口坐标与 `NSScreen.auxiliaryTopLeftArea/auxiliaryTopRightArea` 之间的刘海区域比对，记录 `statusItemObscuredByNotch`。

`scripts/check-startup.sh` 编译真实 AppDelegate，通过 `startBackgroundServices: false` 禁用 Notes 索引、监听器、权限请求与热键注册，使用隔离配置验证窗口生命周期；需要可连接 WindowServer 的图形会话。
