# Blurt for iPhone and iPad

App Store bundle ID `work.blurt.remote`. The current iOS project version is 1.2.1, build 2. The product page can use English (U.S.) as its primary language with Simplified Chinese as a localization.

## English (U.S.)

- Name — Blurt Remote
- Subtitle — Trackpad, shortcuts and voice
- Keywords — remote,trackpad,keyboard,desktop,dictation,screen,mirror,mouse,shortcuts,controller
- Support URL — https://blurt.work/support/
- Privacy Policy URL — https://blurt.work/privacy/
- Marketing URL — https://blurt.work/en/

### Description

Control your computer from your iPhone or iPad. Blurt puts a trackpad, customizable shortcuts, a live view of your desktop and a microphone in your hands.

- See your desktop live. Tap, scroll, drag and pinch to zoom in on what you’re working on.
- Use the computer keyboard or arrange your own shortcut pages.
- Send photos and files between your devices. Get copied items from your computer on request.
- Dictate into your computer. Use your iPhone or iPad microphone or choose the microphone on the paired computer.

Install the Blurt companion app on a Mac, Windows or Linux computer. Open Remote Control, choose Add Device and scan the QR code in the mobile app. Confirm that the pairing code matches on both devices. No Blurt account is required.

## 简体中文

- 名称 — 口喷鸡远程控制
- 副标题 — 触控板、快捷键和语音听写
- 关键词 — 远程控制,桌面共享,触控板,语音听写,快捷键,电脑投屏,鼠标
- 技术支持网址 — https://blurt.work/support/#zh-Hans
- 隐私政策网址 — https://blurt.work/privacy/#zh-Hans
- 营销网址 — https://blurt.work/

### 描述

用 iPhone 或 iPad 控制你的电脑。口喷鸡把触控板、自定义快捷键、实时桌面画面和麦克风放在你手边。

- 看电脑的实时画面，轻点、滚动和拖动，双指捏合就能放大细节。
- 使用电脑键盘，或自定义快捷键和分页。
- 在设备间传输照片和文件，也可获取电脑上拷贝的内容。
- 对着 iPhone 或 iPad 听写，把文字输到电脑上，也可以改用电脑的麦克风。

先在 Mac、Windows 或 Linux 电脑上安装口喷鸡桌面端。打开「远程控制」，选择「添加设备」，再用移动端扫描二维码。在两端确认配对数字一致。无需注册账号。

## App Review notes

Blurt Remote lets people control their own computers from an iPhone or iPad. It is for people who need a trackpad, computer keyboard, live desktop view, microphone, or a way to move files when they are away from the computer's keyboard. The app is free and has no account, sign-in, in-app purchases, public content feed, or user-to-user messaging.

Requirements: a supported iPhone or iPad and a Mac, Windows, or Linux computer running the free Blurt companion. No account or credentials are required. Download the Mac companion from https://github.com/AGIHunt/blurt/releases/tag/v1.2.1 or the Windows or Linux companion from https://github.com/AGIHunt/blurt/releases/tag/v1.2.0.

1. Connect both devices to the same Wi-Fi network. On the computer, open Blurt and select Remote Control, then Add Device. On macOS, allow Local Network, Accessibility, and Screen & System Audio Recording when prompted. On the phone or tablet, launch Blurt, select Scan Code, and allow Camera and Local Network access.
2. Scan the QR code from the computer. Check that the numbers match, then confirm on both devices. Use the trackpad or Computer keyboard to move the pointer and type in an open text editor. Tap the Display button to see the desktop and pinch to zoom.
3. To test dictation, place the computer's cursor in a text field and tap the microphone button in Blurt. Allow microphone access if using the mobile microphone. The companion handles speech recognition. On desktop, use the configured local speech recognizer to test without a cloud account.
4. To test file transfer, open Transfer on the phone and choose Send Files. Select any small file in Files. The computer saves it in Downloads/Blurt. To test the reverse direction, copy a sample file on the computer and use Get Copied Items in Transfer. The app also accepts explicitly shared files through the iOS Share sheet. No supplied sample file is required.

External services: Blurt uses the user's computer as the companion endpoint. The same-network review flow connects directly and needs no cloud service. For remote networks, the optional public connection service uses Cloudflare Workers at meet.blurt.work and a Tencent Cloud relay at relay.blurt.work if direct connection fails. The relay forwards encrypted session traffic. Users can set up their own relay. Any optional cloud speech or text services are configured separately on the desktop, and are unnecessary for review on a local network.

The same features are available throughout the selected storefronts. Connection paths depend on network reachability, and dictation depends on the companion's settings. The app supplies no licensed media or regulated services.

## App Store Connect

- Platform — iOS with iPhone and iPad in the same app record.
- Availability — choose Specific Countries or Regions, select the other intended storefronts and leave China mainland deselected. Simplified Chinese localization is independent of storefront availability.
- Screenshots — upload the appropriate localized sets to iPhone Dynamic Island medium display (1206 × 2622), iPhone Dynamic Island large display (1320 × 2868) and iPad 13-inch display (2064 × 2752).
- App Privacy — use the mobile privacy policy and the connection-service implementation when answering the questionnaire. The public connection service retains the latest host disconnect and sleep status per opaque room. Desktop dictation services are selected separately on the computer.
- Attach a screen recording from a physical device running the latest public OS. Begin on the Home Screen and launch Blurt, then show pairing, live view, pointer and keyboard input, dictation, and transfer with sample content. Keep the App Review contact details with the submission.
