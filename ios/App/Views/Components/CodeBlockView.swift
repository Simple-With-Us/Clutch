import SwiftUI
import UIKit

public struct CodeBlockView: View {
    public let code: String
    public var language: String?
    @State private var isCopied: Bool = false
    
    public init(code: String, language: String? = nil) {
        self.code = code
        self.language = language
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
                
                Spacer()
                
                Button(action: {
                    UIPasteboard.general.string = code
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isCopied = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(isCopied ? .green : Color(white: 0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(red: 0.12, green: 0.14, blue: 0.18))
            
            // Code text
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.9))
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(Color(red: 0.08, green: 0.09, blue: 0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}
