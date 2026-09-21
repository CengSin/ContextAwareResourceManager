import Foundation

public struct PendingDecisionItem: Identifiable, Equatable {
    public var id: String { group.id + "-" + action.rawValue }
    public let group: ProcessGroupViewModel
    public let action: SuggestedAction
    public let evidence: JevDecisionEvidence

    public init(group: ProcessGroupViewModel, action: SuggestedAction, evidence: JevDecisionEvidence) {
        self.group = group
        self.action = action
        self.evidence = evidence
    }
}

public struct PendingDecisionBatch: Identifiable, Equatable {
    public let id: String
    public let items: [PendingDecisionItem]

    public init(id: String, items: [PendingDecisionItem]) {
        self.id = id
        self.items = items
    }
}
