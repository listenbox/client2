/// FFmpegKit Extended 0.11.1, FFmpeg 9.0.1, LGPL small base bundle.
/// Each SHA-256 is the release asset digest, independently checked by download.
/// Source: https://github.com/akashskypatel/ffmpeg-kit-builders/releases
class FfmpegArtifact {
  const FfmpegArtifact(this.url, this.sha256, this.entry);

  final String url;
  final String sha256;
  final String entry;
}

const ffmpegArtifacts = <String, FfmpegArtifact>{
  'macos-arm64': FfmpegArtifact(
    'https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v0.11.1-macos/bundle-base-macos-universal-small-lgpl.xcframework.zip',
    '08c4639a4e8e3d5cb26d75cbf71b508017880b4d94b3cbde63c6cb571e66c910',
    'bundle-base-macos-universal-small-lgpl.xcframework/macos-arm64_x86_64/ffmpegkit.framework/ffmpegkit',
  ),
  'macos-x64': FfmpegArtifact(
    'https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v0.11.1-macos/bundle-base-macos-universal-small-lgpl.xcframework.zip',
    '08c4639a4e8e3d5cb26d75cbf71b508017880b4d94b3cbde63c6cb571e66c910',
    'bundle-base-macos-universal-small-lgpl.xcframework/macos-arm64_x86_64/ffmpegkit.framework/ffmpegkit',
  ),
  'linux-x64': FfmpegArtifact(
    'https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v0.11.1-linux/bundle-base-linux-x86_64-shared-small-lgpl.zip',
    '7a011ac0fe5b8e0a57a5dd1320560b1af2079bf78cf5a32114bde9e24e6070c7',
    'bundle-base-linux-x86_64-shared-small-lgpl/lib/libffmpegkit.so',
  ),
  'windows-x64': FfmpegArtifact(
    'https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v0.11.1-windows/bundle-base-windows-x86_64-shared-small-lgpl.zip',
    '0a69736f01b8d2c1b49f12618da17fc2cc9134adfeaaaa58a2ba9e6693359a4b',
    'bundle-base-windows-x86_64-shared-small-lgpl/bin/libffmpegkit.dll',
  ),
};
