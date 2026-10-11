import Foundation
import Darwin

final class DirectoryNode {
    let path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    weak var parent: DirectoryNode?
    var children: [DirectoryNode] = []
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var fileCount: Int = 0
    var folderCount: Int = 0
    var skippedCount: Int = 0
    var scanned = false
    init(_ path: String) { self.path = path }
}

struct FileRecord {
    let path: String
    let logicalBytes: Int64
    let allocatedBytes: Int64
}

struct ScanProgress {
    let files: Int
    let folders: Int
    let logicalBytes: Int64
    let path: String
}

struct ScanResult {
    let root: DirectoryNode
    let largestFiles: [FileRecord]
    let issues: [String]
    let elapsed: TimeInterval
}

enum ScanError: Error { case cancelled, invalidRoot(String) }

final class DiskScanner {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func scan(_ path: String, progress: (ScanProgress) -> Void = { _ in }) throws -> ScanResult {
        let start = Date()
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ScanError.invalidRoot(path)
        }
        let root = DirectoryNode(URL(fileURLWithPath: path).standardizedFileURL.path)
        var hardlinks = Set<FileIdentity>()
        var largest = LargestFiles(limit: 200)
        var issues: [String] = []
        var files = 0, folders = 0
        var logical: Int64 = 0
        var lastProgress = Date.distantPast
        var sinceCheck = 0

        func checkCancellation() throws {
            lock.lock(); let stop = cancelled; lock.unlock()
            if stop { throw ScanError.cancelled }
        }
        func issue(_ node: DirectoryNode, _ message: String) {
            node.skippedCount += 1
            if issues.count < 50 { issues.append(message) }
        }
        func visit(_ node: DirectoryNode) throws {
            try checkCancellation()
            if Date().timeIntervalSince(lastProgress) >= 0.25 {
                progress(ScanProgress(files: files, folders: folders, logicalBytes: logical, path: node.path))
                lastProgress = Date()
            }
            guard let directory = opendir(node.path) else {
                issue(node, node.path + ": " + String(cString: strerror(errno)))
                node.scanned = true
                return
            }
            defer { closedir(directory) }
            var info = stat()
            if lstat(node.path, &info) == 0 { node.allocatedBytes = Int64(info.st_blocks) * 512 }
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { issue(node, node.path + ": " + String(cString: strerror(errno))) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(validatingUTF8: $0)
                    }
                }
                guard let name = name, name != ".", name != ".." else { continue }
                let childPath = node.path == "/" ? "/" + name : node.path + "/" + name
                sinceCheck += 1
                if sinceCheck >= 128 {
                    try checkCancellation(); sinceCheck = 0
                    if Date().timeIntervalSince(lastProgress) >= 0.25 {
                        progress(ScanProgress(files: files, folders: folders, logicalBytes: logical, path: childPath))
                        lastProgress = Date()
                    }
                }
                var metadata = stat()
                guard lstat(childPath, &metadata) == 0 else {
                    issue(node, childPath + ": " + String(cString: strerror(errno)))
                    continue
                }
                guard metadata.st_dev == rootStat.st_dev else {
                    issue(node, childPath + ": 已跳过其他文件系统")
                    continue
                }
                let kind = metadata.st_mode & S_IFMT
                if kind == S_IFDIR {
                    let child = DirectoryNode(childPath)
                    child.parent = node
                    node.children.append(child)
                    folders += 1
                    try visit(child)
                    node.logicalBytes += child.logicalBytes
                    node.allocatedBytes += child.allocatedBytes
                    node.fileCount += child.fileCount
                    node.folderCount += child.folderCount + 1
                    node.skippedCount += child.skippedCount
                } else if kind == S_IFREG {
                    if metadata.st_nlink > 1 {
                        let identity = FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
                        if !hardlinks.insert(identity).inserted { continue }
                    }
                    let size = Int64(metadata.st_size)
                    let allocated = Int64(metadata.st_blocks) * 512
                    node.logicalBytes += size
                    node.allocatedBytes += allocated
                    node.fileCount += 1
                    files += 1; logical += size
                    largest.insert(FileRecord(path: childPath, logicalBytes: size, allocatedBytes: allocated))
                }
            }
            node.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            node.scanned = true
        }
        try visit(root)
        try checkCancellation()
        progress(ScanProgress(files: files, folders: folders, logicalBytes: logical, path: root.path))
        return ScanResult(root: root, largestFiles: largest.records, issues: issues, elapsed: Date().timeIntervalSince(start))
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

/// Bounded heaps keep the largest files in each size metric without retaining every file.
private struct LargestFiles {
    let limit: Int
    private var physical: [FileRecord] = []
    private var logical: [FileRecord] = []
    init(limit: Int) { self.limit = limit }
    mutating func insert(_ file: FileRecord) {
        Self.insert(file, into: &physical, limit: limit, size: { $0.allocatedBytes })
        Self.insert(file, into: &logical, limit: limit, size: { $0.logicalBytes })
    }
    var records: [FileRecord] {
        var unique: [String: FileRecord] = [:]
        for record in physical + logical { unique[record.path] = record }
        return unique.values.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }
    private static func insert(_ file: FileRecord, into heap: inout [FileRecord], limit: Int, size: (FileRecord) -> Int64) {
        if heap.count < limit {
            heap.append(file)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                if size(heap[parent]) <= size(heap[index]) { break }
                heap.swapAt(parent, index); index = parent
            }
        } else if size(file) > size(heap[0]) {
            heap[0] = file
            var index = 0
            while index * 2 + 1 < heap.count {
                var child = index * 2 + 1
                if child + 1 < heap.count && size(heap[child + 1]) < size(heap[child]) { child += 1 }
                if size(heap[index]) <= size(heap[child]) { break }
                heap.swapAt(index, child); index = child
            }
        }
    }
}
