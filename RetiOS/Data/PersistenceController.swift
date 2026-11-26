//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import OSLog
import SwiftData

/// The store's first versioned schema, identical to the unversioned one earlier builds wrote.
enum RetiOSSchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
  static var models: [any PersistentModel.Type] {
    [
      MessageEntity.self, PeerEntity.self, NomadNodeEntity.self, ChannelEntity.self,
      ChannelMessageEntity.self,
    ]
  }
}

/// Add a schema version and a stage here before changing any model.
enum RetiOSMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [RetiOSSchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}

enum PersistenceController {
  private static let log = Logger(subsystem: "dev.sprell.retios", category: "Persistence")

  /// The app's store, and whether it fell back to memory because the on-disk store failed.
  ///
  /// `url` is the store file; `nil` is the default on-disk store.
  static func makeContainer(url: URL? = nil) -> (container: ModelContainer, fellBack: Bool) {
    let schema = Schema(versionedSchema: RetiOSSchemaV1.self)
    let config =
      url.map { ModelConfiguration(schema: schema, url: $0) }
      ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    do {
      let container = try ModelContainer(
        for: schema, migrationPlan: RetiOSMigrationPlan.self, configurations: [config])
      return (container, false)
    } catch {
      // Crashing here would leave the app unlaunchable, so open an in-memory store and tell
      // the user. The on-disk store stays untouched for recovery.
      log.error("On-disk store failed to open, using memory: \(String(describing: error))")
      let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      do {
        return (try ModelContainer(for: schema, configurations: [memoryConfig]), true)
      } catch {
        // In-memory can't realistically fail; if it does the process
        // genuinely cannot run, so crashing is the honest outcome.
        fatalError("Failed to create in-memory ModelContainer: \(error)")
      }
    }
  }
}
