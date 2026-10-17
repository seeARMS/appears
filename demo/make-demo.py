# Builds demo/files: a made-up home folder for the eval, tests, screenshots and the site.
# Every person, company, number and address in it is invented. Phone numbers use 555-01xx.
#
#   uv run --with pillow==11.3.0 --with reportlab==4.4.4 python3 -I demo/make-demo.py
#
# Deterministic: the same files every run. demo/manifest.json says how old each file
# should look (the eval sets modification dates from it); demo/scenarios.json lists the
# contexts and what Appears should (or shouldn't) find for each.

import json
import math
import random
import subprocess
import tempfile
import textwrap
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

ROOT = Path(__file__).resolve().parent
FILES = ROOT / "files"
random.seed(7)
ages: dict[str, float] = {}

# Synthetic Messages items are loaded directly into the eval's temporary index.
MESSAGES = [
    {
        "path": "messages:demo-rent-payment",
        "title": "Jordan Vale",
        "text": "Me: Did you pay the final Harbor Oaks apartment rent bill?\nJordan: Yes, I paid the final Harbor Oaks rent bill of $640 this morning. The balance is zero.",
        "age": 2,
    },
    {
        "path": "messages:demo-weekend-plans",
        "title": "Jordan Vale",
        "text": "Jordan: Want to walk around the lake on Saturday?\nMe: Sure, let's meet after breakfast.",
        "age": 1,
    },
    {
        "path": "messages:demo-plant-overwatering",
        "title": "Rina Holt",
        "text": "Me: My pothos has yellow leaves again, any idea why?\nRina: Yellow leaves on a pothos almost always means overwatering. Let the top inch of soil dry out between waterings and make sure the pot drains.",
        "age": 400,
    },
]

# Fictional planning example for the landing page, Markdown and share card.
# Keep the message and source text here so the site never uses real information.
LANDING = {
    "email": {
        "subject": "Re: Next steps",
        "to": "Priya Natarajan",
        "greeting": "Hi Priya,",
        "body": "I'm putting together a plan for the next phase. Let's revisit the scope and timeline we agreed on before we add anything new.",
        "quotedHeader": "On Oct 13, 2026, at 4:18 PM, Priya Natarajan wrote:",
        "quotedBody": "Could you send over a plan for the next phase? It would help to have the priorities and timing in one place.",
    },
    "message": {
        "title": "Priya Natarajan",
        "reason": "Earlier decision on scope · May 2025",
        "text": "Let's keep the scope focused on the essentials and review progress at the end of the month before adding anything new.",
    },
    "document": {
        "title": "Project brief.pdf",
        "reason": "Page 2: scope and timeline · May 2025",
        "text": "Scope and timeline: finish the essential work first. Review progress at the end of the month before planning the next phase.",
    },
    "note": {
        "title": "Planning notes",
        "reason": "Priorities from the last review · May 2025",
        "text": "Keep the next phase focused. Revisit the original scope and timeline with Priya before adding new priorities.",
    },
    "photo": {
        "file": "IMG_2041.HEIC",
        "message": {
            "title": "Maya Chen",
            "reason": "Yellow leaves usually mean overwatering · Jun 2025",
            "text": "If the fig's lower leaves go yellow, it's usually too much water. Let the soil dry out first.",
        },
        "note": {
            "title": "Plant care",
            "reason": "Fiddle-leaf fig: water every 10 days · Mar 2024",
            "text": "Fiddle-leaf fig: bright window, water every 10 days, turn it a quarter each week.",
        },
        "image": {
            "title": "IMG_0412.HEIC",
            "reason": "The same plant, the day you bought it · Mar 2024",
        },
    },
    "meeting": {
        "title": "Kitchen walkthrough",
        "with": "Dana Ortiz",
        "time": "2:00 PM",
        "until": "2:30 PM",
        "message": {
            "title": "Dana Ortiz",
            "reason": "Sent the revised cabinet quote · Last week",
            "text": "Here's the revised quote with the taller cabinets. Happy to go through it on Thursday.",
        },
        "document": {
            "title": "Kitchen quote v2.pdf",
            "reason": "Page 1: cabinets and installation · Oct 2026",
            "text": "Cabinets, countertop and installation, with the taller upper cabinets.",
        },
        "image": {
            "title": "IMG_1877.HEIC",
            "reason": "Your handwritten measurements · Sep 2026",
            "text": "Kitchen: north wall 3.6 m, window 1.2 m, ceiling 2.7 m.",
        },
    },
}
(ROOT / "landing.json").write_text(json.dumps(LANDING, indent=2) + "\n")


