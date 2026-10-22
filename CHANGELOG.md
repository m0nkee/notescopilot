# Changelog

本项目的所有重要变更记录在此文件中。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [2.5.0] - 2026-10-22

### 新增
- **选中即加工**：Notes 选中文本后自动弹出悬浮加工条
  - AI 快捷指令：润色 / 总结 / 翻译 / 解释 / 精简，结果可替换选区或追加
  - 自定义指令输入框：任意指令 `⏎` 执行
  - Notes 原生格式按钮 13 项（标题/小标题/副标题/正文/等宽/斜体/下划线/删除线/颜色/圆点列表/短划线/编号列表/块引用），AX 动态枚举「格式」菜单，AXPress 应用 + 快捷键兜底
- **URL 自动转标题超链**：粘贴 URL + 空格自动替换为网页标题超链，三级抓取兜底（HTTP → 共享 Cookie → 浏览器标签页）
- 面板 UI 三段式分组（AI / 自定义 / 格式），Magpie 风格左列标签
- 自定义指令输入框键盘焦点修复（SelectionKeyPanel + ActivatingTextField + 轮询挂起）

### 修复
- 非激活应用的 borderless 面板无法获得键盘焦点的问题
- 面板输入期间选区轮询误收起面板的问题
- 格式应用后前台切换导致 AX 操作失败的问题（动作前自动归还前台给 Notes）

### 测试
- 四套单测回归 128 项全 PASS（selai 33 / slashgroup 26 / template 41 / urltitle 28）
- 新增测试脚本 `scripts/run-tests.sh`

## [2.4.1] - 2026-10-21

- 稳定性与细节优化

## [2.4.0] - 2026-10-21

- 斜杠面板分组展示（AI 优化 / Markdown 格式 / 模板 / 工具，Magpie 风格分组头）

## [2.3.0] - 2026-10-21

- 模板引擎（模板 = Notes「Templates」文件夹笔记，ProNotes 取证结论）

## [2.2.1] - 2026-10-21

- 修复与体验优化

## [2.2.0] - 2026-10-21

- 资料库视图：浏览 Notes 笔记并直接「问 AI」

## [2.1.0] - 2026-10-20

- 斜杠命令与多模型配置增强

## [2.0.1] - 2026-10-18

- 菜单栏常驻 + 全局快捷键 ⇧⌘Space AI 面板
- OpenAI 兼容端点流式对话（DeepSeek / Kimi / 通义千问 / OpenAI / OpenRouter / 硅基流动 / 本地 Ollama·LM Studio）
- Notes 写入（插入光标处 / 替换选区）
