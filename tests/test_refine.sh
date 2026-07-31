#!/usr/bin/env bash
# test_refine.sh — eval suite for LLM refinement (Ollama or OpenAI backend)
# Tests that the refine prompt produces correct output for common patterns.
# Backend is read from ~/.local-whisper/refine_backend (default: ollama).
# Requires: Ollama running locally, or an OpenAI key in ~/.local-whisper/openai_api_key.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

OLLAMA_URL="http://localhost:11434/api/generate"
OPENAI_URL="https://api.openai.com/v1/chat/completions"
CONFIG_DIR="$HOME/.local-whisper"

# Backend selection (mirrors REFINE.backend() in init.lua)
BACKEND="ollama"
if [[ -f "$CONFIG_DIR/refine_backend" ]]; then
    v=$(tr -d '[:space:]' < "$CONFIG_DIR/refine_backend")
    [[ "$v" == "openai" ]] && BACKEND="openai"
fi

if [[ "$BACKEND" == "openai" ]]; then
    KEY_FILE="$CONFIG_DIR/openai_api_key"
    if [[ ! -s "$KEY_FILE" ]]; then
        echo -e "${RED}Error: backend is openai but $KEY_FILE is missing/empty${NC}"
        exit 1
    fi
    OPENAI_KEY=$(tr -d '[:space:]' < "$KEY_FILE")
    MODEL_FILE="$CONFIG_DIR/openai_model"
    if [[ -f "$MODEL_FILE" ]]; then
        MODEL=$(tr -d '[:space:]' < "$MODEL_FILE")
    fi
    MODEL="${MODEL:-gpt-5.6-luna}"
else
    MODEL_FILE="$CONFIG_DIR/refine_model"
    if [[ -f "$MODEL_FILE" ]]; then
        MODEL=$(tr -d '[:space:]' < "$MODEL_FILE")
    fi
    MODEL="${MODEL:-gemma3:4b}"
fi

# Read prompt from config or use default (keep in sync with REFINE.DEFAULT_PROMPT in init.lua)
PROMPT_FILE="$CONFIG_DIR/refine_prompt"
if [[ -f "$PROMPT_FILE" ]] && [[ -s "$PROMPT_FILE" ]]; then
    PROMPT=$(cat "$PROMPT_FILE")
else
    PROMPT=$(cat <<'EOF'
You are a transcription cleanup tool. The input is dictated speech (English, Chinese, or mixed) transcribed by speech recognition. Output ONLY the cleaned text — no commentary, no preamble, no quotes.
Do:
- Add punctuation and sentence breaks. Use Chinese punctuation for Chinese text, especially when it was dictated fast without pauses.
- Convert spoken enumerations (first/second/third, one/two/three, 第一/第二/第三, 第一点/第二点) into a numbered list, one item per line.
- Remove filler words (um, uh, you know, I mean; 嗯, 啊, 呃 — and 这个/就是/然后 only when used as fillers).
- Remove stutters and immediate repetitions: when the same phrase is said twice in a row, keep one.
- Fix obvious speech-recognition errors (e.g. Chinese homophone mistakes) only when the intended word is unambiguous.
Do NOT:
- Rewrite, rephrase, summarize, or reorder anything. Keep the speaker's wording and style.
- Remove sentences or meaningful content.
- Translate or unify languages: keep mixed Chinese/English exactly as mixed.
- Change anything you are unsure about — when in doubt, leave it unchanged.
EOF
)
fi

PASS=0
FAIL=0
TOTAL=0

call_llm() {
    local input="$1"
    local payload response

    if [[ "$BACKEND" == "openai" ]]; then
        payload=$(python3 -c '
import json, sys
model = sys.argv[1]
body = {"model": model, "messages": [{"role": "user", "content": sys.stdin.read()}]}
if model.startswith("gpt-5") or (len(model) > 1 and model[0] == "o" and model[1].isdigit()):
    body["reasoning_effort"] = "minimal"
print(json.dumps(body))
' "$MODEL" <<< "$PROMPT

$input")
        response=$(curl -s --max-time 30 -X POST "$OPENAI_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $OPENAI_KEY" \
            -d "$payload" 2>/dev/null)
        if [[ -z "$response" ]]; then
            echo "ERROR: No response from OpenAI"
            return 1
        fi
        python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
if "error" in data:
    raise SystemExit("API error: " + str(data["error"].get("message", data["error"])))
print(data["choices"][0]["message"]["content"].strip())
' <<< "$response"
    else
        payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': '$MODEL',
    'prompt': sys.stdin.read(),
    'stream': False
}))
" <<< "$PROMPT

$input")
        response=$(curl -s -X POST "$OLLAMA_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        if [[ -z "$response" ]]; then
            echo "ERROR: No response from Ollama"
            return 1
        fi
        python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print(data.get('response', '').strip())
" <<< "$response"
    fi
}

