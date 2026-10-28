# Math recognition models

Sempere's handwriting-to-LaTeX conversion (the app's Convert to Math, `sempere recognize-math`)
runs an image-to-LaTeX encoder-decoder with Core ML. No model ships with Sempere: the app's
catalog (`MathModelCatalog.entries`) is empty, so you convert one yourself with these scripts
and install it.

## The model folder

A model is a `sempere-math-model/1` folder: `manifest.json` and two Core ML packages (encoder
and decoder). The manifest names the model, its license and source, the input size and
preprocessing, the vocabulary, and the SHA-256 and size of every file; Sempere checks every file
against it before use (`MathModelStore`). `convert.py` writes the folder.

## Bring your own model

Any image-to-LaTeX encoder-decoder can be used if it fits the folder contract below. The easy
path is `convert.py`: it takes any Hugging Face `VisionEncoderDecoderModel` (`--model DIR`), or
any other PyTorch model through a loader (`--loader FILE`, a `load(model_dir)` function returning
something with the same `encoder`/`decoder` interface), and writes the whole folder. To build
the folder another way, match this contract (`MathModelManifest`, `Sources/SempereRender/MathModel.swift`).

**How Sempere runs it.** The selected ink is drawn as a gray image as `image` specifies
(`MathInkImage`: every stroke the same width, cropped, scaled into the padded box, normalized
`(v - mean) / std`). The encoder runs once. The decoder then runs once per step of a beam search
(`beamWidth` beams), starting from `start` and ending at `end` or `maxLength`. The surviving
token sequences become text through the vocabulary, are tidied (`LaTeXCleanup`) and are offered
as candidates, best first.

**Core ML packages** (`coreml` in the manifest names both folders and every feature):

| Model | Inputs | Output |
|---|---|---|
| encoder | `image`: `[1, channels, height, width]` Float32 | `encoderOutput`: any shape |
| decoder | `tokens`: `[1, L]` Int32, the prefix padded with `pad`; `encoderStates`: the encoder's output | `logits`: `[1, L, vocabularySize]` |

The decoder must be causal (position *i* sees tokens 0…*i* only); Sempere reads the logits at the
prefix's last position. `L` is `maxLength`, or with `lengths` (Core ML enumerated shapes,
ascending, the last equal to `maxLength`) the shortest that holds the prefix. There is no KV
cache. `computeUnits` is `all`, `cpuAndGPU`, `cpuOnly` or `cpuAndNeuralEngine`; measure before
choosing the Neural Engine, as some encoders compute wrongly on it.

**Vocabulary:** a Hugging Face `tokenizer.json` (`model.vocab` plus `added_tokens`; added tokens
marked special are never shown) or a JSON array of token strings indexed by id. Ids must be
exactly `0..<count`. `joining` is `byteLevel` (GPT-2 byte-level BPE, as in TrOCR, Nougat and
UniMERNet tokenizers) or `words` (whole LaTeX tokens joined with spaces, as in CROHME models).

**manifest.json**, abbreviated (`convert.py` writes it; the hashes and sizes must be exact):

```json
{
  "format": "sempere-math-model/1",
  "id": "my-model", "name": "My Model",
  "licence": "Apache-2.0", "source": "https://example.org/my-model",
  "files": [
    {"path": "decoder.mlpackage/Manifest.json", "sha256": "…64 lowercase hex…", "size": 617},
    {"path": "tokenizer.json", "sha256": "…", "size": 2154630}
  ],
  "image": {"width": 384, "height": 384, "channels": 3, "padding": 8, "strokeWidth": 3,
            "alignLeft": false, "invert": false, "mean": [0.7931], "std": [0.1738]},
  "vocabulary": {"file": "tokenizer.json", "joining": "byteLevel"},
  "decoder": {"start": 0, "end": 2, "pad": 1, "maxLength": 256, "lengths": [16, 32, 64, 128, 256],
              "vocabularySize": 687, "beamWidth": 3},
  "coreml": {"encoder": "encoder.mlpackage", "decoder": "decoder.mlpackage",
             "image": "image", "encoderOutput": "encoder_states", "tokens": "tokens",
             "encoderStates": "encoder_states", "logits": "logits", "computeUnits": "cpuAndGPU"}
}
```

- `files` lists every file in the folder except `manifest.json`, including each file inside the
  two `.mlpackage` folders. Paths are relative, `/`-separated, and use only letters, digits,
  `.`, `_` and `-`, with no part starting with `.`. At most 64 files and 2 GB in all.
- `image`: sides up to 2048 pixels; `channels` 1 or 3 (gray repeated); `invert` true means white
  ink on black; `alignLeft` false centers the ink; `maxInkHeight` (optional) caps how tall a
  short line of ink is drawn; `mean` and `std` have one value or one per channel.
