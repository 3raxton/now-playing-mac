# Now Playing

<img src="./screenshots/appicon.png" alt="Now Playing app icon" width="92px"/>

Now Playing shows the current track in your Dock and controls Spotify, Apple Music, and AmpSonic.

It appears in the Dock as **Now Playing**. In French, the Dock name is **Lecture en cours**.

https://user-images.githubusercontent.com/7284672/199579997-f417812a-1f0f-47db-b6d5-80252d60abe9.mov

This project continues [Groove](https://github.com/woofers/groove) by Jaxson Van Doorn, under the same MIT license.

## Usage

Click the Dock icon to play or pause. Double-click it to skip to the next track.

Right-click the icon for **Playback** and **Music Player**. Playback sits next to the cursor and includes play, pause, previous, and next. The play command is labeled **Pause** while a track is playing and **Play** while it is paused.

Now Playing follows whichever of those apps starts playing. A player you choose in the menu stays selected until a different app starts.

## Configuration

Right-click the Dock icon and choose Spotify, Apple Music, or AmpSonic under **Music Player**.

![Dock menu for choosing the music player](./screenshots/config.png)

## Libraries

- [MusicPlayer](https://github.com/ddddxxx/MusicPlayer) talks to Spotify and Apple Music for playback and track info.
