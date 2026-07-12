// Open Adaptive Switch - inline editor for one button action.
//
// Shows the key choice and its modifiers together, and saves the moment
// something changes (like the rest of the settings). Uses menu-style
// pickers, which reliably propagate a custom selection binding - the
// navigation-style picker this replaced did not, which is why key
// changes appeared to do nothing.
//
// BindingEditor edits any KeyBinding through a binding, so the same rows
// serve the connected-switch screen, profiles, and the default setup.
// SlotEditor wraps it for the connected switch, writing over BLE.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

struct BindingEditor: View {
    let label: String
    @Binding var binding: KeyBinding

    @State private var useCustom = false
    @State private var customText = ""
    // What this editor last wrote; an outside change (applying a profile,
    // a factory reset) makes the binding differ and triggers a re-seed.
    @State private var lastWritten: KeyBinding?

    var body: some View {
        Picker(label, selection: keySelection) {
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
        .onChange(of: binding) {
            if binding != lastWritten { seed() }
        }

        if useCustom {
            HStack {
                Text("Key code (0 to 255)")
                Spacer()
                TextField("30", text: $customText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Key code")
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
        // Keep the menu open so several modifiers can be toggled at once.
        .menuActionDismissBehavior(.disabled)
    }

    // Selection is the keycode, with 255 standing in for "custom".
    private var keySelection: Binding<UInt8> {
        Binding(
            get: { useCustom ? 255 : binding.keycode },
            set: { value in
                if value == 255 {
                    useCustom = true
                    if customText.isEmpty { customText = String(binding.keycode) }
                } else {
                    useCustom = false
                    write(keycode: value)
                }
            })
    }

    private func modifierBinding(_ bit: UInt8) -> Binding<Bool> {
        Binding(
            get: { binding.modifier & bit != 0 },
            set: { on in
                var m = binding.modifier
                if on { m |= bit } else { m &= ~bit }
                write(modifier: m)
            })
    }

    private var modifierSummary: String {
        let names = HIDModifier.all.filter { binding.modifier & $0.bit != 0 }.map { $0.name }
        return names.isEmpty ? "None" : names.joined(separator: " + ")
    }

    private func commitCustom() {
        guard useCustom, let v = Int(customText), (0...255).contains(v) else { return }
        write(keycode: UInt8(v))
    }

    private func write(keycode: UInt8? = nil, modifier: UInt8? = nil) {
        let next = KeyBinding(modifier: modifier ?? binding.modifier,
                              keycode: keycode ?? binding.keycode)
        lastWritten = next
        binding = next
    }

    private func seed() {
        useCustom = !HIDKey.isKnown(binding.keycode)
        customText = useCustom ? String(binding.keycode) : ""
        lastWritten = binding
    }
}

// The connected switch's editor: reads from the live config and saves
// each change over BLE right away.
struct SlotEditor: View {
    @EnvironmentObject var manager: SwitchManager
    let slot: Int

    var body: some View {
        BindingEditor(
            label: SwitchMode.slotLabel(slot, mode: manager.config.mode),
            binding: Binding(
                get: { manager.config.bindings[slot] },
                set: { manager.save(binding: $0, slot: slot) }
            ))
    }
}
