"""Generate the Boomio brand artwork for the tvOS asset catalog.

Everything the App Store / home screen / Top Shelf shows is drawn here: the
layered app icon, the App Store icon, both Top Shelf sizes, the splash, the
wordmark and the packaging icon. The mark is the white "boomio" wordmark on the
same near-black gradient the app uses, with a soft accent glow under the text.

Run from anywhere:  python3 scripts/make-brand-artwork.py
Requires Pillow and the Quicksand font (fonts-quicksand on Debian/Ubuntu).
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT_BOLD = "/usr/share/fonts/truetype/quicksand/Quicksand-Bold.ttf"

BG_TOP = (18, 22, 30)
BG_BOTTOM = (5, 7, 10)
ACCENT = (124, 242, 155)   # the green already used for the signed-in tick
WHITE = (255, 255, 255)

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "tvosApp", "NuvioTV")
ASSETS = os.path.join(ROOT, "Images.xcassets")
BRAND = os.path.join(ASSETS, "AppIcon.brandassets")


def vgradient(size, top=BG_TOP, bottom=BG_BOTTOM):
    w, h = size
    img = Image.new("RGB", (1, h))
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return img.resize((w, h), Image.BILINEAR).convert("RGBA")


def fit_font(text, font_path, target_w):
    """Largest point size whose rendered width fits `target_w`."""
    lo, hi = 8, 4000
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        f = ImageFont.truetype(font_path, mid)
        if f.getlength(text) <= target_w:
            best = f
            lo = mid + 1
        else:
            hi = mid - 1
    return best or ImageFont.truetype(font_path, 8)


def draw_wordmark(img, text="boomio", ratio=0.62, color=WHITE, y_offset=0.0):
    w, h = img.size
    font = fit_font(text, FONT_BOLD, int(w * ratio))
    d = ImageDraw.Draw(img)
    tw = font.getlength(text)
    asc, desc = font.getmetrics()
    th = asc + desc
    d.text(((w - tw) / 2, (h - th) / 2 + y_offset * h), text, font=font, fill=color)
    return img


def draw_front_mark(size):
    """The layered icon's front layer: the wordmark only, transparent elsewhere."""
    return draw_wordmark(Image.new("RGBA", size, (0, 0, 0, 0)), "boomio", ratio=0.60)


def draw_back(size):
    """The layered icon's back layer: the gradient, plus a soft accent glow."""
    img = vgradient(size)
    w, h = size
    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    # A wide, low-opacity ellipse under the wordmark reads as depth at 400x240.
    # Blurred, because a hard edge turns a parallax layer into a visible slab.
    gd.ellipse([w * 0.10, h * 0.55, w * 0.90, h * 0.98], fill=ACCENT + (26,))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=max(w, h) * 0.09))
    return Image.alpha_composite(img, glow)


def save(img, path, scale_from=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if scale_from:
        img = img.resize(scale_from, Image.LANCZOS)
    img.save(path, "PNG", optimize=True)
    print("wrote", path, Image.open(path).size)


def main():
    # ── Layered app icon (tvOS home screen) ──────────────────────────────
    for layer, fn in (("Back", draw_back), ("Front", draw_front_mark)):
        d = os.path.join(BRAND, "App Icon.imagestack", f"{layer}.imagestacklayer",
                         "Content.imageset")
        save(fn((400, 240)), os.path.join(d, "content.png"))
        save(fn((800, 480)), os.path.join(d, "content@2x.png"))

    # ── App Store icon ───────────────────────────────────────────────────
    d = os.path.join(BRAND, "App Icon - App Store.imagestack")
    save(draw_back((1280, 768)),
         os.path.join(d, "Back.imagestacklayer", "Content.imageset", "content.png"))
    save(draw_front_mark((1280, 768)),
         os.path.join(d, "Front.imagestacklayer", "Content.imageset", "content.png"))

    # ── Top Shelf ────────────────────────────────────────────────────────
    for name, size in (("Top Shelf Image", (1920, 720)),
                       ("Top Shelf Image Wide", (2320, 720))):
        img = draw_wordmark(vgradient(size), "boomio", ratio=0.26)
        d = os.path.join(BRAND, f"{name}.imageset")
        save(img, os.path.join(d, "content.png"))
        save(img, os.path.join(d, "content@2x.png"), scale_from=(size[0] * 2, size[1] * 2))

    # ── Splash ───────────────────────────────────────────────────────────
    splash = draw_wordmark(vgradient((2048, 2048)), "boomio", ratio=0.46)
    d = os.path.join(ASSETS, "SplashScreenLegacy.imageset")
    for f in ("image.png", "image@2x.png", "image@3x.png"):
        save(splash, os.path.join(d, f))

    # ── Wordmark asset ───────────────────────────────────────────────────
    # Contents.json declares 1x and 2x; both must be written or the 1x slot
    # keeps whatever artwork was there before.
    wm = Image.new("RGBA", (1112, 264), (0, 0, 0, 0))
    draw_wordmark(wm, "boomio", ratio=0.92)
    save(wm, os.path.join(ASSETS, "BrandWordmark.imageset", "wordmark@2x.png"))
    save(wm, os.path.join(ASSETS, "BrandWordmark.imageset", "wordmark.png"),
         scale_from=(556, 132))

    # ── Resources/AppIcon.png (used by packaging scripts) ────────────────
    icon = Image.alpha_composite(vgradient((1024, 1024)), draw_front_mark((1024, 1024)))
    save(icon, os.path.join(ROOT, "Resources", "AppIcon.png"))


if __name__ == "__main__":
    main()
