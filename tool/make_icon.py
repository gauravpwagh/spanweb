"""Draws the app icon and writes every Android and iOS size.

Run from the project root:  python tool/make_icon.py
Design: a white padlock whose body holds an indigo chain link, on indigo.
"""
import json
import os

from PIL import Image, ImageChops, ImageDraw

SS = 4                     # supersampling for smooth edges
N = 1024 * SS              # master canvas
TOP = (0x5C, 0x6B, 0xC0)   # indigo 400
BOTTOM = (0x28, 0x35, 0x93)  # indigo 800
INK = (0x30, 0x3F, 0x9F)   # indigo 700, the chain link
WHITE = (255, 255, 255)


def s(v):
    return int(v * SS)


def background(size=N):
    """Diagonal indigo gradient."""
    v = Image.linear_gradient("L")             # 0 at top, 255 at bottom
    h = v.transpose(Image.TRANSPOSE)           # 0 at left, 255 at right
    g =Image.blend(v, h, 0.5).resize((size, size), Image.BICUBIC)  # (x+y)/2
    r = g.point(lambda t: int(TOP[0] + (BOTTOM[0] - TOP[0]) * t / 255))
    gg = g.point(lambda t: int(TOP[1] + (BOTTOM[1] - TOP[1]) * t / 255))
    b = g.point(lambda t: int(TOP[2] + (BOTTOM[2] - TOP[2]) * t / 255))
    return Image.merge("RGB", (r, gg, b))


