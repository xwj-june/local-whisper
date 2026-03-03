#!/usr/bin/env bash
# stop_transcribe.sh — stop recording, run final transcription, signal insertion
source "$(dirname "$0")/config.sh"

log "=== stop_transcribe ==="

# Play stop sound
play_sound "$SND_STOP"

# Kill partial transcription loop
if [[ -f "$PARTIAL_PID_FILE" ]]; then
    partial_pid=$(cat "$PARTIAL_PID_FILE")
    if kill -0 "$partial_pid" 2>/dev/null; then
        kill "$partial_pid" 2>/dev/null || true
        wait "$partial_pid" 2>/dev/null || true
        log "partial_transcribe stopped (PID $partial_pid)"
    fi
    rm -f "$PARTIAL_PID_FILE"
fi

# Kill ffmpeg
if [[ -f "$PID_FILE" ]]; then
    ffmpeg_pid=$(cat "$PID_FILE")
    if kill -0 "$ffmpeg_pid" 2>/dev/null; then
        kill "$ffmpeg_pid" 2>/dev/null || true
        wait "$ffmpeg_pid" 2>/dev/null || true
        log "ffmpeg stopped (PID $ffmpeg_pid)"
    fi
    rm -f "$PID_FILE"
else
    log "No PID file found, nothing to stop"
    "$HS" -c "WhisperOverlay.stop()" 2>/dev/null || true
    exit 0
fi

# Signal overlay: transcribing
"$HS" -c 'WhisperOverlay.setStatus("Transcribing...")' 2>/dev/null || true

# Collect chunks (bash 3.2 compatible — no mapfile)
chunks=()
while IFS= read -r f; do
    [[ -n "$f" ]] && chunks+=("$f")
done < <(ls "$CHUNK_DIR"/chunk_*.wav 2>/dev/null | sort)

if [[ ${#chunks[@]} -eq 0 ]]; then
    log "No chunks recorded, aborting"
    "$HS" -c "WhisperOverlay.stop()" 2>/dev/null || true
    rm -rf "$CHUNK_DIR"
    exit 0
fi

log "Concatenating ${#chunks[@]} chunks"

# Build ffmpeg concat list
CONCAT_LIST="$CHUNK_DIR/concat.txt"
for chunk in "${chunks[@]}"; do
    echo "file '$chunk'" >> "$CONCAT_LIST"
done

# Concatenate to single WAV
FULL_WAV="/tmp/whisper_recording.wav"
"$FFMPEG" -y -f concat -safe 0 -i "$CONCAT_LIST" -c copy "$FULL_WAV" \
    >> "$LOG_FILE" 2>&1 || {
    log "ERROR: ffmpeg concat failed"
    "$HS" -c 'WhisperOverlay.setStatus("Error")' 2>/dev/null || true
    sleep 2
    "$HS" -c "WhisperOverlay.stop()" 2>/dev/null || true
    rm -rf "$CHUNK_DIR"
    exit 1
}

# Final transcription
lang=$(get_lang)
log "Running final transcription (lang=$lang)"

final_text=$("$WHISPER_BIN" \
    -m "$WHISPER_MODEL" \
    -f "$FULL_WAV" \
    -l "$lang" \
    -nt \
    --no-prints \
    2>>"$LOG_FILE") || {
    log "ERROR: whisper-cli failed"
    "$HS" -c 'WhisperOverlay.setStatus("Error")' 2>/dev/null || true
    sleep 2
    "$HS" -c "WhisperOverlay.stop()" 2>/dev/null || true
    rm -rf "$CHUNK_DIR"
    exit 1
}

# Clean text: trim, collapse whitespace, fix space before punctuation
final_text=$(echo "$final_text" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | tr -s ' ' \
    | sed 's/ \([.,!?;:]\)/\1/g')

if [[ -z "$final_text" ]]; then
    log "Transcription returned empty text"
    "$HS" -c "WhisperOverlay.stop()" 2>/dev/null || true
    rm -rf "$CHUNK_DIR"
    exit 0
fi

# Write final text
echo -n "$final_text" > "$FINAL_FILE"
log "Final text: $final_text"

# Signal Hammerspoon to insert
"$HS" -c "WhisperOverlay.insertFinal()" 2>/dev/null || log "WARN: could not signal insertion"

# Done sound
play_sound "$SND_DONE"

# Clean up
rm -rf "$CHUNK_DIR"
rm -f "$FULL_WAV"

log "=== done ==="
