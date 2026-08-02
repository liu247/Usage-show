import Foundation

protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot
}
