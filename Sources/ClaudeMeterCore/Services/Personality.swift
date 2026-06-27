import Foundation

/// Pure mappings from "remaining %" to playful representations used by the menu-bar skins.
public enum Personality {
    /// A face that degrades as the budget drains.
    public static func moodEmoji(remaining: Double) -> String {
        switch remaining {
        case ..<5: return "💀"
        case ..<15: return "🥵"
        case ..<30: return "😬"
        case ..<60: return "🙂"
        default: return "😎"
        }
    }

    public enum PetState: String, Equatable, Sendable, CaseIterable {
        case happy, content, tired, sleepy, asleep
    }

    public static func petState(remaining: Double) -> PetState {
        switch remaining {
        case ..<5: return .asleep
        case ..<20: return .sleepy
        case ..<45: return .tired
        case ..<75: return .content
        default: return .happy
        }
    }

    /// A cat whose mood tracks the pet state (sleeps when you're out of budget).
    public static func petEmoji(_ state: PetState) -> String {
        switch state {
        case .happy: return "😺"
        case .content: return "😸"
        case .tired: return "😼"
        case .sleepy: return "🙀"
        case .asleep: return "😴"
        }
    }
}
