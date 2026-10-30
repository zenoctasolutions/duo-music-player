# Duo Music Player 1.1.0 (build 2)

## Play Store "What's new" (under 500 characters)
A fresh look and lots of new features!
• New Duo Logo gradient theme and a redesigned player with smooth animations
• Shuffle button next to Next, A-B repeat and pitch control
• Search across songs, albums, artists and playlists
• Play next / Add to queue, folder browser, M3U import and export
• Home shortcuts and a Quick Settings tile
• Heart and shuffle buttons in the notification
• Better screen-reader support and large-text layouts
• Fixes for Radio, duplicate songs and messy titles

## Details
### New
- Overview home, restyled Library, Albums, Artists, Genres, Playlists, Radio and Smart Mix
- Global search with history; folder browser; M3U playlist import/export
- Play next, Add to queue, Clear queue (with Undo)
- A-B repeat and pitch shift (-6..+6 semitones)
- Launcher shortcuts (Shuffle all, Search, Resume) and a Quick Settings tile
- Favorite and shuffle actions in the media notification
- Accessibility labels, 48dp targets, large-text support; English translation template

### Fixed
- Radio showing blank countries or "1 stations"
- Junk titles/artists, duplicate copies and system sound files in the library
- Queue order now matches the Songs tab; Next/Previous after Play next
- Equalizer failing to register after relaunch

### Under the hood
- Removed unused all-files-access permission; storage permissions limited to the Android versions that need them
- HTTPS-only network rules for the lyrics, radio, iTunes and Last.fm services
