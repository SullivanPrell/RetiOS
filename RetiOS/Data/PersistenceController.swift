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
            // A crash-on-launch here (e.g. an on-disk store left incompatible by
            // a schema change) leaves the app permanently unlaunchable with no
            // recovery. Fall back to an in-memory store so the app still opens;
            // history won't persist this session, but the user isn't locked out.
            print("PersistenceController: on-disk ModelContainer failed (\(error)); falling back to in-memory.")
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                // In-memory can't realistically fail; if it does the process
                // genuinely cannot run, so crashing is the honest outcome.
                fatalError("Failed to create in-memory ModelContainer: \(error)")
            }
        }
    }
}
