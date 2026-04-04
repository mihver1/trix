import Foundation

enum AdminWorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case registration
    case server
    case users
    case featureFlags
    case debugMetrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .registration:
            return "Registration"
        case .server:
            return "Server"
        case .users:
            return "Users"
        case .featureFlags:
            return "Feature flags"
        case .debugMetrics:
            return "Debug metrics"
        }
    }
}

struct AdminOverviewState: Equatable, Sendable {
    var clusterID: UUID
    var clusterDisplayName: String
    var response: AdminOverviewResponse
}
