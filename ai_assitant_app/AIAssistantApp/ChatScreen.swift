import Observation
import SwiftUI

@MainActor
struct ChatScreen: View {
    private static let conversationBottomAnchor = "conversationBottomAnchor"

    let session: ChatSession

    var body: some View {
        @Bindable var session = self.session

        GeometryReader { geometry in
            let topHeight = geometry.size.height * 0.66
            let scrollSignature = Self.scrollSignature(for: session.messages)

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if session.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("开始一段对话")
                                        .font(.system(.title2, design: .rounded, weight: .bold))
                                    Text("试试输入“中国的首都是哪里”、“长城在北京吗”，或者直接问一题加减乘除。")
                                        .font(.system(.body, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(24)
                                .background(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .fill(Color.white.opacity(0.7))
                                )
                            }

                            ForEach(session.messages) { message in
                                MessageBubble(message: message)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(Self.conversationBottomAnchor)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    }
                    .frame(height: topHeight)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.95, green: 0.97, blue: 0.99),
                                Color(red: 0.91, green: 0.95, blue: 0.94),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .accessibilityIdentifier("conversationScrollView")
                    .onAppear {
                        Self.scrollToConversationBottom(using: proxy, animated: false)
                    }
                    .onChange(of: scrollSignature) { _, _ in
                        Self.scrollToConversationBottom(using: proxy, animated: false)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("和 AI 聊聊")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Color(red: 0.14, green: 0.24, blue: 0.23))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                QuickPromptButton(
                                    title: "中国的首都是哪里",
                                    identifier: "quickPromptCapital"
                                ) {
                                    session.draft = "中国的首都是哪里"
                                }

                                QuickPromptButton(
                                    title: "长城在北京吗",
                                    identifier: "quickPromptGreatWall"
                                ) {
                                    session.draft = "长城在北京吗"
                                }

                                QuickPromptButton(
                                    title: "背诵出师表",
                                    identifier: "quickPromptChuShiBiao"
                                ) {
                                    session.draft = "背诵出师表"
                                }
                            }
                        }

                        TextField("输入问题", text: $session.draft)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .rounded))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color(red: 0.69, green: 0.77, blue: 0.73), lineWidth: 1)
                            )
                            .accessibilityIdentifier("chatInputField")

                        HStack(spacing: 12) {
                            if session.isSending {
                                ProgressView()
                                    .tint(Color(red: 0.16, green: 0.43, blue: 0.40))
                                Text("AI 正在回复…")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("streamingStatusLabel")
                            } else {
                                Text("发送后会直接走 SDK 的 agent loop。")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("idleStatusLabel")
                            }

                            Spacer()

                            Button("发送") {
                                session.sendCurrentDraft()
                            }
                            .buttonStyle(.plain)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(red: 0.16, green: 0.43, blue: 0.40))
                            )
                            .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSending)
                            .opacity(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSending ? 0.45 : 1)
                            .accessibilityIdentifier("sendButton")
                        }

                        if let errorText = session.errorText {
                            Text(errorText)
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("errorLabel")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(Color(red: 0.99, green: 0.96, blue: 0.91))
                            .ignoresSafeArea(edges: .bottom)
                    )
                }
                .background(Color(red: 0.93, green: 0.95, blue: 0.93))
            }
        }
    }

    private static func scrollSignature(for messages: [ChatSession.MessageRow]) -> String {
        guard let lastMessage = messages.last else {
            return "empty"
        }

        return "\(messages.count)-\(lastMessage.id)-\(lastMessage.text.count)-\(lastMessage.isStreaming)"
    }

    private static func scrollToConversationBottom(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.animation = animated ? .easeOut(duration: 0.2) : nil

            withTransaction(transaction) {
                proxy.scrollTo(Self.conversationBottomAnchor, anchor: .bottom)
            }
        }
    }
}

private struct QuickPromptButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(self.title, action: self.action)
            .buttonStyle(.plain)
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .foregroundStyle(Color(red: 0.16, green: 0.43, blue: 0.40))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.92))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(red: 0.69, green: 0.77, blue: 0.73), lineWidth: 1)
            )
            .accessibilityIdentifier(self.identifier)
    }
}

private struct MessageBubble: View {
    let message: ChatSession.MessageRow

    var body: some View {
        VStack(alignment: self.message.role == .user ? .trailing : .leading, spacing: 6) {
            Text(self.message.role == .user ? "你" : self.message.role == .assistant ? "AI" : "Tool")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(self.message.text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(self.foregroundColor)
                .frame(maxWidth: .infinity, alignment: self.message.role == .user ? .trailing : .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .accessibilityIdentifier("message_\(self.message.id)")
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(self.backgroundColor)
                )
                .overlay(alignment: .bottomTrailing) {
                    if self.message.isStreaming {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(self.foregroundColor)
                            .padding(10)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: self.message.role == .user ? .trailing : .leading)
        .accessibilityIdentifier("messageBubble_\(self.message.id)")
    }

    private var backgroundColor: Color {
        switch self.message.role {
        case .user:
            return Color(red: 0.16, green: 0.43, blue: 0.40)
        case .assistant:
            return Color.white.opacity(0.86)
        case .tool:
            return Color(red: 0.90, green: 0.93, blue: 0.98)
        }
    }

    private var foregroundColor: Color {
        switch self.message.role {
        case .user:
            return .white
        case .assistant, .tool:
            return Color(red: 0.16, green: 0.18, blue: 0.20)
        }
    }
}
