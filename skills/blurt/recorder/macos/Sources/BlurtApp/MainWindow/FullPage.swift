// A page of the main window that takes the whole content area — Home, Cards, Phone — in place of the items' list and
// detail (MainWindowController.fullPage / syncPage: its view goes in the list column and the detail column folds).
// The page names itself in its own heading (the toolbar keeps only the sidebar button) and reaches the window through
// MainWindowController.shared (go(_:), showDictation()…).
import AppKit
import SwiftUI

protocol FullPage: AnyObject {
    var viewController: NSViewController { get }
    /// The page came on show (the window opened on it, or the sidebar went there): read what it shows again.
    func didShow()
    func didHide()
}

extension FullPage {
    func didShow() {}
    func didHide() {}
}

/// The frame every full page sits in: one scrolling column, 720 pt at most, centred, starting with the page's name in
/// the list headings' size — so Home, Cards and Phone open at the same place on the same grid.
struct FullPageFrame<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    if let s = subtitle { Text(s).font(.system(size: 13)).foregroundStyle(.secondary) }
                }
                .padding(.bottom, 20)
                content()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