def font(names, size):
    for name in names:
        for folder in ["/System/Library/Fonts/Supplemental", "/System/Library/Fonts", "/Library/Fonts"]:
            path = Path(folder) / name
            if path.exists():
                try:
                    return ImageFont.truetype(str(path), size)
                except OSError:
                    pass
    return ImageFont.load_default(size)


HAND = ["Noteworthy.ttc", "Bradley Hand Bold.ttf", "Chalkboard.ttc", "MarkerFelt.ttc"]
SANS = ["HelveticaNeue.ttc", "Helvetica.ttc", "Arial.ttf"]
MONO = ["Menlo.ttc", "Courier New.ttf"]


def write(path, text, age):
    target = FILES / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(textwrap.dedent(text).strip() + "\n")
    ages[path] = age


def pdf(path, pages, age, title=""):
    target = FILES / path
    target.parent.mkdir(parents=True, exist_ok=True)
    c = canvas.Canvas(str(target), pagesize=letter)
    c.setTitle(title or Path(path).stem)
    for page in pages:
        y = 740
        for line in textwrap.dedent(page).strip().splitlines():
            for wrapped in textwrap.wrap(line, 92) or [""]:
                c.setFont("Helvetica-Bold" if line.isupper() else "Helvetica", 10.5)
                c.drawString(60, y, wrapped)
                y -= 15
        c.showPage()
    c.save()
    ages[path] = age


def paper_photo(path, lines, age, size=(1400, 1050), tilt=-2.5):
    """A photo of a handwritten page: off-white paper on a wooden table, slightly rotated."""
    target = FILES / path
    target.parent.mkdir(parents=True, exist_ok=True)
    table = Image.new("RGB", size, (122, 86, 58))
    grain = ImageDraw.Draw(table)
    for y in range(0, size[1], 6):
        shade = random.randint(-12, 12)
        grain.line([(0, y), (size[0], y + random.randint(-4, 4))], fill=(122 + shade, 86 + shade, 58 + shade), width=3)
    paper = Image.new("RGB", (int(size[0] * 0.72), int(size[1] * 0.86)), (247, 243, 232))
    draw = ImageDraw.Draw(paper)
    hand = font(HAND, 44)
    y = 50
    for line in lines:
        draw.text((60, y), line, fill=(30, 40, 90), font=hand)
        y += 62
    paper = paper.rotate(tilt, expand=True, fillcolor=(122, 86, 58))
    table.paste(paper, ((size[0] - paper.width) // 2, (size[1] - paper.height) // 2))
    table = table.filter(ImageFilter.GaussianBlur(0.6))
    table.save(target, quality=85)
    ages[path] = age


def screenshot(path, title, lines, age, size=(1440, 900), dark=False):
    """A screenshot of an app window with text."""
    target = FILES / path
    target.parent.mkdir(parents=True, exist_ok=True)
    bg, fg, chrome = ((30, 30, 32), (230, 230, 230), (50, 50, 54)) if dark else ((255, 255, 255), (25, 25, 25), (236, 236, 236))
    image = Image.new("RGB", size, bg)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, size[0], 56], fill=chrome)
    for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        draw.ellipse([20 + i * 26, 20, 36 + i * 26, 36], fill=color)
    draw.text((120, 16), title, fill=fg, font=font(SANS, 22))
    y = 100
    for line in lines:
        f = font(SANS, 34 if line.startswith("#") else 26)
        draw.text((80, y), line.lstrip("# "), fill=fg, font=f)
        y += 52 if line.startswith("#") else 42
    image.save(target)
    ages[path] = age


# ---------------------------------------------------------------- the kitchen remodel (headline)

