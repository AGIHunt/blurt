# Sensing with the Mac's (and iPhone's) own hardware: what's reachable, what's been done, what to try

Follows the sonar pilot in `silent-dictation-acoustic.md`. That pilot found laptop-distance lip reading with the speakers and mono mic is a no-go: one range axis at 3 cm resolution and no angle. Hand gestures and gross mouth movement work.

## Raw signals on this Mac (Mac17,6, M5 Max, macOS 26), checked locally

Checked without root, with SIP on. Tools are in `tools/silent-dictation/acoustic/` (`audio_devices.swift`, `sensors_probe.swift`).

| Signal | What the hardware has | What we can get |
| --- | --- | --- |
| Mic array | `IOPAudioLPMicDevice` ("lpai", the always-on Siri path): **3 channels, 16 kHz, 24-bit**, with "historic data supported" | Not in CoreAudio. Its user client needs the private entitlement `com.apple.private.aop-audio.user-access`, which only `coreaudiod` holds. CoreAudio gives one beamformed channel, 44.1-96 kHz. |
| Speakers | 6 drivers | Stereo only |
| iPhone mics (Continuity) | Appear as CoreAudio input devices (e.g. "<iPhone name> microphone", 1 ch, 48 kHz) | Usable as a second, remote mic on its own clock |
| AirPods Pro | Mic over Bluetooth, plus a head-motion IMU | Mic is band-limited. Motion is available through `CMHeadphoneMotionManager` (not tested yet). |
| Lid angle | Sensor page 0x20, usage 0x8A | Readable (feature report 1, got 122°) |
| Accelerometer, gyro, ambient light | SPU HID, vendor page 0xFF00, usages 3, 9, 4, 8 ms interval | Devices open, but no reports arrive. `AppleSPUHIDDriver` user client type 2 opens without root, which is a lead. |

More from a deeper read-only pass:
- **Mic path:** the main mic path goes through Apple's Exclaves secure layer (`IOExclaveProxy = Yes`), so even with SIP off a kernel extension may not see raw mic data.
- **Speakers:** the speaker I2S link is 6 channels plus 12 channels of amplifier voltage/current feedback.
- **Hidden switches:** `MacAudio.driver` has strings such as `showSpeakerTapStream` and `_diagnosticMode`, gated by private entitlements. None of this was tested.
- **Asahi Linux:** it exposes 3 raw mics at 48 kHz (a 2 cm triangle) and 6 raw speaker channels on M1/M2, but it has no M5 support.
- **IMU and light sensor:** [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) reads the IMU (about 800 Hz native) and the light sensor (lux plus 4 spectral channels). It uses the same enable sequence as `sensors_probe.swift` but runs with `sudo`, and it is reported working on base M5. Here the drivers still show `ReportInterval = 0` after a non-root set.
- **Trackpad:** raw multitouch (position, capacitance, force) is readable without root through MultitouchSupport ([OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport)).

Bypassing the entitlement would mean turning off SIP and AMFI so a self-signed binary can claim a private entitlement. That's possible on a personal machine, but it lowers the whole system's security, so it's not done here without the user's explicit decision.

## Baselines: what's already been shown

These are reference points, not targets. Source links are in the research notes the survey agents returned; the main ones are below.

| Area | Best known result | Hardware and distance |
| --- | --- | --- |
| Finger tracking | LLAP 3.5 mm 1D, FingerIO 8 mm 2D | Phone, 20-50 cm |
| Breathing / apnea | ApneaApp 95-99% vs polysomnography; LASense 6 m | Phone or speaker, 1-6 m |
| Heartbeat by sonar | Inter-beat error 28 ms (Commun. Biol. 2021) | Smart speaker with mic array |
| Silent speech, acoustic | EchoSpeech 4.5% WER, 31 commands; SoniSpeech 33.7% WER, open vocabulary | Glasses, a few cm |
| Speech enhancement from ultrasound | UltraSE +6 dB SNR | Phone a few cm from mouth |
| Keystrokes | Passive audio 95% on a MacBook Pro; MacBook IMU 89-97% per character ("Et Tu, MacBook?", 2026, via an IOKit bug) | Laptop |
| Jaw IMU silent speech | MuteIt 94.8% on 100 words, using a second IMU to cancel head motion | Worn |
| Lip reading, video | LRS3 visual-only about 13-25% WER; Mandarin CNVSRC about 30% CER | Camera |
| Whispered ASR | Whisper zero-shot 18.8% WER on wTIMIT | Mic |

Nobody has published active sonar on a MacBook for vital signs or speech, raw MacBook mic-array work, or acoustic silent speech in Mandarin.

## Directions, building on the baselines

Each direction lists what is new, what it needs, and the first test.

