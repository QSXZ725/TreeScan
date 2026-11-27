# TreeScan

<img src="desktop/assets/treescan-logo.png" width="64" height="64" alt="TreeScan 图标">

TreeScan 是本地磁盘空间分析工具。选择磁盘或目录后，可以边扫描边浏览，找出占用空间最大的目录和文件。

## 主要功能

- 目录树、面积图和大文件排行，可切换占用空间与逻辑大小。
- 支持停止扫描、重扫指定目录和导出 JSON 快照。
- 在应用内选择目录，按名称筛选已加载的条目。设置中可调整语言、主题、容量单位和扫描线程数。
- Windows 支持文件右键操作、SMART 磁盘健康、WSL 2 文件系统扫描和后台完成通知。
- Windows 的管理员重扫使用只读扫描窗口。文件操作和导出在普通窗口中可用。

## 使用

- **Windows** · 运行对应架构的 MSI，或解压整个便携 ZIP 后运行 `TreeScan.exe`。
- **Linux** · 解压图形包并运行 `treescan`。安装 GTK 3 运行库，并保留包内的 `lib` 和 `data`。
- **macOS** · 从源码构建图形版后启动 `TreeScan.app`，也可使用通用命令行工具。
- **Android** · 安装 APK 后可授权指定目录或共享存储。已 Root 的设备可授权扫描系统目录。

命令行接受目录路径。运行以下命令可扫描当前目录并导出快照。

```powershell
cargo run --locked --release -- . --export TreeScan-snapshot.json
```

## 数据与隐私

扫描在本机进行。快照包含扫描根路径和文件名。桌面与 Android 均可在应用内查看和导出本地崩溃报告。Android 的云备份已关闭，换机传输规则排除了崩溃记录。

## 从源码构建

扫描核心使用 Rust，桌面界面使用 Flutter。Windows 桌面构建需要 Visual Studio 的 C++ 桌面开发工作负载，Linux 需要 GTK 3 构建依赖，macOS 图形版需要 Xcode。 [构建脚本](scripts)

Android 正式版使用固定签名密钥。GitHub Actions 从仓库 Secrets 读取 `TREESCAN_ANDROID_KEYSTORE_BASE64` 和 `TREESCAN_ANDROID_STORE_PASSWORD`，签名别名为 `treescan`。在本机可设置密码环境变量并使用 `scripts/Build-Android.ps1 -Official -ReleaseKeystore <路径>`。普通构建使用预览签名。

## 开源协议

TreeScan 源码采用 MIT 协议。看板娘素材适用 CC BY-NC-SA 4.0，按上游要求署名，并遵循非商业使用和相同方式共享条款。 [MIT 许可证](LICENSE) · [素材清单](THIRD_PARTY_NOTICES.md)
