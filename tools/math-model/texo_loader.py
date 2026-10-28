"""Loader for convert.py --loader: Texo (alephpi/Texo, AGPL-3.0), weights alephpi/FormulaNet on Hugging Face.

Texo's encoder is its own HGNetV2 (model_type "my_hgnetv2"), so transformers must be told about it before
`VisionEncoderDecoderModel.from_pretrained` can read the config. TEXO_SRC is a checkout of github.com/alephpi/Texo.
Needs transformers==4.40.0 (the version the checkpoint was made with).
"""
import os
import sys


def load(model_dir):
    sys.path.insert(0, os.path.join(os.environ["TEXO_SRC"], "src"))
    from texo.model.hgnet2 import HGNetv2, HGNetv2Config
    from transformers import AutoConfig, AutoModel, VisionEncoderDecoderModel
    AutoConfig.register("my_hgnetv2", HGNetv2Config)
    AutoModel.register(HGNetv2Config, HGNetv2)
    return VisionEncoderDecoderModel.from_pretrained(model_dir)
