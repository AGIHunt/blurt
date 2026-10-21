// K10 shorthands for P4's string tables (Sources/BlurtApp/Resources/{en,zh-Hans}.lproj): the key's first part picks
// the table — main.* / menu.* / app.* / notify.* → Main, settings.* / onboarding.* → Settings, anything else
// (kind.*, work.*, session.*, project.*, job.*, action.*…) → Common.
//   T("main.inbox")                         Loc.t("main.inbox", table: "Main")
//   T("main.move.done", name)               %@ / %ld placeholders
//   TP("main.items.selected", n)            Loc.plural(…, count: n) — the .stringsdict entry
import BlurtCore

func table(of key: String) -> String {
    switch key.prefix { $0 != "." } {
    case "main", "menu", "app", "notify": return "Main"
    case "settings", "onboarding": return "Settings"
    default: return "Common"
    }
}

func T(_ key: String, _ args: CVarArg...) -> String { Loc.format(Loc.string(key, table: table(of: key)), args) }

func TP(_ key: String, _ count: Int, _ args: CVarArg...) -> String { Loc.format(Loc.string(key, table: table(of: key)), [count] + args) }
