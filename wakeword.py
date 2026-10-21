#!/usr/bin/env python3
"""Wake-word listener for the local voice assistant.

The only Python in the project. Runs inside the venv at ~/.venv/oww with
openwakeword installed. Listens to the default audio source and touches a
trigger file when it hears the configured wake word; the bash daemon then runs
the normal record -> transcribe -> LLM -> speak loop.

openWakeWord 0.4.0 API note: Model() takes *model file paths*
(wakeword_model_paths), not model names, and predict() returns scores keyed by
the model file's stem (e.g. "hey_jarvis_v0.1"). This script maps a friendly
phrase like "hey jarvis" onto the bundled model file.

Usage:
    python3 wakeword.py --wake-word "hey jarvis" --trigger /path/to/wake
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


def model_resources_dir() -> Path:
    """Locate openWakeWord's bundled model directory."""
    try:
        import openwakeword

        pkg = Path(openwakeword.__file__).resolve().parent
        return pkg / "resources" / "models"
    except Exception:  # noqa: BLE001 - fall through to a sane default
        return (
            Path.home() / ".venv" / "oww" / "lib" / "python3.14" / "site-packages"
            / "openwakeword" / "resources" / "models"
        )


def available_models() -> list[str]:
    """List the bundled wake-word model stems, e.g. ['hey_jarvis_v0.1', ...]."""
    d = model_resources_dir()
    if not d.is_dir():
        return []
    return sorted(
        p.stem
        for p in d.glob("*.onnx")
        if not any(x in p.stem for x in ("vad", "melspec", "embedding"))
    )


def find_model_file(phrase: str) -> Path | None:
    """Map a phrase like 'hey jarvis' onto a bundled model file."""
    models = available_models()
    if not models:
        return None

    wanted = phrase.strip().lower().replace(" ", "_")
    for stem in models:
        if stem.lower() == wanted or stem.lower().startswith(wanted):
            return model_resources_dir() / f"{stem}.onnx"

    # Try each word: "hey jarvis" -> a stem containing every token.
    tokens = [t for t in phrase.lower().replace("-", "_").split() if t]
    for stem in models:
        parts = stem.lower().split("_")
        if all(any(tok in p for p in parts) for tok in tokens):
            return model_resources_dir() / f"{stem}.onnx"

    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Wake-word listener")
    parser.add_argument("--wake-word", default="hey jarvis", help="wake phrase to listen for")
    parser.add_argument("--trigger", help="file to touch on detection")
    parser.add_argument("--threshold", type=float, default=0.5, help="detection threshold")
    parser.add_argument("--list", action="store_true", help="print available wake words and exit")
    parser.add_argument("--debug", action="store_true", help="print detections to stderr")
    args = parser.parse_args()

    if args.list:
        models = available_models()
        if not models:
            print("no bundled wake-word models found", file=sys.stderr)
            return 1
        print("available wake words:")
        for stem in models:
            print(f"  {stem.replace('_v0.1', '').replace('_', ' ')}")
        return 0

    if not args.trigger:
        parser.error("--trigger is required (or use --list)")

    return args


def main() -> int:
    args = parse_args()

    try:
        import numpy as np  # noqa: F401
        from openwakeword.model import Model
    except ImportError:
        print(
            "wakeword: openwakeword is not installed in this venv. "
            "Run: assistant install  (or: ~/.venv/oww/bin/pip install openwakeword sounddevice)",
            file=sys.stderr,
        )
        return 2

    model_file = find_model_file(args.wake_word)
    if model_file is None:
        print(
            f"wakeword: no model for '{args.wake_word}'. Available: "
            + ", ".join(available_models()),
            file=sys.stderr,
        )
        return 2

    # The key predict() reports for this model is the file's stem.
    model_key = model_file.stem

    try:
        models = Model(wakeword_model_paths=[str(model_file)])
    except TypeError as exc:
        # Older openWakeWord used wakeword_models=[name] and accepted an
        # inference_framework kwarg; fall back to that spelling.
        print(f"wakeword: 0.4.0 load failed ({exc}); trying legacy kwargs", file=sys.stderr)
        try:
            models = Model(wakeword_models=[args.wake_word], inference_framework="onnx")
        except Exception as exc2:  # noqa: BLE001
            print(f"wakeword: could not load model: {exc2}", file=sys.stderr)
            return 2
    except Exception as exc:  # noqa: BLE001
        print(f"wakeword: could not load model: {exc}", file=sys.stderr)
        return 2

    try:
        import sounddevice as sd
    except ImportError:
        print(
            "wakeword: sounddevice is missing. "
            "Run: ~/.venv/oww/bin/pip install sounddevice",
            file=sys.stderr,
        )
        return 2

    trigger = Path(args.trigger)
    trigger.parent.mkdir(parents=True, exist_ok=True)

    chunk_size = 1280  # openWakeWord's frame size at 16 kHz (80 ms)
    cooldown_until = 0.0

    print(f"wakeword: listening for '{args.wake_word}' via {model_key}", file=sys.stderr, flush=True)

    try:
        with sd.InputStream(samplerate=16000, channels=1, dtype="int16",
                            blocksize=chunk_size) as stream:
            while True:
                audio, _ = stream.read(chunk_size)
                # sounddevice returns (frames, channels); openWakeWord wants a
                # flat (frames,) int16 buffer or the Conv node rejects the shape.
                audio = audio.reshape(-1)
                predictions = models.predict(audio) or {}
                score = float(predictions.get(model_key, 0.0) or 0.0)

                if score >= args.threshold and time.time() > cooldown_until:
                    cooldown_until = time.time() + 2.0
                    if args.debug:
                        print(f"wakeword: detected (score {score:.2f})", file=sys.stderr, flush=True)
                    trigger.touch(exist_ok=True)
    except KeyboardInterrupt:
        print("wakeword: stopped", file=sys.stderr)
        return 0
    except Exception as exc:  # noqa: BLE001 - surface anything to the daemon
        print(f"wakeword: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
