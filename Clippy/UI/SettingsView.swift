import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var apiKey: String
    @Binding var elevenLabsKey: String
    @Binding var selectedService: AIServiceType

    @State private var tempGeminiKey: String = ""
    @State private var tempElevenLabsKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Gemini API Key")
                            .font(.headline)

                        SecureField("Enter Gemini API key...", text: $tempGeminiKey)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { tempGeminiKey = apiKey }

                        Text("Required for Gemini services. Keys are stored in Keychain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("ElevenLabs API Key")
                            .font(.headline)

                        SecureField("Enter ElevenLabs API key...", text: $tempElevenLabsKey)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { tempElevenLabsKey = elevenLabsKey }

                        Text("Required for voice input (Option+Space). Keys are stored in Keychain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    apiKey = tempGeminiKey
                    elevenLabsKey = tempElevenLabsKey
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 450, height: 350)
    }
}
