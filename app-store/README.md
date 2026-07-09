# App Store materials

Everything needed to fill in the App Store Connect listing.

- `listing.md` - name, subtitle, keywords, promotional text, description, URLs.
- `review-notes.md` - text to paste into App Review notes (fill in your
  demo video link first).
- `../APP-STORE-EXCEPTION.txt` - the GPL section 7 permission that allows
  App Store distribution.
- `../docs/privacy.html` - the privacy policy, served at
  https://mikavj.github.io/open-adaptive-switch/privacy.html once pushed.

## Screenshots

Upload these to the matching size slots in App Store Connect. Both sizes
are on Apple's current accepted list.

- `screenshots-iphone/` - iPhone 6.5" (1284x2778), portrait. Real captures
  from the app on iPhone, showing the actual screens.
- `screenshots-ipad/` - iPad 13" (2752x2064), landscape. Marketing images
  built around the same real captures. The iPad simulator has no
  Bluetooth, so the app's connected screens can't be captured natively on
  iPad; these promotional images show the real interface instead, which is
  standard App Store practice for a universal app.

The raw source captures (and the two plain iPad simulator screens) are in
`../app/screenshots/`. The screen-recording there is your demo video for
the review notes.
