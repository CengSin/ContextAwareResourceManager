import Foundation

public enum DayPart: String, Sendable, CaseIterable, Identifiable {
    case night
    case morning
    case afternoon
    case evening

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .night: return "夜间"
        case .morning: return "上午"
        case .afternoon: return "下午"
        case .evening: return "晚上"
        }
    }

    public static func from(hour: Int) -> DayPart {
        switch hour {
        case 0..<6: return .night
        case 6..<12: return .morning
        case 12..<18: return .afternoon
        default: return .evening
        }
    }
}

public enum MarkovTimeScope: String, Sendable, Equatable {
    case hour
    case dayPart
    case allDay

    public var title: String {
        switch self {
        case .hour: return "当前小时"
        case .dayPart: return "当前时段"
        case .allDay: return "全天"
        }
    }
}

public struct WorkspaceTransition: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let fromWorkspaceID: UUID?
    public let toWorkspaceID: UUID?
    public let hourOfDay: Int
    public let weekday: Int
    public let timestamp: Date

    public init(
        id: Int64 = 0,
        fromWorkspaceID: UUID?,
        toWorkspaceID: UUID?,
        hourOfDay: Int,
        weekday: Int,
        timestamp: Date
    ) {
        self.id = id
        self.fromWorkspaceID = fromWorkspaceID
        self.toWorkspaceID = toWorkspaceID
        self.hourOfDay = hourOfDay
        self.weekday = weekday
        self.timestamp = timestamp
    }
}

public struct MarkovPrediction: Sendable, Equatable, Identifiable {
    public var id: String { workspaceID?.uuidString ?? "unclassified" }
    public let workspaceID: UUID?
    public let probability: Double
    public let count: Int

    public init(workspaceID: UUID?, probability: Double, count: Int) {
        self.workspaceID = workspaceID
        self.probability = probability
        self.count = count
    }
}

public struct MarkovForecast: Sendable, Equatable {
    public let fromWorkspaceID: UUID?
    public let scope: MarkovTimeScope
    public let sampleCount: Int
    public let predictions: [MarkovPrediction]

    public var isEmpty: Bool { sampleCount == 0 || predictions.isEmpty }

    public init(
        fromWorkspaceID: UUID?,
        scope: MarkovTimeScope,
        sampleCount: Int,
        predictions: [MarkovPrediction]
    ) {
        self.fromWorkspaceID = fromWorkspaceID
        self.scope = scope
        self.sampleCount = sampleCount
        self.predictions = predictions
    }

    public static let empty = MarkovForecast(
        fromWorkspaceID: nil,
        scope: .allDay,
        sampleCount: 0,
        predictions: []
    )
}

public struct WorkspaceForecast: Sendable, Equatable, Identifiable {
    public var id: String { workspaceID?.uuidString ?? "unclassified" }
    public let workspaceID: UUID?
    public let name: String
    public let probability: Double
    public let sampleCount: Int
    public let scope: MarkovTimeScope

    public init(
        workspaceID: UUID?,
        name: String,
        probability: Double,
        sampleCount: Int,
        scope: MarkovTimeScope
    ) {
        self.workspaceID = workspaceID
        self.name = name
        self.probability = probability
        self.sampleCount = sampleCount
        self.scope = scope
    }
}

public enum WorkspaceMarkov: Sendable {
    public static let smoothingAlpha = 1.0
    public static let minSamplesForNarrowScope = 3

    public static func shouldRecord(from: UUID?, to: UUID?) -> Bool {
        from != to
    }

    public static func hour(of date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date)
    }

    public static func weekday(of date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date)
    }

    /// Laplace-smoothed P(to | from, t). Narrows by hour, then day-part, then all-day.
    /// Destinations are other known workspaces plus unclassified (when `from` is classified).
    /// Returns empty when there are no observed switches from `from`.
    public static func forecast(
        from: UUID?,
        at: Date,
        transitions: [WorkspaceTransition],
        workspaceIDs: [UUID],
        calendar: Calendar = .current,
        alpha: Double = smoothingAlpha,
        minSamples: Int = minSamplesForNarrowScope
    ) -> MarkovForecast {
        let hour = Self.hour(of: at, calendar: calendar)
        let part = DayPart.from(hour: hour)
        let known = Set(workspaceIDs)
        let fromRows = transitions.filter { row in
            row.fromWorkspaceID == from
                && (row.toWorkspaceID == nil || known.contains(row.toWorkspaceID!))
                && row.toWorkspaceID != from
        }

        guard !fromRows.isEmpty else {
            return MarkovForecast(fromWorkspaceID: from, scope: .allDay, sampleCount: 0, predictions: [])
        }

        let hourRows = fromRows.filter { $0.hourOfDay == hour }
        let partRows = fromRows.filter { DayPart.from(hour: $0.hourOfDay) == part }
        let (rows, scope): ([WorkspaceTransition], MarkovTimeScope) = {
            if hourRows.count >= minSamples { return (hourRows, .hour) }
            if partRows.count >= minSamples { return (partRows, .dayPart) }
            return (fromRows, .allDay)
        }()

        var destinations: [UUID?] = workspaceIDs.filter { $0 != from }
        if from != nil {
            destinations.append(nil)
        }
        guard !destinations.isEmpty else {
            return MarkovForecast(fromWorkspaceID: from, scope: scope, sampleCount: rows.count, predictions: [])
        }

        let k = Double(destinations.count)
        let total = Double(rows.count)
        let predictions = destinations.map { dest -> MarkovPrediction in
            let count = rows.filter { $0.toWorkspaceID == dest }.count
            let probability = (Double(count) + alpha) / (total + alpha * k)
            return MarkovPrediction(workspaceID: dest, probability: probability, count: count)
        }
        .sorted {
            if $0.probability != $1.probability { return $0.probability > $1.probability }
            return ($0.workspaceID?.uuidString ?? "") < ($1.workspaceID?.uuidString ?? "")
        }

        return MarkovForecast(
            fromWorkspaceID: from,
            scope: scope,
            sampleCount: rows.count,
            predictions: predictions
        )
    }
}
