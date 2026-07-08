# QR codes for the config page

Print one of these on the bottom of an enclosure.

- `config-page.svg` / `.png` - points at
  https://mikavj.github.io/open-adaptive-switch/ over plain HTTPS. Works
  with any phone camera. On iOS the page then offers an "Open in Bluefy"
  handoff, since Safari can't do Web Bluetooth. This is the one to print
  by default.
- `config-page-bluefy.svg` / `.png` - encodes
  `bluefy://open?url=...`, which jumps straight into the Bluefy browser
  in one scan. Only useful if Bluefy is already installed; dead end
  otherwise. Optional second sticker for households that use it daily.

An NTAG213 NFC sticker programmed with the plain HTTPS URL (use any NFC
writing app) gives iPhones a tap-to-open version of the same thing.
iPads don't read NFC tags, so keep the QR either way.

Regenerate if the page URL changes (any QR generator works; these were
made with the Python package segno, error level Q).
