import Foundation

enum AdminWorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case registration
    case server
    case users

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
        }
    }
}

struct AdminOverviewState: Equatable, Sendable {
    var clusterID: UUID
    var clusterDisplayName: String
    var response: AdminOverviewResponse
}
