import Foundation
import ResourceStewardCore

enum PerformanceChecks {
    static func run() {
        let hints = (0..<80).map { index in
            AppProcessHint(
                pid: Int32(10_000 + index), bundleID: "com.example.application\(index)",
                name: "Application \(index)", bundlePath: "/Applications/Application\(index).app",
                executablePath: "/Applications/Application\(index).app/Contents/MacOS/main"
            )
        }
        let snapshots: [ProcessSnapshot] = (0..<512).map { index in
            let appIndex = index % 80
            let bundleID: String? = index % 3 == 0 ? nil : "com.example.application\(appIndex).helper.renderer"
            let path = index % 3 == 0 ? "/usr/local/bin/worker\(index)" : "/Applications/Application\(appIndex).app/Contents/MacOS/helper"
            return ProcessSnapshot(
                timestamp: Date(timeIntervalSince1970: 100), pid: Int32(20_000 + index), uid: 501,
                bundleID: bundleID,
                processName: "Application \(index % 80) Helper",
                path: path,
                memoryFootprintMB: 100, cpuPercent: 1, isForeground: false, idleSeconds: 7_200
            )
        }
        var checksum = 0
        func measure(_ name: String, _ operation: () -> Void) {
            var durations: [Double] = []
            for _ in 0..<7 {
                let start = DispatchTime.now().uptimeNanoseconds
                operation()
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            print(String(format: "%@ first=%.3fms median=%.3fms", name, durations[0], durations.sorted()[3]))
        }
        measure("score 512 processes") {
            let scores = ReclaimScorer.scoreAll(snapshots: snapshots, workspace: nil)
            checksum += Int(scores.reduce(0) { $0 + $1.score })
        }
        measure("group 512 processes / 80 hints") {
            let keys = ProcessGrouper.keys(snapshots: snapshots, hints: hints)
            checksum += keys.values.reduce(0) { $0 + $1.utf8.count }
        }
        measure("merge running apps") {
            checksum += RunningAppCatalog.mergingProcessSnapshots(existing: [], snapshots: snapshots, currentUID: 501).count
        }
        print("checksum=\(checksum)")
    }
}
