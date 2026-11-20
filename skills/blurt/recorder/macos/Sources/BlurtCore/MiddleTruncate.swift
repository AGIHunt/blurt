// A name shortened in its middle ("口喷鸡 iOS…截断）") until the line it is in fits — as the sidebar and the switcher show a
// long project name (NSLineBreakMode.byTruncatingMiddle), for a line built from several parts where AppKit can't do it
// (the island's "Filed to <name> · <id>", whose long name wrapped with one character alone on its second line).
public enum MiddleTruncate {
    /// `name` as it is when `fits(line(name))`, else its start and end around "…", as long as still fits (at least one
    /// character each side).
    public static func fit(_ name: String, in line: (String) -> String, fits: (String) -> Bool) -> String {
        if fits(line(name)) { return name }
        let cs = Array(name)
        guard cs.count > 3 else { return name }
        var keep = cs.count - 1
        while keep > 2 {
            let head = (keep + 1) / 2, tail = keep - head
            let s = String(cs.prefix(head)) + "…" + String(cs.suffix(tail))
            if fits(line(s)) { return s }
            keep -= 1
        }
        return String(cs.prefix(1)) + "…" + String(cs.suffix(1))
    }
}
