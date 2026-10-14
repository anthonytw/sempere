#!/usr/bin/env python3
"""Converts an image-to-LaTeX encoder-decoder into a Sempere math model folder.

Output (tools/math-model/README.md):
    OUT/encoder.mlpackage   image [1, C, H, W] float32 -> encoder_states
    OUT/decoder.mlpackage   tokens [1, L] int32 + encoder_states -> logits [1, L, V]
    OUT/tokenizer.json      the model's Hugging Face tokenizer (decoding only)
    OUT/manifest.json       sempere-math-model/1: files with SHA-256 and size, image spec, decoder ids

The model is a Hugging Face `VisionEncoderDecoderModel` (TrOCR / Pix2Text MFR,
UniMERNet, Texo's FormulaNet, TexTeller all are), loaded from a local folder:
this script never downloads anything. The decoder takes the whole padded token
sequence (no KV cache): simple and correct, at the cost of a full decoder pass
per step (see the research note's latency section).

    python3 -I convert.py --model DIR --out OUT --id texo-1 --name "Texo" \\
        --licence AGPL-3.0-only --source https://github.com/alephpi/Texo \\
        --height 384 --width 384 --channels 3 --mean 0.5 --std 0.5 --max-length 256

    python3 -I convert.py --tiny --out OUT      # random tiny model: checks the pipeline only

Needs torch, transformers and coremltools (conversion runs on Linux and macOS;
only macOS can run the result: check it there with `sempere recognize-math --model OUT`).
"""
import argparse
import hashlib
import json
import os
import shutil
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for piece in iter(lambda: f.read(1 << 20), b""):
            h.update(piece)
    return h.hexdigest(), os.path.getsize(path)


def tiny_model(vocab_size, height, width, channels):
    from transformers import (TrOCRConfig, TrOCRForCausalLM, ViTConfig, ViTModel,
                              VisionEncoderDecoderModel)
    enc = ViTModel(ViTConfig(image_size=(height, width), patch_size=16, num_channels=channels, hidden_size=64,
                             num_hidden_layers=2, num_attention_heads=2, intermediate_size=128))
    dec = TrOCRForCausalLM(TrOCRConfig(vocab_size=vocab_size, d_model=64, decoder_layers=2,
                                       decoder_attention_heads=2, decoder_ffn_dim=128, max_position_embeddings=512,
                                       cross_attention_hidden_size=64, use_learned_position_embeddings=True))
    return VisionEncoderDecoderModel(encoder=enc, decoder=dec)


