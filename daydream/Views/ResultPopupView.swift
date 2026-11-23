import SwiftUI

struct ResultPopupView: View {
    private let bodyMaxHeight: CGFloat = 320
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 8
    private let footerVerticalPadding: CGFloat = 8
    private let titlebarTopInset: CGFloat = 8

    var state: ResultPopupState
    var onApply: () -> Void
    var onClose: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                    .frame(height: verticalPadding + titlebarTopInset)

                ScrollView {
                    if state.isStreaming {
                        VStack(alignment: .leading, spacing: 12) {
                            if state.result.output.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text(state.statusMessage)
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            } else {
                                Text(state.result.output)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.system(size: 12))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    } else {
                        MarkdownView(text: state.result.output)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                }
                .frame(maxHeight: bodyMaxHeight)
                .liquidGlassCard(cornerRadius: 10)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 6)

                HStack {
                    Spacer()

                    Text(headerLine)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, horizontalPadding + 4)
                .padding(.bottom, 10)

                Divider()

                HStack(spacing: 10) {
                    Label("AI Commands", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        onClose()
                    } label: {
                        shortcutButtonLabel(title: "Close", shortcut: "esc", emphasized: false)
                    }
                    .softSecondaryLiquidGlassButton()

                    Text("|")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Button {
                        onApply()
                    } label: {
                        shortcutButtonLabel(title: "Apply", shortcut: "↵", emphasized: true)
                    }
                    .softPrimaryLiquidGlassButton()
                    .disabled(!state.canApply)
                    .help("Replace selection. Copies if replacement is unavailable.")
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, footerVerticalPadding)
            }
        }
        .frame(width: 640, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.clear)
    }

    private var headerLine: String {
        "\(state.result.model) • \(state.result.target.displayName)"
    }

    private func shortcutButtonLabel(title: String, shortcut: String, emphasized: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: emphasized ? .semibold : .medium))
                .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

            Text(shortcut)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(emphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

}