# Test case runner
# Usage: test_case "description" "input" "check_type" "expected"
# check_type: "exact" | "contains" | "not_contains" | "starts_with" | "has_newlines"
#           | "min_count:<pattern>" (expected = min occurrences)
#           | "max_count:<pattern>" (expected = max occurrences)
test_case() {
    local desc="$1"
    local input="$2"
    local check="$3"
    local expected="$4"

    TOTAL=$((TOTAL + 1))

    local output
    output=$(call_llm "$input" 2>/dev/null) || {
        echo -e "${RED}FAIL${NC} [$desc] — LLM call failed"
        FAIL=$((FAIL + 1))
        return
    }

    local passed=false
    case "$check" in
        exact)
            [[ "$output" == "$expected" ]] && passed=true
            ;;
        contains)
            echo "$output" | grep -qi "$expected" && passed=true
            ;;
        not_contains)
            ! echo "$output" | grep -qi "$expected" && passed=true
            ;;
        starts_with)
            [[ "$output" == "$expected"* ]] && passed=true
            ;;
        has_newlines)
            # Check output has multiple lines (numbered list)
            local lines
            lines=$(echo "$output" | wc -l | tr -d ' ')
            [[ "$lines" -ge "$expected" ]] && passed=true
            ;;
        min_count:*|max_count:*)
            local pattern="${check#*:}"
            local count
            count=$(echo "$output" | grep -o "$pattern" | wc -l | tr -d ' ')
            if [[ "$check" == min_count:* ]]; then
                [[ "$count" -ge "$expected" ]] && passed=true
            else
                [[ "$count" -le "$expected" ]] && passed=true
            fi
            ;;
    esac

    if $passed; then
        echo -e "${GREEN}PASS${NC} [$desc]"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} [$desc]"
        echo -e "  Input:    ${input:0:80}"
        echo -e "  Output:   ${output:0:120}"
        echo -e "  Expected: $check '$expected'"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Preflight ────────────────────────────────────────────────────────────────

echo -e "${BOLD}local-whisper refine eval suite${NC}"
echo -e "Backend: ${BOLD}$BACKEND${NC}  Model: ${BOLD}$MODEL${NC}"
echo ""

if [[ "$BACKEND" == "openai" ]]; then
    if ! probe=$(call_llm "Say OK." 2>&1); then
        echo -e "${RED}Error: OpenAI not reachable or key rejected${NC}"
        echo "$probe"
        exit 1
    fi
    echo -e "${GREEN}OpenAI reachable${NC} ($OPENAI_URL)"
else
    if ! curl -s "$OLLAMA_URL" -d '{"model":"'$MODEL'","prompt":"hi","stream":false}' > /dev/null 2>&1; then
        echo -e "${RED}Error: Ollama not reachable at $OLLAMA_URL${NC}"
        echo "Make sure Ollama is running: ollama serve"
        exit 1
    fi
    echo -e "${GREEN}Ollama reachable${NC} ($OLLAMA_URL)"
fi
echo ""

# ─── Test Cases ───────────────────────────────────────────────────────────────

echo -e "${BOLD}--- Filler word removal ---${NC}"

test_case "Remove um/uh" \
    "Um, so I was thinking, uh, we should probably, you know, update the docs." \
    "not_contains" "um"

test_case "Keep meaningful content" \
    "I built a dictation tool for macOS. It uses whisper.cpp for transcription." \
    "contains" "dictation tool"

test_case "Keep all sentences" \
    "Ok, here is my itemized list. Let's test whether it worked. First item is great." \
    "contains" "itemized list"

echo ""
echo -e "${BOLD}--- Numbered list formatting ---${NC}"

test_case "First/second/third → numbered list" \
    "First, buy groceries. Second, do laundry. Third, cook dinner." \
    "has_newlines" "3"

test_case "One/two/three → numbered list" \
    "One, check the logs. Two, fix the bug. Three, write a test." \
    "has_newlines" "3"

test_case "Sequential items with context" \
    "I am going to test the itemized feature. First, testing the first item. Second, testing the second item. Third, testing the third item." \
    "has_newlines" "3"

echo ""
echo -e "${BOLD}--- No preamble ---${NC}"

test_case "No 'Here is' preamble" \
    "So basically, um, the main thing is that we need to update the server config and restart the service." \
    "not_contains" "here is"

test_case "No 'Sure' preamble" \
    "I think we should probably consider refactoring the authentication module." \
    "not_contains" "^sure"

echo ""
echo -e "${BOLD}--- Punctuation & capitalization ---${NC}"

test_case "Capitalize first word" \
    "the quick brown fox jumps over the lazy dog" \
    "starts_with" "The"

echo ""
echo -e "${BOLD}--- Chinese: punctuation for pause-free speech ---${NC}"

test_case "Unpunctuated Chinese run gets punctuation" \
    "我想知道一点就是现在我说话它并没有很多标点符号这是因为我说话的时候没有暂停还是有别的原因有什么办法可以解决这个问题" \
    "min_count:[,。?!;]" "3"

test_case "Chinese content preserved" \
    "我想知道一点就是现在我说话它并没有很多标点符号这是因为我说话的时候没有暂停还是有别的原因有什么办法可以解决这个问题" \
    "contains" "标点符号"

echo ""
echo -e "${BOLD}--- Chinese: spoken enumeration → list ---${NC}"

test_case "第一点/第二点/第三点 → numbered list" \
    "我有几个想法第一点我们应该先写测试第二点代码要简单一点第三点文档要同步更新" \
    "has_newlines" "3"

echo ""
echo -e "${BOLD}--- Chinese: fillers & repetition ---${NC}"

test_case "Remove 嗯/啊 fillers" \
    "嗯我觉得啊这个功能嗯还是很有用的我们应该保留它然后继续改进它的性能" \
    "not_contains" "嗯"

test_case "Collapse immediate repetition" \
    "就是说它并没有分割就是说它并没有分割这是我觉得最大的问题我们需要解决它" \
    "max_count:它并没有分割" "1"

test_case "Mixed Chinese/English kept mixed" \
    "我现在就看着这个DocumentModels感觉很复杂我们应该把它拆分成几个小的module这样会更好维护一点" \
    "contains" "DocumentModels"

echo ""
echo -e "${BOLD}--- Short text passthrough ---${NC}"

test_case "Short text preserved" \
    "Hello world, this is a test." \
    "contains" "Hello"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}─────────────────────────────${NC}"
echo -e "${BOLD}Results: ${PASS}/${TOTAL} passed${NC}"
if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}${FAIL} failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed${NC}"
fi
