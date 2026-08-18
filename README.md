# RV There Now

RV There Now adds a host-side player-cap menu to **RV There Yet?**. Press **F6** in game, choose a cap from 4 to 24, and apply it before creating a lobby. Only the host needs the mod for the expanded cap; every player who should hear synchronized internet radio needs it installed.

## Support SomaFM

Internet radio in RV There Now is powered by [SomaFM](https://somafm.com/). Thank you to SomaFM for providing an amazing independent, listener-supported radio service. If you enjoy these stations, please [donate directly to SomaFM](https://somafm.com/support/) and help keep them on the air.

The game is designed for four players. Eight is the recommended expanded cap; larger sessions may expose gameplay, UI, networking, and performance problems.

## In-game menu

- **F6** opens or closes the menu.
- **F7** starts or stops the selected internet station while you are in the RV.
- **Up/Down** selects a row and **Left/Right** changes its value.
- **Enter** activates the selected row and **Escape** closes the menu.
- On the main menu, the dashboard shows only Player Cap and Apply. In a game, it shows the radio and player roster while hiding lobby-creation settings.
- Select **Radio Station** and press **Enter** to open the station list. Use **Up/Down** and **Enter** to choose, or **Escape** to cancel. **Left/Right** cycles stations directly.
- The live roster shows player names, ping, and connection state, with Page Up/Down for larger sessions.
- The optional compact HUD shows the live player count, applied cap, and average remote ping.
- Selecting a cap of four and applying it restores the vanilla lobby size.

The **Internet Radio** row plays one of 17 SomaFM music stations through the bundled radio bridge: Groove Salad, Drone Zone, Secret Agent, Left Coast 70s, Underground 80s, Indie Pop Rocks, DEF CON Radio, Thistle Radio, Vaporwaves, The In-Sound, Deep Space One, Metal Detector, Folk Forward, Tiki Time, 7 Inch Soul, Dub Step Beyond, and Boot Liquor. The catalog uses SomaFM's published permanent MP3 stream links; it does not scrape private service APIs or download individual tracks. Playback rejects non-SomaFM URLs received through lobby metadata.

Live MP3 stations are decoded continuously into an eight-second in-memory ring buffer. The bundled Windows bridge owns the audio device, and its real-time callback performs no file I/O. Lua releases the synchronized start gate through a direct DLL export after two seconds are buffered. The menu reports playback only after the device callback consumes nonzero decoded samples. ICY metadata feeds a small current-song label fixed in the lower-right corner.

The host publishes the source, shared start time, and radio volume as atomic Steam lobby events, with Steam rich presence used only when a lobby is unavailable. One consolidated game-thread scheduler polls Steam state at 500 ms intervals during gameplay, checks startup and positional state at 100 ms while needed, and refreshes the roster once per second. Every modded player resolves the source locally. Lua sends the bridge per-client distance and stereo pan computed from the RV and listener positions. The RV radio's physical Play, Stop, volume, previous, and next buttons remain visible and control internet radio directly; vanilla cassettes are hidden and their finite tape index is reset after input. Previous and next wrap around the station catalog. Only the host can stop or change an active synchronized station, so clients cannot silence their local copy independently. Every player who should hear internet radio must install the mod.

UE4SS loads the bundled radio bridge DLL directly. Its audio worker runs on a background thread inside the game process, so there is no radio executable, command prompt, or desktop file association. Lua stops the worker as soon as the RV world unloads, including when returning to the main menu.

Antivirus software can quarantine unsigned community-mod binaries. Norton may terminate the game when it blocks `rv-radio-bridge.dll`; use only the file from the official release, verify the release checksum, and report or allow that verified file. Disabling antivirus protection globally is not recommended.

Applying a cap writes Unreal's `Game.ini` setting and updates the `GameSession` class default. Create a new lobby after applying it. The first change also creates a one-time backup beside `Game.ini`.

## Credits

Thanks to **squ1rt5** for the multiplayer idea and **GregTheMeg** for the internet radio idea.

## License

Copyright (C) 2026 Rogue-Factor.

Unless otherwise noted, the original source code and assets in this repository are licensed under the [GNU General Public License version 3 or later](LICENSE).

Bundled miniaudio code is not relicensed. It remains available under its respective terms in `mod/licenses` and `bridge/vendor`.

## Install with a mod manager

Install the package through Thunderstore Mod Manager or r2modman. The required `Thunderstore-unreal_shimloader` dependency is declared in `manifest.json` and should be installed automatically.

Download the regular `Rogue-Factor-RVThereNow-<version>.zip` release asset when importing the mod locally. Do not use the standalone archive with a mod manager.

## Standalone install with UE4SS included

Download `Rogue-Factor-RVThereNow-<version>-Standalone.zip` from the GitHub release if you do not use a mod manager. Close the game, open its local files through Steam, and extract the archive into the top-level game folder that already contains `Ride`. The archive supplies the tested UE4SS build, Ride-specific settings, the mod, installation instructions, and license notices.

Back up any existing UE4SS installation first. Users who already maintain UE4SS should install only the regular package's `mod` folder.

For local development, build the Thunderstore package and import the resulting zip as a local mod:

```bash
./scripts/package.sh
./scripts/package-standalone.sh
```

## Command-line fallback

The repository also includes a standalone Bash tool that can change the same setting without loading UE4SS. Close the game, then run:

```bash
./rv-there-now set 8
```

It locates Steam app `3949040` and its Proton prefix automatically. To use a specific library:

```bash
./rv-there-now set 8 --game-dir "/path/to/SteamLibrary/steamapps/common/Ride"
```

Other commands are `status`, `reset`, and `restore`. `reset` removes only this setting; `restore` restores the one-time backup.

## Windows fallback

Without the mod or CLI, close the game and edit:

```text
%LOCALAPPDATA%\Ride\Saved\Config\Windows\Game.ini
```

Add:

```ini
[/Script/Engine.GameSession]
MaxPlayers=8
```

## Development

Run the Bash integration tests and Lua config tests with:

```bash
bash tests/test.sh
```

The tests use temporary files and do not modify the installed game.

## Thunderstore status

As of August 16, 2026, the RV There Yet? community contains four packages: r2modman, GaleModManager, `unreal_shimloader`, and MoreRVers. MoreRVers is currently the only listed gameplay mod. There is no RV-specific shared UI or configuration library to build on, so this menu uses Unreal's native UMG widgets through UE4SS.
