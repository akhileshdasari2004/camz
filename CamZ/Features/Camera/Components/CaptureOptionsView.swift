import SwiftUI

/// Capture options: the save format, the bracketed modes and the grid. One-tap capture stays the default for each.
struct CaptureOptionsView: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Save as", selection: $model.captureFormat) {
                        ForEach(CaptureFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    if model.captureFormat != .processed {
                        Toggle("Also keep a processed photo", isOn: $model.alsoSavesProcessed)
                    }
                    if let note = model.formatNote() {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Format")
                } footer: {
                    Text("RAW keeps the sensor data for editing, so the files are larger. When both are kept, Photos stores the RAW file beside the processed photo.")
                }

                Section {
                    Toggle("HDR for high-contrast scenes", isOn: $model.isHDREnabled)
                    Toggle("Night burst in low light", isOn: $model.isNightModeEnabled)
                } header: {
                    Text("Exposure")
                } footer: {
                    Text("These take several photos, so they are slower. When a scene does not need them, one photo is taken and the reason is shown.")
                }

                Section {
                    Toggle("Grid", isOn: $model.showGrid)
                }
            }
            .navigationTitle("Capture options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.isOptionsPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
