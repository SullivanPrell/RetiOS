import SwiftData

enum PersistenceController {
    static func makeContainer() -> ModelContainer {
        let schema = Schema([
            MessageEntity.self,
            PeerEntity.self,
            NomadNodeEntity.self,
            ChannelEntity.self,
            ChannelMessageEntity.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
