# Quick Folder Size for macOS

A small, native macOS folder-size explorer. Browse a directory tree, compare folder sizes, and find the largest files without opening a terminal.

简易原生 macOS 文件夹大小查看器。左侧目录树，右侧按大小排序的文件与目录列表，帮助快速定位磁盘空间占用。

## Download / 下载

Download **QuickFolderSize-1.0.0-macOS-arm64.zip** from the [latest release](https://github.com/NattoCB/QuickFolderSize/releases/latest), unzip it, and drag **Quick Folder Size.app** into **Applications**.

从 [最新 Release](https://github.com/NattoCB/QuickFolderSize/releases/latest) 下载压缩包，解压后将 **Quick Folder Size.app** 拖入“应用程序”。

- **Requirements:** Apple Silicon Mac, macOS 13 or later.
- **Signing:** locally ad hoc signed; not Apple-notarized. macOS may require you to confirm opening it in System Settings → Privacy & Security after checking the download source.
- **系统要求：** Apple Silicon Mac，macOS 13 或更新版本；当前不提供 Intel 构建。
- **签名：** 使用 ad hoc 签名，未经过 Apple 公证。如果系统阻止打开，请核对来源后按系统提示在“隐私与安全性”中允许打开。

## Features / 功能

- Explorer-style layout: folder tree and sortable file/folder table.
- Background scanning with progress and immediate cancellation.
- Allocated disk space and logical file-size views.
- Percentage bars and recursive file/folder counts.
- Largest files Top 100 across the most recent scan.
- Double-click to drill down; return to parent or previous folder.
- Reveal selected items in Finder and copy their paths.
- Visible reporting of inaccessible directories and incomplete results.
- No third-party dependencies, analytics, or network requests from the application.

## Usage / 使用

Choose a folder in the sidebar and click **扫描** (Scan), or use **选择文件夹…** (Choose Folder) to select and scan it. You can also enter a folder path and press Return. Double-click folders to navigate cached scan results; click column headers to sort.

**占用空间** shows allocated bytes; **文件大小** shows logical bytes. **大文件 Top 100** covers the entire most recent scan, while **目录内容** shows the current directory. Scanning inspects names and metadata, without reading file contents. The application provides no deletion commands.

选择左侧目录后点击“扫描”，或通过“选择文件夹…”开始。路径栏支持输入路径并回车。双击目录进入，点击列标题排序；“上一级”和“返回”用于导航。可以用“停止”取消扫描并保留原有结果。

### Permissions and accuracy / 权限与统计口径

macOS privacy controls can prevent access to protected folders. Incomplete scans show a skipped-item count and the first 50 access issues. For protected-directory scans, manually add **Quick Folder Size** to System Settings → Privacy & Security → Full Disk Access, then restart the app. Selecting a folder through the folder picker can also provide the normal system-authorized access to that folder.

扫描受保护目录时，可能需要在“系统设置 → 隐私与安全性 → 完全磁盘访问”中手动添加应用并重新启动。无法读取的内容会明确显示为未统计，不作为完整的零占用结果。

- Scans stay on the selected filesystem and do not follow symlinks.
- Hard-linked file data is counted once per scan. Individual hard-link rows show the full file size, so summing those rows may exceed the deduplicated folder total.
- Allocated sizes use `st_blocks`. APFS clones and shared extents can be counted more than once; these numbers do **not** guarantee recoverable space.
- The system-disk shortcut scans the Data volume. System, Preboot, Recovery, and VM volumes are separate and excluded from its folder totals.
- Results are snapshots. Rescanning a subtree marks cached parent totals as unscanned to avoid stale summaries.
- Cancellation restores the UI immediately. A background task blocked in a slow filesystem or permission request exits when that system call returns; it cannot replace newer results.

## Build and test / 构建与测试

Install Apple's Command Line Tools, then run:

```sh
sh scripts/test.sh
sh scripts/build.sh
```

The build creates `build/Quick Folder Size.app` with an ad hoc signature. The tests cover recursive totals, empty folders, symlink loops, hard-link deduplication, sparse files, cancellation, invalid roots, and unreadable folders.

```sh
# Generate a JSON size report.
"build/Quick Folder Size.app/Contents/MacOS/QuickFolderSize" --report /path/to/folder

# Open the app and scan a folder.
open "build/Quick Folder Size.app" --args --scan /path/to/folder
```

## License

[MIT](LICENSE) © 2026 NattoCB.