paper_photo(
    "Documents/House/Kitchen/IMG_4471.jpg",
    [
        "Ruiz & Daughters Builders",
        "Quote Q-2291  —  Kitchen remodel",
        "Cabinets (shaker, white oak)   $9,800",
        "Quartz countertops            $4,350",
        "Demo + haul away              $1,200",
        "Electrical, 6 new outlets     $1,650",
        "Labor (3 wks)                 $6,900",
        "Total                        $23,900",
        "Good for 60 days.  — Dana Ruiz  (510) 555-0142",
    ],
    age=520,
)

pdf(
    "Documents/House/Kitchen/permit-BLD-2024-0457.pdf",
    [
        """
        CITY OF OAKLAND — PLANNING & BUILDING
        RESIDENTIAL BUILDING PERMIT
        Permit number: BLD-2024-0457
        Site address: 2214 Alcatraz Ave, Oakland CA 94609
        Owner: on file
        Status: ISSUED
        """,
        """
        CONDITIONS OF APPROVAL
        1. Work shall comply with the 2022 California Residential Code.
        2. Inspections must be requested at least 24 hours in advance.
        3. Hours of construction: Monday through Friday, 8am to 6pm.
        """,
        """
        SCOPE OF WORK
        Interior kitchen remodel. Replace cabinets and countertops, relocate sink 3 feet,
        add six (6) 20-amp GFCI outlets on two new circuits. No structural changes.
        Contractor: Ruiz & Daughters Builders, CSLB license 1049921.
        Valuation: $23,900.
        """,
    ],
    age=505,
    title="Building permit BLD-2024-0457",
)

write(
    "Documents/House/Kitchen measurements.md",
    """
    # Kitchen measurements

    - Back wall: 11' 4" (sink wall)
    - Window: 36" wide, sill at 42"
    - Fridge opening: 36" x 70"
    - Island idea: 4' x 6', leave 42" clearance on all sides
    - Dana said the outlet by the window has to move for code
    """,
    age=530,
)

write(
    "Documents/House/Kitchen/email-draft-to-dana.txt",
    "Dana — can you start on the 14th? Draft, not sent.",
    age=0.5,  # just written: must never be suggested
)

# ---------------------------------------------------------------- other scenarios

pdf(
    "Downloads/EOB-Delta-Dental-2025-03.pdf",
    [
        """
        DELTA DENTAL OF CALIFORNIA — EXPLANATION OF BENEFITS
        THIS IS NOT A BILL
        Claim number: 77310-55821
        Patient: Member
        Provider: Bayside Family Dentistry, Dr. Alma Okafor
        Date of service: 03/04/2025
        Procedure D2740 crown, porcelain/ceramic   Billed $1,480   Allowed $1,120   Plan pays $560
        Your responsibility: $560
        You may appeal this decision within 180 days.
        """
    ],
    age=210,
)

write(
    "Documents/Travel/Lisbon 2023/itinerary.md",
    """
    # Lisbon, May 2023

    - Fri: land 7:40am, Airbnb in Alfama (Rua dos Remédios 41), key in lockbox, code 4417
    - Sat: tram 28 early, Castelo de São Jorge, dinner at Taberna da Rua das Flores (no reservations, go at 6:30)
    - Sun: day trip to Sintra, Pena Palace tickets for 10am
    - Mon: LX Factory, Time Out Market, pastéis at Manteigaria
    - Tue: fly out 1:15pm
    """,
    age=880,
)

screenshot(
    "Desktop/Screenshot 2023-05-11 at 9.12.44 AM.png",
    "TAP Air Portugal — Boarding pass",
    ["# Boarding pass", "TP 238  San Francisco (SFO) → Lisbon (LIS)", "Seat 24A   Group 3   Gate G94",
     "Departs 4:10 PM  May 11, 2023", "Booking reference: K7Q2ZP"],
    age=885,
)

pdf(
    "Documents/Taxes/2024/1099-INT-Harbor-Credit-Union.pdf",
    [
        """
        FORM 1099-INT  INTEREST INCOME  2024
        PAYER: Harbor Credit Union, 400 Embarcadero, San Francisco CA
        RECIPIENT: account ending 0193
        Box 1 Interest income: $1,284.17
        Box 4 Federal income tax withheld: $0.00
        Copy B — For Recipient. Keep for your records.
        """
    ],
    age=250,
)

