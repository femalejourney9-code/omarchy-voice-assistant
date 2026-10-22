# Local voice assistant for Omarchy

A local, private voice assistant: **HEAR → THINK → SPEAK**, all on your own machine.

```
 HEAR                     THINK                          SPEAK
┌──────────────┐   ┌────────────────────────┐   ┌───────────────────┐
│  microphone  │   │  whisper.cpp  (STT)    │   │   Piper TTS       │
│  sox capture │──▶│  ggml-base.en          │──▶│   en_US-lessac    │
│  + silence   │   │                        │   │   -medium         │
│  trim        │   │  Ollama (LLM)          │   │                   │
└──────────────┘   │  llama3.2:3b (local)   │   │  paplay → PipeWire│
                   └────────────────────────┘   └───────────────────┘
```

No cloud calls. No Docker. No telemetry. Ollama, whisper.cpp, and Piper all run locally.

---

## Install

```bash
cd ~/assistant
bash setup.sh
```

`setup.sh` is idempotent and safe to re-run. It:

1. installs packages (`pacman` + `yay`): `pipewire wireplumber pipewire-pulse sox jq curl git base-devel cmake ollama`
2. installs `whisper.cpp` (prebuilt if the AUR has a `-bin`, otherwise builds from source — slow)
3. installs `piper-tts`
4. downloads the whisper model (`ggml-base.en`)
5. downloads one Piper voice (`en_US-lessac-medium`)
6. pulls the Ollama model
7. creates the wake-word venv at `~/.venv/oww`
8. installs `~/bin/assistant` (and adds `~/bin` to `PATH` in `~/.bashrc`)
9. adds the `SUPER + V` binding to `~/.config/hypr/bindings.lua`
10. installs the bar-state widget plugin

Anything it overwrites is first copied to `FILE.bak`.

## Usage

```bash
assistant doctor              # status table; exit 1 if anything is missing
assistant once                # full loop: record -> transcribe -> LLM -> speak
assistant listen              # push-to-talk (shorter cap, same loop)
assistant speak "hello there" # TTS stage only
assistant transcribe f.wav    # STT stage only
assistant daemon              # always-on wake-word loop
```

Keybind (added by the installer):

| Key | Action |
| --- | --- |
| `SUPER + V` | push-to-talk (`assistant listen`) |

The bar shows **🎤 listening**, **🧠 thinking**, or **🔊 speaking** while the assistant works, driven by `~/.local/state/assistant/state`.

## Swapping models

Everything is one variable in `~/.config/assistant/assistant.conf`:

```bash
ASSISTANT_MODEL="llama3.2:3b"        # LLM (Ollama)
ASSISTANT_WHISPER_MODEL="base.en"    # STT: base.en | small.en
ASSISTANT_PIPER_VOICE="en_US-lessac-medium"
```

Change one, then:

```bash
ollama pull "$ASSISTANT_MODEL"       # for a new LLM
# whisper models and piper voices are downloaded by setup.sh on the next run
```

### Which whisper model?

| Model | Size | Pick when |
| --- | --- | --- |
| `base.en` | ~75 MB | **8 GB RAM** — safe default, good accuracy |
| `small.en` | ~500 MB | 16 GB+ and you want better accuracy |

This machine has 8 GB, so `base.en` is the default.

### Which LLM?

`llama3.2:3b` is the default because it is the largest model that runs comfortably on CPU with 8 GB of RAM. On CPU inference there is no GPU acceleration available (this box has an Intel iGPU), so prefer smaller models:

- `llama3.2:3b` — default, ~2 GB
- `llama3.2:1b` — faster, less capable, ~0.8 GB
- `qwen2.5:3b` — good alternative
- anything larger will be slow or not fit

### Performance on this hardware

Measured on this box (Intel HD 620, CPU-only inference, no CUDA/ROCm):

| Reply cap | Time |
| --- | --- |
| 32 tokens | ~25 s |
| 96 tokens | ~58 s |
| 128 tokens | ~61 s |

That is roughly **0.8 s per token**. `ASSISTANT_LLM_NUM_PREDICT` defaults to `32` because it is the single biggest latency lever — a spoken answer needs far less than 96 tokens.

Two things make real-world latency worse than the table:

- **The machine was under load during measurement** (load average 15+). The same 32-token request took 56 s loaded versus 25 s idle. Expect variance.
- **The wake-word daemon costs ~28% CPU continuously** while it listens. On an already-busy machine that directly competes with the LLM.

