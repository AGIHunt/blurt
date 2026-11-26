//! The joining side's gate on `newKey` (the Mac's `RemoteJoinGate`, RemotePairing.swift; docs/design/remote-protocol.md).
//!
//! While joining with a pairing code (or nearby), whoever holds the code can stand in for the computer, finish the handshake and
//! send `newKey`. So the key is taken only when the computer asked first on this connection (`pairingWaits`: the digits are on
//! screen) and this side's user said the digits are the same (Pair), in either order. A key before the question is dropped, not
//! held; a new connection starts over. Checked against `tests/remote-vectors/vectors.json` → `joinGate.cases`.

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JoinGate {
    /// the computer asked: the digits are on screen
    asked: bool,
    /// this side's user said they're the same
    confirmed: bool,
    /// the computer's key, come before this side's yes
    held: Option<Vec<u8>>,
}

/// One step of the vectors' `events`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JoinEvent {
    PairingWaits,
    Same,
    NewKey,
    Reconnect,
}

impl JoinEvent {
    pub fn parse(s: &str) -> Option<JoinEvent> {
        Some(match s {
            "pairingWaits" => JoinEvent::PairingWaits,
            "same" => JoinEvent::Same,
            "newKey" => JoinEvent::NewKey,
            "reconnect" => JoinEvent::Reconnect,
            _ => return None,
        })
    }
}

impl JoinGate {
    pub fn new() -> JoinGate {
        JoinGate::default()
    }

    pub fn asked(&self) -> bool {
        self.asked
    }

    pub fn confirmed(&self) -> bool {
        self.confirmed
    }

    /// the digits can be confirmed now (shown, and not yet confirmed)
    pub fn can_confirm(&self) -> bool {
        self.asked && !self.confirmed
    }

    /// the computer said yes; this side's user hasn't yet
    pub fn key_waiting(&self) -> bool {
        self.held.is_some()
    }

    pub fn pairing_waits(&mut self) {
        self.asked = true;
    }

    /// The user says the digits are the same. The key to store now, when the computer's yes came first. Before the question it
    /// counts for nothing.
    pub fn confirm(&mut self) -> Option<Vec<u8>> {
        if !self.asked {
            return None;
        }
        self.confirmed = true;
        self.held.take()
    }

    /// The computer's `newKey`. The key to store now, or None: held until the user's yes, or dropped when the computer never asked.
    pub fn new_key(&mut self, k: Vec<u8>) -> Option<Vec<u8>> {
        if !self.asked {
            return None;
        }
        if self.confirmed {
            return Some(k);
        }
        self.held = Some(k);
        None
    }

    /// a new connection: new digits, asked again
    pub fn reset(&mut self) {
        *self = JoinGate::default();
    }

    /// Runs `events` in order (the vectors' form): the index of the event at which the key is stored, or None.
    pub fn run(events: &[JoinEvent]) -> Option<usize> {
        let mut g = JoinGate::new();
        for (i, e) in events.iter().enumerate() {
            let got = match e {
                JoinEvent::PairingWaits => {
                    g.pairing_waits();
                    None
                }
                JoinEvent::Same => g.confirm(),
                JoinEvent::NewKey => g.new_key(vec![7; 32]),
                JoinEvent::Reconnect => {
                    g.reset();
                    None
                }
            };
            if got.is_some() {
                return Some(i);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_held_key_is_the_one_taken() {
        let mut g = JoinGate::new();
        g.pairing_waits();
        assert_eq!(g.new_key(vec![1; 32]), None);
        assert!(g.key_waiting() && g.can_confirm());
        assert_eq!(g.confirm(), Some(vec![1; 32]));
        assert!(!g.key_waiting() && !g.can_confirm());
    }

    #[test]
    fn a_key_before_the_question_is_not_held() {
        let mut g = JoinGate::new();
        assert_eq!(g.new_key(vec![1; 32]), None);
        assert!(!g.key_waiting());
        g.pairing_waits();
        assert_eq!(g.confirm(), None);
    }
}
