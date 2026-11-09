//! Long-term references for recovery frames (docs/design/remote-realtime.md §2, the encoder table), as a pure state machine the
//! encoder follows. Media Foundation's controls (hardware MFTs that have them; checked at run time):
//!
//! * `CODECAPI_AVEncVideoLTRBufferControl` = 2 | 1 << 16: two LTR slots, trust mode 1 ("Trust Until": a slot may be used until the
//!   app says otherwise through UseLTRFrame). Static: set before streaming.
//! * `CODECAPI_AVEncVideoMarkLTRFrame` = slot: the next frame goes into that slot. Every 4th frame, into a slot the phone hasn't
//!   acknowledged if there is one (so the acknowledged one stays usable meanwhile), else the older.
//! * `CODECAPI_AVEncVideoUseLTRFrame` = bitmap | 1 << 16: the next frame refers only to these slots (and nothing older than itself
//!   afterwards). That's the recovery frame: decodable by a phone that has the acknowledged frame, whatever was lost since.
//! * `MFSampleExtension_LongTermReferenceFrameInfo` on the output (where the encoder reports it): low 16 bits the slot the frame went
//!   into (0xFFFF: none), high 16 bits the slots it used. A mark or a use the encoder didn't honour is caught there.
//!
//! References are handed to the server as opaque numbers (`EncodedFrame::reference`); it gives back the ones the phone decoded.

pub const SLOTS: usize = 2;
/// a frame marked every this many
pub const EVERY: u64 = 4;

/// What the next frame is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plan {
    pub keyframe: bool,
    /// refers only to these slots (a bitmap): a recovery frame
    pub use_slots: u32,
    /// goes into this slot, with this reference number
    pub mark: Option<(usize, u64)>,
}

#[derive(Debug)]
pub struct Ltr {
    /// the reference number of the frame in each slot, and whether the phone has decoded it
    slots: [Option<(u64, bool)>; SLOTS],
    frames: u64,
    /// reference numbers from another encoder never match
    base: u64,
    next: u64,
}

impl Ltr {
    pub fn new(generation: u64) -> Ltr {
        Ltr { slots: [None; SLOTS], frames: 0, base: generation << 40, next: 0 }
    }

    fn number(&mut self) -> u64 {
        self.next += 1;
        self.base | self.next
    }

    /// The slots holding a frame the phone has: a bitmap.
    pub fn acked(&self) -> u32 {
        self.slots.iter().enumerate().filter(|(_, s)| s.is_some_and(|s| s.1)).fold(0, |b, (i, _)| b | 1 << i)
    }

    /// The next frame: a keyframe if asked (or a recovery with nothing acknowledged to refer to), a recovery frame if asked, else an
    /// ordinary one, marked every `EVERY` frames.
    pub fn plan(&mut self, keyframe: bool, recover: bool) -> Plan {
        self.frames += 1;
        let acked = self.acked();
        if keyframe || (recover && acked == 0) {
            // an IDR forgets every reference: it goes into slot 0 itself
            self.slots = [None; SLOTS];
            let n = self.number();
            self.slots[0] = Some((n, false));
            self.frames = 0;
            return Plan { keyframe: true, use_slots: 0, mark: Some((0, n)) };
        }
        if recover {
            // what isn't acknowledged can't be used from here on (UseLTRFrame's rule): forget it
            for s in &mut self.slots {
                if s.is_some_and(|s| !s.1) {
                    *s = None;
                }
            }
            return Plan { keyframe: false, use_slots: acked, mark: None };
        }
        if !self.frames.is_multiple_of(EVERY) {
            return Plan { keyframe: false, use_slots: 0, mark: None };
        }
        // an empty slot; else the older one not acknowledged yet (keep the one that is); else the older
        let age = |i: &usize| self.slots[*i].map_or(0, |s| s.0);
        let slot = (0..SLOTS)
            .find(|i| self.slots[*i].is_none())
            .or_else(|| (0..SLOTS).filter(|i| self.slots[*i].is_some_and(|s| !s.1)).min_by_key(age))
            .unwrap_or_else(|| (0..SLOTS).min_by_key(age).unwrap_or(0));
        let n = self.number();
        self.slots[slot] = Some((n, false));
        Plan { keyframe: false, use_slots: 0, mark: Some((slot, n)) }
    }

