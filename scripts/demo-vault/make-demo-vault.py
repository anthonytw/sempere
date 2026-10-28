#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "scipy>=1.13", "scikit-image>=0.24", "pillow>=10", "fonttools>=4.50"]
# [tool.uv]
# exclude-newer = "2026-10-26T00:00:00Z"
# ///
"""Builds the Sempere demo vault (App Store hero video, screenshots, the owner's demos) with the
`sempere` CLI only: notes, notebooks, tags, paper, text boxes, equations, pictures, a video clip,
an imported PDF, and handwriting and drawings as strokes (`sempere pages draw`). Nothing in it
is anyone's real notes. What goes on each page is in scenes.py; the handwriting is hand.py.

    scripts/demo-vault/make-demo-vault.py [--out "/Users/Shared/Sempere Demo.sempere"]
                                          [--keys DIR] [--sempere BIN] [--replace] [--no-recognize]

Needs: uv (runs this file with its dependencies), the `sempere` CLI (default: this checkout's
.build/release/sempere), pdflatex (equations and the problem set), gs (outlines their glyphs),
ffmpeg (cuts the video clip), and the network the first time (fonts, NASA media; checked against
the SHA-256 sums in assets.json and kept in --cache). Every asset's source and license is in
CREDITS.md.

The vault is made with a new home device whose state lives in KEYS/state (not the user's own
sempere state), and the device key is copied to KEYS/device-key.txt: paste it into the app's
unlock sheet ("Unlock with Key"), then Confirm Vault… with KEYS/root.txt (the demo's recovery-kit root, from `vault init`) to
open the vault for writing. The recovery key is KEYS/recovery-key.txt. All are throwaway demo keys;
there is no password.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))

from hand import GlyphTracer  # noqa: E402


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(entry: dict, cache: Path) -> Path:
    """Downloads an asset into the cache once, and checks its SHA-256 every time."""
    dest = cache / entry["file"]
    if not dest.exists():
        print(f"  downloading {entry['file']}", file=sys.stderr)
        tmp = dest.with_suffix(dest.suffix + ".part")
        req = urllib.request.Request(entry["url"], headers={"User-Agent": "sempere-demo-vault"})
        with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f)
        tmp.rename(dest)
    got = sha256(dest)
    if got != entry["sha256"]:
        raise SystemExit(f"{dest}: SHA-256 {got} does not match assets.json ({entry['sha256']}); "
                         "delete it to download again, or update assets.json after checking the new file")
    return dest


class Vault:
    """The vault being built, through the `sempere` CLI."""

    def __init__(self, bin_: str, path: Path, env: dict, work: Path):
        self.bin = bin_
        self.path = path
        self.env = env
        self.work = work
        self.n = 0
        self.audio: dict = {}

    def run(self, *args: str, json_out: bool = False):
        cmd = [self.bin, *args, "--vault", str(self.path)] + (["--json"] if json_out else [])
        r = subprocess.run(cmd, env=self.env, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"sempere {' '.join(args[:3])} failed ({r.returncode}): {r.stderr.strip()}")
        return json.loads(r.stdout) if json_out else r.stdout.strip()

    # -- notes --------------------------------------------------------------------------------
    def note(self, title, notebook, tags=(), paper="ruled", pageless=False, pages=1, favorite=False, **paper_opts):
        args = ["notes", "new", title, "--notebook", notebook, "--paper", paper]
        for t in tags:
            args += ["--tag", t]
        for k, v in paper_opts.items():
            args += ["--" + k.replace("_", "-"), str(v)]
        nid = self.run(*args).splitlines()[-1].strip()
        if pages > 1:
            self.run("pages", "add", nid, "--count", str(pages - 1))
        if pageless:
            self.run("notes", "layout", nid, "pageless")
        if favorite:
            self.run("notes", "favorite", nid)
        return nid

    # -- items ----------------------------------------------------------------------------------
    @staticmethod
    def _place(page, at=None, width=None, frame=None):
        a = ["--page", str(page)]
        if frame:
            a += ["--frame", ",".join(f"{v:g}" for v in frame)]
        elif at:
            a += ["--at", f"{at[0]:g},{at[1]:g}"]
            if width:
                a += ["--width", f"{width:g}"]
        return a

    def text(self, nid, text, at, width, size=13, color="#1E2A44", font="sans", page=1, markdown=False, bold=False,
             italic=False, align=None):
        a = ["attach", "text", nid, text, *self._place(page, at, width), "--size", f"{size:g}", "--color", color,
             "--font", font]
        if markdown:
            a.append("--markdown")
        if bold:
            a.append("--bold")
        if italic:
            a.append("--italic")
        if align:
            a += ["--align", align]
        self.run(*a)

    def math(self, nid, latex, at, width=None, color="#1E2A44", page=1, size=20):
        """An equation with a pdflatex rendering stored next to its source (the CLI has no typesetter)."""
        self.n += 1
        d = self.work / f"eq{self.n}"
        d.mkdir()
        (d / "eq.tex").write_text("\\documentclass[preview,border=1pt]{standalone}\n\\usepackage{amsmath,amssymb}\n"
                                  "\\begin{document}\n$\\displaystyle " + latex + "$\n\\end{document}\n")
        subprocess.run(["pdflatex", "-interaction=batchmode", "eq.tex"], cwd=d, check=True, capture_output=True)
        # Outline the glyphs: a rendering then needs no fonts in any reader (the web viewer's pdf.js included).
        subprocess.run(["gs", "-q", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-dNoOutputFonts",
                        f"-sOutputFile={d / 'out.pdf'}", str(d / "eq.pdf")], check=True, capture_output=True)
        a = ["attach", "math", nid, "--latex", latex, *self._place(page, at, width), "--color", color,
             "--size", f"{size:g}", "--render", str(d / "out.pdf"), "--engine", "pdflatex"]
        self.run(*a)

    def image(self, nid, path, page=1, at=None, width=None, frame=None):
        self.run("attach", "image", nid, str(path), *self._place(page, at, width, frame))

    def video(self, nid, path, page=1, at=None, width=None, poster_time=None):
        a = ["attach", "video", nid, str(path), *self._place(page, at, width)]
        if poster_time is not None:
            a += ["--poster-time", f"{poster_time:g}"]
        self.run(*a)

    def voice_note(self, nid, name, frame, page=1):
        """Attaches a committed voice memo (audio/, made once with Kokoro) as a recording with its audio card
        and the script as its transcript, timed per sentence in proportion to the sentence's length."""
        a = self.audio[name]
        out = self.run("attach", "recording", nid, str(a["path"]), "--title", a["title"], "--started", a["started"],
                       "--place", "--page", str(page), "--frame", ",".join(f"{x:g}" for x in frame), json_out=True)
        rec = out["recording"]
        rid, dur = rec["id"], float(rec["duration"])
        sentences = re.findall(r"[^.!?]+[.!?]+(?:\s|$)", a["script"])
        total = sum(len(s) for s in sentences)
        segs, t = [], 0.3
        span = dur - 0.6
        for s in sentences:
            end = t + span * len(s) / total
            segs.append({"start": round(t, 3), "end": round(end, 3), "text": s.strip()})
            t = end
        created = (datetime.fromisoformat(a["started"]) + timedelta(seconds=dur)).astimezone(timezone.utc)
        doc = {"format": "sempere-transcript/1", "recording": rid, "engine": "script-kokoro-82m", "language": "en-US",
               "created": created.strftime("%Y-%m-%dT%H:%M:%SZ"), "segments": segs}
        self.n += 1
        f = self.work / f"transcript{self.n}.json"
        f.write_text(json.dumps(doc))
        self.run("attach", "transcript", nid, rid, str(f))

    def import_pdf(self, pdf, title, notebook, tags=()):
        a = ["import", "pdf", str(pdf), "--title", title, "--notebook", notebook]
        for t in tags:
            a += ["--tag", t]
        self.run(*a)
        notes = self.run("notes", "list", json_out=True)
        notes = notes if isinstance(notes, list) else notes["notes"]
        return next(n["id"] for n in notes if n["title"] == title)

    def draw(self, nid, strokes):
        if not strokes:
            return
        self.n += 1
        f = self.work / f"ink{self.n}.json"
        f.write_text(json.dumps({"strokes": strokes}))
        self.run("pages", "draw", nid, "--file", str(f))


