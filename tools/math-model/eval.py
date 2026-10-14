#!/usr/bin/env python3
"""Accuracy and latency of converted math models on public ink (tools/math-model/README.md).

    eval.py samples MATHWRITING_TEST_DIR OUT_DIR [--n 200] [--seed 0]   pick samples -> OUT/samples.jsonl, OUT/labels.json
    eval.py cli     OUT_DIR VAULT KEY MODEL_DIR [--limit N]              run `sempere recognize-math` on each note -> OUT/pred-<model>.json
    eval.py score   OUT_DIR PRED.json                                    exact match and token edit distance
    eval.py bench   MODEL_DIR [--runs 5]                                 encoder / decoder-step latency, peak memory (Core ML in Python)
    eval.py crohme  MODEL_DIR PARQUET [--limit N]                        CROHME 2019 test IMAGES through the model's own preprocessing,
                                                                         greedy decoding in Python: checks the conversion against published numbers

The ink is MathWriting's test split (CC BY-NC-SA 4.0: for evaluation only, never redistributed here). Pure standard
library except `bench` (needs coremltools and numpy: `uv run --with coremltools --with "numpy<2" eval.py bench ...`).
"""
import argparse
import json
import os
import random
import re
import resource
import statistics
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

CLI = os.environ.get("SEMPERE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../.build/release/sempere"))


def read_inkml(path):
    root = ET.parse(path).getroot()
    ns = "{http://www.w3.org/2003/InkML}"
    ann = {a.get("type"): a.text for a in root.findall(ns + "annotation")}
    strokes = []
    for tr in root.findall(ns + "trace"):
        pts = [[float(v) for v in p.split()] for p in tr.text.strip().split(",")]
        strokes.append(pts)
    return ann, strokes


def samples(a):
    names = sorted(n for n in os.listdir(a.dir) if n.endswith(".inkml"))
    random.Random(a.seed).shuffle(names)
    os.makedirs(a.out, exist_ok=True)
    labels = {}
    with open(os.path.join(a.out, "samples.jsonl"), "w") as f:
        for n in names[:a.n]:
            ann, strokes = read_inkml(os.path.join(a.dir, n))
            sid = ann["sampleId"]
            labels[sid] = ann["normalizedLabel"]
            f.write(json.dumps({"id": sid, "strokes": strokes}) + "\n")
    json.dump(labels, open(os.path.join(a.out, "labels.json"), "w"), indent=1)
    print("%d samples" % len(labels))


def cli(a):
    labels = json.load(open(os.path.join(a.out, "labels.json")))
    preds, times, rss = {}, {}, {}
    for i, sid in enumerate(list(labels)[:a.limit]):
        cmd = ["/usr/bin/time", "-l", CLI, "recognize-math", sid, "--all-ink", "--model", a.model, "--vault", a.vault,
               "--identity", a.key, "--json"]
        t = time.perf_counter()
        r = subprocess.run(cmd, capture_output=True, text=True)
        times[sid] = time.perf_counter() - t
        m = re.search(r"(\d+)\s+maximum resident set size", r.stderr)
        rss[sid] = int(m.group(1)) if m else 0
        try:
            preds[sid] = json.loads(r.stdout)["candidates"][0]["latex"]
        except Exception:
            preds[sid] = ""
            print("FAIL", sid, r.stderr[-300:], file=sys.stderr)
        if i % 20 == 0:
            print(i, sid, repr(preds[sid]), "|", labels[sid], "%.1fs" % times[sid], flush=True)
    name = os.path.basename(os.path.normpath(a.model))
    json.dump({"pred": preds, "seconds": times, "rss": rss}, open(os.path.join(a.out, "pred-%s.json" % name), "w"), indent=1)


