# Computes H2O-Lightning-4B decisions with mlx-vlm (the Python MLX implementation of Qwen3.5),
# for the Swift decider's tests to compare against. The prompt and readout follow H2O's shim
# (h2o_lightning_shim.py at v1.2.3 with serve_config.json): Qwen3.5's chat template with
# thinking off, "Answer:" prefilled, the option labels' scores from the tied output head in
# float32, then softmax(scores / 0.75) over the options.
#
#   uv run --python 3.12 --with 'mlx-vlm>=0.7.6' --with 'transformers>=5.19' \
#     python -I mac/scripts/reference_decisions.py --model mac/Models/h2o-lightning-4b-q4
#
# Writes mac/Packages/AppearsModel/Tests/LightningTests/Resources/reference-decisions.json.
# Every record, question and option is made up.

import argparse
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "mac/Packages/AppearsModel/Tests/LightningTests/Resources/reference-decisions.json"

# Must match DecisionPrompt in AppearsCore/Decider.swift.
SYSTEM = ("You are a decision engine. You read a record and answer one question about it by choosing exactly "
          "one option. Reply with a single letter.")
PREFILL = "Answer:"
TEMPERATURE = 0.75
LABELS = [chr(c) for c in range(ord("A"), ord("Z") + 1)]


def render(record, question, options):
    lines = "\n".join(f"{l}) {name}: {desc}" for l, (name, desc) in zip(LABELS, options))
    user = f"record: {record}\nquestion: {question}\noptions:\n{lines}"
    return ("<|im_start|>system\n" + SYSTEM.strip() + "<|im_end|>\n"
            + "<|im_start|>user\n" + user.strip() + "<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n" + PREFILL)


WINERY = [
    "Them: Asked the guy for recs and he kept pointing out the winery direct wines.",
    "Them: Yeah / Them: The UPS young man said his in-laws own Larkmoor Vineyards in Gilroy.",
    "Them: Halcyon Ridge Winery was my favorite stop / Me: We should go back in the fall",
    "Me: I think you said this is a good winery? / Them: Yes! Their pinot is great",
    "Them: Took the gondola, long tour that explores entire winery",
    "Them: Did the package ever show up? / Them: Finally, he left it at the side gate",
]
BILLS = [
    "Cedar Point rent bill. Payment receipt for month 33: $2432.",
    "Morgan: The initial Cedar Point move-out estimate is $1290.",
    "Morgan: Cedar Point sent an email asking us to pay $845. / Morgan: We only owe $845. The extra rent responsibility was waived.",
    "Morgan: The furniture store charged $845 for the bed. Delivery is Thursday.",
]
NONE = ("none", "None of these messages states the answer")


def pick(question, messages):
    options = [(f"m{i + 1}", m) for i, m in enumerate(messages)] + [NONE]
    return ("Messages from a person's own chat history.",
            f'The person is typing: "{question}". Which past message states the answer?', options)


CASES = [
    pick("what was the name of that winery that the UPS guy recommended", WINERY),
    pick("what was the name of the plumber mom recommended", WINERY),
    pick("how much was the final cedar point bill", BILLS),
    ("Ticket 4471: checkout returns HTTP 500 for every customer since 09:10.", "Which priority?",
     [("p1", "Revenue path fully down"), ("p2", "Degraded but working"), ("p3", "Cosmetic")]),
    ("Café menu: crème brûlée €7 — tarte tatin €6.", "Is a dessert under €7 listed?", [("true", "yes"), ("false", "no")]),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    import mlx.core as mx
    from mlx_vlm import load

    model, processor = load(args.model)
    tokenizer = getattr(processor, "tokenizer", processor)
    lm = model.language_model
    head = lm.model.embed_tokens
    prefix = tokenizer.encode(PREFILL, add_special_tokens=False)
    label_ids = []
    for label in LABELS:
        ids = tokenizer.encode(PREFILL + " " + label, add_special_tokens=False)
        assert len(ids) == len(prefix) + 1 and ids[:len(prefix)] == prefix, label
        label_ids.append(ids[-1])

    out = []
    for record, question, options in CASES:
        prompt = render(record, question, options)
        ids = tokenizer.encode(prompt, add_special_tokens=False)
        # As the community MLX runner calls it: text positions in the (3, B, L) M-RoPE layout.
        input_ids = mx.array([ids], dtype=mx.int32)
        embeddings = model.get_input_embeddings(input_ids).inputs_embeds
        positions = mx.broadcast_to(mx.arange(len(ids), dtype=mx.int32)[None, None], (3, 1, len(ids)))
        h = lm.model(input_ids, inputs_embeds=embeddings, cache=lm.make_cache(), position_ids=positions)
        h = h[0, -1].astype(mx.float32)
        wanted = mx.array(label_ids[:len(options)], dtype=mx.int32)
        rows = mx.dequantize(head.weight[wanted], head.scales[wanted], head.biases[wanted],
                             group_size=head.group_size, bits=head.bits).astype(mx.float32)
        scores = (rows @ h).tolist()
        top = max(s / TEMPERATURE for s in scores)
        exps = [math.exp(s / TEMPERATURE - top) for s in scores]
        probabilities = [e / sum(exps) for e in exps]
        out.append({
            "record": record, "question": question,
            "options": [{"name": n, "description": d} for n, d in options],
            "prompt": prompt, "ids": ids, "probabilities": probabilities,
        })
        print(f"{question[:60]!r}: {[round(p, 3) for p in probabilities]}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"labels": label_ids, "cases": out}, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
