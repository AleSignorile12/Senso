# App Store listing

Copy each field into App Store Connect. The limits are Apple's; every field here fits.
Check that each claim is true on a real device before you submit.

## English

### Header and search result

The top of the product page shows the icon, the **Name** and the **Subtitle**. A search result shows the
icon, the Name, the Subtitle and the first three iPhone screenshots (Ready, pouring at 42%, the 86% alert).
Search matches the Name, the Subtitle and the **Keywords**, so the keywords don't repeat their words.

**Name** (30 max)
Sensow: Pouring Assistant

**Subtitle** (30 max)
Hear when your cup is full

**Promotional text** (170 max)
Pour without overflowing. Sensow listens to your cup and tells you when to stop, with speech, sounds and taps on your Apple Watch.

**Keywords** (100 max, commas, no spaces)
blind,low vision,visually impaired,glass,water,drink,spill,overflow,voiceover,accessibility,liquid

**Description** (4000 max)

Sensow helps blind and low-vision people pour drinks without overflowing.

Put your iPhone next to the cup, tap Fill Up, or say "Start pouring with Sensow", and pour. Sensow listens to the sound of the liquid. As a cup fills, the pitch of the air above the liquid rises; Sensow follows it, tells you how full the cup is, and says "Stop! Glass is full" early enough for you to stop.

• Spoken progress at 25, 50, 75 and 85%, through VoiceOver or Sensow's own voice
• A clear stop sound, timed to give you time to react
• Apple Watch: taps on your wrist that speed up as the cup fills. Set your stop level with the Digital Crown.
• Calibrate your favourite cups once for a more accurate level
• Start hands-free with Siri, the Action Button or Control Center
• Optional camera to find your cup and help you point your iPhone at it
• Designed for VoiceOver and large text

Private by design: sound and camera images are analysed on your iPhone and never leave it. Sensow has no account, no ads and no tracking, and collects no data.

Sensow is an aid, not a guarantee. The level can be wrong, especially with cups you haven't calibrated, in noisy rooms or with thick liquids. Take extra care with hot drinks.

**Support URL:** your hosted page (see README.md)
**Privacy Policy URL:** your hosted privacy-policy.md

## TestFlight

App Store Connect › your app › TestFlight › Test Information. Testers read this in the TestFlight app.
External testing needs the Beta App Description, the Feedback Email and the review contact; internal
testing needs none of them.

**Beta App Description** (4000 max)
Sensow helps blind and low-vision people pour drinks without overflowing. Put your iPhone next to the cup, tap Fill Up, and pour. Sensow listens to the liquid, tells you how full the cup is, and says "Stop! Glass is full" in time to stop. With an Apple Watch, taps on your wrist follow the level.

**Feedback Email:** the address in `privacy-policy.md`
**Marketing URL**, if asked: leave empty
**Privacy Policy URL**, if asked: your hosted privacy-policy.md

**Beta App Review Information:** your name, email and phone (international format, starting with +), and
"Sign-in required" off. Paste `review-notes.md` into Notes.

**What to Test** (per build, 4000 max)
Thanks for testing Sensow! Please use cold water.
- Pour into a few different cups and glasses. Does Sensow say "Stop! Glass is full" in time?
- Calibrate a cup in Settings, then pour into it again. Is the level closer?
- Try a quiet room and a noisy one.
- With an Apple Watch: start from the Watch, follow the taps, and change the stop level with the Digital Crown.
- With VoiceOver on: can you do everything?
- Say "Start pouring with Sensow" to Siri.
To send feedback, open TestFlight, choose Sensow, then Send Beta Feedback. Tell us the cup, the liquid and what Sensow said.
