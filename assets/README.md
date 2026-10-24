# NotesCopilot 应用图标

- `AppIcon.png`：图标源图，使用 1024 × 1024 或更大的正方形、不透明满幅 PNG，由 macOS 处理最终圆角，避免系统外框套住预制圆角图标。
- `AppIcon.icns`：macOS 应用图标，构建时复制到应用包的 `Contents/Resources`。
- `icon-prompt.md`：内置 imagegen 的生成方式与完整提示词。

修改源图后，在项目根目录运行：

```bash
scripts/generate-app-icon.sh
```

脚本使用 macOS 自带的 `sips` 和 `iconutil`，生成 16、32、128、256、512 点及各自的 @2x 尺寸，并自动清理临时文件。随后运行 `./build.sh`，新应用包会在签名前包含图标。
