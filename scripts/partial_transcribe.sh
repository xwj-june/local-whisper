#!/usr/bin/env bash
# partial_transcribe.sh — background loop: transcribe newest chunks for live overlay
# Launched by start_record.sh, killed by stop_transcribe.sh
source "$(dirname "$0")/config.sh"

log "partial_transcribe: starting"

LAST_CHUNK_INDEX=-1

while true; do
    sleep 1

    # Find the newest completed chunk (not the one ffmpeg is currently writing)
    # A chunk is "complete" once a newer one exists
    # (bash 3.2 compatible — no mapfile)
    chunks=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && chunks+=("$f")
    done < <(ls "$CHUNK_DIR"/chunk_*.wav 2>/dev/null | sort)
    num_chunks=${#chunks[@]}

    # Need at least 2 chunks: the last one is still being written
    if [[ $num_chunks -lt 2 ]]; then
        continue
    fi

    # Index of the latest completed chunk (second-to-last)
    latest_complete_index=$((num_chunks - 2))

    # Skip if we already transcribed this chunk
    if [[ $latest_complete_index -le $LAST_CHUNK_INDEX ]]; then
        continue
    fi

    # Transcribe the new completed chunk
    chunk="${chunks[$latest_complete_index]}"
    log "partial_transcribe: transcribing $chunk"

    lang=$(get_lang)
    whisper_lang_flag="$lang"
    if [[ "$lang" == "auto" ]]; then
        whisper_lang_flag="auto"
    fi

    partial=$("$WHISPER_BIN" \
        -m "$WHISPER_MODEL" \
        -f "$chunk" \
        -l "$whisper_lang_flag" \
        -nt \
        --no-prints \
        2>>"$LOG_FILE") || {
        log "partial_transcribe: whisper failed on $chunk"
        continue
    }

    # Clean up: trim, collapse whitespace
    partial=$(echo "$partial" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    if [[ -n "$partial" ]]; then
        # Append to partial file
        echo -n " $partial" >> "$PARTIAL_FILE"
        log "partial_transcribe: appended '$partial'"
    fi

    LAST_CHUNK_INDEX=$latest_complete_index
done
