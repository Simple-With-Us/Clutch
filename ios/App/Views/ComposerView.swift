import SwiftUI

public struct ComposerView: View {
    @Binding public var prompt: String
    @Binding public var selectedModel: ModelItem
    @Binding public var reasoningEffort: ReasoningEffort
    public var isGenerating: Bool
    public var onSend: () -> Void
    
    @State private var isShowingModelPicker: Bool = false
    @FocusState private var isFocused: Bool
    
    public init(
        prompt: Binding<String>,
        selectedModel: Binding<ModelItem>,
        reasoningEffort: Binding<ReasoningEffort>,
        isGenerating: Bool,
        onSend: @escaping () -> Void
    ) {
        self._prompt = prompt
        self._selectedModel = selectedModel
        self._reasoningEffort = reasoningEffort
        self.isGenerating = isGenerating
        self.onSend = onSend
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // Control pills (Model picker + Reasoning effort)
            HStack(spacing: 8) {
                // Model picker button
                Button(action: {
                    isShowingModelPicker = true
                }) {
                    HStack(spacing: 6) {
                        ModelLogoView(vendor: selectedModel.vendor, size: 14)
                        
                        Text(selectedModel.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        if let badge = selectedModel.badge {
                            ProviderBadge(badge)
                        }
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                // Reasoning effort button (if model supports reasoning)
                if selectedModel.supportsReasoning {
                    Menu {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Button(action: {
                                reasoningEffort = effort
                            }) {
                                HStack {
                                    Text(effort.rawValue)
                                    if reasoningEffort == effort {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                                .font(.system(size: 11))
                                .foregroundColor(.indigo)
                            Text("Effort: \(reasoningEffort.rawValue)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            
            // Text input row
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(selectedModel.displayName)...", text: $prompt, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                
                Button(action: {
                    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onSend()
                }) {
                    ZStack {
                        Circle()
                            .fill(prompt.isEmpty || isGenerating ? Color.secondary.opacity(0.3) : Color.accentColor)
                            .frame(width: 36, height: 36)
                        
                        if isGenerating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .disabled(prompt.isEmpty || isGenerating)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheet(selectedModel: $selectedModel)
        }
    }
}

struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedModel: ModelItem
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Label("MiniMax", systemImage: "sparkles")) {
                    ForEach(ModelItem.supportedModels.filter { $0.vendor == .miniMax }) { model in
                        ModelSelectRow(model: model, isSelected: selectedModel.id == model.id) {
                            selectedModel = model
                            dismiss()
                        }
                    }
                }
                
                Section(header: Label("DeepSeek", systemImage: "brain.head.profile")) {
                    ForEach(ModelItem.supportedModels.filter { $0.vendor == .deepSeek }) { model in
                        ModelSelectRow(model: model, isSelected: selectedModel.id == model.id) {
                            selectedModel = model
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct ModelSelectRow: View {
    let model: ModelItem
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                ModelLogoView(vendor: model.vendor, size: 20)
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        if let badge = model.badge {
                            ProviderBadge(badge)
                        }
                    }
                    
                    Text(model.summary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
