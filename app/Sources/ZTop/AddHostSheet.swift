// SPDX-License-Identifier: MIT OR Apache-2.0
import SwiftUI
import ZTopKit

/// Keeps autocapitalization off where the platform has it: pairing
/// codes and pins are lowercase (the agent's alphabet is
/// `abcdefghjkmnpqrstuvwxyz23456789`), so forced capitals would break
/// the exact match.
extension View {
    @ViewBuilder
    func codeField() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

/// The add-host form: address, optional pin, optional immediate pairing.
struct AddHostSheet: View {
    let onAdd: (String, String, UInt16, String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = "127.0.0.1"
    @State private var portText = "7100"
    @State private var pin = ""
    @State private var code = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name", text: $name, prompt: Text("e.g. workstation"))
                    TextField("Address", text: $host, prompt: Text("127.0.0.1"))
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText, prompt: Text("7100"))
                }
                Section {
                    TextField("SHA256 pin (optional)", text: $pin, prompt: Text("SHA256:…"))
                        .codeField()
                        .autocorrectionDisabled()
                } header: {
                    Text("TLS")
                } footer: {
                    Text("Paste the SHA256 pin the agent prints with --tls. Leave empty for a plain loopback agent.")
                }
                Section {
                    TextField("Pairing code (optional)", text: $code)
                        .codeField()
                        .autocorrectionDisabled()
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Run `ztop agent --pair` and enter the code to pair right away; you can also pair later from the host card.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Add Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Add") {
                            working = true
                            Task {
                                do {
                                    try await add()
                                    dismiss()
                                } catch {
                                    self.error = error.localizedDescription
                                }
                                working = false
                            }
                        }
                        .disabled(!valid)
                    }
                }
            }
        }
    }

    private var port: UInt16? {
        UInt16(portText.trimmingCharacters(in: .whitespaces))
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && port != nil
    }

    private func add() async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard let parsedPort = port else {
            throw AgentError.badAnswer("the port must be a number between 1 and 65535")
        }
        try await onAdd(trimmedName, trimmedHost, parsedPort, pin.trimmingCharacters(in: .whitespaces), code.trimmingCharacters(in: .whitespaces))
    }
}

#Preview {
    AddHostSheet { _, _, _, _, _ in }
}
