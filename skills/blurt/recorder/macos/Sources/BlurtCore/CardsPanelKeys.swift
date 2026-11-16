// The keys of a set of cards (BlurtApp MainWindow/CardsPage.swift, its big preview Capture/Island/CardPreview.swift):
// the keys the Cards page and the preview read, and what each one does in the preview. The page's own map is
// CardsPageRules.action. Kept here, without AppKit, so they are tested.
//
// In the preview: ← / → (↑ / ↓) the card before / after it, Space or Esc back to the page.

import Foundation

public enum CardsPanelKey: Equatable {
    case left, right, up, down, space, tab, enter, copy, delete, escape, close
}

public enum CardsPreviewAction: Equatable {
    /// the card N places before (−) or after (+) this one
    case step(Int)
    case close
    case none
}

public enum CardsPanelRules {
    /// What `key` does with the keyboard on the preview.
    public static func previewAction(_ key: CardsPanelKey) -> CardsPreviewAction {
        switch key {
        case .left, .up: return .step(-1)
        case .right, .down: return .step(1)
        case .space, .escape, .close: return .close
        default: return .none
        }
    }
}
