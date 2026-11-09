//! The wire against tests/remote-vectors/vectors.json, written by RemoteVectorsTests.swift: every message decodes and encodes to
//! the same JSON value, every binary packet to the same bytes, and the handshake comes out byte for byte from the fixed keys.

use blurt_remote::crypto::{self, PhoneHandshake, SealIn, SealOut};
use blurt_remote::packets::{self, FrameReader, PointerPacket, VideoPacket};
use blurt_remote::pairing::Pairing;
use blurt_remote::relay;
use blurt_remote::wire::{Crop, ToMac, ToPhone};
use serde_json::Value;

fn vectors() -> Value {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/remote-vectors/vectors.json");
    serde_json::from_slice(&std::fs::read(&p).expect("vectors.json")).expect("JSON")
}

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn key32(s: &str) -> [u8; 32] {
    unhex(s).try_into().unwrap()
}

#[test]
fn version() {
    assert_eq!(vectors()["version"], crypto::VERSION);
}

#[test]
fn every_message_to_the_host() {
    let v = vectors();
    let list = v["toMac"].as_array().unwrap();
    assert_eq!(list.len(), 38);
    for e in list {
        let name = e["name"].as_str().unwrap();
        let m = ToMac::from_json(&e["json"]).unwrap_or_else(|| panic!("{name} doesn't decode"));
        assert_eq!(m.to_json(), e["json"], "{name} encodes differently");
        // through bytes too
        assert_eq!(ToMac::decode(&m.encode()), Some(m), "{name}");
    }
}

#[test]
fn every_message_to_the_phone() {
    let v = vectors();
    let list = v["toPhone"].as_array().unwrap();
    assert_eq!(list.len(), 25);
    for e in list {
        let name = e["name"].as_str().unwrap();
        let m = ToPhone::from_json(&e["json"]).unwrap_or_else(|| panic!("{name} doesn't decode"));
        assert_eq!(m.to_json(), e["json"], "{name} encodes differently");
        assert_eq!(ToPhone::decode(&m.encode()), Some(m), "{name}");
    }
}

#[test]
fn pointer_packets() {
    for e in vectors()["pointer"].as_array().unwrap() {
        let b = unhex(e["hex"].as_str().unwrap());
        let p = PointerPacket::decode(&b).unwrap_or_else(|| panic!("{}", e["name"]));
        assert_eq!(hex(&p.encode()), e["hex"].as_str().unwrap());
    }
    assert_eq!(PointerPacket::decode(&unhex("000000c03f000010c0")), Some(PointerPacket::Move { dx: 1.5, dy: -2.25 }));
}

#[test]
fn cursor() {
    let v = vectors();
    let c = &v["cursor"];
    assert_eq!(hex(&packets::cursor(c["x"].as_f64().unwrap() as f32, c["y"].as_f64().unwrap() as f32)), c["hex"].as_str().unwrap());
}

#[test]
fn video_payload_and_pieces() {
    let v = vectors();
    let p = &v["video"]["payload"];
    let crop = Crop {
        x: p["crop"]["x"].as_f64().unwrap() as f32,
        y: p["crop"]["y"].as_f64().unwrap() as f32,
        w: p["crop"]["w"].as_f64().unwrap() as f32,
        h: p["crop"]["h"].as_f64().unwrap() as f32,
    };
    let sets: Vec<Vec<u8>> = p["parameterSets"].as_array().unwrap().iter().map(|s| unhex(s.as_str().unwrap())).collect();
    let picture = unhex(p["picture"].as_str().unwrap());
    let packed = packets::pack_payload(crop, &sets, &picture);
    assert_eq!(hex(&packed), p["hex"].as_str().unwrap());
    let back = packets::unpack_payload(&packed).unwrap();
    assert_eq!((back.crop, back.parameter_sets, back.picture), (crop, sets, picture));

    let k = &v["video"]["packets"];
    let pieces = VideoPacket::split(
        &packed,
        k["frame"].as_u64().unwrap() as u32,
        k["keyframe"].as_bool().unwrap(),
        k["captured"].as_f64().unwrap(),
        k["pieceSize"].as_u64().unwrap() as usize,
    );
    let want: Vec<&str> = k["hex"].as_array().unwrap().iter().map(|h| h.as_str().unwrap()).collect();
    assert_eq!(pieces.iter().map(|p| hex(&p.encode())).collect::<Vec<_>>(), want);
    let mut a = packets::VideoAssembler::new();
    let whole: Vec<_> = want.iter().filter_map(|h| a.add(VideoPacket::decode(&unhex(h)).unwrap())).collect();
    assert_eq!(whole.len(), 1);
    assert_eq!(whole[0].data, packed);
    assert_eq!(whole[0].captured, 1234.5);
}

