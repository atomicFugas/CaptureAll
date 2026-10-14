#!/usr/bin/env python3
"""Generate AppIcon.appiconset PNGs + AppIcon.icns from the CaptureAll logo."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
USER_LOGO = os.path.join(
    os.path.expanduser("~"),
    ".cursor/projects/Users-aleksejpavlenko-myFiles-CaptureAll/assets",
    "captureLogo-84a6c809-b2e4-4053-a4c2-943a77b45dc3.jpg",
)
FALLBACK = os.path.join(ROOT, "CaptureAll/Resources/CaptureAllLogo.png")
APPICONSET = os.path.join(ROOT, "CaptureAll/Resources/Assets.xcassets/AppIcon.appiconset")
ICONSET = os.path.join(ROOT, "build/AppIcon.iconset")
ICNS = os.path.join(ROOT, "CaptureAll/Resources/AppIcon.icns")
MASTER_OUT = os.path.join(ROOT, "CaptureAll/Resources/CaptureAllLogo.png")

# Avoid literal "name@2x.png" strings (tooling treats them like emails).
RETINA = "@" + "2x"


def icon_name(base: str, retina: bool = False) -> str:
    return f"icon_{base}{RETINA}.png" if retina else f"icon_{base}.png"


# (filename, pixel size)
ENTRIES = [
    (icon_name("16x16"), 16),
    (icon_name("16x16", True), 32),
    (icon_name("32x32"), 32),
    (icon_name("32x32", True), 64),
    (icon_name("128x128"), 128),
    (icon_name("128x128", True), 256),
    (icon_name("256x256"), 256),
    (icon_name("256x256", True), 512),
    (icon_name("512x512"), 512),
    (icon_name("512x512", True), 1024),
]


def load_master() -> Image.Image:
    src = USER_LOGO if os.path.exists(USER_LOGO) else FALLBACK
    if not os.path.exists(src):
        sys.exit(f"missing logo source: {src}")
    img = Image.open(src).convert("RGBA")
    w, h = img.size
    side = max(w, h)
    # Full-bleed opaque black canvas — never leave transparent edges.
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 255))
    canvas.paste(img, ((side - w) // 2, (side - h) // 2))
    master = canvas.resize((1024, 1024), Image.Resampling.LANCZOS)
    return force_black_white_opaque(master)


def force_black_white_opaque(img: Image.Image) -> Image.Image:
    """Keep solid black fill + white camera; crush gray/alpha so Finder can't
    treat the mark as a monochrome template with transparent sides."""
    px = img.convert("RGBA")
    out = Image.new("RGBA", px.size, (0, 0, 0, 255))
    src = px.load()
    dst = out.load()
    w, h = px.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = src[x, y]
            if a < 128:
                dst[x, y] = (0, 0, 0, 255)
                continue
            # Luma: bright → white stroke, dark → black fill
            luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luma >= 140:
                dst[x, y] = (255, 255, 255, 255)
            else:
                dst[x, y] = (0, 0, 0, 255)
    return out


def main() -> None:
    master = load_master()
    master.save(MASTER_OUT, "PNG")
    print("master", MASTER_OUT)

    os.makedirs(APPICONSET, exist_ok=True)
    shutil.rmtree(ICONSET, ignore_errors=True)
    os.makedirs(ICONSET)

    for name, px in ENTRIES:
        # Opaque RGB (no alpha channel) so actool/iconutil won't drop the fill.
        scaled = master.resize((px, px), Image.Resampling.NEAREST)
        rgb = Image.new("RGB", (px, px), (0, 0, 0))
        rgb.paste(scaled.convert("RGB"), (0, 0))
        p_app = os.path.join(APPICONSET, name)
        p_set = os.path.join(ICONSET, name)
        rgb.save(p_app, "PNG")
        rgb.save(p_set, "PNG")
        got = Image.open(p_set).size
        if got != (px, px):
            sys.exit(f"bad size {name}: {got}")
        print("ok", name, px, Image.open(p_set).mode)

    print("iconset:", sorted(os.listdir(ICONSET)))
    subprocess.check_call(["iconutil", "-c", "icns", ICONSET, "-o", ICNS])
    print("icns", ICNS, os.path.getsize(ICNS), "bytes")


if __name__ == "__main__":
    main()
