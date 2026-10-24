"""Zeichnet das App-Icon von AVP Play Remote als visionOS-Ebenenstapel (hinten, Mitte, vorn)."""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter

root = os.path.join(sys.argv[1], "AppIcon.solidimagestack")
S = 1024

def layer(name, image):
    d = os.path.join(root, f"{name}.solidimagestacklayer", "Content.imageset")
    os.makedirs(d, exist_ok=True)
    image.save(os.path.join(d, f"{name.lower()}.png"))
    json.dump({"images": [{"filename": f"{name.lower()}.png", "idiom": "vision", "scale": "2x"}],
               "info": {"author": "xcode", "version": 1}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)
    json.dump({"info": {"author": "xcode", "version": 1}},
              open(os.path.join(root, f"{name}.solidimagestacklayer", "Contents.json"), "w"), indent=2)

# Hinten: ein ruhiger Verlauf von Tiefblau nach Violett.
back = Image.new("RGB", (S, S))
px = back.load()
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * S)
        px[x, y] = (int(28 + 70 * t), int(40 + 20 * t), int(120 + 90 * t))
layer("Back", back)

# Mitte: der Umriss eines Laptops.
mid = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(mid)
d.rounded_rectangle((232, 300, 792, 660), radius=36, outline=(255, 255, 255, 200), width=34)
d.rounded_rectangle((170, 690, 854, 740), radius=24, fill=(255, 255, 255, 200))
layer("Middle", mid)

# Vorn: das Abspielzeichen.
front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(front)
d.polygon([(450, 380), (450, 580), (610, 480)], fill=(255, 255, 255, 255))
layer("Front", front)

json.dump({"info": {"author": "xcode", "version": 1},
           "layers": [{"filename": "Front.solidimagestacklayer"}, {"filename": "Middle.solidimagestacklayer"}, {"filename": "Back.solidimagestacklayer"}]},
          open(os.path.join(root, "Contents.json"), "w"), indent=2)
