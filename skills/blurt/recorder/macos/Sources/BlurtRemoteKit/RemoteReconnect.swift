// Getting back to a computer: how long a session is kept while its app is out of sight, and how soon each way in is tried again
// (docs/design/remote.md §Coming back). Numbers only, so they can be tested and so the phones and the viewers agree
// (Android: core/Reconnect.kt, crates/blurt-remote/src/reconnect.rs).
import Foundation

public enum RemoteReconnect {
    /// Away from home last time (a relay, the go-between or an overlay network): the relay starts with the local ways. At home it waits
    /// this long, so it's never the one that wins there.
    public static let relayAfter = 1.2

    public static func relayDelay(lastAway: Bool) -> Double { lastAway ? 0 : relayAfter }

    /// A relay connection ended before a session: the next one this long after, by how many have ended like that in a row. A computer
    /// that has just let the last session go is back in its room within a second, so the first ones come soon.
    public static func relayAgain(_ times: Int) -> Double {
        switch times {
        case ..<2: 0.4
        case 2: 0.8
        case 3: 1.5
        case 4: 3
        default: 5
        }
    }

    /// Back in front with a session kept meanwhile: no answer from the computer within this and it's taken as gone.
    public static func proof(relay: Bool) -> Double { relay ? 2.5 : 1.2 }

    /// A handshake done and the computer answering pings, but its `session` never came: start over after this.
    public static func sessionDue(relay: Bool) -> Double { relay ? 10 : 5 }

    /// Nothing has answered for this long: said so on the pad. A relay has further to go.
    public static func unreachableAfter(relay: Bool) -> Double { relay ? 12 : 8 }

    /// The go-between turned this phone away: asked again by itself only after RemoteRelay.busyWait. Retry or another network asks at once,
    /// as opening the app again would, but never sooner than the go-between's own rate limit forgets (it blocks for 10 s); coming back to
    /// the app, which people do hundreds of times a day, asks once a minute at most.
    public static func busyFloor(asked: Bool) -> Double { asked ? 12 : 60 }

    /// iOS gives an app about 30 s after it leaves the screen; a session is kept for most of it, and let go properly before the end.
    public static let keepInBackground = 25.0
}
