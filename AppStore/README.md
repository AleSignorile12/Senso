# Publishing Senso

What's already in the project, and what only you can do (accounts, devices, uploads).

## Done in the project

- **Sound model v3** is trained only on data that allows commercial use: FSD50K clips licensed CC0 or CC BY.
  The ESC-50 and Sound of Water data is excluded, and v1, which used it, is removed from the app.
  See `MLTraining/External/ATTRIBUTION.md`.
- **Credits:** CC BY requires naming every creator. The app lists them under
  Settings › Help › Acknowledgements, from `SensoApp/ML/TrainingDataCredits.txt`.
- **App icon:** iPhone and Watch, 1024 px, opaque (`Assets.xcassets/AppIcon`). It's a simple crimson wave
  on sky blue from the Almost Purple colours. Replace the PNG if you have a designed one.
- **Version:** 1.0, build 1. Raise `CURRENT_PROJECT_VERSION` (the project's build number) for every upload.
- **Export compliance:** `ITSAppUsesNonExemptEncryption = NO`, because Senso uses no encryption of its own.
  App Store Connect won't ask about it on each upload.
- **Privacy manifest:** `SensoApp/PrivacyInfo.xcprivacy` says no tracking and no collected data. It also
  declares the three system APIs Senso uses and why: UserDefaults, system uptime and file dates.
- **Data Collection:** only in Debug builds run from Xcode. The App Store and TestFlight builds don't show it.
- **Onboarding:** a welcome sheet on first launch, in Apple's own style. It covers where to put the
  iPhone, how a pour works, calibration, privacy and the safety note. It's a module in
  `SensoApp/Onboarding/` (`.onboardingOnFirstLaunch()`), and Settings › Help › How Senso works shows it again.
- **Home screen:** a large labelled Settings button (at least 64 pt tall) replaces the small cup icon.
- **Leaving mid-pour:** iOS stops the microphone when Senso leaves the screen. Senso now ends the pour
  cleanly and says so when you come back.
- **Support:** Settings › Help › Contact support by email opens an email to you. There's no support
  website to run.

## Before you submit

1. **Test on a real iPhone, and on an Apple Watch if you have one.** Nothing has run on hardware yet. Check:
   - pouring water into a glass, and the Stop alert;
   - VoiceOver on every screen;
   - large Dynamic Type sizes;
   - the Control Center control;
   - the Watch taps.

   Every claim in `metadata.md` must be true on a device.
2. **Put `privacy-policy.md` online. It's the only page you need.** It holds the privacy policy and the
   support contact. Apple requires both a Privacy Policy URL and a Support URL, and you can use the same
   URL for both. Support itself happens by email from the app (Settings › Help › Contact support by email),
   so there's no website to run. The quickest way to get a URL:
   1. Go to gist.github.com and sign in with a free GitHub account.
   2. Name the file `senso-privacy-and-support.md`.
   3. Paste the file's contents, then choose Create public gist.
   4. Copy the address: it's your Privacy Policy URL and your Support URL.

   The email address in it is also in the app's support button (`CupsView.swift`, `supportMail`). If it
   ever changes, change it in both places.
3. **Check the name.** "Senso" may already be taken on the App Store. App Store Connect tells you when you
   create the app. `metadata.md` uses "Senso: Pouring Assistant".

## In App Store Connect (appstoreconnect.apple.com)

1. **Create the app.**
   - My Apps › + › New App
   - Platform: iOS
   - Bundle ID: `com.alessandrosignorile.Senso`
   - Primary language: English
   - SKU: anything, for example `senso-ios`
2. **Fill in the store listing.** Copy the text from `metadata.md`. Senso is English only.
3. **Category:** Utilities as primary, Lifestyle as secondary. Pick what fits you best.
4. **App Privacy:** choose "Data Not Collected". This matches the privacy manifest and the policy.
5. **Age rating:** answer "None" or "No" to everything, which gives 4+.
6. **Accessibility nutrition labels:** claim only what you checked on a device. Apple asks whether the
   common tasks work fully with each feature.

   | Feature | Senso | Notes |
   | --- | --- | --- |
   | VoiceOver | Designed for it | Test every screen, iPhone and Watch |
   | Voice Control | Likely | Every button has a label; test "Tap Fill up" |
   | Larger Text | Designed for it | All text uses Dynamic Type |
   | Sufficient Contrast | Yes by design | 7:1 or more |
   | Differentiate Without Color Alone | Yes | States are always spelled out |
   | Reduced Motion | Yes | With Reduce Motion on, the liquid stays still and screens just fade |
   | Dark Interface | No | Ready and Done are always light, so don't claim it |
   | Captions, Audio Descriptions | Not applicable | Senso has no video |

7. **Screenshots** (required): ready to upload in `Screenshots/`.
   - **iPhone 6.9″:** `Screenshots/iPhone-en/`, 6 images at 1320 × 2868 px from an iPhone 17 Pro Max
     simulator: Ready, pouring at 62%, the 86% alert, Done, the welcome sheet and Settings.
   - **Apple Watch:** `Screenshots/Watch/`, 3 images at 422 × 514 px (Apple Watch Ultra): Ready, pouring,
     Done.

   The level numbers are sample values, because a simulator can't hear a pour. To take them again after a
   design change, run a Debug build in a simulator with a launch argument (it opens that screen):

   ```bash
   xcrun simctl launch --terminate-running-process booted com.alessandrosignorile.Senso -SensoScreenshot pouring
   xcrun simctl io booted screenshot pouring.png
   ```

   iPhone scenes: `ready`, `pouring`, `alert`, `done`, `onboarding`, `settings`. Watch scenes, with
   bundle ID `com.alessandrosignorile.Senso.watchkitapp`: `ready`, `pouring`, `done`. The Release (App
   Store) build doesn't contain this mode.
8. **Upload a build.**
   1. In Xcode, choose the Senso scheme and Any iOS Device.
   2. Choose Product › Archive.
   3. In Organizer, choose Distribute App › App Store Connect › Upload.

   The Watch app and the Control Center extension are inside the same upload.
9. **Test with TestFlight first:** internal testing, on your own iPhone.
10. **Submit for review.** Paste `review-notes.md` into App Review Information › Notes. Apple needs no
    demo account.

## Known review risks

- **Watch background time:** the Watch uses an extended runtime session of the "self-care" type, so its
  taps continue while the wrist is turned away. Apple meant self-care for short personal-care sessions.
  The review notes explain why it fits. If Apple rejects it:
  - remove `WKBackgroundModes` from `SensoWatch-Info.plist`;
  - remove `PourRuntimeSession` from `WatchLink.swift`.

  The Watch then taps only while its screen is awake.
- **Safety:** the listing and the app present Senso as an aid, not a guarantee. Keep it that way, and
  don't promise it prevents burns or spills.
- **Accuracy:** the sound model is trained on public recordings. It hasn't been tested on an iPhone in a
  real kitchen yet. Record a few of your own pours, then run `evaluate-sound` (`MLTraining/README.md`)
  before release.