paper_photo(
    "Desktop/IMG_2031.jpg",
    ["Welcome to Pine Hollow Cabin!", "WiFi: PineHollow-Guest", "Password: trout-meadow-88",
     "Hot tub: cover back on please", "Trash pickup Tuesday a.m.", "Emergency: Joan (530) 555-0177"],
    age=470,
    tilt=3,
)

pdf(
    "Documents/Car/Honda service invoice 2023-08.pdf",
    [
        """
        EASTSHORE HONDA — SERVICE INVOICE  RO# 418820
        Service date: Aug 14, 2023
        Vehicle: 2019 Honda CR-V EX   Mileage in: 42,118
        Services performed:
          Maintenance B1: oil and filter, tire rotation          $189.95
          Replace cabin air filter                                $64.00
          Brake fluid replacement                                 $139.00
        Recommended at next visit: rear brake pads (3mm remaining)
        Total: $392.95   Paid by card ending 5521
        """
    ],
    age=430,
)

write(
    "Documents/Recipes/Grandma's lemon cake.txt",
    """
    Grandma Ruth's lemon cake (the one from the Easter photos)

    2 cups flour, 1.5 cups sugar, 1 cup butter (soft), 4 eggs, zest of 3 lemons,
    1/2 cup buttermilk, 2 tsp baking powder, pinch of salt.
    Bake 350F, 55 min in the bundt pan. Glaze: 1 cup powdered sugar + juice of 1 lemon.
    Ruth always poked holes in it with a skewer so the glaze soaks in.
    """,
    age=1300,
)

screenshot(
    "Desktop/Screenshot 2024-11-02 at 4.31.10 PM.png",
    "Messages",
    ["# Maya Lindqvist", "the vet said Biscuit needs the dental cleaning before March",
     "Dr. Patel at Rockridge Animal Hospital, they quoted $640", "can you call them? (510) 555-0168"],
    age=340,
)

write(
    "Documents/Work/Offsite/offsite-venues.md",
    """
    # Team offsite: venue options (from Priya Natarajan)

    Priya called three places for the spring offsite, for 14 people, two nights:

    - Cavallo Point, Sausalito: great rooms, $$$, needs a deposit by Feb 1
    - Tenaya at Yosemite: cheapest, 4 hours away, snow risk
    - Carmel Valley Ranch: Priya's pick, meeting room included, $410/night

    She's holding the Carmel dates until the end of the month.
    """,
    age=210,
)

pdf(
    "Downloads/Fernway order FW-88310.pdf",
    [
        """
        FERNWAY FURNITURE — ORDER CONFIRMATION
        Order number: FW-88310   Ordered: 06/18/2024
        Ship to: on file
        Lift Pro standing desk, walnut top, 60 x 30 in.        $849.00
        Dual-motor frame, black                                 included
        Cable tray                                               $39.00
        Total: $888.00   Paid by card ending 5521
        Warranty: 7 years on motors and electronics, 2 years on the top.
        Keep this receipt: warranty claims need the order number.
        """
    ],
    age=480,
)

# ---------------------------------------------------------------- a photo open in Preview


def heic(path, image, age):
    """Saves a drawn photo as HEIC, the way an iPhone photo arrives, with macOS's sips."""
    target = FILES / path
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as folder:
        jpeg = Path(folder) / "photo.jpg"
        image.save(jpeg, quality=90)
        subprocess.run(["sips", "-s", "format", "heic", str(jpeg), "--out", str(target)], check=True, capture_output=True)
    ages[path] = age


def leaf(draw, base, length, angle, color):
    """A pothos leaf: a pointed heart shape with a midrib, from its stem end."""
    width = length * 0.42
    upper, lower = [], []
    for i in range(25):
        t = i / 24
        along = t * length
        half = width * math.sin(math.pi * t) ** 0.7 * (1.15 - 0.5 * t)
        upper.append((along, half))
        lower.append((along, -half))
    points = upper + lower[::-1]
    cos, sin = math.cos(angle), math.sin(angle)
    shape = [(base[0] + x * cos - y * sin, base[1] + x * sin + y * cos) for x, y in points]
    draw.polygon(shape, fill=color)
    tip = (base[0] + length * cos, base[1] + length * sin)
    draw.line([base, tip], fill=tuple(max(0, c - 45) for c in color), width=3)


