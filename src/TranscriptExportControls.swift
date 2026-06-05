import SwiftUI

struct TranscriptExportControls: View {
    @Binding var selectedFormat: TranscriptExportFormat
    let exportTranscript: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("Export…") {
                exportTranscript()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help(selectedFormat.helpText)

            Picker("Transcript format", selection: $selectedFormat) {
                ForEach(TranscriptExportFormat.allCases) { format in
                    Text(format.pickerTitle)
                        .tag(format)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 118)
            .help(selectedFormat.helpText)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
