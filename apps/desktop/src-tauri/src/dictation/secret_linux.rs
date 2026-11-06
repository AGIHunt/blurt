//! The cloud key on Linux: the Secret Service (GNOME Keyring, KWallet's bridge), Credential Manager's counterpart.
//! Items carry `application = blurt`, `service = <id>`; the "plain" session (the bus is the user's own) and the
//! default collection, which the login keyring unlocks at sign-in. Without a Secret Service (a bare window manager):
//! a 0600 file under `~/.blurt/secrets/`, said so in the log.

use std::collections::HashMap;
use std::time::Duration;

use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const BUS: &str = "org.freedesktop.secrets";
const SERVICE: &str = "/org/freedesktop/secrets";

type Secret = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);

fn attrs(id: &str) -> HashMap<&'static str, String> {
    HashMap::from([("application", "blurt".to_string()), ("service", id.to_string())])
}

async fn conn() -> zbus::Result<(zbus::Connection, OwnedObjectPath)> {
    let c = zbus::Connection::session().await?;
    let (_out, session): (OwnedValue, OwnedObjectPath) = c
        .call_method(Some(BUS), SERVICE, Some("org.freedesktop.Secret.Service"), "OpenSession", &("plain", Value::from("")))
        .await?
        .body()
        .deserialize()?;
    Ok((c, session))
}

async fn find(c: &zbus::Connection, id: &str) -> zbus::Result<Vec<OwnedObjectPath>> {
    let (unlocked, locked): (Vec<OwnedObjectPath>, Vec<OwnedObjectPath>) = c
        .call_method(Some(BUS), SERVICE, Some("org.freedesktop.Secret.Service"), "SearchItems", &(attrs(id),))
        .await?
        .body()
        .deserialize()?;
    if !locked.is_empty() {
        // a locked keyring: ask once (GNOME shows its own unlock prompt)
        let _ = c.call_method(Some(BUS), SERVICE, Some("org.freedesktop.Secret.Service"), "Unlock", &(locked.clone(),)).await;
    }
    Ok(unlocked.into_iter().chain(locked).collect())
}

async fn get(id: String) -> zbus::Result<Option<String>> {
    let (c, session) = conn().await?;
    for item in find(&c, &id).await? {
        let r: zbus::Result<Secret> = async {
            c.call_method(Some(BUS), item.as_str(), Some("org.freedesktop.Secret.Item"), "GetSecret", &(&session,))
                .await?
                .body()
                .deserialize()
        }
        .await;
        if let Ok((_, _, value, _)) = r {
            if let Ok(s) = String::from_utf8(value) {
                if !s.is_empty() {
                    return Ok(Some(s));
                }
            }
        }
    }
    Ok(None)
}

async fn put(id: String, key: String) -> zbus::Result<()> {
    let (c, session) = conn().await?;
    let coll: OwnedObjectPath = c
        .call_method(Some(BUS), SERVICE, Some("org.freedesktop.Secret.Service"), "ReadAlias", &("default",))
        .await?
        .body()
        .deserialize()?;
    if coll.as_str() == "/" {
        return Err(zbus::Error::Failure("no default keyring".into()));
    }
    let mut props: HashMap<&str, Value> = HashMap::new();
    props.insert("org.freedesktop.Secret.Item.Label", Value::from(format!("Blurt cloud key ({id})")));
    props.insert("org.freedesktop.Secret.Item.Attributes", Value::from(attrs(&id)));
    let secret: Secret = (session, vec![], key.into_bytes(), "text/plain".into());
    c.call_method(Some(BUS), coll.as_str(), Some("org.freedesktop.Secret.Collection"), "CreateItem", &(props, secret, true))
        .await?;
    Ok(())
}

async fn delete(id: String) -> zbus::Result<()> {
    let (c, _) = conn().await?;
    for item in find(&c, &id).await? {
        let _ = c.call_method(Some(BUS), item.as_str(), Some("org.freedesktop.Secret.Item"), "Delete", &()).await;
    }
    Ok(())
}

fn file(id: &str) -> std::path::PathBuf {
    crate::paths::blurt_home().join("secrets").join(id.replace(['/', '\\'], "_"))
}

pub fn key(id: &str) -> Option<String> {
    match super::insert_linux::block(Duration::from_secs(5), get(id.to_string())) {
        Some(Ok(Some(k))) => Some(k),
        Some(Ok(None)) => None,
        _ => std::fs::read_to_string(file(id)).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
    }
}

pub fn store_key(id: &str, k: &str) -> Result<(), String> {
    match super::insert_linux::block(Duration::from_secs(30), put(id.to_string(), k.to_string())) {
        Some(Ok(())) => {
            let _ = std::fs::remove_file(file(id));
            Ok(())
        }
        other => {
            eprintln!("blurt: no Secret Service ({other:?}): the key goes in a private file");
            use std::os::unix::fs::OpenOptionsExt;
            let p = file(id);
            if let Some(d) = p.parent() {
                std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
            }
            use std::io::Write;
            let mut f = std::fs::OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(&p).map_err(|e| e.to_string())?;
            f.write_all(k.as_bytes()).map_err(|e| e.to_string())
        }
    }
}

pub fn delete_key(id: &str) {
    let _ = super::insert_linux::block(Duration::from_secs(5), delete(id.to_string()));
    let _ = std::fs::remove_file(file(id));
}
