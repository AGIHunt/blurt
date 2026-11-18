//! Several displays (docs/design/remote-hosts.md §Several displays): which one the phone sees. Pure, so every rule is tested here.
//!
//!  • follow (the default): the display the pointer is on. A pointer that only grazes the next display's edge — a fling past the
//!    edge, the corner of a menu — mustn't flip the picture, so it moves only once the pointer has stayed on another display for
//!    150 ms or gone 20 pt into it.
//!  • pinned: the phone chose one (`showDisplay`): it stays, wherever the pointer goes.
//!  • a display that goes away (unplugged, the lid closed): back to following.

use crate::host::DisplayInfo;
use crate::wire::Display;

pub const DWELL: f64 = 0.15;
pub const DEPTH: f64 = 20.0;

pub fn to_wire(d: &DisplayInfo) -> Display {
    Display { id: d.id.clone(), name: d.name.clone(), x: d.x, y: d.y, width: d.width, height: d.height, main: d.main }
}

/// The display a desktop point is on.
pub fn at(all: &[DisplayInfo], p: (f64, f64)) -> Option<&DisplayInfo> {
    all.iter().find(|d| d.contains(p.0, p.1))
}

/// How far into `d` the point is: its distance to the nearest edge.
pub fn depth(d: &DisplayInfo, p: (f64, f64)) -> f64 {
    (p.0 - d.x).min(d.x + d.width - p.0).min(p.1 - d.y).min(d.y + d.height - p.1)
}

pub fn find<'a>(all: &'a [DisplayInfo], id: &str) -> Option<&'a DisplayInfo> {
    all.iter().find(|d| d.id == id)
}

/// The display to start on: the pinned one if it's there, else the one under the pointer, else the main one.
pub fn first(all: &[DisplayInfo], pinned: Option<&str>, pointer: Option<(f64, f64)>) -> Option<String> {
    pinned
        .and_then(|p| find(all, p))
        .or_else(|| pointer.and_then(|p| at(all, p)))
        .or_else(|| all.iter().find(|d| d.main))
        .or_else(|| all.first())
        .map(|d| d.id.clone())
}

/// The pointer, 0…1 of `shown`, from a desktop point.
pub fn normalised(shown: &DisplayInfo, p: (f64, f64)) -> (f64, f64) {
    ((p.0 - shown.x) / shown.width.max(1.0), (p.1 - shown.y) / shown.height.max(1.0))
}

/// The pointer on the desktop from the backend's 0…1 of the display shown (backends that don't say where on the desktop it is).
pub fn desktop(shown: &DisplayInfo, n: (f64, f64)) -> (f64, f64) {
    (shown.x + n.0 * shown.width, shown.y + n.1 * shown.height)
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Follow {
    /// the phone's choice (None: follow the pointer)
    pub pinned: Option<String>,
    /// the display being shown now
    pub shown: Option<String>,
    /// the display the pointer has been on since when (seconds), not yet shown
    candidate: Option<(String, f64)>,
}

impl Follow {
    pub fn new(pinned: Option<String>, shown: Option<String>) -> Follow {
        Follow { pinned, shown, candidate: None }
    }

    /// The pointer is at `p` (desktop points) at `now` (seconds): Some(id) when the picture should move to that display.
    pub fn pointer(&mut self, all: &[DisplayInfo], p: (f64, f64), now: f64) -> Option<String> {
        if self.pinned.is_some() {
            self.candidate = None;
            return None;
        }
        let on = at(all, p)?;
        if self.shown.as_deref() == Some(on.id.as_str()) {
            self.candidate = None;
            return None;
        }
        let since = match &self.candidate {
            Some((id, t)) if *id == on.id => *t,
            _ => {
                self.candidate = Some((on.id.clone(), now));
                now
            }
        };
        if now - since >= DWELL || depth(on, p) >= DEPTH {
            self.candidate = None;
            return Some(on.id.clone());
        }
        None
    }

    /// The displays changed: Some(id) when the one shown went (back to following, on the one under the pointer).
    pub fn displays_changed(&mut self, all: &[DisplayInfo], pointer: Option<(f64, f64)>) -> Option<String> {
        if self.pinned.as_deref().is_some_and(|p| find(all, p).is_none()) {
            self.pinned = None;
        }
        if self.shown.as_deref().is_some_and(|s| find(all, s).is_some()) || all.is_empty() {
            return None;
        }
        self.candidate = None;
        first(all, None, pointer)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn two() -> Vec<DisplayInfo> {
        vec![
            DisplayInfo { id: "A".into(), name: "Built-in".into(), x: 0.0, y: 0.0, width: 1512.0, height: 982.0, main: true },
            DisplayInfo { id: "B".into(), name: "DELL".into(), x: 1512.0, y: -458.0, width: 2560.0, height: 1440.0, main: false },
        ]
    }

    #[test]
    fn a_graze_doesnt_flip_the_picture_a_stay_or_a_push_does() {
        let all = two();
        let mut f = Follow::new(None, Some("A".into()));
        assert_eq!(f.pointer(&all, (500.0, 500.0), 0.0), None);
        // 5 pt into B: not yet
        assert_eq!(f.pointer(&all, (1517.0, 300.0), 1.0), None);
        assert_eq!(f.pointer(&all, (1517.0, 300.0), 1.1), None);
        // back on A before 150 ms: nothing, and the clock starts again next time
        assert_eq!(f.pointer(&all, (1500.0, 300.0), 1.12), None);
        assert_eq!(f.pointer(&all, (1517.0, 300.0), 1.2), None);
        assert_eq!(f.pointer(&all, (1517.0, 300.0), 1.36), Some("B".into()), "150 ms on it");
        f.shown = Some("B".into());
        // 25 pt into A at once: no waiting
        assert_eq!(f.pointer(&all, (1487.0, 300.0), 2.0), Some("A".into()));
    }

    #[test]
    fn pinned_stays_and_a_gone_display_unpins() {
        let all = two();
        let mut f = Follow::new(Some("B".into()), Some("B".into()));
        assert_eq!(f.pointer(&all, (100.0, 100.0), 0.0), None);
        assert_eq!(f.pointer(&all, (100.0, 100.0), 5.0), None, "pinned: the pointer doesn't move the picture");
        let only_a = vec![all[0].clone()];
        assert_eq!(f.displays_changed(&only_a, Some((100.0, 100.0))), Some("A".into()));
        assert_eq!(f.pinned, None, "following again");
        f.shown = Some("A".into());
        assert_eq!(f.displays_changed(&all, Some((100.0, 100.0))), None, "a display came: nothing moves");
    }

    #[test]
    fn where_to_start() {
        let all = two();
        assert_eq!(first(&all, Some("B"), Some((10.0, 10.0))).as_deref(), Some("B"));
        assert_eq!(first(&all, Some("gone"), Some((2000.0, 0.0))).as_deref(), Some("B"));
        assert_eq!(first(&all, None, None).as_deref(), Some("A"));
        assert_eq!(first(&[], None, None), None);
        let b = &all[1];
        assert_eq!(desktop(b, normalised(b, (2000.0, 100.0))), (2000.0, 100.0));
        assert!(normalised(&all[0], (2000.0, 100.0)).0 > 1.0, "off the display shown");
    }
}
