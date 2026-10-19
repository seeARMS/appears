"""Fictional retrieval stress corpus. No personal source data belongs here."""
import json
from pathlib import Path

messages = [
    dict(path="messages:retrieval-bill-arrived", title="Morgan Hale", chatID=910,
         text="Morgan: Cedar Point sent an email asking us to pay $845. Does that cover the extra days before the new tenant moved in?\nMorgan: Should I pay the $845 now?\nMe: Sure, but I don't know what it covers.", age=4.08),
    dict(path="messages:retrieval-bill-confirmed", title="Morgan Hale", chatID=910,
         text="Morgan: I'm on hold with the leasing office.\nMorgan: We only owe $845. The extra rent responsibility was waived.\nMe: Nice, why did they waive it?", age=4.03),
    dict(path="messages:retrieval-other-charge", title="Morgan Hale", chatID=910,
         text="Morgan: The furniture store charged $845 for the bed. Delivery is Thursday.", age=4.04),
    dict(path="messages:retrieval-other-person", title="Morgan Hale", chatID=911,
         text="Morgan: My final Cedar Point bill was $920. The extra rent was not waived.", age=3),
    dict(path="messages:retrieval-old-estimate", title="Morgan Hale", chatID=910,
         text="Morgan: The initial Cedar Point move-out estimate is $1290. We still need the leasing office to confirm the final amount.", age=14),
]
for i in range(600):
    messages.append(dict(path=f"messages:retrieval-old-bill-{i}", title="Cedar Point residents", chatID=910 if i % 2 == 0 else 920+i,
                         text=f"Cedar Point rent bill. Payment receipt for month {i+1}: ${2400+i}. Monthly apartment rent paid.", age=120+i))
for i in range(100):
    messages.append(dict(path=f"messages:retrieval-context-{i}", title="Weekend plans", chatID=1200+i,
                         text=f"Bring the work lights and batteries on our walk. The room needs to be brighter. Meet near trail {i+1}.", age=30+i))
for suffix, chat in [("other", 912), ("scoped", 910)]:
    messages.append(dict(path=f"messages:retrieval-photo-{suffix}", title="Photo · Maintenance", chatID=chat,
                         imageOCR=True, text="Kestrel maintenance case K-417. Replacement hinge approved.", age=20))
# The active one-to-one chat is only context. The specific recommendation lives in
# a different group, while the open chat has more topic matches than the shortlist.
messages.append(dict(path="messages:retrieval-courier-winery", title="Family outings", chatID=930,
                     text="The UPS driver said his cousins run Silverbrook Cellars in Oak Hollow. They host tastings on the first Sunday each month. We should visit.", age=5))
for i in range(80):
    topics = [
        "I think you mentioned this is a good winery?",
        "The guy at the wine shop recommended the winery's red wines.",
        "Do you remember which winery we should visit next?",
        "The winery tour includes the cellar and a tasting.",
    ]
    messages.append(dict(path=f"messages:retrieval-winery-topic-{i}", title="Morgan Hale", chatID=910,
                         text=topics[i % len(topics)] + f" We can go on outing number {i+1}.", age=30+i))
# A reported failure: the answer is worded differently ("young man", "in-laws own",
# "Vineyards") in a group chat, while the open chat talks about wineries in words much
# closer to the question. Surface similarity can't tell them apart; reading them can.
messages.append(dict(path="messages:retrieval-group-vineyard", title="Ellis/Parkers & SOs", chatID=940,
                     text="Yeah\nThe FedEx young man said his in-laws own Larkmoor Vineyards in Gilroy.", age=8))
for i, text in enumerate([
    "Asked the guy for recs and he kept pointing out the winery direct wines.",
    "Took the gondola, long tour that explores entire winery",
    "Halcyon Ridge Winery was my favorite stop",
    "Yes! Their pinot is great",
]):
    messages.append(dict(path=f"messages:retrieval-open-winery-{i}", title="Rowan Ellis", chatID=941, text=text, age=400 + i * 90))
Path(__file__).with_name("retrieval-messages.json").write_text(json.dumps(messages, indent=2)+"\n")