TOKEN = re.compile(r"\\[A-Za-z]+|\\.|[A-Za-z]|[0-9]|.", re.S)
DROP = {"\\left", "\\right", "\\displaystyle", "\\textstyle", "\\,", "\\;", "\\:", "\\!", "\\ ", "\\quad", "\\qquad", " ", "\n", "\\big", "\\Big", "\\bigg"}
SAME = {"\\dots": "\\ldots", "\\cdots": "\\ldots", "\\to": "\\rightarrow", "\\le": "\\leq", "\\ge": "\\geq", "\\ne": "\\neq",
        "\\lbrace": "\\{", "\\rbrace": "\\}", "\\mathrm": "\\operatorname", "\\mathit": "", "\\mathbf": "\\boldsymbol", "\\dfrac": "\\frac",
        "\\tfrac": "\\frac", "\\vert": "|", "\\mid": "|", "\\prime": "'"}


def tokens(s, lenient):
    out = []
    for t in TOKEN.findall(s):
        if t in DROP:
            continue
        t = SAME.get(t, t)
        if lenient and t in "{}":
            continue
        if t:
            out.append(t)
    return out


def edit(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[-1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def score(a):
    labels = json.load(open(os.path.join(a.out, "labels.json")))
    data = json.load(open(a.pred))
    pred = data["pred"]
    res = {}
    for lenient in (False, True):
        em, ed, n = 0, [], 0
        for sid, p in pred.items():
            ref, hyp = tokens(labels[sid], lenient), tokens(p, lenient)
            n += 1
            em += ref == hyp
            ed.append(edit(ref, hyp) / max(len(ref), 1))
        res["lenient" if lenient else "strict"] = {"n": n, "exact": em / n, "edit": sum(ed) / n,
                                                   "within1": sum(1 for sid in pred if edit(tokens(labels[sid], lenient), tokens(pred[sid], lenient)) <= 1) / n}
    s = list(data["seconds"].values())
    res["cli_seconds_median"] = statistics.median(s)
    res["cli_peak_rss_mb"] = max(data["rss"].values()) / 1e6
    print(json.dumps(res, indent=1))


def bench(a):
    import coremltools as ct
    import numpy as np
    man = json.load(open(os.path.join(a.model, "manifest.json")))
    units = {"cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU, "cpuOnly": ct.ComputeUnit.CPU_ONLY, "all": ct.ComputeUnit.ALL,
             "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE}[a.units or man["coreml"]["computeUnits"]]
    t = time.perf_counter()
    enc = ct.models.MLModel(os.path.join(a.model, "encoder.mlpackage"), compute_units=units)
    dec = ct.models.MLModel(os.path.join(a.model, "decoder.mlpackage"), compute_units=units)
    load = time.perf_counter() - t
    im = man["image"]
    x = np.random.rand(1, im["channels"], im["height"], im["width"]).astype(np.float32)
    states = enc.predict({"image": x})["encoder_states"]
    e = []
    for _ in range(a.runs + 1):
        t = time.perf_counter()
        states = enc.predict({"image": x})["encoder_states"]
        e.append(time.perf_counter() - t)
    steps = {}
    for n in man["decoder"]["lengths"]:
        tok = np.full((1, n), man["decoder"]["pad"], dtype=np.int32)
        tok[0, 0] = man["decoder"]["start"]
        dec.predict({"tokens": tok, "encoder_states": states})
        ts = []
        for _ in range(a.runs):
            t = time.perf_counter()
            dec.predict({"tokens": tok, "encoder_states": states})
            ts.append(time.perf_counter() - t)
        steps[n] = statistics.median(ts) * 1000
    print(json.dumps({"load_s": round(load, 2), "encoder_ms": round(statistics.median(e[1:]) * 1000, 1),
                      "decoder_step_ms_by_length": {k: round(v, 1) for k, v in steps.items()},
                      "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, 0),
                      "units": a.units or man["coreml"]["computeUnits"]}, indent=1))


def crohme(a):
    import io
    import numpy as np
    import pyarrow.parquet as pq
    import coremltools as ct
    from PIL import Image, ImageOps
    from tokenizers import Tokenizer
    man = json.load(open(os.path.join(a.model, "manifest.json")))
    units = ct.ComputeUnit.CPU_AND_GPU
    enc = ct.models.MLModel(os.path.join(a.model, "encoder.mlpackage"), compute_units=units)
    dec = ct.models.MLModel(os.path.join(a.model, "decoder.mlpackage"), compute_units=units)
    tok = Tokenizer.from_file(os.path.join(a.model, "tokenizer.json"))
    W, H, D = man["image"]["width"], man["image"]["height"], man["decoder"]
    mean, std = man["image"]["mean"][0], man["image"]["std"][0]
    rows = pq.read_table(a.parquet).to_pylist()[:a.limit]

    def prepare(png):
        # The reference preprocessing of UniMERNet / Texo: crop the white margin, scale to fit, pad with BLACK, centre.
        im = Image.open(io.BytesIO(png)).convert("RGB")
        g = np.asarray(im.convert("L"), dtype=np.float32)
        lo, hi = g.min(), g.max()
        if hi > lo:
            ys, xs = np.nonzero((g - lo) / (hi - lo) * 255 < 200)
            im = im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
        scale = min(H / im.height, W / im.width)
        im = im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))), Image.BICUBIC)
        dw, dh = W - im.width, H - im.height
        im = ImageOps.expand(im, (dw // 2, dh // 2, dw - dw // 2, dh - dh // 2))
        v = (np.asarray(im.convert("L"), dtype=np.float32) / 255 - mean) / std
        return np.repeat(v[None, None], man["image"]["channels"], axis=1).astype(np.float32)

    em = {False: 0, True: 0}
    ed = {False: [], True: []}
    t_enc, t_step, t_tot, ntok = [], [], [], []
    for i, row in enumerate(rows):
        ref = re.sub(r"^\\\[|\\\]$", "", row["latex_formula"].strip())
        x = prepare(row["image"]["bytes"])
        t0 = time.perf_counter()
        states = enc.predict({"image": x})["encoder_states"]
        t1 = time.perf_counter()
        toks = [D["start"]]
        for _ in range(min(D["maxLength"] - 1, 200)):
            L = next(l for l in D["lengths"] if l >= len(toks))
            t = np.full((1, L), D["pad"], dtype=np.int32)
            t[0, :len(toks)] = toks
            lg = dec.predict({"tokens": t, "encoder_states": states})["logits"][0, len(toks) - 1]
            nxt = int(lg.argmax())
            if nxt == D["end"]:
                break
            toks.append(nxt)
        t2 = time.perf_counter()
        hyp = tok.decode(toks[1:], skip_special_tokens=True)
        t_enc.append(t1 - t0); t_tot.append(t2 - t0); ntok.append(len(toks) - 1)
        t_step.append((t2 - t1) / max(len(toks), 1))
        for lenient in (False, True):
            r, h = tokens(ref, lenient), tokens(hyp, lenient)
            em[lenient] += r == h
            ed[lenient].append(edit(r, h) / max(len(r), 1))
        if i % 100 == 0:
            print(i, repr(hyp), "|", ref, flush=True)
    n = len(rows)
    print(json.dumps({"n": n, "strict": {"exact": em[False] / n, "edit": sum(ed[False]) / n},
                      "lenient": {"exact": em[True] / n, "edit": sum(ed[True]) / n},
                      "greedy_seconds_median": statistics.median(t_tot), "encoder_ms_median": statistics.median(t_enc) * 1000,
                      "step_ms_median": statistics.median(t_step) * 1000, "tokens_median": statistics.median(ntok)}, indent=1))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("samples"); s.add_argument("dir"); s.add_argument("out"); s.add_argument("--n", type=int, default=200)
    s.add_argument("--seed", type=int, default=0); s.set_defaults(f=samples)
    c = sub.add_parser("cli"); c.add_argument("out"); c.add_argument("vault"); c.add_argument("key"); c.add_argument("model")
    c.add_argument("--limit", type=int); c.set_defaults(f=cli)
    r = sub.add_parser("score"); r.add_argument("out"); r.add_argument("pred"); r.set_defaults(f=score)
    b = sub.add_parser("bench"); b.add_argument("model"); b.add_argument("--runs", type=int, default=5)
    b.add_argument("--units"); b.set_defaults(f=bench)
    k = sub.add_parser("crohme"); k.add_argument("model"); k.add_argument("parquet"); k.add_argument("--limit", type=int)
    k.set_defaults(f=crohme)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
