"""Loader for convert.py --loader: UniMERNet (opendatalab/UniMERNet, Apache-2.0), weights wanderkid/unimernet_{tiny,small,base}.

The checkpoint is a plain `unimernet_*.pth` state dict for the project's own classes (a Swin-style encoder and an
mBART decoder with extra layers), not a transformers folder. UNIMERNET_SRC is a checkout of
github.com/opendatalab/UniMERNet; MODEL_DIR holds the Hugging Face files (config.json, tokenizer.json, unimernet_*.pth).
Needs transformers==4.42.4. The package's `__init__` pulls in training code (webdataset, fairscale, ...), so the two
modules we need are loaded by file path under a stub package name instead.
"""
import glob
import importlib.util
import os
import sys
import types

import torch


def _stub_package(src):
    pkg = types.ModuleType("unimernet")
    pkg.__path__ = [os.path.join(src, "unimernet")]
    sys.modules["unimernet"] = pkg
    for sub in ("models", "models.unimernet"):
        m = types.ModuleType("unimernet." + sub)
        m.__path__ = [os.path.join(src, "unimernet", *sub.split("."))]
        sys.modules["unimernet." + sub] = m


def load(model_dir):
    src = os.environ["UNIMERNET_SRC"]
    _stub_package(src)
    from transformers import AutoImageProcessor, AutoModel, VisionEncoderDecoderConfig
    enc_dec = importlib.import_module("unimernet.models.unimernet.encoder_decoder")
    config = VisionEncoderDecoderConfig.from_pretrained(model_dir)
    config.encoder = enc_dec.VariableUnimerNetConfig(**vars(config.encoder))
    AutoModel.register(enc_dec.VariableUnimerNetConfig, enc_dec.VariableUnimerNetModel)
    model = enc_dec.CustomVisionEncoderDecoderModel(config=config)
    state = torch.load(glob.glob(os.path.join(model_dir, "*.pth"))[0], map_location="cpu")
    state = state.get("model", state)
    # Keys look like "model.model.encoder..." (UniMERModel.model = DonutEncoderDecoder.model = this class).
    prefix = "model.model."
    state = {k[len(prefix):] if k.startswith(prefix) else k: v for k, v in state.items()}
    model.decoder.resize_token_embeddings(config.decoder.vocab_size)
    print(model.load_state_dict(state, strict=False))
    config.decoder_start_token_id = config.decoder.bos_token_id
    return model
