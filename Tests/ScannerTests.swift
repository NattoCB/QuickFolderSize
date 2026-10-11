import Foundation
import Darwin

@main
struct ScannerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qfs-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { print("PASS: \(message)") }
            else { failures += 1; print("FAIL: \(message)") }
        }
        let nested = root.appendingPathComponent("nested")
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 4096).write(to: root.appendingPathComponent("small.txt"))
        try Data(repeating: 66, count: 8192).write(to: nested.appendingPathComponent("big.bin"))
        try fm.createSymbolicLink(atPath: nested.appendingPathComponent("loop").path, withDestinationPath: root.path)
        let first = try DiskScanner().scan(root.path)
        check(first.root.logicalBytes == 12288, "recursive totals exclude symlink targets")
        check(first.root.fileCount == 2, "recursive regular file count")
        check(first.root.folderCount == 2, "recursive folder count")
        check(first.root.children.first(where: { $0.name == "nested" })?.logicalBytes == 8192, "child aggregate enables drill-down")
        check(first.root.children.first(where: { $0.name == "empty" })?.logicalBytes == 0, "empty directories remain navigable")
        check(first.largestFiles.first?.path.hasSuffix("big.bin") == true, "largest files sorted by allocated size")

        try fm.linkItem(at: nested.appendingPathComponent("big.bin"), to: root.appendingPathComponent("hardlink.bin"))
        let linked = try DiskScanner().scan(root.path)
        check(linked.root.logicalBytes == 12288 && linked.root.fileCount == 2, "hard links counted once across directories")

        let sparse = root.appendingPathComponent("sparse.bin")
        _ = fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()
        let sparseResult = try DiskScanner().scan(root.path)
        check(sparseResult.root.logicalBytes == 33566720, "sparse file retains its logical length")
        check(sparseResult.root.allocatedBytes < sparseResult.root.logicalBytes, "allocated size distinguishes sparse data")

        let cancelled = DiskScanner()
        cancelled.cancel()
        do { _ = try cancelled.scan(root.path); check(false, "cancelled scan throws") }
        catch ScanError.cancelled { check(true, "cancelled scan throws") }
        catch { check(false, "unexpected cancellation error: \(error)") }
        do { _ = try DiskScanner().scan(root.appendingPathComponent("missing").path); check(false, "missing root rejected") }
        catch ScanError.invalidRoot { check(true, "missing root rejected") }
        catch { check(false, "unexpected missing-root error: \(error)") }
        do { _ = try DiskScanner().scan(sparse.path); check(false, "file root rejected") }
        catch ScanError.invalidRoot { check(true, "file root rejected") }
        catch { check(false, "unexpected file-root error: \(error)") }

        let denied = root.appendingPathComponent("denied")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        chmod(denied.path, 0)
        let deniedResult = try DiskScanner().scan(root.path)
        chmod(denied.path, 0o700)
        check(deniedResult.root.skippedCount == 1 && !deniedResult.issues.isEmpty, "unreadable folders reported instead of silently counted as empty")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("All scanner tests passed")
    }
}