def houseplant(seed, size, wall, yellow, leaves, scale):
    """A pothos in a terracotta pot on a wooden shelf against a wall. `yellow` leaves are
    yellowing, the rest green."""
    rng = random.Random(seed)
    w, h = size
    image = Image.new("RGB", size, wall)
    draw = ImageDraw.Draw(image)
    for y in range(h):  # soft light from a window on the left
        shade = int(18 * (1 - y / h))
        draw.line([(0, y), (w, y)], fill=tuple(min(255, c + shade) for c in wall))
    shelf = int(h * 0.78)
    draw.rectangle([0, shelf, w, h], fill=(150, 108, 72))
    for y in range(shelf, h, 7):
        draw.line([(0, y), (w, y + rng.randint(-3, 3))], fill=(140 + rng.randint(-10, 10), 100, 66), width=2)
    cx = w // 2 + rng.randint(-60, 60)
    pot_w, pot_h = int(260 * scale), int(230 * scale)
    top = shelf - pot_h + 10
    draw.polygon([(cx - pot_w // 2, top), (cx + pot_w // 2, top), (cx + pot_w // 2.6, shelf + 10), (cx - pot_w // 2.6, shelf + 10)], fill=(196, 104, 64))
    draw.rectangle([cx - pot_w // 2 - 12, top - 24, cx + pot_w // 2 + 12, top + 14], fill=(206, 114, 72))
    draw.ellipse([cx - pot_w // 2, top - 30, cx + pot_w // 2, top + 6], fill=(72, 50, 34))
    yellowed = set(rng.sample(range(leaves), yellow))
    for i in range(leaves):
        angle = math.pi * (1.05 + 0.9 * i / max(1, leaves - 1)) + rng.uniform(-0.15, 0.15)
        reach = rng.uniform(140, 320) * scale
        stem_end = (cx + reach * math.cos(angle), top - 10 + reach * math.sin(angle) * 0.9)
        if rng.random() < 0.3:  # a vine trailing over the pot's edge
            stem_end = (cx + rng.choice([-1, 1]) * rng.uniform(150, 260) * scale, top + rng.uniform(40, 200) * scale)
        draw.line([(cx, top - 12), stem_end], fill=(80, 120, 50), width=5)
        if i in yellowed:
            color = (226 + rng.randint(-10, 10), 196 + rng.randint(-15, 10), 70 + rng.randint(-20, 20))
        else:
            color = (52 + rng.randint(-12, 12), 128 + rng.randint(-20, 20), 48 + rng.randint(-12, 12))
        leaf(draw, stem_end, rng.uniform(110, 160) * scale, angle + rng.uniform(-0.6, 0.6), color)
    return image.filter(ImageFilter.GaussianBlur(1.2))


def beach(size):
    """A beach at sunset: nothing to do with anything in the demo."""
    w, h = size
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    horizon = int(h * 0.55)
    for y in range(horizon):
        t = y / horizon
        draw.line([(0, y), (w, y)], fill=(int(70 + 180 * t), int(90 + 80 * t), int(170 - 60 * t)))
    draw.ellipse([w * 0.6, horizon - 120, w * 0.6 + 170, horizon + 50], fill=(255, 196, 90))
    for y in range(horizon, int(h * 0.75)):
        t = (y - horizon) / (h * 0.2)
        draw.line([(0, y), (w, y)], fill=(int(40 + 30 * t), int(80 + 40 * t), int(130 + 20 * t)))
    for y in range(int(h * 0.75), h):
        draw.line([(0, y), (w, y)], fill=(222, 196, 150))
    for i in range(12):
        y = horizon + 20 + i * 18
        draw.line([(w * 0.6 + 20 - i * 6, y), (w * 0.6 + 150 + i * 6, y)], fill=(250, 180, 100), width=3)
    return image.filter(ImageFilter.GaussianBlur(1.5))


# Just taken: the pothos is yellowing. The eval opens it as if in Preview.
heic("Desktop/IMG_2041.HEIC", houseplant(41, (1600, 1200), (214, 206, 190), yellow=7, leaves=16, scale=1.15), age=0.2)
# The same plant two years ago, healthy, on the same shelf, from further back.
heic("Pictures/2024/IMG_0412.HEIC", houseplant(12, (1600, 1200), (220, 212, 196), yellow=0, leaves=11, scale=0.9), age=730)
# A beach at sunset, for a photo that relates to nothing.
heic("Desktop/IMG_2077.HEIC", beach((1600, 1200)), age=0.3)

write(
    "Documents/House/Plant care.md",
    """
    # Plant care

    Pothos (the one on the living room shelf, in the terracotta pot)
    - Water only when the top inch of soil is dry, about every 10 days. Less in winter.
    - Yellow leaves = too much water. Brown crispy edges = too little.
    - Bright indirect light. Not the south window, it scorched the leaves.
    - Feed once a month spring to fall, half-strength.
    - Repotted March 2024 into the terracotta pot with a drainage hole.
    """,
    age=410,
)

# ---------------------------------------------------------------- distractors

topics = [
    ("Work/Meetings", "Weekly sync", ["roadmap review", "hiring update", "Q3 planning", "design critique", "launch checklist", "incident retro"]),
    ("Work/Docs", "Spec", ["notification settings", "billing migration", "search ranking", "onboarding flow", "export to CSV", "dark mode"]),
    ("Personal/Journal", "Journal", ["long run in the rain", "garden tomatoes finally", "book club notes", "new bike fitting", "cleaned the garage", "farmers market"]),
    ("Personal/Lists", "List", ["camping gear", "holiday gifts", "books to read", "podcasts", "packing for Denver", "pantry restock"]),
]
words = ("alpha meadow river orchard copper lantern harbor willow summit granite cedar maple velvet ember quarry "
         "signal anchor beacon compass prairie tundra cobalt saffron juniper falcon heron otter badger").split()
for folder, kind, subjects in topics:
    for i, subject in enumerate(subjects):
        for n in range(4):
            body = f"# {kind}: {subject} ({n + 1})\n\n" + "\n".join(
                f"- {random.choice(words).title()} {random.choice(words)}: {' '.join(random.sample(words, 6))}" for _ in range(8)
            )
            write(f"Documents/{folder}/{subject.replace(' ', '-')}-{n + 1}.md", body, age=random.uniform(30, 1500))

stores = ["Corner Hardware", "Bay Grocery", "Lakeshore Books", "Sunset Pharmacy", "Mission Cycles", "Elm St Cafe"]
for i in range(18):
    store = stores[i % len(stores)]
    total = random.uniform(8, 240)
    pdf(f"Downloads/receipt-{i + 101}.pdf",
        [f"{store.upper()}\nReceipt #{20000 + i * 37}\nItems: {', '.join(random.sample(words, 4))}\nTotal ${total:.2f}\nThank you!"],
        age=random.uniform(20, 900))

apps = ["Calendar", "Notes", "Safari", "Slack", "Xcode", "Figma"]
for i in range(14):
    screenshot(f"Desktop/Screenshot 2024-0{1 + i % 9}-{10 + i} at 10.{10 + i}.00 AM.png", random.choice(apps),
               ["# " + " ".join(random.sample(words, 3)).title()] + [" ".join(random.sample(words, 7)) for _ in range(6)],
               age=random.uniform(40, 1000), dark=i % 3 == 0)

write("Documents/Outings/Courier recommendation.md", """
    Was this at your gate?
    Yes, this morning.
    The parcel courier said his relatives own Silverbrook Cellars in Oak Hollow.
    They host complimentary tastings on the third Saturday of each month.
    You can bring your own picnic.
    The map screenshot was about a small vegetation fire nearby.
""", age=120)

(ROOT / "manifest.json").write_text(json.dumps({"about": "Days since each demo file was last touched. The eval sets modification dates from this.", "ages": dict(sorted(ages.items()))}, indent=2) + "\n")
(ROOT / "messages.json").write_text(json.dumps(MESSAGES, indent=2) + "\n")
print(f"wrote {len(ages)} files")
