import SwiftUI

enum WidgetCodeTab { case html, css }

struct WidgetStudio: View {
    @ObservedObject var widgets: DesktopWidgets
    @State private var draft = CustomWidgetPackage.starter
    @State private var editorTab: WidgetCodeTab = .html
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: WidgetText.eyebrow.localized())
                        Text(WidgetText.studio.localized()).font(
                            .system(size: 29, weight: .semibold, design: .rounded))
                        Text(WidgetText.subtitle.localized()).foregroundStyle(
                            .secondary)
                    }
                    Spacer()
                    Button(
                        widgets.editing
                            ? ProductText.widgetsFinish.localized()
                            : ProductText.widgetsEdit.localized()
                    ) {
                        widgets.setEditing(!widgets.editing)
                    }.buttonStyle(VioletButtonStyle())
                }
                HStack {
                    Text(
                        WidgetText.movementHint.format(ProductText.widgetsFinish.localized())
                    ).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(ProductText.allDisplays.localized(), isOn: $widgets.settings.allDisplays)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 400))], spacing: 14) {
                    ForEach(WidgetKind.allCases) { kind in independentCard(kind) }
                }
                HStack {
                    Text(WidgetText.samplingHint.localized()).font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(WidgetText.resetLayout.localized()) { widgets.resetLayout() }
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(WidgetText.buildOwn.localized()).font(.headline)
                            Text(WidgetText.buildHint.localized())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(WidgetText.importJSON.localized()) {
                            if let imported = widgets.importCustom() { draft = imported }
                        }
                        Button(WidgetText.exportJSON.localized()) { widgets.exportCustom(draft) }
                    }
                    HStack {
                        TextField(WidgetText.namePlaceholder.localized(), text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                        Text(EditorText.height.localized()).foregroundStyle(.secondary)
                        TextField(
                            EditorText.height.localized(), value: $draft.height, format: .number
                        ).frame(width: 65)
                            .textFieldStyle(.roundedBorder)
                        Text("pt").foregroundStyle(.secondary)
                    }
                    Picker(WidgetText.code.localized(), selection: $editorTab) {
                        Text("HTML").tag(WidgetCodeTab.html)
                        Text("CSS").tag(WidgetCodeTab.css)
                    }.pickerStyle(.segmented).frame(width: 200)
                    TextEditor(text: editorTab == .html ? $draft.html : $draft.css)
                        .font(.system(size: 12, design: .monospaced)).scrollContentBackground(
                            .hidden
                        )
                        .padding(10).frame(height: 260).background(
                            .black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    Text(
                        WidgetText.codeHint.localized()
                    )
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    if let error = widgets.error {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack {
                        Button(WidgetText.loadStarter.localized()) { draft = .starter }
                        Text(
                            draft == widgets.custom
                                ? WidgetText.saved.localized() : WidgetText.unapplied.localized()
                        ).font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(WidgetText.applyCode.localized()) {
                            widgets.applyCustom(draft)
                            if widgets.error == nil { widgets.customEnabled = true }
                        }.buttonStyle(VioletButtonStyle())
                    }
                }.padding(20).background(
                    WupsyTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                Text(
                    WidgetText.readingsHint.localized()
                ).font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }.background(WupsyTheme.background).onAppear { draft = widgets.custom }
    }
    private func independentCard(_ kind: WidgetKind) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(kind.title, systemImage: kind.icon).font(.headline).foregroundStyle(
                    WupsyTheme.lavender)
                Spacer()
                Toggle(
                    kind.title,
                    isOn: Binding(
                        get: { widgets.enabled(kind) }, set: { widgets.setEnabled(kind, $0) })
                ).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if kind == .custom {
                VStack(spacing: 8) {
                    Image(systemName: "curlybraces").font(.title)
                    Text(widgets.custom.name).font(.caption)
                }.frame(maxWidth: .infinity).frame(height: 90).foregroundStyle(.secondary)
            } else {
                SingleWidgetFace(readings: widgets.readings, kind: kind, scale: 0.75).frame(
                    maxWidth: .infinity
                ).frame(height: 90)
            }
            HStack {
                Text(WidgetText.size.localized()).font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { widgets.scale(kind) }, set: { widgets.setScale(kind, $0) }),
                    in: 0.6...2.5
                ).accessibilityLabel(WidgetText.sizeAX.format(kind.title))
                Text(WidgetValues.percent(widgets.scale(kind) * 100, digits: 0)).font(
                    .caption.monospacedDigit()
                ).fixedSize(horizontal: true, vertical: false)
            }
        }.padding(16).background(WupsyTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(
                    widgets.enabled(kind) ? WupsyTheme.accent.opacity(0.4) : WupsyTheme.border))
    }

}
