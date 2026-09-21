import Foundation
import ResourceStewardCore

enum JevFamilyChecks {
    static func run() throws -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) {
            print("\(value ? "ok  " : "FAIL") \(name)")
            if !value { failures.append(name) }
        }
        func member(pid: Int32, bundle: String, name: String, memory: Double, accessory: Bool = false, foreground: Bool = false) -> ProcessViewModel {
            let snapshot = ProcessSnapshot(
                pid: pid, uid: 501, bundleID: bundle, processName: name, path: "/Applications/Browser.app",
                memoryFootprintMB: memory, cpuPercent: 0, isForeground: foreground,
                isAccessory: accessory, isRegularApp: !accessory, idleSeconds: 900, startUnix: 100
            )
            return ProcessViewModel(snapshot: snapshot, score: ReclaimScorer.score(snapshot: snapshot, workspace: nil), appPath: "/Applications/Browser.app")
        }
        let load = JevLoadState(memory_pressure: "warning", cpu_percent: 20, memory_used_ratio: 0.9, swap_used_mb: 300, memory_pressure_seconds: 25)
        for (bundle, helper) in [("com.google.Chrome", "com.google.Chrome.helper.renderer"), ("com.anysphere.sand", "com.anysphere.sand.electron-helper.Renderer")] {
            let root = member(pid: 101, bundle: bundle, name: "Browser", memory: 232)
            let renderer = member(pid: 102, bundle: helper, name: "Browser Helper (Renderer)", memory: 415, accessory: true)
            let group = ProcessGroupViewModel(key: bundle, members: [root, renderer])
            check("fixture has largest renderer", group.primary.snapshot.pid == 102)
            let candidate = JevHardGate.Candidate(group: group, favorites: [])
            check("family consult uses main identity", candidate.pid == 101 && candidate.bundleID == bundle)
            check("accessory helper does not hide regular main app", !candidate.isAccessory && candidate.isRegularApp)
            check("family with main app passes consultation gate", JevHardGate.isGrayZone(candidate))
            let gray = JevGrayZone.apps(groups: [group], favorites: [], windowOwnerPIDs: [])
            let selected = JevCandidateSelector.select(load: load, apps: gray)
            check("yellow sustained pressure selects family", selected.count == 1 && selected.first?.bundle_id == bundle && selected.first?.memory_mb == 647)
            let assessment = try JevAssessmentQuestions.parse(JevPipelineChecks.assessmentData(), apps: selected)
            let decision = try JevActionQuestions.parse(Data(#"{"app_0":{"type":"choice","choice":"quit","confidence":0.99}}"#.utf8), apps: selected, assessment: assessment)
            check("family decision and evidence use root key", decision.actions[bundle] == .quit && decision.evidence[bundle] != nil)
            let helperOnly = ProcessGroupViewModel(key: bundle, members: [renderer])
            check("isolated renderer remains protected", JevGrayZone.apps(groups: [helperOnly], favorites: [], windowOwnerPIDs: []).isEmpty)
            check("favorite family remains protected", JevGrayZone.apps(groups: [group], favorites: [bundle], windowOwnerPIDs: []).isEmpty)
            let front = member(pid: 101, bundle: bundle, name: "Browser", memory: 232, foreground: true)
            let frontGroup = ProcessGroupViewModel(key: bundle, members: [front, renderer])
            check("foreground family remains protected", JevGrayZone.apps(groups: [frontGroup], favorites: [], windowOwnerPIDs: []).isEmpty)
        }
        check("no gray apps explained", JevPipelineStatus.idle(load: load, grayAppCount: 0) == .noEligibleApps)
        check("resource thresholds explained", JevPipelineStatus.idle(load: load, grayAppCount: 2) == .noCandidates)
        var brief = load
        brief.memory_pressure_seconds = 10
        check("observation duration explained", JevPipelineStatus.idle(load: brief, grayAppCount: 2) == .observingLoad)
        do {
            _ = try JevAssessmentQuestions.parse(Data("{}".utf8), apps: [])
            check("parse error identifies question", false)
        } catch {
            check("parse error identifies question", error.localizedDescription.contains("memory_urgency"))
        }
        return failures
    }
}