    /// The phone decoded the frames with these reference numbers.
    pub fn acknowledged(&mut self, refs: &[u64]) {
        for s in self.slots.iter_mut().flatten() {
            if refs.contains(&s.0) {
                s.1 = true;
            }
        }
    }

    /// The encoder didn't put a marked frame into its slot (its output said so): that number means nothing.
    pub fn unmarked(&mut self, reference: u64) {
        for s in &mut self.slots {
            if s.is_some_and(|s| s.0 == reference) {
                *s = None;
            }
        }
    }
}

/// LTRBufferControl's value: `SLOTS` frames, trust mode 1.
pub const BUFFER_CONTROL: u32 = SLOTS as u32 | 1 << 16;

/// UseLTRFrame's value for a bitmap of slots.
pub fn use_value(bitmap: u32) -> u32 {
    (bitmap & 0xFFFF) | 1 << 16
}

/// MFSampleExtension_LongTermReferenceFrameInfo → (slot it went into, slots it used).
pub fn info(v: u32) -> (Option<usize>, u32) {
    let slot = v & 0xFFFF;
    ((slot != 0xFFFF).then_some(slot as usize), v >> 16)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marks_every_fourth_frame_and_keeps_the_acknowledged_slot() {
        let mut l = Ltr::new(1);
        let k = l.plan(true, false);
        assert!(k.keyframe);
        let (s0, r0) = k.mark.unwrap();
        assert_eq!(s0, 0);
        let marks: Vec<_> = (0..8).map(|_| l.plan(false, false).mark).collect();
        assert_eq!(marks.iter().filter(|m| m.is_some()).count(), 2);
        // frame 4 went into slot 1 (0 not acknowledged yet, but 1 is empty), frame 8 into slot 0 (neither acknowledged: the older)
        assert_eq!(marks[3].unwrap().0, 1);
        assert_eq!(marks[7].unwrap().0, 0);
        let r8 = marks[7].unwrap().1;
        assert!(r8 != r0);
        l.acknowledged(&[r8]);
        assert_eq!(l.acked(), 0b01);
        // the next mark spares the acknowledged slot
        let next: Vec<_> = (0..4).filter_map(|_| l.plan(false, false).mark).collect();
        assert_eq!(next.len(), 1);
        assert_eq!(next[0].0, 1);
    }

    #[test]
    fn a_recovery_refers_to_what_the_phone_has_or_is_a_keyframe() {
        let mut l = Ltr::new(2);
        l.plan(true, false);
        assert!(l.plan(false, true).keyframe, "nothing acknowledged: a keyframe");
        let r = l.plan(true, false).mark.unwrap().1;
        l.acknowledged(&[r]);
        for _ in 0..4 {
            l.plan(false, false); // frame 4 marked into slot 1, not acknowledged
        }
        let p = l.plan(false, true);
        assert_eq!(p, Plan { keyframe: false, use_slots: 0b01, mark: None });
        assert_eq!(l.acked(), 0b01, "the unacknowledged slot is forgotten, the acknowledged one kept");
        // another encoder's numbers don't count
        let mut other = Ltr::new(3);
        other.plan(true, false);
        other.acknowledged(&[r]);
        assert_eq!(other.acked(), 0);
    }

    #[test]
    fn a_mark_the_encoder_dropped_is_never_used() {
        let mut l = Ltr::new(4);
        let r = l.plan(true, false).mark.unwrap().1;
        l.unmarked(r);
        l.acknowledged(&[r]);
        assert!(l.plan(false, true).keyframe);
    }

    #[test]
    fn the_values() {
        assert_eq!(BUFFER_CONTROL, 0x0001_0002);
        assert_eq!(use_value(0b10), 0x0001_0002);
        assert_eq!(info(0x0001_FFFF), (None, 1));
        assert_eq!(info(0x0000_0001), (Some(1), 0));
    }
}
