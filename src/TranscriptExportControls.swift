import SwiftUI
import AppKit

struct TranscriptExportControls: View {
    @Binding var selectedFormat: TranscriptExportFormat
    @Binding var selectedLayout: TranscriptExportLayout
    @Binding var selectedTimecodeStyle: TranscriptExportTimecodeStyle
    let isOptionKeyPressed: Bool
    let exportTranscript: (_ quickExport: Bool) -> Void
    @State private var showsPopover = false

    private func optionRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                exportTranscript(true)
            } else {
                showsPopover.toggle()
            }
        } label: {
            Label(
                isOptionKeyPressed ? "Quick Export" : "Export",
                systemImage: isOptionKeyPressed ? "bolt.fill" : "square.and.arrow.up"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Export Transcript")
                    .font(.headline)

                VStack(spacing: 10) {
                    optionRow("Format") {
                        Picker("Format", selection: $selectedFormat) {
                            ForEach(TranscriptExportFormat.allCases) { format in
                                Text(format.pickerTitle)
                                    .tag(format)
                            }
                        }
                        .labelsHidden()
                    }

                    if selectedFormat.supportsReadableLayout {
                        optionRow("Layout") {
                            Picker("Layout", selection: $selectedLayout) {
                                ForEach(TranscriptExportLayout.allCases) { layout in
                                    Text(layout.title)
                                        .tag(layout)
                                }
                            }
                            .labelsHidden()
                        }

                        optionRow("Timecodes") {
                            Picker("Timecodes", selection: $selectedTimecodeStyle) {
                                ForEach(TranscriptExportTimecodeStyle.allCases) { style in
                                    Text(style.title)
                                        .tag(style)
                                }
                            }
                            .labelsHidden()
                            .disabled(selectedLayout == .continuousText)
                        }
                    }
                }
                .controlSize(.small)

                if selectedFormat.supportsReadableLayout,
                   selectedLayout == .continuousText {
                    Text("Continuous text does not include timecodes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(selectedFormat.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack {
                    Spacer()
                    Button(isOptionKeyPressed ? "Quick Export Transcript" : "Export Transcript…") {
                        let quickExport = NSEvent.modifierFlags.contains(.option)
                        showsPopover = false
                        DispatchQueue.main.async {
                            exportTranscript(quickExport)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
        .help(
            isOptionKeyPressed
                ? "Quick Export Transcript (no save dialog)"
                : "Choose a format and export the transcript. Option-click for Quick Export."
        )
    }
}
