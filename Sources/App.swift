import AppKit
import Darwin

func formattedSize(_ bytes: Int64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes), index = 0
    while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
    return index == 0 ? "\(bytes) B" : String(format: value >= 10 ? "%.1f %@" : "%.2f %@", value, units[index])
}

private struct BrowserRow {
    let path: String
    let directory: DirectoryNode?
    let logical: Int64?
    let allocated: Int64?
    let files: Int?
    let kind: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

private final class ShareCell: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        var fill = rect; fill.size.width *= min(1, max(0, fraction))
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
        let text = String(format: "%.1f%%", fraction * 100) as NSString
        let style = NSMutableParagraphStyle(); style.alignment = .right
        text.draw(in: rect.insetBy(dx: 6, dy: -1), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: style
        ])
    }
}

final class FolderWindow: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let outline = NSOutlineView()
    private let table = NSTableView()
    private let pathField = NSTextField()
    private let status = NSTextField(labelWithString: "选择文件夹，点击扫描即可查看每个子目录的大小。")
    private let summary = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let scanButton = NSButton(title: "扫描", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let upButton = NSButton(title: "上一级", target: nil, action: nil)
    private let backButton = NSButton(title: "返回", target: nil, action: nil)
    private let revealButton = NSButton(title: "在 Finder 中显示", target: nil, action: nil)
    private let issueButton = NSButton(title: "访问问题", target: nil, action: nil)
    private let metric = NSSegmentedControl(labels: ["占用空间", "文件大小"], trackingMode: .selectOne, target: nil, action: nil)
    private let mode = NSSegmentedControl(labels: ["目录内容", "大文件 Top 100"], trackingMode: .selectOne, target: nil, action: nil)
    private var roots: [DirectoryNode] = []
    private var rootNames: [String: String] = [:]
    private var current: DirectoryNode!
    private var result: ScanResult?
    private var rows: [BrowserRow] = []
    private var scanner: DiskScanner?
    private let scanQueue = DispatchQueue.global(qos: .utility)
    private var pendingPath: String?
    private var history: [DirectoryNode] = []
    private var selecting = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Quick Folder Size — 文件夹大小"
        window.minSize = NSSize(width: 900, height: 540)
        window.setFrameAutosaveName("QuickFolderSizeWindow")
        super.init(window: window)
        buildUI()
        loadRoots()
        navigate(to: roots[1], recordHistory: false)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func button(_ button: NSButton, _ action: Selector) {
        button.bezelStyle = .rounded; button.target = self; button.action = action
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let choose = NSButton(title: "选择文件夹…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        button(scanButton, #selector(scanCurrent))
        button(stopButton, #selector(stopScan))
        button(upButton, #selector(goUp))
        button(backButton, #selector(goBack))
        button(revealButton, #selector(reveal))
        button(issueButton, #selector(showIssues))
        scanButton.keyEquivalent = "r"; scanButton.keyEquivalentModifierMask = .command
        stopButton.isEnabled = false
        issueButton.isHidden = true
        pathField.placeholderString = "文件夹路径"; pathField.target = self; pathField.action = #selector(pathEntered)
        pathField.font = .systemFont(ofSize: 12)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metric.selectedSegment = 0; metric.target = self; metric.action = #selector(changeMetric)
        metric.toolTip = "占用空间来自文件块分配量；APFS 克隆共享块可能重复统计。文件大小为逻辑长度。"
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(changeDisplayMode)

        let tools = NSStackView(views: [choose, backButton, upButton, pathField, scanButton, stopButton])
        tools.orientation = .horizontal; tools.spacing = 8
        tools.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tools)

        let info = NSStackView(views: [metric, mode, revealButton, issueButton])
        info.orientation = .horizontal; info.spacing = 12; info.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(info)

        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        let sidebar = NSScrollView(); sidebar.hasVerticalScroller = true; sidebar.borderType = .noBorder
        let sidebarColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        sidebarColumn.title = "磁盘与文件夹"; sidebarColumn.width = 250
        outline.addTableColumn(sidebarColumn); outline.outlineTableColumn = sidebarColumn
        outline.headerView = nil; outline.rowHeight = 26; outline.indentationPerLevel = 16
        outline.dataSource = self; outline.delegate = self; outline.style = .sourceList
        outline.autoresizingMask = [.width, .height]; outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sidebar.documentView = outline
        let tableScroll = NSScrollView(); tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 30; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openRow)
        table.allowsMultipleSelection = false; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let columns: [(String, String, CGFloat)] = [
            ("name", "名称", 300), ("size", "占用空间", 115), ("share", "占比", 100),
            ("files", "文件数", 90), ("kind", "类型 / 状态", 150)
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? 160 : 65
            if id != "share" && id != "kind" { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name") }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        let menu = NSMenu()
        menu.addItem(withTitle: "打开文件夹", action: #selector(openRow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "在 Finder 中显示", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "复制路径", action: #selector(copyPath), keyEquivalent: "").target = self
        table.menu = menu
        tableScroll.documentView = table
        split.addArrangedSubview(sidebar); split.addArrangedSubview(tableScroll)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true

        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        progressBar.style = .bar; progressBar.isIndeterminate = true; progressBar.isDisplayedWhenStopped = false
        for view in [summary, status, progressBar] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tools.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tools.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            info.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10),
            info.leadingAnchor.constraint(equalTo: tools.leadingAnchor),
            split.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -10),
            summary.leadingAnchor.constraint(equalTo: tools.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: tools.trailingAnchor),
            status.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: tools.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: tools.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            progressBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: split.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3)
        ])
        content.layoutSubtreeIfNeeded()
        split.setPosition(265, ofDividerAt: 0)
    }

    private func loadRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let initial = [("/System/Volumes/Data", "Macintosh HD · 数据卷"), (home, "个人目录"),
                       (home + "/Desktop", "桌面"), (home + "/Downloads", "下载")]
        for (path, name) in initial { roots.append(DirectoryNode(path)); rootNames[path] = name }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path.hasPrefix("/Volumes/") {
            roots.append(DirectoryNode(volume.path)); rootNames[volume.path] = volume.lastPathComponent
        }
        outline.reloadData()
    }
    private var allocatedMetric: Bool { metric.selectedSegment == 0 }
    private func bytes(_ row: BrowserRow) -> Int64? { allocatedMetric ? row.allocated : row.logical }
    private func bytes(_ node: DirectoryNode) -> Int64 { allocatedMetric ? node.allocatedBytes : node.logicalBytes }

    private func loadChildren(_ node: DirectoryNode) {
        guard !node.scanned, node.children.isEmpty else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: node.path) else { return }
        for name in names {
            let path = node.path == "/" ? "/" + name : node.path + "/" + name
            var s = stat()
            if lstat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR {
                let child = DirectoryNode(path); child.parent = node; node.children.append(child)
            }
        }
        node.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func navigate(to node: DirectoryNode, recordHistory: Bool = true) {
        if scanner != nil { return }
        if recordHistory, let current = current, current.path != node.path { history.append(current) }
        current = node; pathField.stringValue = node.path
        upButton.isEnabled = node.path != "/"; backButton.isEnabled = !history.isEmpty
        mode.selectedSegment = 0
        reloadRows()
        if let parent = node.parent { outline.expandItem(parent) }
        let index = outline.row(forItem: node)
        if index >= 0 {
            selecting = true; outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            outline.scrollRowToVisible(index); selecting = false
        }
    }
    private func reloadRows() {
        guard let current = current else { return }
        if mode.selectedSegment == 1 {
            rows = (result?.largestFiles ?? []).map {
                BrowserRow(path: $0.path, directory: nil, logical: $0.logicalBytes, allocated: $0.allocatedBytes, files: 1,
                           kind: URL(fileURLWithPath: $0.path).deletingLastPathComponent().path)
            }
            rows.sort { (bytes($0) ?? 0) > (bytes($1) ?? 0) }
            rows = Array(rows.prefix(100))
        } else {
            loadChildren(current)
            rows = current.children.map {
                BrowserRow(path: $0.path, directory: $0, logical: $0.scanned ? $0.logicalBytes : nil,
                           allocated: $0.scanned ? $0.allocatedBytes : nil, files: $0.scanned ? $0.fileCount : nil,
                           kind: $0.skippedCount > 0 ? "文件夹 · \($0.skippedCount) 项跳过" : "文件夹")
            }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) {
                for name in names {
                    let path = current.path == "/" ? "/" + name : current.path + "/" + name
                    var s = stat()
                    guard lstat(path, &s) == 0, (s.st_mode & S_IFMT) != S_IFDIR else { continue }
                    let regular = (s.st_mode & S_IFMT) == S_IFREG
                    rows.append(BrowserRow(path: path, directory: nil, logical: regular ? Int64(s.st_size) : nil,
                                           allocated: regular ? Int64(s.st_blocks) * 512 : nil, files: regular ? 1 : nil,
                                           kind: regular ? (s.st_nlink > 1 ? "文件 · 硬链接" : "文件") : "符号链接 / 特殊文件"))
                }
            }
        }
        sortRows()
        table.reloadData()
        updateSummary()
    }
    private func sortRows() {
        let descriptor = table.sortDescriptors.first ?? NSSortDescriptor(key: "size", ascending: false)
        rows.sort { a, b in
            if descriptor.key == "name" {
                let order = a.name.localizedStandardCompare(b.name)
                return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            let av = descriptor.key == "files" ? a.files.map(Int64.init) : bytes(a)
            let bv = descriptor.key == "files" ? b.files.map(Int64.init) : bytes(b)
            if av == nil && bv != nil { return false }
            if av != nil && bv == nil { return true }
            if av == bv { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return descriptor.ascending ? (av ?? 0) < (bv ?? 0) : (av ?? 0) > (bv ?? 0)
        }
    }
    private func updateSummary() {
        guard let current = current else { return }
        if mode.selectedSegment == 1, let result = result {
            summary.stringValue = "大文件 Top 100 · 扫描范围：\(result.root.path)"
        } else if current.scanned {
            summary.stringValue = "\(formattedSize(bytes(current)))  ·  \(current.fileCount.formatted()) 个文件  ·  \(current.folderCount.formatted()) 个文件夹" +
                (current.skippedCount > 0 ? "  ·  \(current.skippedCount) 项未统计" : "")
        } else {
            summary.stringValue = "未扫描 · \(current.path)"
        }
        var volume = statfs()
        if statfs(current.path, &volume) == 0, scanner == nil {
            let block = Int64(volume.f_bsize)
            let total = Int64(volume.f_blocks) * block, free = Int64(volume.f_bavail) * block
            status.stringValue = "所在卷：总容量 \(formattedSize(total)) · 可用 \(formattedSize(free))   |   不跟随符号链接；扫描不跨卷；APFS 共享块可能重复统计。"
        }
        revealButton.isEnabled = true
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "选择并扫描"
        panel.directoryURL = URL(fileURLWithPath: current.path)
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openPath(url.path, scan: true)
        }
    }
    func openPath(_ path: String, scan: Bool) {
        if scanner != nil { pendingPath = path; stopScan(); return }
        let expanded = (path as NSString).expandingTildeInPath
        var s = stat()
        guard lstat(expanded, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else {
            let alert = NSAlert(); alert.messageText = "无法打开文件夹"; alert.informativeText = expanded
            alert.beginSheetModal(for: window!); return
        }
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let existing = findNode(normalized)
        let node = existing ?? DirectoryNode(normalized)
        if existing == nil { roots.append(node); outline.reloadData() }
        navigate(to: node)
        if scan { scanCurrent() }
    }
    private func findNode(_ path: String) -> DirectoryNode? {
        func search(_ node: DirectoryNode) -> DirectoryNode? {
            if node.path == path { return node }
            for child in node.children where path.hasPrefix(child.path + "/") || path == child.path {
                if let found = search(child) { return found }
            }
            return nil
        }
        for root in roots { if let node = search(root) { return node } }
        return nil
    }
    @objc func pathEntered() { openPath(pathField.stringValue, scan: true) }
    @objc func scanCurrent() {
        guard scanner == nil, let current = current else { return }
        window?.makeFirstResponder(nil)
        let requested = URL(fileURLWithPath: (pathField.stringValue as NSString).expandingTildeInPath).standardizedFileURL.path
        if requested != current.path { openPath(requested, scan: true); return }
        let path = current.path
        let worker = DiskScanner(); scanner = worker
        scanButton.isEnabled = false; stopButton.isEnabled = true
        backButton.isEnabled = false; upButton.isEnabled = false; pathField.isEnabled = false
        issueButton.isHidden = true; progressBar.startAnimation(nil)
        status.stringValue = "正在扫描：\(path)"
        summary.stringValue = "扫描中…可停止；不会读取文件正文。"
        scanQueue.async { [weak self] in
            do {
                let result = try worker.scan(path) { progress in
                    DispatchQueue.main.async {
                        guard let self = self, self.scanner === worker else { return }
                        self.summary.stringValue = "扫描中 · \(progress.files.formatted()) 个文件 · \(progress.folders.formatted()) 个目录 · \(formattedSize(progress.logicalBytes)) 文件大小"
                        self.status.stringValue = progress.path
                    }
                }
                DispatchQueue.main.async {
                    guard self?.scanner === worker else { return }
                    self?.finishScan(result, error: nil, original: current)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.scanner === worker else { return }
                    self?.finishScan(nil, error: error, original: current)
                }
            }
        }
    }
    private func finishScan(_ completed: ScanResult?, error: Error?, original: DirectoryNode) {
        scanner = nil; scanButton.isEnabled = true; stopButton.isEnabled = false
        pathField.isEnabled = true; progressBar.stopAnimation(nil)
        if let completed = completed {
            result = completed
            let node = completed.root
            if let parent = original.parent, let index = parent.children.firstIndex(where: { $0 === original }) {
                parent.children[index] = node; node.parent = parent
                // Parent totals become stale after rescanning a subtree; require a fresh parent scan.
                var ancestor: DirectoryNode? = parent
                while let item = ancestor { item.scanned = false; ancestor = item.parent }
            } else if let index = roots.firstIndex(where: { $0 === original }) { roots[index] = node }
            outline.reloadData(); outline.expandItem(node)
            navigate(to: node, recordHistory: false)
            issueButton.isHidden = completed.root.skippedCount == 0
            issueButton.title = "访问问题 (\(completed.root.skippedCount))"
            status.stringValue = String(format: "扫描完成 · %.1f 秒 · ", completed.elapsed) +
                (completed.root.skippedCount > 0 ? "结果不完整，\(completed.root.skippedCount) 项已跳过。" : "") +
                "占用空间不等于可释放空间；APFS 共享块可能重复统计。"
        } else {
            navigate(to: original, recordHistory: false)
            status.stringValue = error is ScanError ? "扫描已停止或目录无法读取；原有结果已保留。" : "扫描失败：\(error?.localizedDescription ?? "未知错误")"
        }
        if let pending = pendingPath { pendingPath = nil; openPath(pending, scan: true) }
    }
    @objc func stopScan() {
        scanner?.cancel()
        finishScan(nil, error: ScanError.cancelled, original: current)
    }
    @objc func goUp() {
        guard scanner == nil else { return }
        if let parent = current.parent { navigate(to: parent) }
        else { openPath(URL(fileURLWithPath: current.path).deletingLastPathComponent().path, scan: false) }
    }
    @objc func goBack() { if scanner == nil, let last = history.popLast() { navigate(to: findNode(last.path) ?? last, recordHistory: false) } }
    @objc func changeMetric() {
        table.tableColumns.first(where: { $0.identifier.rawValue == "size" })?.title = allocatedMetric ? "占用空间" : "文件大小"
        reloadRows()
    }
    @objc func changeDisplayMode() {
        if mode.selectedSegment == 1 && result == nil { mode.selectedSegment = 0 }
        reloadRows()
    }
    private var selectedRow: BrowserRow? {
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(index) ? rows[index] : nil
    }
    @objc func openRow() {
        guard scanner == nil, let row = selectedRow else { return }
        if let node = row.directory { navigate(to: node) }
        else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
    }
    @objc func reveal() {
        let path = selectedRow?.path ?? current.path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    @objc func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedRow?.path ?? current.path, forType: .string)
    }
    @objc func showIssues() {
        guard let result = result else { return }
        let alert = NSAlert(); alert.messageText = "\(result.root.skippedCount) 项未统计"
        alert.informativeText = "权限不足的目录不会计作完整结果。可在系统设置 → 隐私与安全性 → 完全磁盘访问中添加 Quick Folder Size，然后重新扫描。以下显示前 50 项。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 260)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = result.issues.joined(separator: "\n\n"); scroll.documentView = text
        alert.accessoryView = scroll; alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "打开系统设置")
        alert.beginSheetModal(for: window!) { response in
            if response == .alertSecondButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { sortRows(); table.reloadData() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        if column.identifier.rawValue == "share" {
            guard let size = bytes(item), let current = current, current.scanned || mode.selectedSegment == 1 else { return textCell("—", alignment: .right) }
            let denominator = mode.selectedSegment == 1 ? (result.map { bytes($0.root) } ?? 0) : bytes(current)
            let cell = ShareCell(); cell.fraction = denominator > 0 ? Double(size) / Double(denominator) : 0
            return cell
        }
        if column.identifier.rawValue == "name" {
            let cell = NSTableCellView()
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = NSImage(systemSymbolName: item.directory != nil ? "folder.fill" : "doc", accessibilityDescription: nil)
            icon.contentTintColor = item.directory != nil ? .systemBlue : .secondaryLabelColor
            let text = label(item.name); text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon); cell.addSubview(text); cell.textField = text; cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6)
            ])
            cell.toolTip = item.path; return cell
        }
        switch column.identifier.rawValue {
        case "size": return textCell(bytes(item).map(formattedSize) ?? "未扫描", alignment: .right)
        case "files": return textCell(item.files?.formatted() ?? "—", alignment: .right)
        default: return textCell(item.kind, color: item.kind.contains("跳过") ? .systemOrange : .secondaryLabelColor)
        }
    }
    private func textCell(_ value: String, alignment: NSTextAlignment = .left, color: NSColor = .labelColor) -> NSView {
        let cell = NSView(), text = label(value, alignment: alignment)
        cell.wantsLayer = true; cell.layer?.masksToBounds = true
        text.translatesAutoresizingMaskIntoConstraints = false; text.textColor = color
        cell.addSubview(text); cell.toolTip = value
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    private func label(_ value: String, alignment: NSTextAlignment = .left) -> NSTextField {
        let text = NSTextField(labelWithString: value)
        text.alignment = alignment; text.lineBreakMode = .byTruncatingMiddle
        text.font = alignment == .right ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        return text
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DirectoryNode else { return roots.count }
        loadChildren(node); return node.children.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? DirectoryNode)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? DirectoryNode else { return false }
        return !node.scanned || !node.children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DirectoryNode else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(systemSymbolName: rootNames[node.path] != nil ? "internaldrive" : "folder", accessibilityDescription: nil)
        image.contentTintColor = .secondaryLabelColor
        let text = label(rootNames[node.path] ?? node.name); text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image); cell.addSubview(text); cell.textField = text; cell.imageView = image; cell.toolTip = node.path
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, scanner == nil, let item = outline.item(atRow: outline.selectedRow) as? DirectoryNode else { return }
        navigate(to: item)
    }
    func cancelOnExit() { scanner?.cancel() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: FolderWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Quick Folder Size", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Quick Folder Size", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
        controller = FolderWindow(); controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let index = CommandLine.arguments.firstIndex(of: "--scan"), CommandLine.arguments.indices.contains(index + 1) {
            controller?.openPath(CommandLine.arguments[index + 1], scan: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { controller?.cancelOnExit() }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first { controller?.openPath(path, scan: true) }
        sender.reply(toOpenOrPrint: .success)
    }
}

@main
struct QuickFolderSize {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let result = try DiskScanner().scan(CommandLine.arguments[index + 1])
                let report: [String: Any] = [
                    "path": result.root.path, "logicalBytes": result.root.logicalBytes,
                    "allocatedBytes": result.root.allocatedBytes, "files": result.root.fileCount,
                    "folders": result.root.folderCount, "skipped": result.root.skippedCount,
                    "elapsedSeconds": result.elapsed, "issues": result.issues,
                    "directories": result.root.children.map { ["path": $0.path, "logicalBytes": $0.logicalBytes, "allocatedBytes": $0.allocatedBytes, "files": $0.fileCount] as [String: Any] },
                    "largestFiles": Array(result.largestFiles.prefix(100)).map { ["path": $0.path, "logicalBytes": $0.logicalBytes, "allocatedBytes": $0.allocatedBytes] as [String: Any] }
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data); print("")
            } catch { fputs("Scan failed: \(error)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
