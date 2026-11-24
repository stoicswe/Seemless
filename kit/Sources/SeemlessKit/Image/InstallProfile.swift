import Foundation

/// The removal recipes offered for an automatic install (image/recipes/).
/// UI and CLI list these; `recipe` is the directory name under
/// `image/recipes/`.
public enum InstallProfile: String, CaseIterable, Sendable, Identifiable {
    case lean
    case leanXbox
    case fat

    public var id: String { rawValue }

    public var recipe: String {
        switch self {
        case .lean: return "seemless-default"
        case .leanXbox: return "seemless-gaming"
        case .fat: return "stock"
        }
    }

    public var title: String {
        switch self {
        case .lean: return "Lean"
        case .leanXbox: return "Lean, with Xbox"
        case .fat: return "Fat"
        }
    }

    public var summary: String {
        switch self {
        case .lean:
            return "Removes promotional and consumer apps, Edge, widgets, Copilot, the Xbox apps and suggestions."
        case .leanXbox:
            return "Like Lean (Edge removed too), but keeps the Xbox apps and legacy Media Player for Game Pass and older games."
        case .fat:
            return "Windows 11 exactly as Microsoft ships it. Nothing removed."
        }
    }

    public init?(recipe: String) {
        guard let p = Self.allCases.first(where: { $0.recipe == recipe }) else { return nil }
        self = p
    }
}
