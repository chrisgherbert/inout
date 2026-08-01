import SwiftUI

struct TranscriptExportControls: View {
    @Binding var selectedFormat: TranscriptExportFormat
    @Binding var selectedLayout: TranscriptExportLayout
    @Binding var selectedTimecodeStyle: TranscriptExportTimecodeStyle
    let exportTranscript: () -> Void
    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Export Transcript")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Format")
                            .foregroundStyle(.secondary)
                        Picker("Format", selection: $selectedFormat) {
                            ForEach(TranscriptExportFormat.allCases) { format in
                                Text(format.pickerTitle)
                                    .tag(format)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    if selectedFormat.supportsReadableLayout {
                        GridRow {
                            Text("Layout")
                                .foregroundStyle(.secondary)
                            Picker("Layout", selection: $selectedLayout) {
                                ForEach(TranscriptExportLayout.allCases) { layout in
                                    Text(layout.title)
                                        .tag(layout)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }

                        GridRow {
                            Text("Timecodes")
                                .foregroundStyle(.secondary)
                            Picker("Timecodes", selection: $selectedTimecodeStyle) {
                                ForEach(TranscriptExportTimecodeStyle.allCases) { style in
                                    Text(style.title)
                                        .tag(style)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
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
                    Button("Export Transcript…") {
                        showsPopover = false
                        DispatchQueue.main.async {
                            exportTranscript()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
        .help("Choose a format and export the transcript")
    }
}
