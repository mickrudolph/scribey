#!/usr/bin/env python3
import difflib
import json
import os
import re
import signal
import socket
import struct
import sys
import time

import soundfile as sf

MODEL_NAME = "mlx-community/parakeet-tdt-0.6b-v2"
SOCKET_PATH = os.path.expanduser("~/Library/Application Support/Scribey/scribey.sock")
CUSTOM_WORDS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "custom_words.txt")

# Parakeet (an RNNT/TDT model) has no prompt- or vocab-biasing mechanism at
# decode time, unlike Whisper's initial_prompt. This is a post-hoc fuzzy
# correction instead: words in the output that are "close enough" to an
# entry in custom_words.txt get snapped to that entry's exact spelling. It
# only rescues near-misses, not wildly different mishearings.
CUSTOM_WORD_CUTOFF = 0.75
CUSTOM_WORD_MIN_LENGTH = 3

# MLX keeps freed GPU buffers in a reuse cache keyed by size. Every new clip
# length allocates a fresh set, so over a day of varied dictation lengths the
# cache grows without bound (observed: 10GB+), pushing the machine into swap
# and making transcription 5-20x slower. Cap it and release the tail after
# each clip: the cache only ever saves a few ms of allocator work.
GPU_CACHE_LIMIT_BYTES = 512 * 1024 * 1024

# Clips shorter than this underflow parakeet-mlx's internal downsampling and
# wedge the Metal GPU context for all subsequent requests, so skip them.
MIN_DURATION_SECONDS = 0.35


def audio_duration(path):
    try:
        info = sf.info(path)
        return info.frames / info.samplerate
    except Exception:
        return None


def log(message):
    print(message, flush=True)


def read_frame(conn):
    header = conn.recv(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack(">I", header)
    payload = b""
    while len(payload) < length:
        chunk = conn.recv(length - len(payload))
        if not chunk:
            return None
        payload += chunk
    return json.loads(payload.decode("utf-8"))


def write_frame(conn, obj):
    payload = json.dumps(obj).encode("utf-8")
    conn.sendall(struct.pack(">I", len(payload)) + payload)


def load_custom_words(path):
    if not os.path.exists(path):
        return [], {}, []
    words = []
    aliases = {}
    context_rules = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # "word: trigger1, trigger2 => Canonical" -> only replace `word`
            # with Canonical when the very next word in the transcript is one
            # of the triggers. For ambiguous words (e.g. "cloud" is sometimes
            # really "cloud", sometimes a mishearing of "Claude" said right
            # before "code"/"chat"/etc.) that an unconditional alias would
            # wrongly force every time.
            if "=>" in line:
                left, _, canonical = line.partition("=>")
                canonical = canonical.strip()
                word_part, _, triggers_part = left.partition(":")
                rule_word = word_part.strip().lower()
                triggers = {
                    t.strip().lower() for t in triggers_part.split(",") if t.strip()
                }
                if rule_word and triggers and canonical:
                    context_rules.append((rule_word, triggers, canonical))
            # "Canonical: alias1, alias2" -> exact-match aliases, bypassing the
            # fuzzy cutoff entirely. For known mishearings that don't spell
            # close enough to the canonical word (e.g. "clod" -> "Claude").
            elif ":" in line:
                canonical, _, rest = line.partition(":")
                canonical = canonical.strip()
                words.append(canonical)
                for alias in rest.split(","):
                    alias = alias.strip()
                    if alias:
                        aliases[alias.lower()] = canonical
            else:
                words.append(line)
    return words, aliases, context_rules


def apply_custom_words(text, custom_words, aliases, context_rules):
    if not custom_words and not aliases and not context_rules:
        return text
    lower_words = [w.lower() for w in custom_words]
    matches = list(re.finditer(r"[A-Za-z0-9']+", text))
    replacements = {}

    for i, match in enumerate(matches):
        word = match.group(0)
        lower = word.lower()

        matched_context = False
        for rule_word, triggers, canonical in context_rules:
            if lower != rule_word:
                continue
            if i + 1 < len(matches) and matches[i + 1].group(0).lower() in triggers:
                replacements[i] = canonical
                log(
                    f"Scribey daemon: context corrected '{word}' -> '{canonical}' "
                    f"(before '{matches[i + 1].group(0)}')"
                )
                matched_context = True
                break
        if matched_context:
            continue

        if lower in aliases:
            replacement = aliases[lower]
            if replacement != word:
                log(f"Scribey daemon: alias corrected '{word}' -> '{replacement}'")
            replacements[i] = replacement
            continue

        if len(word) < CUSTOM_WORD_MIN_LENGTH:
            continue
        candidates = difflib.get_close_matches(
            lower, lower_words, n=1, cutoff=CUSTOM_WORD_CUTOFF
        )
        if not candidates:
            continue
        replacement = custom_words[lower_words.index(candidates[0])]
        if replacement != word:
            log(f"Scribey daemon: custom word corrected '{word}' -> '{replacement}'")
        replacements[i] = replacement

    out = []
    last_end = 0
    for i, match in enumerate(matches):
        out.append(text[last_end:match.start()])
        out.append(replacements.get(i, match.group(0)))
        last_end = match.end()
    out.append(text[last_end:])
    return "".join(out)


def main():
    log("Scribey daemon: loading model (this can take a while on first run)...")
    import mlx.core as mx
    from parakeet_mlx import from_pretrained

    mx.set_cache_limit(GPU_CACHE_LIMIT_BYTES)
    model = from_pretrained(MODEL_NAME)

    # First transcription pays ~1.5s of lazy Metal kernel compilation. Warm it
    # here so the user's first dictation of the day isn't the one that pays it.
    try:
        warmup = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warmup.wav")
        if os.path.exists(warmup):
            model.transcribe(warmup)
            mx.clear_cache()
            log("Scribey daemon: warmup transcription done.")
    except Exception as exc:
        log(f"Scribey daemon: warmup failed (non-fatal): {exc}")

    log("Scribey daemon: model loaded.")

    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(1)
    log(f"Scribey daemon: listening on {SOCKET_PATH}")

    def handle_shutdown(signum, frame):
        log("Scribey daemon: shutting down.")
        try:
            server.close()
        finally:
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)

    while True:
        conn, _ = server.accept()
        try:
            while True:
                request = read_frame(conn)
                if request is None:
                    break
                if request.get("cmd") != "transcribe":
                    write_frame(conn, {"ok": False, "error": f"unknown cmd: {request.get('cmd')}"})
                    continue
                path = request.get("path")
                duration = audio_duration(path)
                log(f"Scribey daemon: received clip, duration={duration}")
                if duration is not None and duration < MIN_DURATION_SECONDS:
                    log(f"Scribey daemon: clip too short ({duration:.2f}s), skipping")
                    write_frame(conn, {"ok": True, "text": ""})
                    continue
                try:
                    started = time.monotonic()
                    result = model.transcribe(path)
                    elapsed = time.monotonic() - started
                    speed = f" ({duration / elapsed:.1f}x realtime)" if duration else ""
                    log(f"Scribey daemon: transcribed in {elapsed:.2f}s{speed}")
                    words, aliases, context_rules = load_custom_words(CUSTOM_WORDS_PATH)
                    text = apply_custom_words(result.text.strip(), words, aliases, context_rules)
                    write_frame(conn, {"ok": True, "text": text})
                except Exception as exc:
                    write_frame(conn, {"ok": False, "error": str(exc)})
                finally:
                    mx.clear_cache()
        finally:
            conn.close()


if __name__ == "__main__":
    main()
