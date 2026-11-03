//! The word list (`$BLURT_HOME/dictation/vocabulary.json`, dictation_vocab.py's file; the Mac's DictationVocabulary):
//! names and terms the speech model is biased toward and polish spells exactly. Every dictation request sends
//! `"vocab": true` (the speech server reads the file) and polish gets the active terms (engine.rs `vocab`). This is
//! the editing the Words list needs — add, remove (kept as removed, so a suggestion of it doesn't come back), rename,
//! accept a suggestion — on the file's own shape: a term is {"term", "sounds_like", "source", "state", "added",
//! "hits", "seen"}; only `active` ones are used. Pure: tests below.

use serde_json::{json, Value};

/// The file's format (dictation_vocab.py SCHEMA).
pub const SCHEMA: i64 = 2;

fn terms_mut(doc: &mut Value) -> &mut Vec<Value> {
    if !doc.is_object() {
        *doc = json!({});
    }
    if doc.get("schema").is_none() {
        doc["schema"] = json!(SCHEMA);
    }
    if !doc["terms"].is_array() {
        doc["terms"] = json!([]);
    }
    doc["terms"].as_array_mut().unwrap()
}

fn same(a: &str, b: &str) -> bool {
    a.trim().to_lowercase() == b.trim().to_lowercase()
}

/// The terms in use: active ones (a term without a state is active, as the script reads it).
pub fn active(doc: &Value) -> Vec<Value> {
    doc["terms"]
        .as_array()
        .map(|a| a.iter().filter(|t| t["state"].as_str().unwrap_or("active") == "active").cloned().collect())
        .unwrap_or_default()
}

/// Every term but the removed and rejected ones, for the list (suggestions included, marked by their state).
pub fn listed(doc: &Value) -> Vec<Value> {
    doc["terms"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|t| !matches!(t["state"].as_str(), Some("removed" | "rejected")))
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

/// Add `term` (typed by the user: active at once; "a, b, c" adds each). One already there comes back active.
/// → how many were added or brought back.
pub fn add(doc: &mut Value, typed: &str, now: &str) -> usize {
    let mut n = 0;
    for term in typed.split([',', '，', '、', '\n']).map(str::trim).filter(|t| !t.is_empty()) {
        let terms = terms_mut(doc);
        if let Some(t) = terms.iter_mut().find(|t| same(t["term"].as_str().unwrap_or(""), term)) {
            if t["state"].as_str() != Some("active") {
                t["state"] = json!("active");
                n += 1;
            }
            continue;
        }
        terms.push(json!({"term": term, "sounds_like": [], "source": "manual", "state": "active", "added": now, "hits": 0, "seen": 0}));
        n += 1;
    }
    n
}

/// Remove `term`: kept as removed (so it isn't suggested again). → whether it was there.
pub fn remove(doc: &mut Value, term: &str) -> bool {
    set_state(doc, term, "removed")
}

/// A suggested term accepted (active) or turned down (rejected), or one removed brought back (Undo).
pub fn set_state(doc: &mut Value, term: &str, state: &str) -> bool {
    match terms_mut(doc).iter_mut().find(|t| same(t["term"].as_str().unwrap_or(""), term)) {
        Some(t) => {
            t["state"] = json!(state);
            true
        }
        None => false,
    }
}

/// Rename `from` to `to` (its sounds-like and hits stay). False when `from` isn't there or `to` is another term.
pub fn rename(doc: &mut Value, from: &str, to: &str) -> bool {
    let to = to.trim();
    if to.is_empty() {
        return false;
    }
    let terms = terms_mut(doc);
    if !same(from, to) && terms.iter().any(|t| same(t["term"].as_str().unwrap_or(""), to) && t["state"].as_str() != Some("removed")) {
        return false;
    }
    match terms.iter_mut().find(|t| same(t["term"].as_str().unwrap_or(""), from)) {
        Some(t) => {
            t["term"] = json!(to);
            true
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_remove_rename() {
        let mut d = json!({});
        assert_eq!(add(&mut d, "Blurt, 豆包、Typeless", "2026-11-02"), 3);
        assert_eq!(d["schema"], SCHEMA);
        assert_eq!(active(&d).len(), 3);
        // already there: nothing new
        assert_eq!(add(&mut d, "blurt", "x"), 0);
        assert!(remove(&mut d, "豆包"));
        assert_eq!(active(&d).len(), 2);
        assert_eq!(listed(&d).len(), 2);
        // added again: back, not doubled
        assert_eq!(add(&mut d, "豆包", "x"), 1);
        assert_eq!(d["terms"].as_array().unwrap().len(), 3);
        assert!(rename(&mut d, "Typeless", "Typeless AI"));
        assert!(!rename(&mut d, "Typeless AI", "Blurt")); // another term's name
        assert!(rename(&mut d, "blurt", "Blurt")); // its own, re-cased
        assert!(!rename(&mut d, "nope", "x"));
        assert!(!remove(&mut d, "nope"));
    }

    #[test]
    fn suggestions_are_listed_not_used() {
        let mut d = json!({"terms": [{"term": "GIF", "state": "suggested"}, {"term": "Peep"}]});
        assert_eq!(active(&d).len(), 1); // a term without a state is active
        assert_eq!(listed(&d).len(), 2);
        assert!(set_state(&mut d, "gif", "active"));
        assert_eq!(active(&d).len(), 2);
        assert!(set_state(&mut d, "GIF", "rejected"));
        assert_eq!(listed(&d).len(), 1);
    }
}