def stadium(w, h, stroke):
    """An outlined pill shape (one chain link) on a transparent layer."""
    layer = Image.new("L", (s(w) + 8, s(h) + 8), 0)
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((4, 4, 4 + s(w), 4 + s(h)), radius=s(h) // 2, fill=255)
    d.rounded_rectangle(
        (4 + s(stroke), 4 + s(stroke), 4 + s(w - stroke), 4 + s(h - stroke)),
        radius=s(h - 2 * stroke) // 2, fill=0)
    return layer


def glyph(scale=1.0):
    """Mask of the padlock (white) and mask of the chain link (cut-in colour).

    Coordinates are on a 1024 grid, scaled about the centre by [scale]."""
    lock = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(lock)
    # shackle: a thick U
    sw = 64
    sx0, sx1, sy0, sy1 = 352, 672, 214, 470
    d.rounded_rectangle((s(sx0), s(sy0), s(sx1), s(sy1 + 200)),
                        radius=s((sx1 - sx0) / 2), fill=255)
    d.rounded_rectangle((s(sx0 + sw), s(sy0 + sw), s(sx1 - sw), s(sy1 + 200)),
                        radius=s((sx1 - sx0 - 2 * sw) / 2), fill=0)
    # body
    d.rounded_rectangle((s(282), s(440), s(742), s(820)), radius=s(84), fill=255)

    # chain link: two interlocked pills at -45 degrees, centred in the body
    link = Image.new("L", (N, N), 0)
    # Each pill is drawn horizontally, the pair rotated 45 degrees at the end.
    # They overlap by one cap; where the second crosses the first, the first
    # is cut away around it, so the two read as interlocked.
    w, h, st, gap = 236, 128, 42, 20
    sep = 172                                   # centre-to-centre distance
    size = (s(w + sep + 2 * gap) + 80, s(h + 2 * gap) + 80)
    ax, bx, y = 40 + s(gap), 40 + s(gap + sep), 40 + s(gap)

    def place(img, x, yy):
        layer = Image.new("L", size, 0)
        layer.paste(255, (x - 4, yy - 4), img)
        return layer

    A = place(stadium(w, h, st), ax, y)
    B = place(stadium(w, h, st), bx, y)
    # the same pills grown by [gap] on both sides of the stroke
    Ad = place(stadium(w + 2 * gap, h + 2 * gap, st + 2 * gap), ax - s(gap), y - s(gap))
    Bd = place(stadium(w + 2 * gap, h + 2 * gap, st + 2 * gap), bx - s(gap), y - s(gap))
    top = Image.new("L", size, 0)
    ImageDraw.Draw(top).rectangle((0, 0, size[0], y + s(h) // 2), fill=255)
    bottom = ImageChops.invert(top)
    # top crossing: A passes over B; bottom crossing: B passes over A
    A = ImageChops.subtract(A, ImageChops.multiply(Bd, bottom))
    B = ImageChops.subtract(B, ImageChops.multiply(Ad, top))
    pair = ImageChops.lighter(A, B)
    pair = pair.rotate(45, expand=True, resample=Image.BICUBIC)
    link.paste(255, (s(512) - pair.width // 2, s(630) - pair.height // 2), pair)

    if scale != 1.0:
        def sc(m):
            k = int(N * scale)
            m2 = m.resize((k, k), Image.LANCZOS)
            out = Image.new("L", (N, N), 0)
            out.paste(m2, ((N - k) // 2, (N - k) // 2))
            return out
        lock, link = sc(lock), sc(link)
    return lock, link


def foreground(scale, transparent=True):
    """Glyph on a transparent canvas (adaptive foreground) or on the gradient."""
    lock, link = glyph(scale)
    base = Image.new("RGBA", (N, N), (0, 0, 0, 0)) if transparent else background().convert("RGBA")
    white = Image.new("RGBA", (N, N), WHITE + (255,))
    base.paste(white, (0, 0), lock)
    ink = Image.new("RGBA", (N, N), INK + (255,))
    base.paste(ink, (0, 0), ImageChops.multiply(link, lock))
    return base


def down(img, px):
    return img.resize((px, px), Image.LANCZOS)


def rounded(img, radius_frac):
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, img.width - 1, img.height - 1),
                                        radius=int(img.width * radius_frac), fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), m)
    return out


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res = os.path.join(root, "android", "app", "src", "main", "res")

    # Full-bleed square icon (iOS, Play Store, previews). Glyph fills ~70%.
    full = foreground(1.0, transparent=False).convert("RGB")
    # Adaptive foreground: 108dp canvas, keep the glyph inside the 66dp safe
    # zone (launchers crop to circles, squircles...).
    fg = foreground(0.84)
    lock_only, link_only = glyph(0.84)
    mono = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    mono.paste(Image.new("RGBA", (N, N), (0, 0, 0, 255)), (0, 0),
               ImageChops.subtract(lock_only, link_only))

    os.makedirs(os.path.join(root, "assets", "icon"), exist_ok=True)
    down(full, 1024).save(os.path.join(root, "assets", "icon", "icon-1024.png"))
    down(full, 512).save(os.path.join(root, "assets", "icon", "play-store-512.png"))

    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, f in densities.items():
        d = os.path.join(res, f"mipmap-{name}")
        os.makedirs(d, exist_ok=True)
        # legacy icon (Android 7): rounded square, 48dp
        down(rounded(full.convert("RGBA"), 0.18), int(48 * f)).save(os.path.join(d, "ic_launcher.png"))
        down(fg, int(108 * f)).save(os.path.join(d, "ic_launcher_foreground.png"))
        down(mono, int(108 * f)).save(os.path.join(d, "ic_launcher_monochrome.png"))
        down(background(), int(108 * f)).save(os.path.join(d, "ic_launcher_background.png"))

    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as fh:
        fh.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
            '</adaptive-icon>\n')

    # iOS: every size listed in Contents.json, opaque (App Store rejects alpha).
    ios = os.path.join(root, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    with open(os.path.join(ios, "Contents.json"), encoding="utf-8") as fh:
        images = json.load(fh)["images"]
    for im in images:
        pt = float(im["size"].split("x")[0])
        px = round(pt * int(im["scale"][0]))
        down(full, px).save(os.path.join(ios, im["filename"]))
    print("icons written")


if __name__ == "__main__":
    main()
