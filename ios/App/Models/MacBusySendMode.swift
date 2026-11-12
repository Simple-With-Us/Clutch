import Foundation

enum MacBusySendMode: String, CaseIterable, Identifiable {
    case queue
    case steer

    static let storageKey = "codes.clutch.mac-busy-send-mode"
    static let defaultMode: MacBusySendMode = .queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: return "Queue"
        case .steer: return "Steer"
        }
    }

    var symbol: String {
        switch self {
        case .queue: return "text.badge.plus"
        case .steer: return "arrowshape.turn.up.right"
        }
    }

    var explanation: String {
        switch self {
        case .queue: return "Send this message after the current turn finishes."
        case .steer: return "Send a new instruction into the active turn without interrupting it."
        }
    }
}
