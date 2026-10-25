"""Zeichnet die Titelbilder der erfundenen Spiele des Demo-Modus – eigene Bilder, damit Screenshots und Demo keine
fremden Marken zeigen. Aufruf: python3 tools/make-demo-covers.py Resources/Demo.xcassets"""
import json, math, os, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1280, 720
OUT = sys.argv[1]
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
DIN = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"
ROCKWELL = "/System/Library/Fonts/Supplemental/Rockwell.ttc"

def gradient(top, bottom):
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        t = y / (H - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(W):
            px[x, y] = c
    return img

def title(img, text, font_path, size, fill, y=None, index=0, shadow=(0, 0, 0, 150)):
    font = ImageFont.truetype(font_path, size, index=index)
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    box = d.textbbox((0, 0), text, font=font)
    x = (W - (box[2] - box[0])) // 2
    y = y if y is not None else (H - (box[3] - box[1])) // 2
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).text((x + 4, y + 6), text, font=font, fill=shadow)
    glow = glow.filter(ImageFilter.GaussianBlur(8))
    d.text((x, y), text, font=font, fill=fill)
    out = Image.alpha_composite(img.convert("RGBA"), glow)
    return Image.alpha_composite(out, layer).convert("RGB")

def stars(d, n, rng, color=(255, 255, 255)):
    for _ in range(n):
        x, y, r = rng.randrange(W), rng.randrange(H), rng.choice([1, 1, 2, 3])
        d.ellipse((x - r, y - r, x + r, y + r), fill=color)