def tiny_tokenizer(path, vocab_size):
    # A byte-level vocabulary: special tokens, then printable characters, then filler.
    specials = ["<s>", "<pad>", "</s>", "<unk>"]
    chars = [chr(c) for c in range(33, 127)]
    vocab = {t: i for i, t in enumerate(specials + chars)}
    while len(vocab) < vocab_size:
        vocab["tok%d" % len(vocab)] = len(vocab)
    data = {"model": {"type": "BPE", "vocab": vocab},
            "added_tokens": [{"id": i, "content": t, "special": True} for i, t in enumerate(specials)],
            "decoder": {"type": "ByteLevel"}}
    with open(path, "w") as f:
        json.dump(data, f)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", help="folder of a VisionEncoderDecoderModel (from_pretrained)")
    p.add_argument("--tokenizer", help="tokenizer.json (default: MODEL/tokenizer.json)")
    p.add_argument("--tiny", action="store_true", help="convert a random tiny model instead (pipeline check)")
    p.add_argument("--loader", help="a Python file defining load(model_dir) -> VisionEncoderDecoderModel, for models "
                                    "whose encoder or config is not in transformers (see texo_loader.py, unimernet_loader.py)")
    p.add_argument("--int8", action="store_true", help="also quantise weights to 8 bits (per-channel linear, coremltools.optimize)")
    p.add_argument("--trust-remote-code", action="store_true", help="allow the model folder's own Python code")
    p.add_argument("--out", required=True)
    p.add_argument("--id", default="tiny-test")
    p.add_argument("--name", default="Tiny test model (random weights)")
    p.add_argument("--licence", default="none")
    p.add_argument("--source", default="random")
    p.add_argument("--height", type=int, default=64)
    p.add_argument("--width", type=int, default=256)
    p.add_argument("--channels", type=int, default=1)
    p.add_argument("--mean", type=float, nargs="+", default=[0.0])
    p.add_argument("--std", type=float, nargs="+", default=[1.0])
    p.add_argument("--invert", action="store_true", help="the model reads white ink on black")
    p.add_argument("--stroke-width", type=float, default=3.0)
    p.add_argument("--padding", type=int, default=8)
    p.add_argument("--max-ink-height", type=float)
    p.add_argument("--centre", action="store_true", help="centre the ink (default: left-aligned)")
    p.add_argument("--max-length", type=int, default=64)
    p.add_argument("--lengths", type=int, nargs="+",
                   help="token lengths the decoder accepts (default: 16, 32, ... up to --max-length); each step pads "
                        "to the shortest that fits, so short equations decode several times faster than at --max-length")
    p.add_argument("--beam-width", type=int, default=3)
    p.add_argument("--joining", choices=["byteLevel", "words"], default="byteLevel")
    p.add_argument("--compute-units", default="cpuAndGPU", choices=["all", "cpuAndGPU", "cpuOnly", "cpuAndNeuralEngine"])
    p.add_argument("--fp32", action="store_true", help="keep float32 weights (default float16)")
    a = p.parse_args()

    import coremltools as ct
    import numpy as np
    import torch

    if os.path.exists(a.out):
        sys.exit("refusing to overwrite %s" % a.out)
    os.makedirs(a.out)
    tok_out = os.path.join(a.out, "tokenizer.json")

    if a.tiny:
        model = tiny_model(200, a.height, a.width, a.channels)
        tiny_tokenizer(tok_out, 200)
        start, end, pad = 0, 2, 1
    else:
        if not a.model:
            sys.exit("--model or --tiny")
        from transformers import VisionEncoderDecoderModel
        if a.loader:
            import importlib.util
            spec = importlib.util.spec_from_file_location("sempere_model_loader", a.loader)
            loader = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(loader)
            model = loader.load(a.model)
        else:
            model = VisionEncoderDecoderModel.from_pretrained(a.model, trust_remote_code=a.trust_remote_code)
        shutil.copyfile(a.tokenizer or os.path.join(a.model, "tokenizer.json"), tok_out)
        cfg = model.config
        start = cfg.decoder_start_token_id if cfg.decoder_start_token_id is not None else cfg.decoder.bos_token_id
        end = cfg.eos_token_id if cfg.eos_token_id is not None else cfg.decoder.eos_token_id
        pad = cfg.pad_token_id if cfg.pad_token_id is not None else cfg.decoder.pad_token_id
    model.eval()
    # Plain attention traces into ops Core ML converts (the fused kernels do not).
    if hasattr(model, "set_attn_implementation"):
        model.set_attn_implementation("eager")
    for c in (model.config, model.encoder.config, model.decoder.config):
        c._attn_implementation = "eager"
    vocab_size = model.decoder.config.vocab_size

    class Encoder(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, image):
            states = self.m.encoder(pixel_values=image).last_hidden_state
            # The projection VisionEncoderDecoderModel applies when the widths differ.
            proj = getattr(self.m, "enc_to_dec_proj", None)
            return proj(states) if proj is not None else states

    class Decoder(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, tokens, encoder_states):
            # Core ML inputs are int32; embeddings index with int64.
            return self.m.decoder(input_ids=tokens.long(), encoder_hidden_states=encoder_states, use_cache=False).logits

    lengths = sorted(set(a.lengths or [n for n in (16, 32, 64, 128, 256, 512, 1024, 2048, 4096) if n < a.max_length]
                                       + [a.max_length]))
    if lengths[-1] != a.max_length or lengths[0] < 2:
        sys.exit("--lengths must end at --max-length and start at 2 or more")
    image = torch.zeros(1, a.channels, a.height, a.width)
    enc = Encoder(model)
    with torch.no_grad():
        states = enc(image)
        traced_enc = torch.export.export(enc, (image,)).run_decompositions({})
        tokens = torch.full((1, a.max_length), pad, dtype=torch.int32)
        tokens[0, 0] = start
        dec = Decoder(model)
        reference = dec(tokens, states)
        # torch.export, not torch.jit.trace: traced shape arithmetic in the
        # decoders' masks becomes aten::Int on tensors, which coremltools rejects.
        seq = torch.export.Dim("seq", min=2, max=a.max_length)
        traced_dec = torch.export.export(dec, (tokens, states),
                                         dynamic_shapes={"tokens": {1: seq}, "encoder_states": None}).run_decompositions({})
    precision = ct.precision.FLOAT32 if a.fp32 else ct.precision.FLOAT16
    target = ct.target.iOS17
    ml_enc = ct.convert(traced_enc, outputs=[ct.TensorType(name="encoder_states", dtype=np.float32)],
                        minimum_deployment_target=target, compute_precision=precision, convert_to="mlprogram")
    if a.int8:
        import coremltools.optimize.coreml as cto
        q = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8",
                                                                             granularity="per_channel"))
        ml_enc = cto.linear_quantize_weights(ml_enc, q)
    ml_enc.save(os.path.join(a.out, "encoder.mlpackage"))
    ml_dec = ct.convert(traced_dec,
                        inputs=[ct.TensorType(name="tokens", dtype=np.int32,
                                              shape=ct.EnumeratedShapes(shapes=[[1, n] for n in lengths],
                                                                        default=[1, a.max_length])),
                                ct.TensorType(name="encoder_states", shape=states.shape, dtype=np.float32)],
                        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
                        minimum_deployment_target=target, compute_precision=precision, convert_to="mlprogram")
    if a.int8:
        ml_dec = cto.linear_quantize_weights(ml_dec, q)
    ml_dec.save(os.path.join(a.out, "decoder.mlpackage"))
    assert tuple(reference.shape) == (1, a.max_length, vocab_size), reference.shape

    files = []
    for root, _, names in os.walk(a.out):
        for n in sorted(names):
            full = os.path.join(root, n)
            rel = os.path.relpath(full, a.out).replace(os.sep, "/")
            digest, size = sha256(full)
            files.append({"path": rel, "sha256": digest, "size": size})
    files.sort(key=lambda f: f["path"])
    manifest = {
        "format": "sempere-math-model/1", "id": a.id, "name": a.name, "licence": a.licence, "source": a.source,
        "files": files,
        "image": {"width": a.width, "height": a.height, "channels": a.channels, "padding": a.padding,
                  "strokeWidth": a.stroke_width, "maxInkHeight": a.max_ink_height, "alignLeft": not a.centre,
                  "invert": a.invert, "mean": a.mean, "std": a.std},
        "vocabulary": {"file": "tokenizer.json", "joining": a.joining},
        "decoder": {"start": int(start), "end": int(end), "pad": int(pad), "maxLength": a.max_length, "lengths": lengths,
                    "vocabularySize": int(vocab_size), "beamWidth": a.beam_width},
        "coreml": {"encoder": "encoder.mlpackage", "decoder": "decoder.mlpackage", "image": "image",
                   "encoderOutput": "encoder_states", "tokens": "tokens", "encoderStates": "encoder_states",
                   "logits": "logits", "computeUnits": a.compute_units},
    }
    if manifest["image"]["maxInkHeight"] is None:
        del manifest["image"]["maxInkHeight"]
    data = json.dumps(manifest, indent=2, sort_keys=True).encode()
    with open(os.path.join(a.out, "manifest.json"), "wb") as f:
        f.write(data)
    total = sum(f["size"] for f in files)
    print("wrote %s: %d files, %.1f MB, manifest sha256 %s" % (a.out, len(files), total / 1e6, hashlib.sha256(data).hexdigest()))


if __name__ == "__main__":
    main()
