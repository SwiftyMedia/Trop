//
//  ReportCommentSheet.swift
//  Trop
//
//  Created by 686udjie on 14/11/2026.
//

import SwiftUI

/// YouTube's comment abuse-report flow: reason list → optional details,
/// driven by `get_panel` + `/flow` exactly like the web. The sheet closes
/// itself as soon as the server confirms the report — there is no
/// confirmation screen. Known reason labels use app localization; other
/// panel copy arrives from the server (English — the app pins `hl=en`).
struct ReportCommentSheet: View {
    let comment: CommentItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings

    @State private var model = ReportCommentModel()

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(.systemGroupedBackground))
                .navigationTitle(NSLocalizedString("Report comment", comment: "Report sheet title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                    }
                }
        }
        .appSheetChrome([.medium, .large])
        .task {
            await model.load(params: comment.reportParams)
        }
        .onChange(of: model.didComplete) { _, finished in
            if finished { dismiss() }
        }
    }

    // MARK: - Stages

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed(let message):
            failureView(message: message, canRetry: true)
        case .reasons:
            reasonsView
        case .details:
            detailsView
        case .signIn(let header, let text):
            signInView(header: header, text: text)
        case .failed(let message):
            failureView(message: message, canRetry: false)
        }
    }

    private func failureView(message: String, canRetry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canRetry {
                Button("Retry") {
                    Task { await model.load(params: comment.reportParams) }
                }
                .buttonStyle(.bordered)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Reason select

    private var reasonsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let header = model.panel?.pageHeader {
                    Text(localizedPanelText(header))
                        .font(.title3.weight(.bold))
                }

                MenuCard {
                    let reasons = model.panel?.reasons ?? []
                    ForEach(reasons, id: \.key) { reason in
                        reasonRow(reason)
                        if reason.key != reasons.last?.key {
                            Divider()
                        }
                    }
                }

                errorBanner

                submitButton {
                    Task { await model.submitReason() }
                }
            }
            .padding(16)
        }
    }

    private func reasonRow(_ reason: CommentsParser.CommentReportReason) -> some View {
        let selected = model.selectedKey == reason.key
        return Button {
            model.selectReason(reason)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? settings.accentColor : Color.secondary)
                Text(reasonText(reason))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Known reason labels are localized by stable key; unknown labels use the server text.
    private func reasonText(_ reason: CommentsParser.CommentReportReason) -> String {
        if let key = Self.reasonLocalizationKeys[reason.key] {
            return NSLocalizedString(key, comment: "Report reason")
        }
        if let text = reason.text, !text.isEmpty { return text }
        return reason.key
    }

    private func localizedPanelText(_ text: String) -> String {
        guard let key = Self.panelLocalizationKeys[text] else { return text }
        return NSLocalizedString(key, comment: "Report panel text")
    }

    // MARK: - Details

    private var detailsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let page = model.detailsPage {
                    if let header = page.header {
                        Text(header)
                            .font(.title3.weight(.bold))
                    }
                    if let body = page.bodyText {
                        Text(body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        model.detailsPage?.placeholder
                            ?? NSLocalizedString("Provide additional details (optional)", comment: ""),
                        text: $model.detailsText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    HStack {
                        if !model.detailsIsValid {
                            Text(
                                model.detailsPage?.maxCharsErrorMessage
                                    ?? NSLocalizedString("Maximum number of characters exceeded", comment: "")
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        Spacer()
                        Text("\(model.detailsText.count)/\(model.detailsMaxChars)")
                            .font(.caption)
                            .foregroundStyle(model.detailsIsValid ? Color.secondary : Color.red)
                    }
                }

                errorBanner

                submitButton {
                    Task { await model.submitDetails() }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Sign-in

    private func signInView(header: String?, text: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(header ?? NSLocalizedString("Sign in to report this comment.", comment: ""))
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if let text {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(settings.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Shared chrome

    private var errorBanner: some View {
        Group {
            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func submitButton(action: @escaping () -> Void) -> some View {
        let title = model.panel?.navTitle.map(localizedPanelText)
            ?? NSLocalizedString("Submit report", comment: "")
        let enabled = model.canSubmit
        return Button(action: action) {
            HStack(spacing: 8) {
                if model.isAdvancing {
                    ProgressView()
                        .tint(.white)
                }
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.sheetRadius, style: .continuous)
                    .fill(enabled ? settings.accentColor : Color.secondary.opacity(0.35))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    // MARK: - Reason labels

    /// Localizable labels keyed by YouTube's stable reason enum.
    private static let reasonLocalizationKeys: [String: String] = [
        "SEXUAL": "Sexual content",
        "VIOLENCE": "Violent or repulsive content",
        "HATE": "Hateful or abusive content",
        "HARASSMENT": "Harassment or bullying",
        "DANGEROUS": "Harmful or dangerous acts",
        "SUICIDE_SELF_HARM_OR_EATING_DISORDERS": "Suicide, self-harm, or eating disorders",
        "MISINFORMATION": "Misinformation",
        "CHILD_ABUSE": "Child abuse",
        "TERRORISM": "Promotes terrorism",
        "SPAM": "Spam or misleading"
    ]

    private static let panelLocalizationKeys: [String: String] = [
        "Report": "Report",
        "What's going on?": "What's going on?",
        "What’s going on?": "What's going on?"
    ]
}

// MARK: - View model

/// Drives one report session: loads the panel, mirrors the web's local
/// state mutations (reason select, debounced details), and posts each
/// `/flow` advance. Server rejections surface inline on the current step;
/// a confirmation step flips `didComplete` so the sheet can close itself.
@MainActor
@Observable
final class ReportCommentModel {
    enum Stage {
        case loading
        case loadFailed(String)
        case reasons
        case details
        case signIn(header: String?, text: String?)
        case failed(String)
    }

    private(set) var stage: Stage = .loading
    private(set) var panel: CommentsParser.CommentReportPanel?
    private(set) var detailsPage: CommentsParser.CommentReportDetailsPage?
    private(set) var selectedKey: String?
    private(set) var isAdvancing = false
    private(set) var errorMessage: String?
    private(set) var detailsMaxChars = 500
    /// Set once the server confirms the report; the sheet dismisses on it.
    private(set) var didComplete = false
    var detailsText = ""

    private var flowState: [String: Any]?
    private var flowStateKey = ""
    private var flowId = "abuse_report_flow"
    private var targetId = "abuse_report_flow"
    private var reasonKey: String?

    var detailsIsValid: Bool { detailsText.count <= detailsMaxChars }
    /// One gate for the bottom-bar button across both steps.
    var canSubmit: Bool {
        guard !isAdvancing else { return false }
        switch stage {
        case .reasons: return selectedKey != nil
        case .details: return detailsIsValid
        default: return false
        }
    }

    func load(params: String?) async {
        guard let params, !params.isEmpty else {
            stage = .loadFailed(Self.text("Couldn't load report options"))
            return
        }
        stage = .loading
        errorMessage = nil
        do {
            let panel = try await CommentsService.shared.loadReportPanel(params: params)
            self.panel = panel
            flowState = panel.flowState
            flowStateKey = panel.flowStateEntityKey
            flowId = panel.flowId
            targetId = panel.targetId
            stage = .reasons
        } catch {
            stage = .loadFailed(Self.message(from: error, fallback: "Couldn't load report options"))
        }
    }

    /// Mirrors the web's radio handler: a selection only mutates local
    /// entity state — the POST happens when the bottom bar is tapped.
    func selectReason(_ reason: CommentsParser.CommentReportReason) {
        selectedKey = reason.key
        reasonKey = reason.key
        errorMessage = nil
        guard var state = flowState else { return }
        var abuse = state["abuseReportFlowState"] as? [String: Any] ?? [:]
        abuse["reasonKey"] = reason.key
        abuse["navigationEnabled"] = true
        abuse["isReportFormDirty"] = true
        abuse["navigationCommand"] = reason.command
        state["abuseReportFlowState"] = abuse
        flowState = state
    }

    func submitReason() async {
        guard canSubmit, reasonKey != nil, flowState != nil else { return }
        await advance()
    }

    /// Details text rides along in `abuseReportFlowState.userComments` on
    /// the next POST, exactly like the web's debounced input handler.
    func submitDetails() async {
        guard canSubmit, detailsIsValid, var state = flowState else { return }
        var abuse = state["abuseReportFlowState"] as? [String: Any] ?? [:]
        abuse["userComments"] = detailsText
        abuse["navigationEnabled"] = true
        abuse["isReportFormDirty"] = true
        state["abuseReportFlowState"] = abuse
        state["flowFormState"] = ["isValid": true]
        flowState = state
        await advance()
    }

    private func advance() async {
        guard let state = flowState, !flowStateKey.isEmpty else {
            stage = .failed(Self.text("Failed to report comment"))
            return
        }
        isAdvancing = true
        errorMessage = nil
        defer { isAdvancing = false }
        do {
            let update = try await CommentsService.shared.advanceReportFlow(
                flowState: state,
                flowStateEntityKey: flowStateKey,
                flowId: flowId,
                targetId: targetId
            )
            apply(update)
        } catch {
            errorMessage = Self.message(from: error, fallback: "Failed to report comment")
        }
    }

    private func apply(_ update: CommentsParser.CommentReportFlowUpdate) {
        if let state = update.flowState {
            flowState = state
            if let key = update.flowStateEntityKey, !key.isEmpty {
                flowStateKey = key
            }
            if let abuse = state["abuseReportFlowState"] as? [String: Any],
               let command = abuse["navigationCommand"] as? [String: Any],
               !command.isEmpty {
                let route = CommentsParser.flowRoute(from: command)
                flowId = route.flowId
                targetId = route.targetId
            }
        }

        switch update.outcome {
        case .failure(let message):
            errorMessage = message ?? Self.text("Failed to report comment")
        case .noOp:
            errorMessage = Self.text("Failed to report comment")
        case .steps(let steps):
            guard !steps.isEmpty else {
                errorMessage = Self.text("Failed to report comment")
                return
            }
            // Prefer the step the new entity says is current; fall back to
            // the furthest step when the server omits `currentStepId`.
            let currentId = flowState?["currentStepId"] as? String
            let chosen = steps.first { ($0["stepId"] as? String) == currentId }
                ?? steps.last
                ?? steps[0]
            apply(step: CommentsParser.parseReportStep(chosen))
        }
    }

    private func apply(step: CommentsParser.CommentReportStep) {
        if let key = step.flowStateKey, !key.isEmpty, key != flowStateKey {
            flowStateKey = key
        }

        switch step.page {
        case .details(let page):
            detailsPage = page
            detailsMaxChars = page.maxChars
            stage = .details
        case .confirmation:
            // Report accepted — no finish screen, just close the sheet.
            didComplete = true
        case .signIn(let header, let text):
            stage = .signIn(header: header, text: text)
        case .reasons(let header, let body, let reasons):
            guard var panel else {
                stage = .failed(Self.text("Failed to report comment"))
                return
            }
            panel.pageHeader = header ?? panel.pageHeader
            panel.bodyText = body ?? panel.bodyText
            if !reasons.isEmpty { panel.reasons = reasons }
            self.panel = panel
            selectedKey = reasonKey
            stage = .reasons
        case .unknown:
            stage = .failed(Self.text("Failed to report comment"))
        }
    }

    private static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private static func message(from error: Error, fallback key: String) -> String {
        if case CommentsError.rejected(let message) = error, !message.isEmpty {
            return message
        }
        return NSLocalizedString(key, comment: "")
    }
}
