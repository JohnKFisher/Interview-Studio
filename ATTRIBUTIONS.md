# Third-Party Attributions

This file is included in local app bundles so the packaged development artifact carries the same attribution record as the repository.

## FFmpeg and FFprobe

- Project: FFmpeg
- Source: https://ffmpeg.org/
- License: GPL or LGPL depending on the individual build configuration and enabled components
- Attribution: Copyright the FFmpeg contributors; see the complete license and legal notices published by FFmpeg at https://ffmpeg.org/legal.html
- Packaging note: script/build_and_run.sh copies a matching ffmpeg/ffprobe pair from the build host only when both executables are present. The generated BundledTools/PROVENANCE.txt records the reported versions and SHA-256 hashes. This host-specific bundle is a local development artifact; redistribution requires confirming the selected build's license obligations, source-availability obligations, and any applicable patent or codec requirements.

## Interview Studio

- Project license: MIT
- Copyright: Sidelark Labs ; John Kenneth Fisher
- Repository: https://github.com/JohnKFisher/Interview-Studio
