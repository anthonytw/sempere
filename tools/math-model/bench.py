#!/usr/bin/env python3
"""Decoder cost of image-to-LaTeX encoder-decoders, random weights (tools/math-model/README.md).

Times the encoder and one decoder step padded to 16, 32, 64 and 256 tokens, and the total for a
reading of 16, 32 and 64 tokens with beam 3: padded to 256 (a converted decoder without KV cache),
with length buckets (what `MathModelManifest.Decoder.lengths` does), and with a KV cache.

    python3 -I bench.py      # needs torch and transformers
"""
import time

import torch
from transformers import TrOCRConfig, TrOCRForCausalLM, ViTConfig, ViTModel, VisionEncoderDecoderModel

SHAPES = [("~20M (Texo-sized)", (384, 6, 384, 2, 1200, 384)), ("~100M (UniMERNet-T-sized)", (512, 12, 512, 6, 50000, 384))]


def model(enc_dim, enc_layers, dec_dim, dec_layers, vocab, img):
    enc = ViTModel(ViTConfig(image_size=img, patch_size=16, num_channels=3, hidden_size=enc_dim,
                             num_hidden_layers=enc_layers, num_attention_heads=max(enc_dim // 64, 1),
                             intermediate_size=enc_dim * 4))
    dec = TrOCRForCausalLM(TrOCRConfig(vocab_size=vocab, d_model=dec_dim, decoder_layers=dec_layers,
                                       decoder_attention_heads=max(dec_dim // 64, 1), decoder_ffn_dim=dec_dim * 4,
                                       max_position_embeddings=512, cross_attention_hidden_size=enc_dim))
    m = VisionEncoderDecoderModel(encoder=enc, decoder=dec).eval()
    for c in (m.config, m.encoder.config, m.decoder.config):
        c._attn_implementation = "eager"
    return m


def timed(f, n=10):
    f()
    t = time.perf_counter()
    for _ in range(n):
        f()
    return (time.perf_counter() - t) / n


def main():
    torch.set_num_threads(4)
    for name, args in SHAPES:
        m = model(*args)
        params = sum(p.numel() for p in m.parameters())
        img = torch.randn(1, 3, args[5], args[5])
        with torch.no_grad():
            states = m.encoder(pixel_values=img).last_hidden_state
            enc = timed(lambda: m.encoder(pixel_values=img), 3)
            step = {b: timed(lambda b=b: m.decoder(input_ids=torch.zeros(1, b, dtype=torch.long),
                                                   encoder_hidden_states=states, use_cache=False))
                    for b in (16, 32, 64, 256)}

            def cached(n):
                past, tok = None, torch.zeros(1, 1, dtype=torch.long)
                t = time.perf_counter()
                for _ in range(n):
                    past = m.decoder(input_ids=tok, encoder_hidden_states=states, past_key_values=past,
                                     use_cache=True).past_key_values
                return (time.perf_counter() - t) / n

            per_cached = cached(64)
        print("%s: %.1fM params, %.0f MB fp16, encoder %.0f ms, step %s" % (
            name, params / 1e6, params * 2 / 1e6, enc * 1000,
            ", ".join("%d: %.1f ms" % (b, s * 1000) for b, s in step.items())))
        for n in (16, 32, 64):
            bucketed = sum(step[min(b for b in step if b >= k)] for k in range(1, n + 1)) * 3
            print("  %d tokens, beam 3: padded-256 %.2f s, buckets %.2f s, KV cache %.2f s" % (
                n, enc + step[256] * n * 3, enc + bucketed, enc + per_cached * n * 3))


if __name__ == "__main__":
    main()
