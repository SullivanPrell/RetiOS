//===----------------------------------------------------------------------===//
// Copyright (c) 2026 RetiOS contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import SwiftUI

/// The `[stamps]` section and `default_gravity` of a Python config file.
///
/// Also the LXMF delivery stamp value. A blank field keeps the default its placeholder shows.
struct StampSettingsView: View {
  @Environment(StackController.self) private var stack

  var body: some View {
    @Bindable var stack = stack
    rnsSettingsContainer {
      Section {
        Toggle("Enforce stamps", isOn: $stack.networkSettings.enforceStamps)
        Toggle("Stamp every link request", isOn: $stack.networkSettings.alwaysStampLRs)
      } footer: {
        Text(
          "Enforcing drops announces and path requests whose stamps fall short of the costs "
            + "below, and ignores link requests with insufficient stamps. The second switch "
            + "stamps link requests even to destinations that announce no cost.")
      }

      Section {
        field("Announces", $stack.networkSettings.destinationCost, default: "23.5")
        field("Path requests", $stack.networkSettings.prCost, default: "15.8")
        field("Link requests", $stack.networkSettings.lrCost, default: "12.5")
      } header: {
        Text("Cost Required of Others")
      } footer: {
        Text("Costs are capped at 100, and link requests at 40.")
      }

      Section("Value of This Device's Stamps") {
        field("Announces", $stack.networkSettings.destinationValue, default: "25")
        field("Path requests", $stack.networkSettings.prValue, default: "15.8")
        field("Messaging address", $stack.networkSettings.deliveryStampValue, default: "25")
      }

      Section {
        field("Link requests", $stack.networkSettings.lrStampTimeout, default: "15")
        field("Path requests", $stack.networkSettings.prStampTimeout, default: "15")
      } header: {
        Text("Stamp Timeouts (Seconds)")
      }

      Section {
        LabeledContent("Default gravity") {
          TextField(
            "Default gravity", value: $stack.networkSettings.defaultGravity, format: .number,
            prompt: Text("0")
          )
          .multilineTextAlignment(.trailing)
          #if os(iOS)
          .keyboardType(.numberPad)
          #endif
        }
      } header: {
        Text("Interfaces")
      } footer: {
        Text(
          "Gravity for interfaces that don't set their own. Changes on this screen take "
            + "effect the next time Reticulum starts.")
      }
    }
    .rnsScreenBackground()
    .navigationTitle("Stamps & Gravity")
    .rnsInlineNavigationTitle()
  }

  private func field(_ label: String, _ value: Binding<Double?>, default placeholder: String)
    -> some View
  {
    LabeledContent(label) {
      TextField(label, value: value, format: .number, prompt: Text(placeholder))
        .multilineTextAlignment(.trailing)
        #if os(iOS)
      .keyboardType(.decimalPad)
        #endif
    }
  }
}
