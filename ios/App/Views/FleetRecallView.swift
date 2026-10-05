import SwiftUI

public struct FleetRecallView: View {
    @State private var recall = FleetRecallClient.shared
    @State private var queryText: String = ""
    @State private var isShowingContributeSheet: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // Stats Section
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

                        HStack(spacing: 20) {
                            StatPill(title: "Total Chunks", value: "\(recall.stats.totalChunks)")
                            StatPill(title: "Collections", value: "\(recall.stats.collectionsCount)")
                            StatPill(title: "Queries (24h)", value: "\(recall.stats.queryCount24h)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Search Bar
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

                // Results
                if !recall.searchResults.isEmpty {
                    Section(header: Text("Results (\(recall.searchResults.count))")) {
                        ForEach(recall.searchResults) { hit in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("[\(hit.app.uppercased())] \(hit.title)")
                                        .font(.system(size: 14, weight: .bold))
                                        .lineLimit(1)

                                    Spacer()

                                    Text("\(Int(hit.score * 100))% MATCH")
                                        .font(.system(size: 9, weight: .black))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundColor(.green)
                                        .clipShape(Capsule())
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
                    }
                }

                // Contribute
                Section {
                    Button(action: {
                        isShowingContributeSheet = true
                    }) {
                        Label("Contribute New Lesson to Fleet Recall", systemImage: "square.and.pencil")
                    }

                    if let success = recall.contributionSuccessMessage {
                        Text(success.replacingOccurrences(of: "&nbsp;", with: "  "))
                            .font(.footnote)
                            .foregroundColor(.green)
                    }
                }
            }
            .navigationTitle("Fleet Recall")
            .sheet(isPresented: $isShowingContributeSheet) {
                ContributeRecallSheet()
            }
        }
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
    @State private var category: String = "lesson"

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Lesson Details")) {
                    TextField("Short Title", text: $title)
                    TextField("App Slug", text: $appSlug)
                    TextField("Category (e.g. lesson, decision, finding)", text: $category)
                }

                Section(header: Text("Content / Finding")) {
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("Contribute to Recall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task {
                            _ = await recall.contributeLesson(
                                title: title,
                                content: content,
                                category: category,
                                appSlug: appSlug
                            )
                            dismiss()
                        }
                    }
                    .disabled(title.isEmpty || content.isEmpty || recall.isContributing)
                }
            }
        }
    }
}
