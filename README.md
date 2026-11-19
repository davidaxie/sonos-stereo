# sonos-stereo

Play two Sonos Era 100 speakers on a desk as a stereo pair from a Mac.

Started 2026-11-18. The speakers are two Era 100s whose Bluetooth names are
`Left (SONOS A4B6)` and `Right (SONOS 921E)`.

There are three ways to do this, covered below:

1. **Bluetooth from the Mac** (this tool). Built and working, but the sound drops out.
2. **Wired line-in.** Researched, not bought.
3. **Private Wi-Fi with a travel router.** Researched, not bought. This is the current
   recommendation.

## Status (2026-11-18)

- **The Bluetooth tool works:** it makes the pair, the volume keys work, and connecting
  one speaker connects the other. The helper is installed on the MacBook Pro.
- **Bluetooth audio drops out:** it breaks up in bursts and sometimes pauses on both
  speakers. A 6-minute stall monitor found zero stalls inside the Mac's audio system, so
  the sound is lost on the Bluetooth link. A known Era 100 problem: when the speaker has
  no Wi-Fi, users report Bluetooth dropouts with Apple devices.
- **A USB-C to USB-C cable from the Mac into an Era 100 does nothing.** The Era 100's
  USB-C port is not a USB sound card. It only takes Sonos's own Line-In or Combo
  Adapter.
- **Next step:** buy a GL.iNet Beryl AX travel router and set up option 3.

## Option 1: Bluetooth from the Mac (this tool)

macOS can't send one Bluetooth song to two speakers on its own, so the tool builds a
CoreAudio "aggregate device" called **Sonos Stereo**. That device sends the left channel
to one speaker and the right channel to the other, and it is set as the Mac's sound
output.

### Build and install

```bash
./build.sh                # compile, embed Info.plist, ad-hoc sign
./sonos-stereo install    # copy to ~/Library/Application Support/sonos-stereo and start the helper
```

After the helper starts, macOS asks for **Accessibility** access so the volume keys can
work. Every rebuild counts as a new app. The old entry in System Settings > Privacy &
Security > Accessibility still looks ON but no longer works. To fix it, remove the entry
with "−", run `install` again, and grant access again.

### Commands

| Command | What it does |
|---|---|
| `on [--swap] [--bt-clock]` | Build the pair and make it the sound output. `--swap` swaps Left and Right. `--bt-clock` uses a speaker as the clock instead of the Mac's built-in speakers. |
| `off` | Remove the pair and pause auto-pairing. |
| `status` | Show the speakers, the pair, the sound output, the helper and the calibration. |
| `vol <0-100>` | Set the volume on both speakers. |
| `test` | Play a left/right test tone. |
| `calibrate` | Line the two speakers up in time using the Mac's microphone. Run it from Terminal.app: recordings started from Claude or launchd come out silent. |
| `install` / `uninstall` | Install or remove the background helper (LaunchAgent `local.sonos-stereo`). |
| `daemon` | The helper itself (launchd runs this). |

### How it works

- **Clock:** the MacBook Pro's built-in speakers act as the clock and stay silent. Both
  Sonos speakers use max-quality drift correction, and everything runs at 44.1 kHz.
  Left plays on channel 3 and Right on channel 6 of the aggregate.
- **Helper** (`~/Library/LaunchAgents/local.sonos-stereo.plist`):
  - **Volume keys:** catches the volume up, down and mute keys while the pair is the
    sound output (1/16 steps, Option+Shift for 1/64 steps).
  - **Auto-pairing:** when either speaker connects over Bluetooth, connects the other one
    and rebuilds the pair. A pair with a missing speaker is removed.
- **Bluetooth runs only inside the helper.** IOBluetooth crashes when run from Claude's
  shell, but works under launchd.
- **Settings:** `~/Library/Application Support/sonos-stereo/settings.json`.
- **Logs:** `~/Library/Logs/sonos-stereo.log` (helper) and
  `~/Library/Logs/sonos-calibrate.log`.

### Not finished: wired mode

`sonos-stereo.swift` has the start of a wired mode, where any two outputs can be set as
Left and Right by their CoreAudio UID. The `leftUID`/`rightUID` settings, transport
detection and clock selection are in. The `assign` command that sets them is not
written, so nothing uses this yet.

Option 2 below wouldn't need it: one headphone jack with a splitter cable needs no
software.

## Option 2: Wired line-in (no wireless at all)

Wiring from the **Mac mini's** headphone jack:

```
Mac mini headphone jack
  -> 3.5 mm male to 2x RCA female adapter        (splits Left and Right)
     -> per channel: RCA Y splitter, 1 male to 2 female   (copies the channel to both inputs)
        -> 2x RCA male to 3.5 mm male stereo cable
           -> Sonos Line-In Adapter -> Era 100
```

Each speaker plays its own channel on both of its tweeters. Everything comes from one
output, so the speakers stay in sync, and the normal volume keys work without the helper.

Parts, about $65 in total:

| Qty | Part | About |
|---|---|---|
| 2 | Sonos Line-In Adapter (USB-C to 3.5 mm) | $19 each |
| 1 | 3.5 mm male to 2 RCA female adapter | $6 |
| 1 pack | RCA Y splitter, 1 male to 2 female (need 2) | $7 |
| 2 | 2 RCA male to 3.5 mm male stereo cable, about 6 ft | $8 each |

Caveats:

- **Line-in has to be turned on in the Sonos app.** For each speaker, set Line-In
  Autoplay to On and pick that speaker as the Autoplay room. Set Audio Delay to the
  lowest setting.
- **Working with no network is not confirmed by Sonos.** Sonos Community users say it
  plays offline once Autoplay is set. One user says the Era 100 needs a network to start
  up properly. Test one speaker with the Wi-Fi off before buying parts for both.
- **Use stereo cables, not mono.** A mono cable or adapter only plays one side.

## Option 3: Private Wi-Fi with a travel router (recommended)

A small travel router on the desk makes its own Wi-Fi network ("Desk") for the speakers
and your devices. Sonos keeps the stereo pair in sync on Wi-Fi itself.

- **Audio path:** your device -> router -> speakers. It never uses the apartment Wi-Fi.
- **Internet path:** the router uses the apartment Wi-Fi in repeater mode, only for
  internet (Spotify downloading songs, Sonos updates, browsing). No Ethernet jack is
  needed.

Router: **GL.iNet Beryl AX (GL-MT3000)**, about $80 to $90.
- Wi-Fi 6, the same standard the Era 100 uses.
- Fast enough in repeater mode that the laptop's internet isn't slowed down.
- The cheaper **Opal (GL-SFT1200)**, about $35 to $40, works too, but its repeater mode
  is slower.

Setup takes about 30 to 45 minutes:

1. **Router:** power it on, join its `GL-MT3000-xxx` network (password on the label),
   open `192.168.8.1`, and set an admin password.
2. **Internet:** go to Internet > Repeater > Scan, pick the apartment Wi-Fi, and enter
   its password.
3. **Desk network:** under Wireless, name the 5 GHz network `Desk` and set a password.
   Put the apartment uplink on the other band if you can, so the two don't share
   airtime.
4. **Speakers:** in the Sonos app, while the speakers can still reach the old Wi-Fi, add
   the `Desk` network under Settings > System > Network. Then move both speakers to it.
5. **Stereo pair:** in the Sonos app, choose Set Up Stereo Pair and assign Left and
   Right.
6. **Devices:** join `Desk` on the Mac mini (Wi-Fi, or Ethernet to the router's LAN
   port), the iPhone and the MacBook. Turn off Auto-Join for the apartment network on
   each.
7. **MacBook helper:** run `./sonos-stereo uninstall` so it stops grabbing the speakers
   over Bluetooth.
8. **Play:** use AirPlay from Control Center > Sound, or Spotify Connect.

Notes:

- **Every device has to be on `Desk`.** A device on the apartment Wi-Fi won't see the
  speakers.
- **Android and Windows** can't use AirPlay. They can play through Spotify Connect or
  the Sonos app.
- **AirPlay waits about 2 seconds before sound starts.** Video apps usually adjust for
  it.
- **Moving apartments:** only the router's repeater setting changes. Plug the router into
  an Ethernet jack if the new place has one.
- **Dorm or campus Wi-Fi** may need a school sign-in (WPA2-Enterprise), device
  registration, or may not allow personal routers.

## iPhone

See [iphone/README.md](iphone/README.md). Short version: an iPhone can't play to two
Bluetooth speakers at once, so the iPhone uses the same Wi-Fi stereo pair as option 3,
with a Shortcuts automation called "Play on Desk".

## Files

- `sonos-stereo.swift`: the tool (one file, no dependencies)
- `Info.plist`: embedded in the binary, so macOS can ask for Bluetooth and microphone
  access
- `build.sh`: compile and sign
- `iphone/README.md`: iPhone guide