1. **AirPods head motion cancels head motion in the sonar.**
   - *What's new:* this is MuteIt's two-IMU idea, but with the earbuds the user already wears. `CMHeadphoneMotionManager` gives head orientation with no camera. It goes straight at the pilot's failure (mouthing while nodding, AUC 0.49).
   - *Needs:* nothing new; no root.
   - *First test:* rerun test 3 with AirPods in, regress head motion out of the echoes, and see whether mouthing-while-nodding vs nodding passes 0.75.
2. **"Is it really me talking" gate for Blurt.**
   - *What's new:* sonar mouth movement plus voice activity. Speech from someone nearby, or from another app, gets rejected even when it matches the user's voice. This complements the voiceprint gate with a physical check. Detection already works at 45 cm with a still head (0.98).
   - *First test:* the user dictates, or stays silent while someone else speaks nearby, or plays a recording of their own voice. Score frame-level AUC.
3. **Hands-free start and pre-roll.**
   - *What's new:* lips part about 100-300 ms before sound. Sonar sees leaning in, a hand raised, or the mouth opening, then starts dictation with the audio before the onset already buffered. No hotkey, no camera.
   - *First test:* measure the gap between sonar mouth onset and voice onset over 50 utterances.
4. **Multistatic sonar with the iPhone.**
   - *What's new:* the Mac's speakers transmit, and the iPhone records at 48 kHz from another angle, through Blurt Remote or the Continuity mic, sitting on the desk or held near the mouth. A second viewpoint gives angle information, which one mono mic cannot. Clock drift is solved from the periodic probe's direct path. Sweeping the phone by hand, with the Core Motion trajectory, makes a real synthetic aperture (like AIM, but with a fixed transmitter on the laptop).
   - *First test:* check that the iPhone's mic passes 17.5-23 kHz, then track a hand from two views.
5. **iPhone near-field silent speech in Mandarin.**
   - *What's new:* TrueDepth's 52 blendshapes at 60 Hz, plus iPhone sonar at about 5 cm, plus an LLM decoder. Nobody has published silent speech from ARKit blendshapes, and acoustic silent speech has not been done in Mandarin.
   - *Needs:* the existing Blurt Remote app.
6. **Desk as a touch surface.**
   - *What's new:* taps on the desk beside the laptop. The IMU (with sudo, about 800 Hz) gives the exact tap time; the sonar gives where the hand is. Together they make virtual buttons or a scroll strip on the desk. Only a hobby page exists (PalmEcho), with no results.
7. **Wellbeing at the desk with no camera.**
   - *What's new:* breathing from sonar, heartbeat from the IMU (wrists on the palm rest) or trackpad force, and posture and distance from sonar. Uses: break and posture reminders, breath-paced focus, and noticing when dictation is held while the user isn't breathing normally. All of these are unvalidated on laptops.
8. **Screen as a light source.**
   - *What's new:* flicker a small part of the screen in a code and read it back with the 4-channel light sensor (with sudo), for camera-free proximity and presence. Shown only slowly on Android so far.

Needs root, SIP off and AMFI off, so not planned: the raw 3-mic array (direction of arrival, 2D sonar, better whisper pickup) and the speaker feedback channels (each driver as its own receiver). Both are also behind Exclaves, so they may not work even then.

## Direction 1, first check: can a measured head pose be removed from the sonar? (camera pose as a stand-in, block 3 data)

`score_headcomp.py` learns a ridge map from head-motion signals to each echo bin's phase displacement. The signals are position, size, roll, pitch, their derivatives, and lags of ±20 frames. The map is learned on head-only trials of the other rounds and subtracted from the held-out round. Sonar Lab now also logs AirPods head motion (`headmotion.csv`, about 47 Hz, on the same uptime clock), and the `headpods` block is ready for that test.

| | mouth+head vs nod | vs shake | vs sway | silent vs still |
| --- | --- | --- | --- | --- |
| No compensation | 0.57 | 0.88 | 0.61 | 0.94 |
| Camera head pose removed | 0.57 | 0.16 | 0.55 | 0.92 |
| Control: pose shifted half a trial | 0.57 | 0.18 | 0.67 | 0.94 |

On held-out trials, camera pose explains about 0% of the echo motion (median R² between -0.05 and 0.04 over three ridge strengths), whether aligned or shifted. A first version that fitted inside each trial "explained" 70% even with shifted pose. That was overfitting, and it was dropped.

**Reading.** A gentle nod moves the face about 1 cm, which is more than half the probe wavelength (1.7 cm). So each 3 cm cell's echo is many scatterers interfering, and it changes nonlinearly with motion. MuteIt-style linear cancellation works for an IMU, which measures the rigid motion itself, but not for speckle-like echoes. AirPods measure the head better than the camera does, but they don't remove this nonlinearity, so the odds for test 3b are low. Directions 2 and 3 don't depend on it: speaking aloud with the head roughly still, which sonar already handles.
