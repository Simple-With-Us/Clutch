import SwiftUI

public struct FleetRecallView: View {
    @State private var recall = FleetRecallClient.shared
    @State private var queryText: String = ""
    @State private var isShowingContributeSheet: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                corpusSection
                searchSection
                searchStateSection
                contributeSection
            }
            .navigationTitle("Fleet Recall")
            .sheet(isPresented: $isShowingContributeSheet) {
                ContributeRecallSheet()
            }
        }
    }

    // MARK: - Corpus

    private var corpusSection: some View {
        Section(header: Text("Fleet Knowledge Base")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fleet Recall Corpus")
                            .font(.system(size: 15, weight: .bold))
                        Text(recall.endpoint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                if recall.stats.isPlaceholder {
                    // No stats method is confirmed on this endpoint, so say that
                    // instead of showing invented counts.
                    Text("Corpus counts are unavailable.  This endpoint doesn't serve a stats call.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 20) {
                        StatPill(title: "Total Chunks", value: "\(recall.stats.totalChunks)")
                        StatPill(title: "Collections", value: "\(recall.stats.collectionsCount)")
                        StatPill(title: "Queries (24h)", value: "\(recall.stats.queryCount24h)")
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        Section(header: Text("Search Fleet Memory")) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search lessons, rules, PRs, decisions…", text: $queryText)
                    .onSubmit {
                        Task { await recall.search(query: queryText) }
                    }

                if recall.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if !queryText.isEmpty {
                    Button("Search") {
                        Task { await recall.search(query: queryText) }
                    }
                    .font(.system(size: 12, weight: .bold))
                }
            }
        }
    }

    /// Results, a real failure with a retry, or an honest empty state — never a
    ///  fabricated list standing in for a corpus that could not be reached.
    @ViewBuilder
    private var searchStateSection: some View {
        if let message = recall.searchErrorMessage {
            Section {
                ContentUnavailableView {
                    Label("Couldn't Search Fleet Memory", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await recall.search(query: queryText) }
                    }
                }
            }
            .listRowInsets(EdgeInsets())
        } else if recall.hasSearched && recall.searchResults.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("No Lessons Matched", systemImage: "magnifyingglass")
                } description: {
                    Text("The corpus has nothing for this query.  Try different words or a narrower phrase.")
                }
            }
            .listRowInsets(EdgeInsets())
        } else if !recall.searchResults.isEmpty {
            Section(header: Text("Results (\(recall.searchResults.count))")) {
                ForEach(recall.searchResults) { hit in
                    RecallHitRow(hit: hit)
                }
            }
        }
    }

    // MARK: - Contribute

    private var contributeSection: some View {
        Section {
            Button(action: {
                isShowingContributeSheet = true
            }) {
                Label("Contribute New Lesson to Fleet Recall", systemImage: "square.and.pencil")
            }

            if let message = recall.contributionSuccessMessage {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recall.contributionSuccessTitle ?? "Lesson Contributed")
                        .font(.footnote.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                }
                .foregroundColor(.green)
            }
        }
    }
}

struct RecallHitRow: View {
    let hit: RecallHit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(titleLine)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)

                Spacer()

                // Only claim a match percentage when the corpus reported one.
                if let score = hit.score {
                    Text("\(Int(score * 100))% MATCH")
                        .font(.system(size: 9, weight: .black))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
            }

            if !hit.heading.isEmpty {
                Text(hit.heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(hit.text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(3)

            if !hit.path.isEmpty {
                Text(hit.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var titleLine: String {
        let title = hit.title.isEmpty ? hit.heading : hit.title
        return title.isEmpty ? "[\(hit.app.uppercased())] Lesson" : "[\(hit.app.uppercased())] \(title)"
    }
}

struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

struct ContributeRecallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recall = FleetRecallClient.shared
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var appSlug: String = "clutch"
    @State private var seatTag: String = "AG"
    @State private var category: RecallCategory = .lesson

    /// Validation copy only appears once someone has tried to submit, so the form
    ///  doesn't scold a half-typed lesson.
    @State private var showsValidation: Bool = false
    @State private var failure: RecallContributionError?
    @State private var confirmation: RecallContributionOutcome?

    private var draft: RecallContributionDraft {
        RecallContributionDraft(
            title: title,
            text: content,
            category: category.rawValue,
            app: appSlug,
            seat: seatTag
        )
    }

    private var validationError: RecallContributionError? {
        showsValidation ? draft.validate() : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Lesson Details")) {
                    TextField("Short Title", text: $title)
                    Picker("Category", selection: $category) {
                        ForEach(RecallCategory.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    TextField("App Slug", text: $appSlug)
                    TextField("Seat Tag", text: $seatTag)
                }

                Section(header: Text("Lesson Text")) {
                    TextEditor(text: $content)
                        .frame(minHeight: 140)

                    Text(lengthSummary)
                        .font(.caption)
                        .foregroundColor(isOverLength ? .red : .secondary)
                }

                if recall.isContributing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Contributing to the corpus…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let validationError {
                    Section {
                        Text(validationError.message)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if let failure {
                    Section {
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if let confirmation {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(confirmation.confirmationTitle)
                                .font(.footnote.weight(.semibold))
                            Text(confirmation.confirmationMessage)
                                .font(.footnote)
                        }
                        .foregroundColor(.green)
                    }
                }
            }
            .navigationTitle("Contribute to Recall")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(recall.isContributing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if confirmation != nil {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Submit") {
                            Task { await submit() }
                        }
                        .disabled(recall.isContributing)
                    }
                }
            }
        }
    }

    private var isOverLength: Bool {
        content.count > RecallContributionDraft.maxTextLength
    }

    private var lengthSummary: String {
        "\(content.count) of \(RecallContributionDraft.maxTextLength) characters.  At least \(RecallContributionDraft.minTextLength) required."
    }

    private func submit() async {
        showsValidation = true
        failure = nil
        confirmation = nil
        guard draft.validate() == nil else { return }

        switch await recall.contribute(draft) {
        case .success(let outcome):
            confirmation = outcome
        case .failure(let error):
            failure = error
        }
    }
}