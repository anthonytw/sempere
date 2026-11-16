import Sempere
import SempereAppCore
import SempereInsights
import SwiftUI

// Topic summaries (docs/design/1.2-note-insights.md §6 item 4, §4 step 9, D8; Insights PR 3): "Summary" on a notebook
// or tag with at least 3 summarized notes shows the stored paragraph with a "Generated" badge and a "Check sources" list
// of the current members; stale when the members changed. Generating devices make them in the background (the model's
// passes) and "Regenerate" makes one now. Devices without the model read the others' files. No cluster summaries (D8).

/// The words of topic summaries.
enum TopicText {
    /// A topic's scope: the notebook's path, or the tag as the vault's notes spell it (`tags`, the sidebar's list; the
    /// scope holds only the case-folded key). Vault data, never translated.
    static func name(_ scope: InsightsTopicsFile.Scope, tags: [String]) -> String {
        if let nb = scope.notebook { return nb }
        let key = scope.tag ?? ""
        return tags.first { NoteOps.tagKey($0) == key } ?? key
    }

    static func systemImage(_ scope: InsightsTopicsFile.Scope) -> String { scope.notebook != nil ? "book.closed" : "tag" }

    static func problem(_ p: InsightsTopicProblem) -> String {
        switch p {
        case .factCheck: return String(localized: "The new summary named things its notes do not support, so it was not kept.")
        case .tooFewMembers: return String(localized: "A summary needs at least 3 summarized notes.")
        case .unavailable: return String(localized: "Apple Intelligence is not available on this device.")
        case .failed(let why): return String(localized: "The summary could not be made: \(why)", comment: "%@ is the reason")
        }
    }
}

/// One scope's summary and sources: the sheet's content and Settings ▸ Note Insights ▸ Topic Summaries' detail.
struct TopicSummaryContent: View {
    @AppModelEnvironment private var model
    let scope: InsightsTopicsFile.Scope
    /// Opens a source note (the sheet also closes itself).
    var onOpen: (UUID) -> Void

    var body: some View {
        List {
            if let topic = model.insightsTopic(scope) {
                summarySection(topic)
                sourcesSection(topic)
            } else {
                Text("A summary needs at least 3 summarized notes.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(TopicText.name(scope, tags: model.tags))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("topicSummary")
    }

    @ViewBuilder private func summarySection(_ topic: TopicSummaries.Shown) -> some View {
        let name = TopicScopes.name(scope)
        let running = model.insights.regeneratingTopics.contains(name)
        Section {
            if let summary = topic.summary {
                Text(verbatim: summary)
                    .foregroundStyle(topic.stale ? .secondary : .primary)
                    .textSelection(.enabled)
            } else {
                Text("No summary yet: a device with Apple Intelligence makes one in the background, at most once a day.")
                    .foregroundStyle(.secondary)
            }
            if topic.stale {
                Label("Its notes changed since this was made; it is made again within a day.", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
            }
            if let made = madeLine(topic) {
                Text(made).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = model.insights.topicProblems[name] {
                Label(TopicText.problem(problem), systemImage: "exclamationmark.triangle").font(.footnote)
            }
            if model.canRegenerateInsightsTopics {
                Button {
                    Task { await model.regenerateInsightsTopic(scope) }
                } label: {
                    if running {
                        HStack { ProgressView(); Text("Making the Summary…") }
                    } else {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(running)
                .help("Make this summary again now on this device")
                .accessibilityIdentifier("topicSummary.regenerate")
            }
        } header: {
            HStack {
                Text("Summary")
                if topic.summary != nil {
                    Text("Generated", comment: "Badge: the text was written by the on-device model")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .accessibilityIdentifier("topicSummary.generated")
                }
            }
        }
    }

    private func madeLine(_ topic: TopicSummaries.Shown) -> String? {
        guard let device = topic.device, let at = topic.at else { return nil }
        let name = model.insights.status?.devices.first { $0.device == device.rawValue }.map(InsightsText.deviceName)
            ?? String(localized: "Device \(device.rawValue)", comment: "%@ is a short device id")
        return String(localized: "Generated on \(name), \(at.formatted(date: .abbreviated, time: .omitted))", comment: "Note Insights: device name, date")
    }

    @ViewBuilder private func sourcesSection(_ topic: TopicSummaries.Shown) -> some View {
        Section {
            ForEach(topic.members, id: \.self) { id in
                Button {
                    onOpen(id)
                } label: {
                    Text(verbatim: NoteTitle.display(model.notesByID[id]?.title ?? "")).foregroundStyle(.primary)
                }
                .help("Open this note")
            }
        } header: {
            Text("Check Sources")
        } footer: {
            Text("The summary is made from these notes' summaries. Check what it says against them.")
        }
    }
}

/// "Summary" of a notebook or tag as a sheet (the sidebar's menus).
struct TopicSummarySheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let scope: InsightsTopicsFile.Scope

    var body: some View {
        NavigationStack {
            TopicSummaryContent(scope: scope) { id in
                model.selectedNoteID = id
                dismiss()
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Settings ▸ Note Insights ▸ Topic Summaries: every notebook and tag that can have a summary.
struct InsightsTopicsList: View {
    @AppModelEnvironment private var model

    var body: some View {
        List {
            let topics = model.insightsTopics
            if topics.isEmpty {
                Text("A notebook or tag gets a summary once it holds at least 3 summarized notes.").foregroundStyle(.secondary)
            }
            ForEach(topics, id: \.scope) { t in
                NavigationLink {
                    TopicSummaryContent(scope: t.scope) { model.selectedNoteID = $0 }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(TopicText.name(t.scope, tags: model.tags), systemImage: TopicText.systemImage(t.scope))
                        Group {
                            if t.summary == nil {
                                Text("No summary yet")
                            } else if t.stale {
                                Text("Summary out of date")
                            } else {
                                Text("\(t.members.count) notes", comment: "Topic summaries: the number of notes a summary is made from")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Topic Summaries")
        .navigationBarTitleDisplayMode(.inline)
    }
}
