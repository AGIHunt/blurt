//! What the host keeps (RemoteServer.swift §identity and devices): the paired phones (`devices.json`), its own settings
//! (`host.json`: id, TCP port, relay, whether the screen may be shown) in the folder the app gives it, and each phone's key in the
//! OS's secret store through `KeyStore`, which the app implements (Windows Credential Manager, Linux Secret Service): the crate
//! stays free of app code. A test host keeps keys in a file instead (`FileKeyStore`), never the user's store.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub trait KeyStore: Send + Sync {
    fn get(&self, id: &str) -> Option<Vec<u8>>;
    fn put(&self, id: &str, key: &[u8]) -> Result<(), String>;
    fn delete(&self, id: &str);
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    /// unix ms
    pub added: i64,
    #[serde(rename = "lastSeen", default, skip_serializing_if = "Option::is_none")]
    pub last_seen: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Settings {
    /// this host's id (the pairing link's `mac`, the DNS-SD TXT `id`): outlives its name and address
    pub id: String,
    /// the TCP port, kept across restarts so a phone's last-known address keeps working (0: any)
    #[serde(default)]
    pub port: u16,
    /// the owner's relay. Missing: never set (a phone may offer the one it knows). `null`: cleared by the owner.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "double_option")]
    pub relay: Option<Option<String>>,
    /// the address came from a phone, not typed here
    #[serde(rename = "relayFromPhone", default)]
    pub relay_from_phone: bool,
    /// a paired phone may ask for the screen
    #[serde(default = "yes")]
    pub screen: bool,
}

fn yes() -> bool {
    true
}

mod double_option {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    pub fn serialize<S: Serializer>(v: &Option<Option<String>>, s: S) -> Result<S::Ok, S::Error> {
        v.as_ref().unwrap_or(&None).serialize(s)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Option<String>>, D::Error> {
        Ok(Some(Option::<String>::deserialize(d)?))
    }
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// The folder and its two files.
pub struct Files {
    dir: PathBuf,
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = path.with_extension("tmp");
    {
        #[cfg(unix)]
        let mut f = {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(&tmp)?
        };
        #[cfg(not(unix))]
        let mut f = std::fs::File::create(&tmp)?;
        std::io::Write::write_all(&mut f, bytes)?;
    }
    std::fs::rename(&tmp, path)
}

impl Files {
    pub fn new(dir: impl Into<PathBuf>) -> Files {
        Files { dir: dir.into() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn devices(&self) -> Vec<Device> {
        std::fs::read(self.dir.join("devices.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save_devices(&self, list: &[Device]) {
        if let Ok(b) = serde_json::to_vec_pretty(list) {
            if let Err(e) = write_private(&self.dir.join("devices.json"), &b) {
                eprintln!("blurt remote: devices.json: {e}");
            }
        }
    }

    /// The settings, made (with a fresh id) the first time.
    pub fn settings(&self) -> Settings {
        if let Some(s) = std::fs::read(self.dir.join("host.json")).ok().and_then(|b| serde_json::from_slice::<Settings>(&b).ok()) {
            if !s.id.is_empty() {
                return s;
            }
        }
        let s = Settings { id: crate::crypto::new_id(), port: 0, relay: None, relay_from_phone: false, screen: true };
        self.save_settings(&s);
        s
    }

    pub fn save_settings(&self, s: &Settings) {
        if let Ok(b) = serde_json::to_vec_pretty(s) {
            if let Err(e) = write_private(&self.dir.join("host.json"), &b) {
                eprintln!("blurt remote: host.json: {e}");
            }
        }
    }
}

/// Keys in a 0600 JSON file: test hosts, and a machine with no secret store.
pub struct FileKeyStore {
    path: PathBuf,
    lock: std::sync::Mutex<()>,
}

impl FileKeyStore {
    pub fn new(path: impl Into<PathBuf>) -> FileKeyStore {
        FileKeyStore { path: path.into(), lock: Default::default() }
    }

    fn read(&self) -> std::collections::BTreeMap<String, String> {
        std::fs::read(&self.path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }
}

impl KeyStore for FileKeyStore {
    fn get(&self, id: &str) -> Option<Vec<u8>> {
        let _g = self.lock.lock().unwrap();
        self.read().get(id).and_then(|k| crate::wire::unb64(k))
    }

    fn put(&self, id: &str, key: &[u8]) -> Result<(), String> {
        let _g = self.lock.lock().unwrap();
        let mut m = self.read();
        m.insert(id.to_string(), crate::wire::b64(key));
        write_private(&self.path, &serde_json::to_vec(&m).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
    }

    fn delete(&self, id: &str) {
        let _g = self.lock.lock().unwrap();
        let mut m = self.read();
        if m.remove(id).is_some() {
            let _ = write_private(&self.path, &serde_json::to_vec(&m).unwrap_or_default());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_keep_unset_apart_from_cleared() {
        let d = std::env::temp_dir().join(format!("blurt-remote-store-{}", crate::crypto::new_id()));
        let f = Files::new(&d);
        let mut s = f.settings();
        assert_eq!(s.relay, None);
        assert!(s.screen);
        let id = s.id.clone();
        s.relay = Some(None);
        f.save_settings(&s);
        assert_eq!(f.settings().relay, Some(None), "cleared stays cleared");
        assert_eq!(f.settings().id, id);
        s.relay = Some(Some("wss://r.example".into()));
        f.save_settings(&s);
        assert_eq!(f.settings().relay, Some(Some("wss://r.example".into())));
        let k = FileKeyStore::new(d.join("keys.json"));
        k.put("a", &[1, 2, 3]).unwrap();
        assert_eq!(k.get("a"), Some(vec![1, 2, 3]));
        k.delete("a");
        assert_eq!(k.get("a"), None);
        f.save_devices(&[Device { id: "x".into(), name: "Pixel".into(), added: 1, last_seen: None }]);
        assert_eq!(f.devices().len(), 1);
        let _ = std::fs::remove_dir_all(d);
    }
}
