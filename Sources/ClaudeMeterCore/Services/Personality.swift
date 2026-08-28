import Foundation

/// Pure mappings from "remaining %" to playful representations used by the menu-bar skins.
public enum Personality {
    /// A face that degrades as the budget drains.
    public static func moodEmoji(remaining: Double) -> String {
        switch remaining {
        case ..<5: "💀"
        case ..<15: "🥵"
        case ..<30: "😬"
        case ..<60: "🙂"
        default: "😎"
        }
    }

    public enum PetState: String, Equatable, Sendable, CaseIterable {
        case happy, content, tired, sleepy, asleep
    }

    public static func petState(remaining: Double) -> PetState {
        switch remaining {
        case ..<5: .asleep
        case ..<20: .sleepy
        case ..<45: .tired
        case ..<75: .content
        default: .happy
        }
    }

    /// A cat whose mood tracks the pet state (sleeps when you're out of budget).
    public static func petEmoji(_ state: PetState) -> String {
        switch state {
        case .happy: "😺"
        case .content: "😸"
        case .tired: "😼"
        case .sleepy: "🙀"
        case .asleep: "😴"
        }
    }
}
