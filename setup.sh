#!/usr/bin/env bash
#
# setup.sh — installer for the local voice assistant on Omarchy.
#
# Idempotent: every step checks whether it already did the work, so re-running
# is safe. Anything it overwrites is first backed up to FILE.bak.
#
#   pacman/yay : pipewire, sox, jq, whisper.cpp, piper-tts, ollama, curl
#   downloads : whisper.cpp model (ggml-base.en) + one Piper voice
#   ollama    : pull the LLM model
#   install   : ~/bin/assistant (chmod +x)
#
# GPU note: this box has an Intel iGPU (no CUDA/ROCm), so whisper.cpp and
# ollama both run on the CPU. The installer therefore does not add CUDA build
# flags; add them by hand if you move this to an NVIDIA/AMD machine.

set -euo pipefail

readonly CONF_FILE="${HOME}/.config/assistant/assistant.conf"
readonly STATE_DIR="${HOME}/.local/state/assistant"
readonly VOICE_DIR="${HOME}/.local/share/assistant/voices"
readonly WHISPER_DIR="${HOME}/.local/share/assistant/whisper"
readonly BIN_DIR="${HOME}/bin"
readonly VENV_DIR="${HOME}/.venv/oww"
readonly ASSISTANT_SRC="${HOME}/assistant"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARN: %s\n' "$*" >&2; }
die()  { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

backup() {
    # backup <file> — copy to FILE.bak if it exists and we are about to change it
    local f="$1"
    if [[ -e "${f}" && ! -e "${f}.bak" ]]; then
        cp -a "${f}" "${f}.bak"
        log "backed up ${f} -> ${f}.bak"
    fi
}

need_sudo() {
    if (( EUID != 0 )) && ! sudo -n true 2>/dev/null; then
        log "this step needs sudo; you may be prompted for a password"
    fi
}

# run <description> <command...>
run() {
    local desc="$1"; shift
    log "${desc}"
    "$@"
}

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------

install_pacman() {
    local pkgs=("$@")
    local missing=()
    local p
    for p in "${pkgs[@]}"; do
        pacman -Qq "${p}" >/dev/null 2>&1 || missing+=("${p}")
    done
    if (( ${#missing[@]} == 0 )); then
        log "pacman packages already installed: ${pkgs[*]}"
        return 0
    fi
    need_sudo
    log "installing via pacman: ${missing[*]}"
    sudo pacman -S --needed --noconfirm "${missing[@]}"
}

install_aur() {
    # install_aur <package> — via yay if present, else paru, else fail.
    local pkg="$1"
    pacman -Qq "${pkg}" >/dev/null 2>&1 && { log "aur package already installed: ${pkg}"; return 0; }

    if command -v yay >/dev/null 2>&1; then
        log "installing via yay: ${pkg}"
        yay -S --needed --noconfirm "${pkg}"
    elif command -v paru >/dev/null 2>&1; then
        log "installing via paru: ${pkg}"
        paru -S --needed --noconfirm "${pkg}"
    else
        die "no AUR helper (yay/paru) found; install ${pkg} manually"
    fi
}

step_packages() {
    log "--- packages ---"
    install_pacman pipewire wireplumber pipewire-pulse sox jq curl git base-devel cmake
    install_pacman ollama || install_aur ollama

    # whisper.cpp: prefer a prebuilt binary package (fast), else build from git.
    if ! command -v whisper-cpp >/dev/null 2>&1 && ! command -v whisper-cpp-cli >/dev/null 2>&1; then
        if yay -Si whisper-cpp-bin >/dev/null 2>&1; then
            install_aur whisper-cpp-bin
        else
            warn "no whisper-cpp-bin on the AUR; building whisper.cpp from source (slow)"
            install_aur whisper-cpp-git || install_aur whisper-cpp
        fi
    else
        log "whisper.cpp already installed"
    fi

    # piper: the AUR package is piper-tts (binary) or piper (build).
    if ! command -v piper >/dev/null 2>&1 && ! command -v piper-tts >/dev/null 2>&1; then
        install_aur piper-tts || install_aur piper
    else
        log "piper already installed"
    fi
}

# ---------------------------------------------------------------------------
# 2. whisper.cpp model
# ---------------------------------------------------------------------------

step_whisper_model() {
    log "--- whisper.cpp model ---"

    local model="base.en"
    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONF_FILE}"
        model="${ASSISTANT_WHISPER_MODEL:-base.en}"
    fi

    local out="${WHISPER_DIR}/ggml-${model}.bin"
    local url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${model}.bin"

    if [[ -s "${out}" ]]; then
        log "whisper model already present: ${out} ($(stat -c '%s' "${out}") bytes)"
        return 0
    fi

    mkdir -p "${WHISPER_DIR}"
    log "downloading ${url}"
    if ! curl -fL --progress-bar -o "${out}.part" "${url}"; then
        rm -f "${out}.part"
        die "whisper model download failed"
    fi
    mv "${out}.part" "${out}"
    log "whisper model ready: ${out}"
}

# ---------------------------------------------------------------------------
# 3. Piper voice
# ---------------------------------------------------------------------------

step_piper_voice() {
    log "--- piper voice ---"

    local voice="en_US-lessac-medium"
    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONF_FILE}"
        voice="${ASSISTANT_PIPER_VOICE:-en_US-lessac-medium}"
    fi

    local base="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium"
    local onnx="${VOICE_DIR}/${voice}.onnx"
    local conf="${VOICE_DIR}/${voice}.onnx.json"

    mkdir -p "${VOICE_DIR}"

    if [[ -s "${onnx}" && -s "${conf}" ]]; then
        log "piper voice already present: ${onnx}"
        return 0
    fi

    log "downloading voice ${voice}"
    curl -fL --progress-bar -o "${onnx}.part"    "${base}/${voice}.onnx"    || die "voice download failed"
    curl -fL --progress-bar -o "${conf}.part"     "${base}/${voice}.onnx.json" || die "voice config download failed"
    mv "${onnx}.part" "${onnx}"
    mv "${conf}.part"  "${conf}"
    log "piper voice ready: ${onnx}"
}

# ---------------------------------------------------------------------------
# 4. Ollama model
# ---------------------------------------------------------------------------

step_ollama() {
    log "--- ollama model ---"

    local model="llama3.2:3b"
    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONF_FILE}"
        model="${ASSISTANT_MODEL:-llama3.2:3b}"
    fi

    if ! command -v ollama >/dev/null 2>&1; then
        warn "ollama not installed; skipping model pull"
        return 0
    fi

    # Make sure the server is up before asking it to pull.
    if ! curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        log "starting ollama to pull the model"
        systemctl --user enable --now ollama >/dev/null 2>&1 || true
        sleep 3
    fi

    if curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null \
        | jq -e --arg m "${model}" '(.models // []) | map(.name) | index($m)' >/dev/null 2>&1; then
        log "ollama model already pulled: ${model}"
        return 0
    fi

    log "pulling ollama model: ${model} (this can take a while)"
    ollama pull "${model}" || die "ollama pull failed"
    log "ollama model ready: ${model}"
}

# ---------------------------------------------------------------------------
# 5. Wake-word venv (the only Python in the project)
# ---------------------------------------------------------------------------

step_wakeword_venv() {
    log "--- wake-word venv ---"

    if [[ ! -f "${ASSISTANT_SRC}/wakeword.py" ]]; then
        warn "wakeword.py not found; skipping venv"
        return 0
    fi

    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        log "creating venv at ${VENV_DIR}"
        python3 -m venv "${VENV_DIR}"
    else
        log "venv already present: ${VENV_DIR}"
    fi

    log "installing openwakeword into the venv"
    if "${VENV_DIR}/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1; then
        log "pip upgraded"
    fi

    # openwakeword pulls onnxruntime + numpy. It does NOT pull sounddevice,
    # which the listener needs to open the microphone, so install it explicitly.
    # On a very new Python (3.13/3.14) wheels may be missing; that is a warning
    # here, not a hard failure, so the rest of the assistant still works and you
    # can fall back to VAD mode.
    if "${VENV_DIR}/bin/pip" install --quiet openwakeword sounddevice 2>/dev/null; then
        log "openwakeword + sounddevice installed"
    else
        warn "openwakeword/sounddevice failed to install (Python $(python3 --version 2>&1 | awk '{print $2}'))"
        warn "  -> wake word will be unavailable; 'assistant once' and 'listen' still work."
        warn "  -> fix: install a Python with onnxruntime wheels, or edit assistant.conf"
    fi

    # Verify the listener can actually import what it needs.
    if "${VENV_DIR}/bin/python" -c "import openwakeword, sounddevice" 2>/dev/null; then
        log "wake-word dependencies import cleanly"
    else
        warn "wake-word imports failed; run: ${VENV_DIR}/bin/pip install openwakeword sounddevice"
    fi
}

# ---------------------------------------------------------------------------
# 6. Install ~/bin/assistant
# ---------------------------------------------------------------------------

step_install_script() {
    log "--- assistant script ---"

    mkdir -p "${BIN_DIR}"

    local target="${BIN_DIR}/assistant"
    if [[ -e "${target}" || -L "${target}" ]]; then
        backup "${target}"
        # A symlink (common during development) would make cp a no-op with
        # "same file"; remove it so the real file lands there.
        [[ -L "${target}" ]] && rm -f "${target}"
    fi

    cp -a "${ASSISTANT_SRC}/assistant" "${target}"
    chmod +x "${target}"
    log "installed ${target}"

    # Make sure ~/bin is on PATH for login shells.
    local shell_rc="${HOME}/.bashrc"
    if [[ -f "${shell_rc}" ]] && ! grep -q 'HOME}/bin' "${shell_rc}" 2>/dev/null; then
        backup "${shell_rc}"
        printf '\n# local bin\nexport PATH="${HOME}/bin:${PATH}"\n' >> "${shell_rc}"
        log "added ~/bin to PATH in ${shell_rc}"
    fi

    mkdir -p "${STATE_DIR}"
}

# ---------------------------------------------------------------------------
# 7. Hyprland binding
# ---------------------------------------------------------------------------

step_hypr_binding() {
    log "--- hyprland binding ---"

    # This Omarchy uses the Lua config: hyprland.lua requires hypr.bindings,
    # which is ~/.config/hypr/bindings.lua. There is no bindings.conf on this
    # system, so writing one would be silently ignored.
    local bindings="${HOME}/.config/hypr/bindings.lua"

    if [[ ! -f "${bindings}" ]]; then
        warn "not found: ${bindings} — skipping the keybind (add it yourself, see README)"
        return 0
    fi

    if grep -q 'assistant listen' "${bindings}" 2>/dev/null; then
        log "binding already present in ${bindings}"
        return 0
    fi

    backup "${bindings}"

    cat >> "${bindings}" <<'EOF'

-- Local voice assistant (push-to-talk).
o.bind("SUPER + V", "Assistant: listen", "assistant listen")
EOF

    log "added SUPER + V -> assistant listen to ${bindings}"
    log "reload Hyprland to apply: hyprctl reload"
}

# ---------------------------------------------------------------------------
# 8. Omarchy bar widget
# ---------------------------------------------------------------------------

step_bar_widget() {
    log "--- omarchy bar widget ---"

    local plugin_dir="${HOME}/.config/omarchy/plugins/io.github.hermes.assistant"

    if [[ ! -f "${ASSISTANT_SRC}/assistant-bar/BarWidget.qml" ]]; then
        warn "bar widget source not found; skipping"
        return 0
    fi

    mkdir -p "${plugin_dir}"
    backup "${plugin_dir}/BarWidget.qml"
    backup "${plugin_dir}/manifest.json"

    cp -a "${ASSISTANT_SRC}/assistant-bar/BarWidget.qml" "${plugin_dir}/"
    cp -a "${ASSISTANT_SRC}/assistant-bar/manifest.json" "${plugin_dir}/"

    omarchy plugin enable io.github.hermes.assistant >/dev/null 2>&1 || \
        warn "could not enable the bar widget plugin automatically; run: omarchy plugin enable io.github.hermes.assistant"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

    log "bar widget installed to ${plugin_dir}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "assistant setup starting"
    log "home: ${HOME}"
    log "note: CPU-only inference (Intel iGPU, no CUDA/ROCm)"

    mkdir -p "${STATE_DIR}"

    step_packages
    step_whisper_model
    step_piper_voice
    step_ollama
    step_wakeword_venv
    step_install_script
    step_hypr_binding
    step_bar_widget

    echo
    log "setup complete."
    log "next steps:"
    log "  assistant doctor        # verify everything"
    log "  assistant speak \"test\" # test the TTS stage"
    log "  assistant once          # full loop"
}

main "$@"
