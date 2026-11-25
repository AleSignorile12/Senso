# Notes for App Review

Paste the text below into App Store Connect › App Review Information › Notes.

---

Sensow is an accessibility app. It helps blind and low-vision people pour drinks without overflowing the cup.
No account or sign-in is needed.

HOW TO TEST (about 1 minute, with water):
1. Open Sensow. A one-screen introduction appears on first launch: read it and tap Continue. Then tap FILL UP
   and allow microphone access.
2. Place the iPhone on the counter next to an empty glass. Pour water from a bottle or jug into the glass.
3. Sensow detects the pour, speaks the progress at 25, 50, 75 and 85%, and says "Stop! Glass is full" when the
   glass nears the stop level (90% by default). With VoiceOver on, progress is spoken through VoiceOver.
4. Optional: tap Settings at the top right › Add a cup › Calibrate. Pour from empty to
   full, then tap Full. Later pours into that cup are more accurate.

The level comes from the sound of the air above the liquid, so results vary with the glass and the room.
The app presents itself as an aid, not a guarantee.

MICROPHONE: used only while a pour is running, analysed on the device in real time, never recorded or sent.

CAMERA: optional and off by default (Settings › Use the camera to find the cup). It looks for the cup, so a
pour is recognised a little sooner, and gives spoken tips for pointing the iPhone at it before pouring. Sensow
works fully without it. During the pour, the glass drawn on screen takes its colours from the camera image, like
a heavily blurred preview. Images are analysed on the device and never saved.

APPLE WATCH: the Watch app mirrors the pour and taps the wrist faster as the cup fills, so the user can
follow the pour without looking or listening. While a pour is running (usually under a minute), it holds a
WKExtendedRuntimeSession of the self-care type, so the taps continue while the user's wrist is turned to hold
the cup or jug. The session ends as soon as the pour finishes or is stopped. The Watch app works alongside the
iPhone app and needs it.

SIRI AND CONTROL CENTER: "Start pouring with Sensow" opens the app
and starts listening. The same action is available as a Control Center control and for the Action Button.

DATA: Sensow collects no data, has no network features, ads or analytics. The sound model was trained on
FSD50K clips licensed CC0 and CC BY; the creators are credited in the app under Settings › Help ›
Acknowledgements.
