# iPhone: play music on both desk Sonos speakers as a stereo pair

Written 2026-11-18. Nothing on the speakers or the Sonos system has been changed yet.
Step 2 (stereo pairing) is done by you in the Sonos app.

## Short answer

- **Over Bluetooth, this can't be done from an iPhone.** iOS sends Bluetooth music
  (A2DP) to one speaker at a time. Apple's "Share Audio" only works with AirPods
  and Beats headphones ([Apple](https://support.apple.com/102526)), not Sonos. No
  Shortcut or app can get around that, so "when the phone connects to one speaker,
  play on both" is not possible over Bluetooth.
- **Over Wi-Fi it works well, and better than the Mac Bluetooth setup.** Put both
  speakers on Wi-Fi, make them a stereo pair in the Sonos app (one Left, one Right),
  and play from the iPhone with AirPlay or the Sonos/Spotify apps. Sonos keeps the
  two speakers in sync itself, so there is no lag or drift between them. The pair
  shows up on the iPhone as **one** AirPlay speaker.
- **The "script" part:** a Shortcuts automation that, whenever you open your music
  app at home, sends the iPhone's audio to the stereo pair. Steps are in part 3.
  It triggers on opening the music app (plus being on home Wi-Fi), not on a
  Bluetooth connection, because once the speakers are on Wi-Fi a Bluetooth
  connection to one of them would break the pair (see "Why not trigger on Bluetooth").

This is the same Wi-Fi pair the Mac session recommends, so one pair serves both the
Mac (AirPlay from the Mac) and the iPhone.

## Which speakers these are

What the Mac reports over Bluetooth for both: Sonos Bluetooth names
`SONOS A4B6` and `SONOS 921E`, product ID
0x1200, firmware 20.3.6, A2DP + AVRCP. The "Left (...)" / "Right (...)" prefixes are
just names on the Mac.

- Both report the same product ID, so they are almost certainly the **same model**.
  That matters: Sonos only stereo pairs matching models (Roam with Roam or Roam 2,
  Move 2 with Move 2).
- The Bluetooth data does not say which model it is. Since they use Bluetooth with
  a default `SONOS xxxx` name, they are most likely a model that works over
  Bluetooth out of the box, such as **Roam 2** or **Move 2** (the original Roam needed
  Sonos app setup first). Not confirmed.
- To confirm: Roam 2 is the small bottle-sized one with a separate Bluetooth button
  on the back; Move 2 is the big one with a handle. The Sonos app also shows the
  model once they are added.
- Every portable Sonos that supports Wi-Fi supports AirPlay 2 and stereo pairing of
  two matching units, so the plan below works for any of these.

## Part 1. Get both speakers onto Wi-Fi (one time)

1. Install the **Sonos** app on the iPhone and sign in (or create a Sonos account).
2. Have the iPhone on your home Wi-Fi (2.4 or 5 GHz, not a guest or captive-portal
   network; a school/hotel network with a login page will not work).
3. On the Mac, stop the Bluetooth helper so it does not keep grabbing the speakers:
   in Terminal, `~/Desktop/sonos-stereo/sonos-stereo off`. (Coordinate with the Mac
   session; that is its tool.)
4. In the iPhone's Settings > Bluetooth, tap the (i) next to each Sonos speaker and
   choose **Disconnect** (or turn the Mac's Bluetooth off for a minute).
5. In the Sonos app: **Settings (gear) > Manage > Add Product** (wording may vary
   slightly by app version) and add the first speaker, then the second. Give them
   names, for example `Desk Left` and `Desk Right`.
6. If a speaker had been set up before and is stuck in Bluetooth mode: short-press
   its **Bluetooth button** once. That switches it back to Wi-Fi (white light instead
   of blue).

## Part 2. Make them a stereo pair

1. Put the speakers where they will sit: the one you want on the left on the left.
2. Sonos app > tap the **Desk Left** speaker > **Settings** for that product >
   **Set Up Stereo Pair** (sometimes under Room/Product Settings).
3. Pick the second speaker, then follow the prompts: the app plays a tone on each
   so you can assign Left and Right.
4. Name the pair's room, for example **Desk**. From now on the iPhone, the Mac and
   every app see one speaker called **Desk** that plays in stereo.

Undo any time: same screen, **Separate Speakers**.

## Part 3. Shortcuts automation: open music app at home -> play on the pair

Built in the Shortcuts app on the iPhone (iOS 17 or later; menu names below match
iOS 17/18 and may shift slightly in newer versions).

### 3a. Make the shortcut

1. Open **Shortcuts** > **Shortcuts** tab > **+** (top right).
2. Tap the name at the top, rename it **Play on Desk**.
3. Tap **Search Actions**, add **Get Network Details**. Make it read
   *Get **Network Name** of **Wi-Fi***.
4. Add **If**. Make it read *If **Network Details** **is** `YourHomeWiFiName`*
   (type the exact Wi-Fi name; capital letters matter).
5. Inside the If (between If and Otherwise), add **Set Playback Destination**.
   Tap the **iPhone** placeholder in that action and pick **Desk** (the pair). If
   Desk is not in the list, wake both speakers (press play/pause on each) and make
   sure the phone is on home Wi-Fi, then try again.
6. Delete the **Otherwise** part if you like (tap and remove), or leave it empty.
7. Tap **Done**. Test it: start a song, run the shortcut by tapping it. Music should
   move to both speakers.

### 3b. Make it run by itself

1. Shortcuts > **Automation** tab > **+** (or **New Automation**).
2. Choose **App**.
3. **Choose** your music apps (Music, Spotify, YouTube Music, ...), tap Done.
4. Leave **Is Opened** checked.
5. Select **Run Immediately** (and turn **Notify When Run** off if you don't want a
   banner). Tap **Next**.
6. Pick the **Play on Desk** shortcut. Done.

Now: at home, opening Music or Spotify points the iPhone's audio at the Desk pair;
away from home it does nothing. Hit play and it comes out of both speakers in stereo.

### 3c. Optional: a one-tap button

For playing on the pair without opening a music app first:
- Settings > Accessibility > Touch > **Back Tap** > Double Tap > choose
  **Play on Desk**. Double-tap the back of the phone to send audio to the pair.
- Or add **Play on Desk** to the Home Screen or Control Center.

Back to the phone's own speaker: Control Center > AirPlay icon > iPhone.

## Other ways to play on the pair (no automation needed)

- **Control Center**: long-press the music tile > AirPlay icon > **Desk**.
- **Spotify**: tap the devices icon > **Desk**. This uses Spotify Connect, so the
  speakers stream straight from the internet and the phone is only a remote.
  Better for phone battery and calls do not interrupt the music.
- **Sonos app**: pick Desk and play from Apple Music, Spotify, etc. inside the app.

## Why not trigger on Bluetooth

Shortcuts does have a "Bluetooth: is connected" trigger, but it does not help here:
- A portable Sonos in Bluetooth mode turns its Wi-Fi off, and a stereo pair only
  exists on Wi-Fi. So when the iPhone connects to one speaker over Bluetooth, that
  speaker leaves the pair. You get one speaker, not two.
- iOS can't add a second Bluetooth speaker, so no action could fix it after the
  connection.

So the rule is: **leave the speakers on Wi-Fi and don't connect to them over
Bluetooth** from the phone (or the Mac). If the phone auto-reconnects to them over
Bluetooth, go to Settings > Bluetooth > (i) next to each Sonos > **Forget This Device**.

## Things that can trip this up

- **Speaker not in the AirPlay list:** portable Sonos speakers go to sleep after a
  while on battery. Press play/pause on each, or keep them on their chargers on
  the desk. In the Sonos app, check the battery saver setting for each speaker if
  they keep disappearing.
- **Automation shows an error** if the pair is asleep or unreachable when the app
  opens. Harmless; wake the speakers and run Play on Desk again.
- **Small delay when you hit play**: AirPlay buffers about 2 seconds before sound
  starts. Normal, and both speakers stay in sync with each other. Fine for music;
  for video, apps like YouTube adjust automatically.
- **Leaving home**: the speakers stay on Wi-Fi. If you take one out, short-press its
  Bluetooth button to use it over Bluetooth, and press it again back home to return
  to Wi-Fi and the pair.

## Sources

- Apple, Share audio with AirPods and Beats: https://support.apple.com/102526
- Sonos, Roam 2 product guide: https://www.sonos.com/en-us/guides/roam2
- Sonos, Move 2 product guide: https://www.sonos.com/en/guides/move2
- Sonos community, stereo pair needs Wi-Fi (not Bluetooth): https://en.community.sonos.com/portable-speakers-229130/roam-move-bluetooth-stereo-pair-6905782
- Shortcuts Set Playback Destination examples: https://matthewcassinelli.com/shortcuts/start-airplay/
