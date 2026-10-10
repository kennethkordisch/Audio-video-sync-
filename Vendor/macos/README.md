# Vendor/macos

`ffmpeg` (gitignored) is a static macOS ffmpeg binary that the AVSyncPatternMaker build phase
copies into the app bundle so DNxHR MXF export works without a Homebrew install.

It is fetched automatically on the first build by `tools/fetch-ffmpeg-macos.sh`
(arm64 or x86_64 static build). To use a specific build instead, place your own `ffmpeg`
binary here before building. It must include the `dnxhd` encoder and the `mxf` muxer, which
every standard build does.
