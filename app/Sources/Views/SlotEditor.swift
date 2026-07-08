// Open Adaptive Switch - inline editor for one button action.
//
// Shows the key choice and its modifiers together, and saves the moment
// something changes (like the rest of the settings). Uses menu-style
// pickers, which reliably propagate a custom selection binding - the
// navigation-style picker this replaced did not, which is why key
// changes appeared to do nothing.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

struct SlotEditor: View {
    @EnvironmentObject var manager: SwitchManager
    let slot: Int

    @State private var keycode: UInt8 = 0x68
    @State private var modifier: UInt8 = 0
    @State private var useCustom = false
    @State private var customText = ""

    var body: some View {
        Picker(SwitchMode.slotLabel(slot, mode: manager.config.mode), selection: keySelection) {
            ForEach(HIDKey.groups) { group in
                Section(group.name) {
                    ForEach(group.keys, id: \.code) { k in
                        Text(k.name).tag(k.code)
                    }
                }
            }
            Text("Custom code").tag(UInt8(255))
        }
        .pickerStyle(.menu)
        .onAppear(perform: seed)

        if useCustom {
            HStack {
                Text("Key code (0 to 255)")
                Spacer()
                TextField("30", text: $customText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 70, maxWidth: 120)
                    .onChange(of: customText) { commitCustom() }
            }
        }

        Menu {
            ForEach(HIDModifier.all) { m in
                Toggle(m.name, isOn: modifierBinding(m.bit))
            }
        } label: {
            HStack {
                Text("Hold with")
                Spacer()
                Text(modifierSummary).foregroundStyle(.secondary)
            }
        }
    }

    // Selection is the keycode, with 255 standing in for "custom".
    private var keySelection: Binding<UInt8> {
        Binding(
            get: { useCustom ? 255 : keycode },
            set: { value in
                if value == 255 {
                    useCustom = true
                    if customText.isEmpty { customText = String(keycode) }
                } else {
                    useCustom = false
                    keycode = value
                    saveNow()
                }
            })
    }

    private func modifierBinding(_ bit: UInt8) -> Binding<Bool> {
        Binding(
            get: { modifier & bit != 0 },
            set: { on in
                if on { modifier |= bit } else { modifier &= ~bit }
                saveNow()
            })
    }

    private var modifierSummary: String {
        let names = HIDModifier.all.filter { modifier & $0.bit != 0 }.map { $0.name }
        return names.isEmpty ? "None" : names.joined(separator: " + ")
    }

    private func commitCustom() {
        guard useCustom, let v = Int(customText), (0...255).contains(v) else { return }
        keycode = UInt8(v)
        saveNow()
    }

    private func saveNow() {
        manager.save(binding: KeyBinding(modifier: modifier, keycode: keycode), slot: slot)
    }

    private func seed() {
        let b = manager.config.bindings[slot]
        modifier = b.modifier
        keycode = b.keycode
        useCustom = !HIDKey.isKnown(b.keycode)
        customText = useCustom ? String(b.keycode) : ""
    }
}
