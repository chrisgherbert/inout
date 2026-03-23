import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum URLDownloadOptionsLayout {
    case sheet
    case inline
}

private struct URLDownloadOptionsDisclosureHeader: View {
    @Binding var isExpanded: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
            Text("More Options")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

private struct URLDownloadPresetOptionRow: View {
    let preset: URLDownloadPreset
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(preset.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if let badgeText = preset.badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(preset.badgeTint.opacity(0.16), in: Capsule())
                        .foregroundStyle(preset.badgeTint)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct URLDownloadAdvancedOptionsView: View {
    @Binding var preset: URLDownloadPreset
    @Binding var saveMode: URLDownloadSaveLocationMode
    @Binding var customFolderPath: String
    @Binding var authenticationMode: URLDownloadAuthenticationMode
    @Binding var browserCookiesSource: URLDownloadBrowserCookiesSource
    @Binding var showAdvancedOptions: Bool

    let layout: URLDownloadOptionsLayout
    let onChooseCustomFolder: () -> Void

    private var disclosureHeight: CGFloat {
        layout == .sheet ? 40 : 36
    }

    private var sectionTopPadding: CGFloat {
        layout == .sheet ? 8 : 4
    }

    private var sectionLeadingPadding: CGFloat {
        14
    }

    @ViewBuilder
    private var qualitySection: some View {
        Text("Quality")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(URLDownloadPreset.allCases) { option in
                URLDownloadPresetOptionRow(preset: option, isSelected: preset == option) {
                    preset = option
                }
            }
        }

        Text(preset.helpText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var saveLocationSection: some View {
        Text("Save Location")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        if layout == .sheet {
            Picker("Save location", selection: $saveMode) {
                ForEach(URLDownloadSaveLocationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            if saveMode == .customFolder {
                customFolderRow(expands: false)
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                Picker("Save location", selection: $saveMode) {
                    ForEach(URLDownloadSaveLocationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 190, alignment: .leading)

                if saveMode == .customFolder {
                    customFolderRow(expands: true)
                }
            }
        }
    }

    @ViewBuilder
    private func customFolderRow(expands: Bool) -> some View {
        HStack(spacing: 8) {
            Text(customFolderPath.isEmpty ? "No custom folder selected" : customFolderPath)
                .font(.caption)
                .foregroundStyle(customFolderPath.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…", action: onChooseCustomFolder)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder
    private var authenticationSection: some View {
        Text("Authentication")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        if layout == .sheet {
            Picker("Authentication", selection: $authenticationMode) {
                ForEach(URLDownloadAuthenticationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            if authenticationMode == .browserCookies {
                Picker("Browser", selection: $browserCookiesSource) {
                    ForEach(URLDownloadBrowserCookiesSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                Picker("Authentication", selection: $authenticationMode) {
                    ForEach(URLDownloadAuthenticationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 190, alignment: .leading)

                if authenticationMode == .browserCookies {
                    Picker("Browser", selection: $browserCookiesSource) {
                        ForEach(URLDownloadBrowserCookiesSource.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 140, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }

        if let helpText = authenticationMode.helpText {
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            URLDownloadOptionsDisclosureHeader(isExpanded: $showAdvancedOptions, height: disclosureHeight)

            if showAdvancedOptions {
                VStack(alignment: .leading, spacing: 10) {
                    qualitySection

                    Spacer()
                        .frame(height: layout == .sheet ? 8 : 6)

                    saveLocationSection

                    Spacer()
                        .frame(height: layout == .sheet ? 8 : 6)

                    authenticationSection
                }
                .padding(.top, sectionTopPadding)
                .padding(.leading, sectionLeadingPadding)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showAdvancedOptions)
        .animation(.easeInOut(duration: 0.15), value: preset)
        .animation(.easeInOut(duration: 0.15), value: saveMode)
        .animation(.easeInOut(duration: 0.15), value: authenticationMode)
    }
}

struct ClipEmptySourceView: View {
    @Binding var emptyStateURLText: String
    @Binding var isDropTargeted: Bool
    @Binding var urlDownloadPreset: URLDownloadPreset
    @Binding var urlDownloadSaveMode: URLDownloadSaveLocationMode
    @Binding var customURLDownloadDirectoryPath: String
    @Binding var urlDownloadAuthenticationMode: URLDownloadAuthenticationMode
    @Binding var urlDownloadBrowserCookiesSource: URLDownloadBrowserCookiesSource

    let reduceTransparency: Bool
    let isURLDownloadEnabled: Bool
    let onChooseFile: () -> Void
    let onDownload: () -> Void
    let onChooseCustomFolder: () -> Void
    let onHandleDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            Text("Open Media")
                .font(.system(size: 32, weight: .semibold))

            VStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 58, weight: .regular))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

                Text("Drag a video or audio file here")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)

                Button("Choose File…", action: onChooseFile)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            .background(
                RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                    .fill(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                    .stroke(
                        isDropTargeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.24),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2.4 : 1.6, dash: [8, 6])
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                    .stroke(isDropTargeted ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 6)
            )
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: onHandleDrop)

            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 1)
                    .frame(maxWidth: 260)
                Text("or")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 1)
                    .frame(maxWidth: 260)
            }
            .padding(.vertical, 2)

            InitialURLDownloadControl(
                text: $emptyStateURLText,
                preset: $urlDownloadPreset,
                saveMode: $urlDownloadSaveMode,
                customFolderPath: $customURLDownloadDirectoryPath,
                authenticationMode: $urlDownloadAuthenticationMode,
                browserCookiesSource: $urlDownloadBrowserCookiesSource,
                isEnabled: isURLDownloadEnabled,
                reduceTransparency: reduceTransparency,
                onDownload: onDownload,
                onChooseCustomFolder: onChooseCustomFolder
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 980)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ClipURLImportSheetView: View {
    @Binding var importURLText: String
    @Binding var importURLPreset: URLDownloadPreset
    @Binding var importURLSaveMode: URLDownloadSaveLocationMode
    @Binding var importCustomFolderPath: String
    @Binding var importURLAuthenticationMode: URLDownloadAuthenticationMode
    @Binding var importURLBrowserCookiesSource: URLDownloadBrowserCookiesSource
    @Binding var showAdvancedOptions: Bool

    let clipboardURLString: String?
    let onCancel: () -> Void
    let onSubmit: () -> Void
    let onChooseCustomFolder: () -> Void

    @FocusState.Binding var isURLFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from URL")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text("URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("https://example.com/video", text: $importURLText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isURLFieldFocused)
                        .onSubmit(onSubmit)
                    if let clipboardURLString {
                        Button("Paste URL") {
                            importURLText = clipboardURLString
                            isURLFieldFocused = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            URLDownloadAdvancedOptionsView(
                preset: $importURLPreset,
                saveMode: $importURLSaveMode,
                customFolderPath: $importCustomFolderPath,
                authenticationMode: $importURLAuthenticationMode,
                browserCookiesSource: $importURLBrowserCookiesSource,
                showAdvancedOptions: $showAdvancedOptions,
                layout: .sheet,
                onChooseCustomFolder: onChooseCustomFolder
            )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                Button("Download", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            DispatchQueue.main.async {
                isURLFieldFocused = true
            }
        }
    }
}

private struct InitialURLDownloadControl: View {
    @Binding var text: String
    @Binding var preset: URLDownloadPreset
    @Binding var saveMode: URLDownloadSaveLocationMode
    @Binding var customFolderPath: String
    @Binding var authenticationMode: URLDownloadAuthenticationMode
    @Binding var browserCookiesSource: URLDownloadBrowserCookiesSource
    let isEnabled: Bool
    let reduceTransparency: Bool
    let onDownload: () -> Void
    let onChooseCustomFolder: () -> Void

    @State private var showAdvancedOptions = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var canSubmit: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("Download from URL")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField("https://…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .regular))
                        .focused($isFocused)
                        .onSubmit {
                            if canSubmit {
                                onDownload()
                            }
                        }
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(maxHeight: .infinity, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isEnabled else { return }
                    isFocused = true
                }

                Button(action: onDownload) {
                    Text("Download")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSubmit ? Color.white : Color.white.opacity(0.72))
                        .frame(minWidth: 120)
                        .frame(minHeight: 56)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: UIRadius.medium,
                        topTrailingRadius: UIRadius.medium,
                        style: .continuous
                    )
                    .fill(canSubmit ? Color.accentColor : Color.white.opacity(colorScheme == .dark ? 0.10 : 0.08))
                )
                .disabled(!canSubmit)
            }
            .frame(maxWidth: 920)
            .frame(height: 56)
            .background(
                adaptiveContainerFill(
                    material: .thinMaterial,
                    fallback: Color(nsColor: .controlBackgroundColor),
                    reduceTransparency: reduceTransparency
                ),
                in: RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                    .stroke(
                        isFocused ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.10),
                        lineWidth: isFocused ? 1.2 : 0.8
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.72)

            if isEnabled {
                URLDownloadAdvancedOptionsView(
                    preset: $preset,
                    saveMode: $saveMode,
                    customFolderPath: $customFolderPath,
                    authenticationMode: $authenticationMode,
                    browserCookiesSource: $browserCookiesSource,
                    showAdvancedOptions: $showAdvancedOptions,
                    layout: .inline,
                    onChooseCustomFolder: onChooseCustomFolder
                )
                .frame(maxWidth: 920, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.14), value: canSubmit)
    }
}
