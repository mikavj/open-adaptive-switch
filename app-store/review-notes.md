# App Review notes

Paste the block below into the **App Review Information > Notes** field in
App Store Connect when you submit. It tells the reviewer the app is a
companion to DIY hardware and points them to the demo video, which is the
single most important thing for getting a hardware app approved.

Before you submit: upload your screen recording somewhere the reviewer can
watch it (an unlisted YouTube link, or a shared iCloud/Dropbox link) and
paste that link where marked. Keep it reachable until the app is approved.

---

This app is a configuration companion for Open Adaptive Switch, an
open-source, do-it-yourself Bluetooth accessibility switch that a person
builds themselves from a Seeed XIAO nRF52840 board, a button, and a small
battery. The project is at https://github.com/mikavj/open-adaptive-switch

Because the app talks to that physical hardware over Bluetooth, its main
screens only appear once a switch is connected, and you will not have one
during review. So the "Switches nearby" screen will stay empty on your
device. This is expected, not a bug.

To see the full app working with a real switch, please watch this short
demo video: [PASTE YOUR VIDEO LINK HERE]

The video shows connecting to a switch, changing the key it sends, adjusting
the battery and settings screens, and the firmware-update screen.

What the app does: it lets a caregiver set which key the switch sends to iOS
Switch Control, choose single/tap-hold/multi-press modes, set a sleep timer,
rename the switch, pick a display color, watch the battery, and install
firmware updates over Bluetooth.

The app has no accounts and collects no data. It uses Bluetooth to reach the
switch and contacts GitHub only to check for firmware updates. Privacy
policy: https://mikavj.github.io/open-adaptive-switch/privacy.html

The app is free and open-source (GPL-3.0 with an added App Store
distribution permission; see APP-STORE-EXCEPTION.txt in the repository).

Thank you for reviewing an accessibility project.

---

## Fields around it in App Store Connect

- Sign-in required: No (leave the demo-account fields empty).
- Contact info: your name, phone, and email.
- Attachment: optionally attach the same demo video file here as well as
  linking it in the notes.