def mountains(d, base, color, rng, peaks=6, height=260):
    pts = [(0, H)]
    for i in range(peaks + 1):
        x = i * W / peaks
        pts.append((x, base - rng.randrange(height // 3, height)))
    pts.append((W, H))
    d.polygon(pts, fill=color)

def covers():
    rng = random.Random(7)
    c = {}

    img = gradient((10, 12, 48), (88, 30, 120)); d = ImageDraw.Draw(img); stars(d, 260, rng)
    d.ellipse((820, 90, 1100, 370), fill=(255, 170, 90)); d.ellipse((860, 120, 1140, 400), fill=(60, 20, 90))
    mountains(d, 640, (30, 12, 50), rng)
    c["starfall"] = title(img, "STARFALL RANGERS", FUTURA, 104, (255, 236, 200), y=420, index=2)

    img = gradient((5, 5, 20), (20, 0, 40)); d = ImageDraw.Draw(img)
    for i in range(16):
        y = 380 + i * 22; d.line((0, y + i * 6, W, y - i * 4), fill=(255, 40 + i * 10, 200), width=4)
    for i in range(9):
        x = 140 + i * 125; d.rounded_rectangle((x, 150, x + 80, 230), radius=14, outline=(80, 240, 255), width=6)
    c["neonrhythm"] = title(img, "NEON RHYTHM", DIN, 190, (120, 250, 255), y=240)

    img = gradient((250, 180, 120), (60, 80, 140)); d = ImageDraw.Draw(img)
    d.ellipse((540, 220, 740, 420), fill=(255, 230, 160)); d.rectangle((0, 470, W, H), fill=(40, 70, 120))
    for i in range(14):
        d.line((100 + i * 80, 500 + (i % 3) * 30, 160 + i * 80, 500 + (i % 3) * 30), fill=(255, 220, 160), width=4)
    d.rectangle((180, 300, 220, 470), fill=(30, 30, 40)); d.polygon([(160, 300), (240, 300), (200, 250)], fill=(220, 60, 50))
    c["harbor"] = title(img, "Harbor Lights", ROCKWELL, 120, (255, 250, 240), y=540)

    img = gradient((160, 220, 255), (210, 245, 220)); d = ImageDraw.Draw(img)
    for _ in range(22):
        x, y, r = rng.randrange(W), rng.randrange(200, H), rng.randrange(20, 70)
        col = rng.choice([(255, 120, 150), (255, 200, 80), (140, 110, 255), (90, 200, 120)])
        d.ellipse((x - r, y - r, x + r, y + r), fill=col)
    d.ellipse((520, 60, 760, 300), outline=(90, 140, 90), width=10)
    c["gravitygarden"] = title(img, "Gravity Garden", FUTURA, 120, (40, 90, 60), y=300, index=0, shadow=(255, 255, 255, 160))

    img = gradient((0, 70, 110), (0, 20, 40)); d = ImageDraw.Draw(img)
    for i in range(7):
        x = 120 + i * 170; d.polygon([(x, H), (x + 30, 420 - (i % 3) * 60), (x + 60, H)], fill=(255, 110 - i * 8, 110))
    for _ in range(40):
        x, y, r = rng.randrange(W), rng.randrange(H), rng.randrange(3, 12)
        d.ellipse((x - r, y - r, x + r, y + r), outline=(180, 240, 255), width=2)
    c["deepreef"] = title(img, "DEEP REEF EXPLORER", DIN, 150, (210, 250, 255), y=220)

    img = gradient((120, 190, 255), (255, 240, 220)); d = ImageDraw.Draw(img)
    for x, y in [(160, 160), (900, 120), (520, 260)]:
        d.ellipse((x, y, x + 220, y + 80), fill=(255, 255, 255)); d.ellipse((x + 60, y - 40, x + 180, y + 60), fill=(255, 255, 255))
    d.polygon([(560, 470), (760, 430), (700, 520)], fill=(230, 80, 60)); d.rectangle((600, 460, 720, 500), fill=(250, 200, 70))
    c["skycourier"] = title(img, "SKY COURIER", FUTURA, 140, (30, 60, 120), y=520, index=2, shadow=(255, 255, 255, 140))

    img = gradient((70, 140, 70), (30, 70, 40)); d = ImageDraw.Draw(img)
    for i in range(5):
        x = 140 + i * 230; h = 160 + (i % 2) * 80
        d.rectangle((x, 520 - h, x + 120, 520), fill=(200, 180, 150)); d.polygon([(x - 20, 520 - h), (x + 140, 520 - h), (x + 60, 420 - h)], fill=(160, 50, 50))
    d.rectangle((0, 520, W, H), fill=(60, 110, 50))
    c["pocketkingdoms"] = title(img, "Pocket Kingdoms", ROCKWELL, 120, (255, 240, 200), y=560)

    img = gradient((140, 200, 255), (220, 240, 255)); d = ImageDraw.Draw(img)
    mountains(d, 520, (90, 110, 150), rng, peaks=4, height=300); d.rectangle((0, 560, W, H), fill=(80, 170, 90))
    d.ellipse((600, 600, 640, 640), fill=(255, 255, 255)); d.line((900, 460, 900, 610), fill=(60, 60, 60), width=6); d.polygon([(900, 460), (980, 485), (900, 510)], fill=(230, 60, 60))
    c["mountaingolf"] = title(img, "Mountain Golf Club", FUTURA, 110, (255, 255, 255), y=200, index=0)

    img = gradient((25, 25, 30), (60, 20, 20)); d = ImageDraw.Draw(img)
    for i in range(10):
        d.polygon([(i * 140, H), (i * 140 + 300, 380), (i * 140 + 330, 380), (i * 140 + 30, H)], fill=(255, 180 - i * 12, 40))
    c["echoracers"] = title(img, "ECHO RACERS", DIN, 200, (255, 245, 230), y=190)

    img = gradient((10, 30, 30), (20, 60, 50)); d = ImageDraw.Draw(img)
    for i in range(12):
        x = rng.randrange(W); d.rectangle((x, 0, x + rng.randrange(20, 50), H), fill=(10, 25 + i, 22))
    for _ in range(18):
        x, y = rng.randrange(W), rng.randrange(200, 650)
        lamp = Image.new("RGBA", (120, 120), (0, 0, 0, 0)); ImageDraw.Draw(lamp).ellipse((30, 30, 90, 90), fill=(255, 210, 120, 255))
        img.paste(lamp.filter(ImageFilter.GaussianBlur(10)), (x - 60, y - 60), lamp.filter(ImageFilter.GaussianBlur(10)))
    c["lanternwoods"] = title(img, "Lantern Woods", ROCKWELL, 130, (255, 225, 160), y=300)

    img = gradient((30, 20, 60), (90, 60, 140)); d = ImageDraw.Draw(img); stars(d, 120, rng)
    d.ellipse((480, 200, 800, 520), fill=(250, 250, 255)); d.ellipse((560, 330, 720, 380), fill=(240, 140, 60))
    d.arc((380, 160, 900, 560), 200, 340, fill=(255, 200, 90), width=10)
    c["orbitchef"] = title(img, "ORBIT CHEF", FUTURA, 140, (255, 220, 120), y=560, index=2)

    img = gradient((20, 20, 20), (50, 50, 60)); d = ImageDraw.Draw(img)
    for x in range(0, W, 32):
        for y in range(0, H, 32):
            if rng.random() < 0.08: d.rectangle((x, y, x + 28, y + 28), fill=rng.choice([(80, 220, 120), (240, 90, 90), (90, 160, 255)]))
    d.rectangle((140, 300, 170, 440), fill=(255, 255, 255)); d.rectangle((1110, 260, 1140, 400), fill=(255, 255, 255)); d.rectangle((620, 360, 650, 390), fill=(255, 255, 255))
    c["pixelpaddle"] = title(img, "PIXEL PADDLE", DIN, 180, (255, 255, 255), y=230)
    return c

def write(name, image):
    folder = os.path.join(OUT, f"demo-{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    image.save(os.path.join(folder, f"{name}.jpg"), quality=82)
    json.dump({"images": [{"filename": f"{name}.jpg", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}},
              open(os.path.join(folder, "Contents.json"), "w"), indent=2)

os.makedirs(OUT, exist_ok=True)
json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, "Contents.json"), "w"), indent=2)
for name, image in covers().items():
    write(name, image)
print("ok")
