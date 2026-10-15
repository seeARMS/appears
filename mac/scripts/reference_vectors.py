# Computes EmbeddingGemma 2 vectors with the official implementation (sentence-transformers
# on PyTorch, CPU, float32), for the Swift embedder's tests to compare against.
#
#   uv run --with 'sentence-transformers[image]>=6.1' --with torch \
#     python -I mac/scripts/reference_vectors.py --model mac/Models/embeddinggemma-2
#
# Writes mac/Packages/WhoSaidModel/Tests/GemmaEmbedderTests/Resources/reference-vectors.json.
# Inputs are the demo queries, context-window documents built the way the Swift indexer
# builds them, and the demo screenshots. All of it is made-up demo data.

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEMO = ROOT / "demo"
OUT = ROOT / "mac/Packages/WhoSaidModel/Tests/GemmaEmbedderTests/Resources/reference-vectors.json"

# Must match EmbeddingGemmaPrompt in SearchIndex/Embedder.swift.
def query(text: str) -> str:
    return f"task: search result | query: {text}"

def document(title: str, text: str) -> str:
    return f"title: {title or 'none'} | text: {text}"

DOCUMENTS = [
    document(
        "Dinner crew · Mar 12, 2026",
        "Alex Moreno: ok where are we doing dinner friday\n"
        "Sierra Vance: Osteria Fennel? they hold the bar for walk-ins\n"
        "Me: yes please, haven't been\n"
        "Alex Moreno: in\n"
        "Sierra Vance: 1188 Valencia St, 7:30. I'll get there early and grab seats\n"
        "Me: perfect",
    ),
    document(
        "Marcus Hale · Jan 9, 2026",
        "Marcus Hale: we finally moved! new place is 88 Linden St, Oakland\n"
        "Me: congrats!! housewarming?\n"
        "Marcus Hale: saturday the 24th, bring nothing",
    ),
    document("Priya Natarajan · Dec 2, 2025", "Priya Natarajan: you have to read Piranesi. trust me\nMe: adding it to the list"),
    document("", "a short message with no title"),
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Folder with google/embeddinggemma-2")
    args = parser.parse_args()

    import torch
    from sentence_transformers import SentenceTransformer

    torch.manual_seed(0)
    model = SentenceTransformer(args.model, device="cpu", model_kwargs={"torch_dtype": torch.float32})

    demo = json.loads((DEMO / "conversations.json").read_text())
    queries = [query(q["q"]) for q in demo["queries"]]
    texts = queries + DOCUMENTS
    # Inputs are already formatted with their prompts, so encode them as raw text.
    text_vectors = model.encode(texts, normalize_embeddings=True, convert_to_numpy=True)

    images = sorted((DEMO / "images").glob("*.png"))
    image_vectors = model.encode([{"image": str(path)} for path in images], normalize_embeddings=True, convert_to_numpy=True)

    weights = Path(args.model) / "model.safetensors"
    result = {
        "about": "EmbeddingGemma 2 reference vectors from sentence-transformers (CPU, float32). Made-up demo inputs.",
        "weights_sha256": hashlib.sha256(weights.read_bytes()).hexdigest(),
        "dimension": int(text_vectors.shape[1]),
        "texts": [{"input": t, "vector": [round(float(x), 7) for x in v]} for t, v in zip(texts, text_vectors)],
        "images": [{"file": p.name, "vector": [round(float(x), 7) for x in v]} for p, v in zip(images, image_vectors)],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n")

    # A quick sanity check: each query's nearest document or image.
    import numpy as np
    candidates = np.concatenate([text_vectors[len(queries):], image_vectors])
    labels = [d.split(" | text: ")[1][:50].replace("\n", " / ") for d in DOCUMENTS] + [f"[image] {p.name}" for p in images]
    for q, v in zip(demo["queries"], text_vectors[: len(queries)]):
        scores = candidates @ v
        best = int(np.argmax(scores))
        print(f"{scores[best]:.3f}  {q['q']!r} → {labels[best]}")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