#[test]
fn the_handshake_byte_for_byte() {
    let v = vectors();
    let h = &v["handshake"];
    let paired = unhex(h["paired"].as_str().unwrap());
    let phone_priv = key32(h["phoneEphPrivate"].as_str().unwrap());
    let host_priv = key32(h["macEphPrivate"].as_str().unwrap());
    let nonce = key32(h["nonce"].as_str().unwrap());
    let id = h["id"].as_str().unwrap();

    assert_eq!(hex(&crypto::public_key(phone_priv)), h["phoneEph"].as_str().unwrap());
    assert_eq!(hex(&crypto::public_key(host_priv)), h["macEph"].as_str().unwrap());
    let (_, secret) = crypto::x25519(host_priv, &unhex(h["phoneEph"].as_str().unwrap())).unwrap();
    assert_eq!(hex(&secret), h["sharedSecret"].as_str().unwrap());
    let t = crypto::transcript(id, &unhex(h["phoneEph"].as_str().unwrap()), &unhex(h["macEph"].as_str().unwrap()));
    assert_eq!(hex(&t), h["transcript"].as_str().unwrap());
    assert_eq!(hex(&crypto::proof(&paired, &t)), h["proof"].as_str().unwrap());
    let (to_host, to_phone) = crypto::session_keys(&secret, &paired, &t);
    assert_eq!(hex(&to_host), h["keyToMac"].as_str().unwrap());
    assert_eq!(hex(&to_phone), h["keyToPhone"].as_str().unwrap());
    assert_eq!(hex(&crypto::commitment(&nonce)), h["commitment"].as_str().unwrap());
    assert_eq!(crypto::check(&t, &nonce), h["check"].as_str().unwrap());

    // the hellos, as JSON values
    let phone = PhoneHandshake::with(id, &paired, phone_priv, nonce);
    let hello: Value = serde_json::from_slice(&phone.hello()).unwrap();
    assert_eq!(hello, h["phoneHello"]);
    let answer = crypto::answer(&phone.hello(), host_priv, |asked| (asked == id).then(|| paired.clone()));
    let reply: Value = serde_json::from_slice(&answer.reply).unwrap();
    assert_eq!(reply, h["macHello"]);
    let refused: Value = serde_json::from_slice(&crypto::refusal("not_paired")).unwrap();
    assert_eq!(refused, h["macHelloRefused"]);
    let mut host = answer.keys.unwrap();
    assert_eq!(host.transcript, t);
    assert_eq!(host.check_revealing(&nonce).as_deref(), h["check"].as_str());
    let mut phone_keys = phone.finish(&answer.reply).unwrap();

    // the stream, phone → host: sealed from the plain bytes, and opened back
    let mut out = SealOut::new(&to_host);
    for (i, f) in h["tcpPhoneToMac"].as_array().unwrap().iter().enumerate() {
        let plain = unhex(f["plain"].as_str().unwrap());
        let sealed = out.seal(&plain);
        assert_eq!(hex(&sealed), f["sealed"].as_str().unwrap(), "frame {i}");
        if let Some(framed) = f["framed"].as_str() {
            assert_eq!(hex(&FrameReader::framed(&sealed)), framed);
        }
        assert_eq!(phone_keys.out.seal(&plain), sealed);
        assert_eq!(host.inn.open(&sealed), Some(plain.clone()));
        if i == 0 {
            // the first sealed message is the hello that reveals the nonce
            match ToMac::decode(&plain[1..]) {
                Some(ToMac::Hello { device, mic_on_phone, nonce: Some(n) }) => {
                    assert_eq!((device.as_str(), mic_on_phone, n.as_slice()), ("Pixel", true, &nonce[..]));
                }
                other => panic!("not the hello: {other:?}"),
            }
        }
    }
    // host → phone
    for f in h["tcpMacToPhone"].as_array().unwrap() {
        let plain = unhex(f["plain"].as_str().unwrap());
        let sealed = host.out.seal(&plain);
        assert_eq!(hex(&sealed), f["sealed"].as_str().unwrap());
        assert_eq!(phone_keys.inn.open(&sealed), Some(plain.clone()));
        assert_eq!(ToPhone::decode(&plain[1..]), Some(ToPhone::UdpOk));
    }
    // datagrams, phone → host
    let mut udp_in = SealIn::new(&to_host);
    for f in h["udpPhoneToMac"].as_array().unwrap() {
        let plain = unhex(f["plain"].as_str().unwrap());
        let sealed = phone_keys.out.seal_packet(&plain, f["session"].as_u64().unwrap() as u32);
        assert_eq!(hex(&sealed), f["sealed"].as_str().unwrap(), "counter {}", f["counter"]);
        assert_eq!(crypto::session_of_packet(&sealed), Some(7));
        assert_eq!(udp_in.open_packet(&sealed), Some(plain));
    }
}

#[test]
fn relay_room() {
    let v = vectors();
    let r = &v["relayRoom"];
    assert_eq!(relay::room(&unhex(r["paired"].as_str().unwrap())), r["room"].as_str().unwrap());
}

#[test]
fn pairing_url() {
    let v = vectors();
    let p = Pairing {
        host_id: "host-id-1".into(),
        device_id: "device-id-1".into(),
        key: unhex(v["handshake"]["paired"].as_str().unwrap()),
        name: "Studio PC".into(),
        port: 50123,
        addresses: vec!["192.168.1.20".into(), "fe80::1".into()],
        relay: Some("wss://relay.example.com".into()),
    };
    assert_eq!(p.url(), v["pairingURL"].as_str().unwrap());
    assert_eq!(Pairing::parse(v["pairingURL"].as_str().unwrap()), Some(p));
}