- `decoder`: `start`, `end` and `pad` are ids below `vocabularySize`; `beamWidth` is 1 to 16.
- Get the preprocessing right: a model fed images unlike its training images reads badly, and
  nothing in the folder can detect that. Compare against the model's own preprocessing code.

**Test it** before installing: `sempere recognize-math NOTE --all-ink --model DIR --json` reads
a note's ink with the folder as is (any manifest problem is reported by name), and
`--save-image FILE.png` writes the exact image the encoder was given. `eval.py` (below) measures
accuracy on MathWriting.

## Converting a model

Work outside the repository; nothing downloaded or converted is committed. The scripts:
`convert.py` (PyTorch → Core ML, writes the folder), `texo_loader.py` and
`unimernet_loader.py` (model-specific loaders), `eval.py` (accuracy and latency),
`bench.py` (decoder cost), `eval-vault/` (a small Swift package that builds a throwaway vault
from ink samples).

```sh
# Weights (Hugging Face): Texo = alephpi/FormulaNet; UniMERNet-T = wanderkid/unimernet_tiny
git clone --depth 1 https://github.com/alephpi/Texo texo-src
git clone --depth 1 https://github.com/opendatalab/UniMERNet unimernet-src
C=/path/to/sempere/tools/math-model
IMG="--channels 3 --mean 0.7931 0.7931 0.7931 --std 0.1738 0.1738 0.1738 --max-length 256 --centre"

TEXO_SRC=$PWD/texo-src uv run --python 3.12 --with torch==2.7.0 --with transformers==4.40.0 \
  --with "numpy<2" --with coremltools --with safetensors python -I $C/convert.py \
  --model texo-hf --loader $C/texo_loader.py --out models/texo-fp16 --id texo --name Texo \
  --licence AGPL-3.0-only --source https://huggingface.co/alephpi/FormulaNet --height 384 --width 384 $IMG
#   add --int8 for 8-bit weights

UNIMERNET_SRC=$PWD/unimernet-src uv run --python 3.12 --with torch==2.7.0 --with transformers==4.42.4 \
  --with "numpy<2" --with ftfy --with pillow --with torchvision==0.22.0 --with coremltools python -I \
  $C/convert.py --model unimernet-t --loader $C/unimernet_loader.py --out models/unimernet-t-fp16 \
  --id unimernet-t --name UniMERNet-T --licence Apache-2.0 \
  --source https://huggingface.co/wanderkid/unimernet_tiny --height 192 --width 672 $IMG

# Package for the app (a stored zip: Finder's Compress deflates, which is refused)
(cd models/texo-fp16 && zip -0 -r -q ../texo-fp16.zip . -x '.*')
```

Check a model's license and its training data's terms before you use or share it.

Things to know:

1. **Neither model is a plain Hugging Face `VisionEncoderDecoderModel`.** Texo's encoder is its
   own HGNetV2 (registered by importing the Texo repository); UniMERNet ships a `.pth` state dict
   for its own encoder and an mBART decoder. Hence `convert.py --loader FILE` (a
   `load(model_dir)` function).
2. **Pin the Python packages:** Texo needs `transformers` 4.40.0, UniMERNet 4.42.4; `torch` 2.7,
   Python 3.12 and `numpy<2` for coremltools.
3. **Preprocessing is part of the model.** Both read 3-channel gray images normalized with mean
   0.7931 and std 0.1738, the ink cropped, fitted and centered on black padding; Texo reads
   384 × 384, UniMERNet-T 192 × 672. The manifest records all of it.
4. **No KV cache:** the decoder runs one full pass per step at the smallest enumerated length that
   holds the prefix (16, 32, 64, 128 or 256 tokens), so its size dominates latency.
5. An fp16 decoder conversion prints one `overflow encountered in cast` warning; it is harmless.
6. The CLI prints Core ML diagnostics on standard output; use `--json` and parse that.

## Measuring a model

```sh
# Ink: MathWriting 2024 (CC BY-NC-SA 4.0: evaluation only); only test/ is needed.
curl -LO https://storage.googleapis.com/mathwriting_data/mathwriting-2024.tgz
mkdir mw && tar -xzf mathwriting-2024.tgz -C mw mathwriting-2024/test
python3 $C/eval.py samples mw/mathwriting-2024/test run --n 200
(cd $C/eval-vault && swift build -c release)
$C/eval-vault/.build/release/eval-vault run/samples.jsonl run/vault.sempere run/key
python3 $C/eval.py cli run run/vault.sempere run/key models/texo-fp16   # sempere recognize-math per note
python3 $C/eval.py score run run/pred-texo-fp16.json
uv run --python 3.12 --with coremltools --with "numpy<2" python $C/eval.py bench models/texo-fp16
```

## Installing

In the app: Settings ▸ Handwritten Math ▸ **Add Model from Files…** picks a model folder or a
stored zip, checks it against its manifest and installs it; **Use This Model** chooses which one
reads. The CLI takes `--model DIR` (`docs/cli.md`, `recognize-math`).
