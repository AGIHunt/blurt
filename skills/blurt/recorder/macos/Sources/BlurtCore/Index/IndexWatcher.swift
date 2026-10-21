// FSEvents on the recording roots → session dirs that changed (the app then runs `index.py update`, debounced 300 ms).
// Owned by WP5; WP4-gate stub.
import Foundation

public final class IndexWatcher {
    public let roots: [URL]
    public var onChange: (([URL]) -> Void)?
    public init(roots: [URL]) { self.roots = roots }
}