If latency matters more than the wake word, either lower `ASSISTANT_LLM_NUM_PREDICT`, switch to `llama3.2:1b`, or stop the daemon and use `SUPER + V` push-to-talk:

```bash
systemctl --user stop assistant-daemon   # frees ~28% CPU
```

### Which Piper voice?

The full list is at <https://rhasspy.github.io/piper-samples/>. The installer only downloads the one you configure, so to add another, download the `.onnx` and `.onnx.json` pair into `~/.local/share/assistant/voices/` and point `ASSISTANT_PIPER_VOICE` at the basename.

## Adding a wake word

Wake words are openWakeWord models. Available phrases include `hey jarvis`, `hey computer`, `ok google`, `hey google`, `terminator`, and more.

```bash
# 1. pick a phrase
ASSISTANT_WAKE_WORD="hey computer"   # in ~/.config/assistant/assistant.conf

# 2. restart the daemon
systemctl --user restart assistant-daemon

# 3. check it is listening
assistant doctor
```

To add a **custom** trained wake word, place its `.onnx` in `~/.local/share/assistant/whisper/`-style directory and point the detector at it — see `wakeword.py` for the model-loading call.

## systemd

```bash
systemctl --user enable --now assistant-daemon
systemctl --user status assistant-daemon
journalctl --user -u assistant-daemon -f
```

The unit lives at `~/.config/systemd/user/assistant-daemon.service` and logs to both the journal and `~/.local/state/assistant/assistant.log` (rotated at 5 MB, keeping 3 generations).

## Files

```
~/assistant/
  setup.sh                     installer (idempotent)
  assistant                    the dispatcher (also installed to ~/bin)
  wakeword.py                  the only Python in the project
  assistant-bar/               Omarchy bar-widget plugin
  assistant.conf                all tunables
  README.md

~/.config/assistant/assistant.conf          tunables (loaded by the script)
~/.config/systemd/user/assistant-daemon.service
~/.config/hypr/bindings.lua                 SUPER + V binding
~/.config/omarchy/plugins/io.github.hermes.assistant/   bar widget
~/.local/state/assistant/assistant.log      rotated log
~/.local/state/assistant/state             idle|listening|thinking|speaking
~/.local/share/assistant/whisper/          ggml-*.bin
~/.local/share/assistant/voices/           *.onnx + *.onnx.json
~/.venv/oww/                               wake-word Python environment
```

## Troubleshooting

### No mic input

```bash
pactl list short sources                  # is there a source at all?
pactl info | grep "Default Source"        # is one set as default?
```

- If there is no source, the mic is not detected — check `wpctl status` and the hardware.
- If the wrong device is default, set it: `pactl set-default-source <name>`.
- Test capture directly: `rec -d 3 test.wav && aplay test.wav` (or `paplay test.wav`).

### Wrong default source

```bash
pactl info | grep "Default Source"                 # current
pactl list short sources                           # candidates
pactl set-default-source alsa_input.pci-0000_00_1f.3.analog-stereo
```

The assistant uses whatever `pactl` reports as the default, so fixing it there fixes the assistant.

### Whisper model not found

```bash
ls -la ~/.local/share/assistant/whisper/
```

If empty, re-run `assistant install` (or `bash ~/assistant/setup.sh`). The file must be named `ggml-<model>.bin` where `<model>` matches `ASSISTANT_WHISPER_MODEL`. Note the two names must agree: `base.en` → `ggml-base.en.bin`.

### Ollama not running

```bash
systemctl --user status ollama
systemctl --user start ollama
curl -fsS http://127.0.0.1:11434/api/tags | jq .     # should list models
```

The assistant talks to `127.0.0.1:11434` over HTTP — no API key, purely local.

### Piper voice path wrong

```bash
ls -la ~/.local/share/assistant/voices/
```

You need **both** `<voice>.onnx` and `<voice>.onnx.json`. A missing `.onnx.json` is the usual cause of "voice path wrong" — the installer fetches them as a pair.

### Wake-word false positives

- Raise the threshold: `--threshold 0.5` in `wakeword.py` (default) — try `0.6` or `0.7`.
- Choose a more distinctive phrase; `hey google` is prone to false triggers because it appears in speech and media.
- A 2-second cooldown after each detection prevents repeats from one utterance.
- Check the log: `journalctl --user -u assistant-daemon -f` shows detections.
- If openWakeWord will not install (Python too new for `onnxruntime` wheels), the assistant still works — just use `SUPER + V` push-to-talk and leave the daemon off.

### Everything at once

```bash
assistant doctor          # the fastest way to find the broken stage
```

It prints a status table and exits non-zero if anything is missing.
