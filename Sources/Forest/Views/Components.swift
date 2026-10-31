import ForestCore
import SwiftUI

struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 20

    var body: some View {
        let color = Theme.avatarColor(for: email.isEmpty ? name : email)
        Circle()
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .overlay(
                Text(Format.initials(name))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .help("\(name) <\(email)>")
    }
}

struct RefBadge: View {
    let label: RefLabel
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .bold))
            Text(label.name)
                .font(.system(size: 10.5, weight: label.isHead ? .bold : .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(label.isHead ? Color.white : color)
        .background(
            Capsule().fill(label.isHead ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.14)))
        )
        .overlay(Capsule().strokeBorder(color.opacity(label.isHead ? 0 : 0.35), lineWidth: 0.5))
        .fixedSize()
    }

    private var icon: String {
        switch label.kind {
        case .localBranch: label.isHead ? "checkmark" : "arrow.triangle.branch"
        case .remoteBranch: "cloud.fill"
        case .tag: "tag.fill"
        case .stash: "tray.full.fill"
        }
    }
}

struct StatusIcon: View {
    let status: ChangeStatus

    var body: some View {
        Text(status.letter)
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.color(for: status).gradient))
            .help(status.rawValue.capitalized)
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct CountBadge: View {
    let count: Int
    var color: Color = .accentColor

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(color))
        }
    }
}

struct FilePathLabel: View {
    let change: FileChange

    var body: some View {
        HStack(spacing: 4) {
            Text(change.fileName)
                .lineLimit(1)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .font(.system(size: 12.5))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A borderless icon button that lights up on hover.
struct HoverButton: View {
    let systemImage: String
    var help: String = ""
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 22, height: 20)
                .foregroundStyle(hovering ? Color.primary : tint)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ClaudeMark: View {
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.claudeGradient))
    }
}

struct PulsingDot: View {
    var color: Color = .green
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(animate ? 2.2 : 1).opacity(animate ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

struct EmptyState: View {
    let title: String
    let systemImage: String
    var message: String = ""

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if !message.isEmpty { Text(message) }
        }
    }
}
