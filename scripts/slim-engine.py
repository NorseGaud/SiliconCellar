#!/usr/bin/env python3
"""Make a Wine Engine tree smaller before it goes into the app bundle.

1. Remove DWARF debug data from the Windows PE DLLs (keeps the "Wine builtin DLL" marker).
2. Remove GStreamer plugins that winegstreamer cannot reach (network, cloud, effects, tracers).
3. Remove dylibs that no remaining Mach-O file links to and that Wine does not dlopen.

Usage: slim-engine.py <Engine dir>
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

# winegstreamer plugs decoders, demuxers, parsers, muxers and an H.264 encoder through
# decodebin and element factories, so every local decode path stays. These plugins are
# sources, sinks, cloud services, effects or encoders that Wine never asks for.
UNUSED_GSTREAMER_PLUGINS = {
    # Network and streaming
    "adaptivedemux2", "aws", "curl", "dash", "dtls", "hls", "hlsmultivariantsink",
    "hlssink3", "icecast", "ipcpipeline", "mpegtslive", "mse", "ndi", "netsim", "nice",
    "quinn", "reqwest", "rfbsrc", "rist", "rsonvif", "rsrtp", "rsrtsp", "rswebrtc", "rtmp",
    "rtmp2", "rtp", "rtpmanager", "rtpmanagerbad", "rtponvif", "rtsp", "rtspclientsink",
    "sctp", "sdpelem", "shm", "smoothstreaming", "soup", "srt", "srtp", "tcp",
    "threadshare", "udp", "unixfd", "webrtc", "webrtchttp",
    # Cloud speech and AI
    "demucs", "elevenlabs", "speechmatics",
    # Tracers and debug
    "coretracers", "debug", "debugutilsbad", "rstracers",
    # Capture, output and GPU elements
    "decklink", "dvdread", "jack", "opengl", "osxvideo", "resindvd", "vulkan",
    # Effects, visualizers and rendering
    "audiovisualizers", "cairo", "coloreffects", "effectv", "frei0r", "gaudieffects",
    "gdkpixbuf", "geometrictransform", "goom", "goom2k1", "ladspa", "pango", "qroverlay",
    "rsaudiofx", "rsvg", "rsvideofx", "zbar",
    # Pipeline helpers for apps, not for decoding
    "accurip", "camerabin", "dtmf", "encoding", "fallbackswitch", "gopbuffer", "json",
    "livesync", "raptorq", "regex", "spandsp", "streamgrouper", "textahead", "textwrap",
    "togglerecord", "transcode", "uriplaylistbin",
    # Encoders Wine has no MFT for (Wine encodes H.264 only)
    "rav1e", "svtav1", "x265",
}

PE_STRIP_TOOLS = {
    "x86_64-windows": "x86_64-w64-mingw32-strip",
    "i386-windows": "i686-w64-mingw32-strip",
}

DYLIB_NAME = re.compile(rb"lib[A-Za-z0-9_.+-]+\.dylib")


def require_pe_strip_tools() -> None:
    missing = [tool for tool in PE_STRIP_TOOLS.values() if shutil.which(tool) is None]
    if missing:
        sys.exit(f"{' and '.join(missing)} not found (brew install mingw-w64)")


def strip_pe_debug_data(engine_dir: Path) -> None:
    require_pe_strip_tools()
    for subdir, tool in PE_STRIP_TOOLS.items():
        pe_files = [str(p) for p in (engine_dir / "lib/wine" / subdir).iterdir() if p.is_file()]
        subprocess.run([tool, "--strip-debug", *pe_files], check=True)


def remove_unused_gstreamer_plugins(engine_dir: Path) -> None:
    plugin_dir = engine_dir / "lib/gstreamer-1.0"
    for plugin in UNUSED_GSTREAMER_PLUGINS:
        (plugin_dir / f"libgst{plugin}.dylib").unlink(missing_ok=True)


def is_mach_o(path: Path) -> bool:
    with path.open("rb") as file:
        return file.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")


def referenced_dylib_names(mach_o: Path) -> set[str]:
    """Load commands and dlopen() strings both hold the plain dylib file name."""
    names = {name.decode() for name in DYLIB_NAME.findall(mach_o.read_bytes())}
    names.discard(mach_o.name)
    return names


def remove_unreferenced_dylibs(engine_dir: Path) -> None:
    lib_dir = engine_dir / "lib"
    while True:
        mach_o_files = [p for p in engine_dir.rglob("*") if p.is_file() and is_mach_o(p)]
        needed_names = set().union(*(referenced_dylib_names(p) for p in mach_o_files))
        unneeded_dylibs = [p for p in lib_dir.glob("*.dylib") if p.name not in needed_names]
        if not unneeded_dylibs:
            return
        for dylib in unneeded_dylibs:
            dylib.unlink()


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--require-tools":
        require_pe_strip_tools()
        return
    engine_dir = Path(sys.argv[1]).resolve()
    if not (engine_dir / "bin/wine").is_file():
        sys.exit(f"{engine_dir} is not a Wine Engine tree")
    strip_pe_debug_data(engine_dir)
    remove_unused_gstreamer_plugins(engine_dir)
    remove_unreferenced_dylibs(engine_dir)


if __name__ == "__main__":
    main()
