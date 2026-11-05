#!/usr/bin/env python3
"""Dual app icons (plan §12). Reads colors.json, draws the shared geometry,
writes 7 appiconsets (light, dark, tinted), 7 IconPreview imagesets (light and
dark), dual-icon.svg (vector source for Icon Composer) and a contact sheet.
Deterministic: same inputs -> same PNG bytes. Needs Pillow only.

  python3 Design/Icon/render_icons.py            # writes into App/Assets.xcassets
"""
import json, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageChops

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ASSETS = ROOT / "App" / "Assets.xcassets"
SS = 4                      # supersampling
W = 1024
# Geometry (1024 canvas): frame and glass, from §12.2.
FRAME = (176, 164, 176 + 600, 164 + 600); FRAME_R = 128; STROKE = 20
GLASS = (540, 500, 540 + 328, 500 + 328); GLASS_R = 72

def hexrgb(h): h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def s(box): return tuple(v * SS for v in box)

def rrect_mask(box, r, outline=None):
    m = Image.new("L", (W * SS, W * SS), 0)
    d = ImageDraw.Draw(m)
    if outline: d.rounded_rectangle(s(box), r * SS, outline=255, width=outline * SS)
    else: d.rounded_rectangle(s(box), r * SS, fill=255)
    return m

def gradient(stops, darken=1.0):
    """Linear gradient along the glass diagonal, top-left -> bottom-right."""
    cols = [tuple(min(255, int(c * darken)) for c in hexrgb(x)) for x in stops]
    n = 256
    ramp = Image.new("RGB", (n, 1))
    for i in range(n):
        t = i / (n - 1)
        a, b, u = (cols[0], cols[1], t * 2) if t < 0.5 else (cols[1], cols[2], (t - 0.5) * 2)
        ramp.putpixel((i, 0), tuple(round(a[k] + (b[k] - a[k]) * u) for k in range(3)))
    gx0, gy0, gx1, gy1 = s(GLASS)
    size = gx1 - gx0
    # diagonal gradient: value = (x + y) / 2 across the glass box
    vert = Image.linear_gradient("L").resize((size, size))
    diag = Image.blend(vert, vert.transpose(Image.Transpose.ROTATE_90).transpose(Image.Transpose.FLIP_LEFT_RIGHT), 0.5)
    lut = [ramp.getpixel((v, 0)) for v in range(256)]
    rgb = Image.merge("RGB", [diag.point([c[k] for c in lut]) for k in range(3)])
    full = Image.new("RGB", (W * SS, W * SS)); full.paste(rgb, (gx0, gy0))
    return full

def render(stops, variant):
    big = W * SS
    frame_mask = rrect_mask(FRAME, FRAME_R, outline=STROKE)
    glass_mask = rrect_mask(GLASS, GLASS_R)
    if variant == "light":
        base = Image.new("RGBA", (big, big), (255, 255, 255, 255)); line = (0, 0, 0); line_a = 1.0
        glass_a, darken, shadow_a = 0.9, 1.0, 0.08
    elif variant == "dark":
        base = Image.new("RGBA", (big, big), (0, 0, 0, 0)); line = (255, 255, 255); line_a = 0.9
        glass_a, darken, shadow_a = 0.96, 0.82, 0.25
    else:  # tinted: grayscale, shared by all colours
        base = Image.new("RGBA", (big, big), (0, 0, 0, 0)); line = (208, 208, 208); line_a = 1.0
        glass_a, darken, shadow_a = 0.95, 1.0, 0.0
    img = base
    lay = Image.new("RGBA", (big, big), line + (0,)); lay.putalpha(frame_mask.point(lambda v: int(v * line_a)))
    img = Image.alpha_composite(img, lay)
    if shadow_a:
        sh = rrect_mask((GLASS[0], GLASS[1] + 12, GLASS[2], GLASS[3] + 12), GLASS_R).filter(ImageFilter.GaussianBlur(24 * SS / 2))
        lay = Image.new("RGBA", (big, big), (0, 0, 0, 0)); lay.putalpha(sh.point(lambda v: int(v * shadow_a)))
        img = Image.alpha_composite(img, lay)
    if variant == "tinted":
        fill = Image.new("RGB", (big, big), (128, 128, 128))
    else:
        fill = gradient(stops, darken)
    lay = fill.convert("RGBA"); lay.putalpha(glass_mask.point(lambda v: int(v * glass_a)))
    img = Image.alpha_composite(img, lay)
    # Frosted line: blurred copy of the covered frame segment, clipped to the glass.
    blur = frame_mask.filter(ImageFilter.GaussianBlur(10 * SS / 2))
    seen = ImageChops.multiply(blur, glass_mask).point(lambda v: int(v * 0.35))
    lay = Image.new("RGBA", (big, big), line + (0,)); lay.putalpha(seen)
    img = Image.alpha_composite(img, lay)
    # 1 px highlight on the glass edge.
    hi = rrect_mask(GLASS, GLASS_R, outline=1).point(lambda v: int(v * (0.7 if variant != "tinted" else 0.5)))
    lay = Image.new("RGBA", (big, big), (255, 255, 255, 0)); lay.putalpha(hi)
    img = Image.alpha_composite(img, lay)
    img = img.resize((W, W), Image.LANCZOS)
    if variant == "light": return img.convert("RGB")
    if variant == "tinted": return img.convert("LA")
    return img

