#!/usr/bin/env bash
# start_record.sh — begin chunked audio recording + partial transcription
source "$(dirname "$0")/config.sh"

log "=== start_record ==="

# Check dependencies
check_deps || exit 1

# Guard: kill stale recording if PID file exists but process is dead
if [[ -f "$PID_FILE" ]]; then
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        log "Recording already in progress (PID $old_pid), aborting"
        exit 1
    else
        log "Stale PID file found (PID $old_pid), cleaning up"
        rm -f "$PID_FILE"
    fi
fi

# Clean up from previous run (guard against symlink attacks)
if [[ -L "$CHUNK_DIR" ]]; then
    log "ERROR: $CHUNK_DIR is a symlink, aborting"
    exit 1
fi
rm -rf "$CHUNK_DIR"
mkdir -p "$CHUNK_DIR"
rm -f "$PARTIAL_FILE" "$FINAL_FILE"
touch "$PARTIAL_FILE"

# Play start sound
play_sound "$SND_START"

# Signal Hammerspoon overlay
"$HS" -c "WhisperOverlay.start()" 2>/dev/null || log "WARN: could not signal Hammerspoon overlay start"

# Start ffmpeg chunked recording
# -f avfoundation: macOS audio capture
# -ac 1 -ar 16000: mono, 16kHz (what whisper expects)
# -f segment: split into chunks for partial transcription
"$FFMPEG" -y -f avfoundation -i "$AUDIO_DEVICE" \
    -ac 1 -ar 16000 \
    -f segment -segment_time "$CHUNK_DURATION" -reset_timestamps 1 \
    "$CHUNK_DIR/chunk_%05d.wav" \
    >> "$LOG_FILE" 2>&1 &

FFMPEG_PID=$!
echo "$FFMPEG_PID" > "$PID_FILE"
log "ffmpeg started (PID $FFMPEG_PID), chunks → $CHUNK_DIR"

# Start partial transcription loop in background
"$(dirname "$0")/partial_transcribe.sh" &
PARTIAL_PID=$!
echo "$PARTIAL_PID" > "$PARTIAL_PID_FILE"
log "partial_transcribe started (PID $PARTIAL_PID)"
