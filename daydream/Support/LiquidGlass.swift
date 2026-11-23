import SwiftUI

extension View {
    func liquidGlassCard(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    func interactiveLiquidGlassCard(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func liquidGlassButton(prominent: Bool) -> some View {
        modifier(LiquidGlassButtonModifier(prominent: prominent))
    }

    func softPrimaryLiquidGlassButton() -> some View {
        modifier(SoftPrimaryLiquidGlassButtonModifier())
    }

    func softSecondaryLiquidGlassButton() -> some View {
        modifier(SoftSecondaryLiquidGlassButtonModifier())
    }
}

private struct LiquidGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        styled(content)
            .contentShape(.rect(cornerRadius: 8))
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .brightness(isHovered ? 0.018 : 0)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

private struct SoftPrimaryLiquidGlassButtonModifier: ViewModifier {
    @State private var isHovered = false
    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .contentShape(.rect(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(tintOpacity))
            }
            .foregroundStyle(.primary)
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
            )
    }

    private var tintOpacity: Double {
        if isPressed {
            return 0.12
        }
        if isHovered {
            return 0.08
        }
        return 0
    }
}

private struct SoftSecondaryLiquidGlassButtonModifier: ViewModifier {
    @State private var isHovered = false
    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .contentShape(.rect(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(tintOpacity))
            }
            .foregroundStyle(.primary)
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
            )
    }

    private var tintOpacity: Double {
        if isPressed {
            return 0.10
        }
        if isHovered {
            return 0.07
        }
        return 0
    }
}
