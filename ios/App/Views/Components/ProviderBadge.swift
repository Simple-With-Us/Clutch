import SwiftUI

public struct ProviderBadge: View {
    public let text: String
    public var roleDescription: String?
    
    public init(_ text: String, roleDescription: String? = nil) {
        self.text = text
        self.roleDescription = roleDescription
    }
    
    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeBackground)
            .foregroundColor(badgeForeground)
            .clipShape(Capsule())
    }
    
    private var badgeBackground: Color {
        switch text.lowercased() {
        case "preview":
            return Color.orange.opacity(0.15)
        case "multimodal":
            return Color.purple.opacity(0.15)
        case "2x cost":
            return Color.red.opacity(0.15)
        default:
            return Color.secondary.opacity(0.15)
        }
    }
    
    private var badgeForeground: Color {
        switch text.lowercased() {
        case "preview":
            return Color.orange
        case "multimodal":
            return Color.purple
        case "2x cost":
            return Color.red
        default:
            return Color.secondary
        }
    }
}

public struct ModelLogoView: View {
    public let vendor: ModelVendor
    public var size: CGFloat = 16
    
    public init(vendor: ModelVendor, size: CGFloat = 16) {
        self.vendor = vendor
        self.size = size
    }
    
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(vendor == .miniMax ? Color.red.opacity(0.12) : Color.blue.opacity(0.12))
                .frame(width: size + 6, height: size + 6)
            
            Image(systemName: vendor.iconName)
                .font(.system(size: size * 0.75, weight: .bold))
                .foregroundColor(vendor == .miniMax ? .red : .blue)
        }
    }
}