def svg(stops):
    gx0, gy0, gx1, gy1 = GLASS
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <!-- Dual icon, light appearance. Glass colour = the three --glass-* stops (colors.json). -->
  <defs>
    <linearGradient id="glass" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{stops[0]}"/><stop offset="0.5" stop-color="{stops[1]}"/><stop offset="1" stop-color="{stops[2]}"/>
    </linearGradient>
    <clipPath id="glassClip"><rect x="{gx0}" y="{gy0}" width="{gx1 - gx0}" height="{gy1 - gy0}" rx="{GLASS_R}"/></clipPath>
    <filter id="frost"><feGaussianBlur stdDeviation="5"/></filter>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="12" stdDeviation="12" flood-color="#000" flood-opacity="0.08"/></filter>
  </defs>
  <rect id="background" width="1024" height="1024" fill="#FFFFFF"/>
  <rect id="frame" x="{FRAME[0] + STROKE / 2}" y="{FRAME[1] + STROKE / 2}" width="{600 - STROKE}" height="{600 - STROKE}" rx="{FRAME_R - STROKE / 2}" fill="none" stroke="#000" stroke-width="{STROKE}"/>
  <g id="glass-layer">
    <rect x="{gx0}" y="{gy0}" width="{gx1 - gx0}" height="{gy1 - gy0}" rx="{GLASS_R}" fill="url(#glass)" fill-opacity="0.9" filter="url(#shadow)"/>
    <g clip-path="url(#glassClip)" opacity="0.35"><rect x="{FRAME[0] + STROKE / 2}" y="{FRAME[1] + STROKE / 2}" width="{600 - STROKE}" height="{600 - STROKE}" rx="{FRAME_R - STROKE / 2}" fill="none" stroke="#000" stroke-width="{STROKE}" filter="url(#frost)"/></g>
    <rect x="{gx0 + 0.5}" y="{gy0 + 0.5}" width="{gx1 - gx0 - 1}" height="{gy1 - gy0 - 1}" rx="{GLASS_R}" fill="none" stroke="#FFF" stroke-opacity="0.7" stroke-width="1"/>
  </g>
</svg>
'''

def write_json(path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False, sort_keys=True) + "\n")

def main(out_assets=ASSETS):
    cfg = json.loads((HERE / "colors.json").read_text())
    tinted = render(cfg["colors"][cfg["primary"]]["stops"], "tinted")
    sheet = Image.new("RGB", (len(cfg["order"]) * 220 + 20, 3 * 220 + 20), (128, 128, 128))
    for i, key in enumerate(cfg["order"]):
        stops = cfg["colors"][key]["stops"]
        name = "AppIcon" if key == cfg["primary"] else f"AppIcon-{key}"
        d = out_assets / f"{name}.appiconset"; d.mkdir(parents=True, exist_ok=True)
        light, dark = render(stops, "light"), render(stops, "dark")
        light.save(d / "light.png", optimize=True); dark.save(d / "dark.png", optimize=True); tinted.save(d / "tinted.png", optimize=True)
        for old in d.glob("*.png"):
            if old.name not in ("light.png", "dark.png", "tinted.png"): old.unlink()
        write_json(d / "Contents.json", {"images": [
            {"filename": "light.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1}})
        p = out_assets / f"IconPreview-{key}.imageset"; p.mkdir(parents=True, exist_ok=True)
        light.resize((180, 180), Image.LANCZOS).save(p / "light.png", optimize=True)
        dk = Image.new("RGBA", (W, W), (28, 28, 30, 255)); dk = Image.alpha_composite(dk, dark).convert("RGB")
        dk.resize((180, 180), Image.LANCZOS).save(p / "dark.png", optimize=True)
        write_json(p / "Contents.json", {"images": [
            {"filename": "light.png", "idiom": "universal"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "dark.png", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1}})
        (HERE / "svg").mkdir(exist_ok=True)
        (HERE / "svg" / f"dual-icon-{key.lower()}.svg").write_text(svg(stops))
        # Contact sheet: light / dark (on #1C1C1E) / tinted (on grey), rounded like the home screen.
        mask = Image.new("L", (200, 200), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, 199, 199), 45, fill=255)
        tint_on = Image.alpha_composite(Image.new("RGBA", (W, W), (40, 40, 40, 255)), tinted.convert("RGBA"))
        for row, im in enumerate([light.convert("RGBA"), dk.convert("RGBA"), tint_on]):
            sheet.paste(im.resize((200, 200), Image.LANCZOS), (20 + i * 220, 20 + row * 220), mask)
    (HERE / "dual-icon.svg").write_text(svg(cfg["colors"][cfg["primary"]]["stops"]))
    sheet.save(HERE / "contact-sheet.png", optimize=True)
    print("rendered", len(cfg["order"]), "icons")

if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else ASSETS)
