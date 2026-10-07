# Thru3D Media Player

[English](README.md)

面向 Meta Quest 和 PICO 的独立 Android VR/MR 媒体播放器。使用 Godot OpenXR 构建界面，Kotlin 管理媒体与授权，libmpv/FFmpeg 解码，MNN OpenCL 执行人物抠像与深度推理。

## 功能

- 视频和照片：平面、180°、360°，单目和左右立体。
- 支持的 180° 视频人物抠像与透视合成。
- 平面单目视频、照片的深度 2D→3D 显示。
- 本地文件、SMB、WebDAV、DLNA、媒体服务器及原生 115/百度适配。
- 音轨、字幕、播放控制、逐文件观看偏好。
- 手柄射线/扳机选择、手部交互及中英日界面。

## 公开范围与构建条件

公开仓库包含应用源码、必要资源、构建与模型修改脚本、第三方来源和测试。模型权重、编译依赖、签名密钥、个人媒体和研发记录不进入 Git。

**全新克隆尚不能在缺少外部工具链和匹配模型时直接生成 APK。** 当前默认抠像模型是本项目修改并蒸馏的 RVM；本次源码发布没有托管其权重，上游 checkpoint 不能直接替代。具体文件、SHA256、导入方式和复现边界见 [模型说明](docs/MODELS.md)。本快照不宣称已经完成现有 APK 的完整对应源码交付。

不依赖模型和 Android SDK 的源码检查：

```powershell
python tools/Check-PublicSource.py
$env:GODOT_EXE = (Get-Command godot).Source
./tools/Test-Source.ps1
```

Android 构建需先完成 [环境准备](docs/BUILD.md)，再导入自行取得且有权使用的版本匹配模型：

```powershell
$env:THRU3D_TOOL_ROOT = Join-Path $HOME '.cache/thru3d-toolchain'
./tools/Import-ModelAssets.ps1 -FromDirectory ./external-model-assets
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Quest
./tools/Build-Player.ps1 -ToolRoot $env:THRU3D_TOOL_ROOT -UsePreparedModelAssets -XrVendor Pico
```

输出在忽略的 `artifacts` 目录。自行生成的签名不一定可以覆盖已有发行版。Quest/PICO 分别使用对应厂商导出预设；PICO 打包检查不等同于 PICO 真机验证。

## 目录与操作

`app/godot` 包含场景、菜单、着色器和语言；`android` 包含 Kotlin 插件和 JVM 测试；`native` 包含 JNI 与推理/渲染；`tools` 包含构建和验证；`models` 只保存契约、哈希和许可；`third_party` 保存依赖来源与声明。

左 Menu 打开菜单，用手柄射线指向并按对应扳机选择。菜单内摇杆用于列表滚动，并屏蔽播放快捷动作；也支持手部指向和捏合。桌面模式用于开发预览。

抠像质量、GPU 支持及持续性能取决于模型、设备和媒体；主机与打包测试不代表头显播放性能验收。技术细节见 [架构](docs/ARCHITECTURE.md)、[测试](docs/TESTING.md) 和 [贡献指南](CONTRIBUTING.md)。

项目原创源码采用 **GPL-3.0-only**，完整文本见 [LICENSE](LICENSE)。第三方组件及资源保留原许可；适用范围和二进制发行要求见 [许可说明](docs/LICENSING.md)。
