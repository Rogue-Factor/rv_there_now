# Changelog

## 0.15.1

- Add a standalone release archive containing the tested UE4SS build for one-drag manual installation.
- Pin and verify the UE4SS source package and include its MIT license and attribution.
- Configure the standalone UE4SS build specifically for Ride's Unreal Engine 5.6 runtime.
- Keep the regular Thunderstore package dependent on `unreal_shimloader` to avoid mod-manager conflicts.

## 0.15.0

- Replace the silent Steam Integration Kit procedural-wave handoff with continuous playback from the bundled native Windows bridge.
- Route direct streams, AccuRadio, and downloaded YouTube audio through the same synchronized chunk player.
- Apply live RV-relative distance, stereo panning, and cassette volume gains to the native output.
- Keep the physical cassette Play, Stop, Next, and Previous controls connected to synchronized internet radio.
- Confirm nonzero samples from the audio-device callback before the menu reports playback.
- Fix the native playback gate parsing so Lua's ASCII start sequence is accepted by the bridge.

## 0.14.1

- Match vanilla cassette playback's mono channel contract instead of feeding a stereo procedural wave into its positional audio path.
- Route procedural audio through the exact `SC_Music_CasettePlayer` sound class used by the game's tape MetaSounds.
- Explicitly keep the RV cassette component spatialized and out of UI audio routing.

## 0.14.0

- Map the RV cassette player's physical next and previous controls to the internet-radio station list.
- Wrap station selection in both directions without depending on the game's cassette array.
- Synchronize and restart playback automatically when the host changes stations while the radio is playing.

## 0.13.5

- Restart the selected synchronized internet station when the RV's physical Play control is pressed after Stop.
- Clear the completed synchronization generation during teardown so a new Play event cannot be mistaken for the previous start.

## 0.13.4

- Compare reflected Unreal objects by native address so fresh UE4SS wrappers do not restart radio playback every 25 milliseconds.
- Match the cassette player to the active world by native address and discard stale cached actors after map changes.
- Start the procedural cassette component exactly once instead of invoking both `Activate` and `Play`.

## 0.13.3

- Replace in-place SIK stream queue updates with fresh procedural-wave handoffs because `SIK_QueueAudio` resets its wave on every call.
- Explicitly activate, unpause, and normalize pitch on the RV cassette audio component.
- Verify that Unreal reports the cassette component as playing before accepting a chunk.

## 0.13.2

- Reduce synchronized radio startup from 30 seconds to 12 seconds.
- Start after the first eight-second chunk is buffered while retaining three chunks for recovery.
- Show a synchronized-start countdown in the in-game menu.

## 0.13.1

- Pass the required `StartTime` argument to Unreal's reflected audio `Play` function during stream startup, underrun recovery, and radio rebinds.

## 0.13.0

- Replace editable stream URLs with an eight-station keyboard dropdown.
- Remove the Reset row; selecting four players and applying restores the vanilla cap.
- Pass the required `bSuccess` out-parameter table when loading PCM through Steam Integration Kit.
- Add verified SomaFM ambient, lounge, rock, synthpop, indie, and electronic stations.

## 0.12.1

- Resolve AccuRadio channel page URLs through their JSON playlist and continuous M4A track queue.
- Parse provider playlists with the already bundled QuickJS runtime instead of treating webpage HTML as MP3 audio.
- Preserve the existing three-chunk procedural buffer, synchronization, positional playback, and stop cleanup.

## 0.12.0

- Add continuous procedural buffering for direct MP3 radio streams.
- Prebuffer three eight-second PCM chunks and roll them through the cassette's long-lived procedural sound wave.
- Keep live stream start, stop, volume, RV position, and chunk timing on the existing synchronized radio path.

## 0.11.0

- Replaced the unavailable Unreal Media Framework path with the game's bundled Steam Integration Kit procedural sound API.
- Decode downloaded YouTube audio to PCM in the bundled bridge and play it through the cassette player's own positional audio component.
- Restore the cassette's original sound on stop and keep its volume control attached to procedural playback.

## 0.10.2

- Open prepared YouTube audio with Unreal's local-file API instead of treating its path as a stream URL.
- Log the accepted media-opening path for runtime diagnosis.

## 0.10.1

- Fall back to Steam rich presence when the game session does not expose a joined Steam lobby.
- Chunk long radio URLs and commit control metadata last to avoid partial client updates.
- Start locally in solo sessions when Steam is temporarily unavailable and retry synchronization in the background.

## 0.10.0

- Move playback into an Unreal MediaSound component owned by the RV tape player.
- Publish the host's URL, play/stop generation, and shared start time through Steam lobby metadata.
- Resolve YouTube locally on every modded client and relay live MP3 through a loopback-only HTTP endpoint.
- Use the replicated tape player state for physical play/stop control across the session.

## 0.9.0

- Pan and attenuate internet audio from the RV tape player's world position.
- Follow the physical cassette player's start and stop controls during internet playback.
- Apply the RV radio volume multiplier to internet playback.

## 0.8.1

- Clear the URL field when editing begins so a pasted address replaces the previous stream.
- Reject malformed values containing multiple concatenated HTTP addresses.

## 0.8.0

- Add self-contained YouTube audio playback for pasted video and short URLs.
- Bundle pinned 32-bit yt-dlp and QuickJS executables; no host tools or Python runtime are required.
- Download the selected M4A audio to a temporary file, decode AAC through Media Foundation, and remove it when playback stops.
- Report YouTube download, decoder, and playback states through the existing radio row.

## 0.7.0

- Add a keyboard-editable, persistent internet-radio stream URL to the F6 menu.
- Pass stream URLs to the bundled bridge through a temporary file so query strings remain intact.
- Restore game keyboard focus when URL editing ends or the menu closes.

## 0.6.0

- Bundle a 64-bit Windows HTTP MP3 bridge built with WinHTTP and miniaudio.
- Remove the Proton host `mpv` and `socat` requirements.
- Report bridge connection, playback, and decoder errors in the in-game menu.

## 0.5.2

- Fall back to the host `mpv` decoder when the game rejects HTTP audio under Proton.
- Control the detached fallback player from the existing radio toggle without bundling another decoder.

## 0.5.1

- Create the media sound through the tape player actor so Unreal owns and registers it correctly.
- Keep full Lua errors in the UE4SS log instead of rendering tracebacks over the menu.

## 0.5.0

- Add an experimental live dashboard radio test using Unreal's native media framework.
- Attach radio audio to the RV tape player and reuse its attenuation and music sound class when available.
- Add an F7 radio shortcut and explicit connection, playback, and failure states.

## 0.4.1

- Let mouse input pass through the full-screen overlay to the game's menus.

## 0.4.0

- Replace cap presets with a live, paged player roster.
- Show player names, ping, and connection state for up to eight players per page.
- Add average remote ping to the compact HUD.

## 0.3.0

- Move the menu to a compact upper-right panel.
- Replace mouse hitboxes with keyboard row navigation.
- Add named cap presets and separate selected/applied cap state.
- Add live host/client and player-count status.
- Add an optional compact session HUD when the menu is closed.

## 0.2.0

- Add an in-game player-cap menu toggled with F6.
- Add mouse and keyboard controls for selecting, applying, and resetting the cap.
- Persist the cap in `Game.ini` and update live `GameSession` objects for new lobbies.
- Update the package for `Thunderstore-unreal_shimloader-1.1.7`.
- Avoid UE4SS map hooks and global object scans during world transitions.

## 0.1.0

- Add a host-side command-line tool for changing and restoring the player cap.
