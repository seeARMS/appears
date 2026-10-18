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
Path(__file__).with_name("retrieval-messages.json").write_text(json.dumps(messages, indent=2)+"\n")