LABEL = "Sempere Demo"
KEYS_README = "Throwaway keys of the Sempere demo vault (made by scripts/demo-vault/make-demo-vault.py)."


def is_demo_vault(path: Path) -> bool:
    try:
        return path.is_dir() and json.loads((path / "vault.json").read_text()).get("label") == LABEL
    except (OSError, ValueError, AttributeError):
        return False


def is_demo_keys(path: Path) -> bool:
    try:
        return path.is_dir() and (path / "README.txt").read_text().startswith(KEYS_README)
    except OSError:
        return False


def make_world_readable(root):
    """chmod a+rX under root: files gain read for all, folders read and search; nothing loses a bit."""
    for path in [root, *root.rglob("*")]:
        if path.is_symlink():
            continue
        mode = path.stat().st_mode
        extra = 0o555 if path.is_dir() else (0o444 | (0o111 if mode & 0o111 else 0))
        os.chmod(path, mode | extra)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--out", default="/Users/Shared/Sempere Demo.sempere")
    p.add_argument("--keys", help="where the demo keys and the CLI state go (default: OUT without .sempere + ' keys')")
    p.add_argument("--sempere", default=os.environ.get("SEMPERE_BIN", str(REPO / ".build/release/sempere")))
    p.add_argument("--cache", default=str(Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) /
                                          "sempere-demo-vault"))
    p.add_argument("--replace", action="store_true", help="delete an existing vault and keys folder first")
    p.add_argument("--no-recognize", action="store_true", help="skip handwriting recognition (macOS Vision)")
    p.add_argument("--only", help="build only the notes whose title contains this (for iterating on a scene)")
    args = p.parse_args()

    out = Path(args.out)
    if out.suffix != ".sempere":
        raise SystemExit("--out must end in .sempere")
    keys = Path(args.keys) if args.keys else out.with_name(out.stem + " keys")
    for t in ("pdflatex", "gs", "ffmpeg"):
        if not shutil.which(t):
            raise SystemExit(f"{t} not found")
    if not Path(args.sempere).exists() and not shutil.which(args.sempere):
        raise SystemExit(f"sempere CLI not found at {args.sempere} (swift build -c release --product sempere)")
    if out.exists() or keys.exists():
        if not args.replace:
            raise SystemExit(f"{out} or {keys} exists (pass --replace to rebuild)")
        # Delete only what this script made: a vault labeled LABEL, a keys folder with its README.
        if out.exists() and not is_demo_vault(out):
            raise SystemExit(f"refusing to replace {out}: it is not a demo vault made by this script "
                             f"(vault.json label is not {LABEL!r})")
        if keys.exists() and not is_demo_keys(keys):
            raise SystemExit(f"refusing to replace {keys}: it has no README.txt written by this script")
        shutil.rmtree(out, ignore_errors=True)
        shutil.rmtree(keys, ignore_errors=True)

    cache = Path(args.cache)
    cache.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((HERE / "assets.json").read_text())
    fonts = {name: GlyphTracer(fetch(e, cache), cache) for name, e in manifest["fonts"].items()}
    media = {name: fetch(e, cache) for name, e in manifest["media"].items()}

    keys.mkdir(parents=True)
    (keys / "state").mkdir(mode=0o700)
    env = dict(os.environ, XDG_STATE_HOME=str(keys / "state"), XDG_CACHE_HOME=str(keys / "cache"))
    env.pop("SEMPERE_VAULT", None)
    env.pop("SEMPERE_IDENTITY", None)

    with tempfile.TemporaryDirectory(prefix="sempere-demo-") as tmp:
        work = Path(tmp)
        # Build in a temporary folder next to the output, then move it into place in one rename.
        building = out.with_name(".building-" + out.name)
        shutil.rmtree(building, ignore_errors=True)
        init = subprocess.run([args.sempere, "vault", "init", str(building), "--recovery-out", str(keys / "recovery-key.txt"),
                               "--name", "Demo generator", "--kind", "cli", "--vault-label", LABEL, "--json"],
                              env=env, capture_output=True, text=True)
        if init.returncode != 0:
            raise SystemExit(f"vault init failed: {init.stderr.strip()}")
        info = json.loads(init.stdout)
        vault = Vault(args.sempere, building, env, work)
        # The voice memos are committed (audio/, synthesized once; CREDITS.md): only their SHA-256 is checked.
        for name, e in manifest["audio"].items():
            path = HERE / e["file"]
            if sha256(path) != e["sha256"]:
                raise SystemExit(f"{path}: SHA-256 does not match assets.json")
            vault.audio[name] = {**e, "path": path}

        import scenes
        scenes.build(vault, fonts, media, work, only=args.only)
        for t in fonts.values():
            t.save()

        if not args.no_recognize and sys.platform == "darwin":
            r = subprocess.run([args.sempere, "recognize", "--all", "--vault", str(building)], env=env, capture_output=True, text=True)
            if r.returncode != 0:
                print(f"note: recognize failed ({r.stderr.strip()}); search finds typed text only", file=sys.stderr)
        vault.run("vault", "summaries")
        vault.run("vault", "verify")
        building.rename(out)

    # The vault id names the state folder; the device key opens the vault (paste into Unlock with Key).
    dev_dir = keys / "state" / "sempere" / "devices" / info["vaultId"]
    shutil.copyfile(dev_dir / "device.key", keys / "device-key.txt")
    # The demo's recovery-kit root (16 groups), from `vault init` when the vault was made: what its printed kit would
    # carry. The app confirms a pasted device key with it
    # (Confirm Vault…), since its trust record of the vault is the generator's (state/), not the app's.
    root = info["root"]
    (keys / "root.txt").write_text(" ".join(root[i:i + 4] for i in range(0, len(root), 4)) + "\n")
    # Demo keys, readable by every account on this Mac on purpose (the vault is in /Users/Shared for the
    # owner's own account to open). Never do this with a real vault's keys.
    for f in ("device-key.txt", "recovery-key.txt", "root.txt"):
        os.chmod(keys / f, 0o644)
    # The vault itself readable by every account too (a+rX): the CLI writes blobs 0600, so another macOS user could
    # list the notes but not open their attachments.
    make_world_readable(out)
    (keys / "README.txt").write_text(
        KEYS_README + "\n\n"
        "device-key.txt   this vault's home device key. In the app: open the vault, then paste the file's\n"
        "                 whole text into the unlock sheet and choose Unlock with Key. The app has not\n"
        "                 confirmed this vault yet, so it opens read-only: choose Confirm Vault… and paste\n"
        "                 root.txt to write. For the CLI: --identity device-key.txt (with XDG_STATE_HOME=state,\n"
        "                 or add --root \"$(cat root.txt)\" once).\n"
        "root.txt         the demo vault's recovery-kit root (16 groups), recorded when it was made: stands in for a\n"
        "                 printed kit. With a real vault, take the root only from its printed kit.\n"
        "recovery-key.txt the vault's recovery key (opens it read-only, or Take Over with Recovery Kit).\n"
        "state/           the generator's sempere state (XDG_STATE_HOME) for the vault.\n\n"
        "These are demo keys, readable by every account on this Mac on purpose. Never put real notes in this vault.\n")
    notes = Vault(args.sempere, out, env, Path(tempfile.gettempdir())).run("notes", "list", json_out=True)
    notes = notes if isinstance(notes, list) else notes["notes"]
    print(f"{out}: {len(notes)} notes; keys in {keys}")


if __name__ == "__main__":
    main()
