import SwiftUI

/// iOS 16 兼容的空状态视图（替代 iOS 17 的 ContentUnavailableView）
struct EmptyState: View {
    let title: String
    let systemImage: String
    var description: String? = nil

    /// 可选的主动作按钮（「去导入」之类），老调用点不传也不受影响
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.6))
                .frame(width: 84, height: 84)
                .background(Theme.accent.opacity(0.10), in: Circle())
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
            }
            if let actionTitle, let action {
                Button {
                    withAnimation(HMD.Motion.fast) { action() }
                } label: {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
