// Open Adaptive Switch - key binding editor for one slot.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import SwiftUI

struct KeyPickerView: View {
    @EnvironmentObject var manager: SwitchManager
    @Environment(\.dismiss) private var dismiss

    let slot: Int

    @State private var modifier: UInt8 = 0
    @State private var keycode: UInt8 = 0x68
    @State private var useCustomCode = false
    @State private var customCodeText = ""

    private var binding: KeyBinding {
        KeyBinding(modifier: modifier, keycode: keycode)
    }

    private var customCodeValid: Bool {
        if !useCustomCode { return true }
        guard let v = Int(customCodeText), (0...255).contains(v) else { return false }
        return true
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Sends", value: binding.display)
                    .font(.body.weight(.medium))
            } footer: {
                Text("F13 through F24 are safe defaults: nothing else on an iPhone or iPad uses them, so each one registers as its own switch.")
            }

            Section("Key") {
                // Tag 255 is the "custom" sentinel. Safe because no key in
                // the common catalog uses code 255 (the HID keyboard page
                // tops out well below it); if that ever changes, pick a
                // different sentinel.
                Picker("Key", selection: Binding(
                    get: { useCustomCode ? UInt8(255) : keycode },
                    set: { newValue in
                        if newValue == 255 && !HIDKey.isCommon(255) {
                            useCustomCode = true
                            customCodeText = String(keycode)
                        } else {
                            useCustomCode = false
                            keycode = newValue
                        }
                    }
                )) {
                    ForEach(HIDKey.common, id: \.code) { entry in
                        Text(entry.name).tag(entry.code)
                    }
                    Text("Custom key code...").tag(UInt8(255))
                }
                .pickerStyle(.navigationLink)

                if useCustomCode {
                    HStack {
                        Text("Key code (0 to 255)")
                        Spacer()
                        TextField("104", text: $customCodeText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 70, maxWidth: 120)
                            .onChange(of: customCodeText) {
                                if let v = Int(customCodeText), (0...255).contains(v) {
                                    keycode = UInt8(v)
                                }
                            }
                    }
                    if !customCodeValid {
                        Text("Enter a whole number from 0 to 255.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Held together with") {
                ForEach(HIDModifier.all) { m in
                    Toggle(m.name, isOn: Binding(
                        get: { modifier & m.bit != 0 },
                        set: { on in
                            if on { modifier |= m.bit } else { modifier &= ~m.bit }
                        }
                    ))
                }
            }
        }
        .navigationTitle(SwitchMode.slotLabel(slot, mode: manager.config.mode))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    manager.save(binding: binding, slot: slot)
                    dismiss()
                }
                .disabled(!customCodeValid)
            }
        }
        .onAppear {
            let current = manager.config.bindings[slot]
            modifier = current.modifier
            keycode = current.keycode
            useCustomCode = !HIDKey.isCommon(current.keycode)
            if useCustomCode { customCodeText = String(current.keycode) }
        }
    }
}
