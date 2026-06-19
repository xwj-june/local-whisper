-- init.lua — local-whisper: Hammerspoon-only dictation
-- Hold a modifier key → record → transcribe → insert at cursor
-- No Karabiner needed. Just Hammerspoon + ffmpeg + whisper.cpp

require("hs.ipc")

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local HOME = os.getenv("HOME")
local TMPDIR = os.getenv("TMPDIR") or "/tmp"
local WHISPER_TMP = TMPDIR .. "/whisper-dictate"
local CHUNK_DIR = WHISPER_TMP .. "/chunks"

-- Config directory (all user settings live here)
local CONFIG_DIR = HOME .. "/.local-whisper"
os.execute("mkdir -p '" .. CONFIG_DIR .. "'")

-- External binaries (absolute paths, with ARM/Intel fallback)
local FFMPEG = hs.fs.attributes("/opt/homebrew/bin/ffmpeg") and "/opt/homebrew/bin/ffmpeg" or "/usr/local/bin/ffmpeg"
local WHISPER_BIN = HOME .. "/whisper.cpp/build/bin/whisper-cli"
local MODELS_DIR = HOME .. "/whisper.cpp/models"
local MODEL_FILE = CONFIG_DIR .. "/model"

-- Scan available models
local function getAvailableModels()
    local models = {}
    local ok, iter, dir = pcall(hs.fs.dir, MODELS_DIR)
    if not ok then return models end
    for file in iter, dir do
        local name = file:match("^ggml%-(.+)%.bin$")
        if name then table.insert(models, name) end
    end
    table.sort(models)
    return models
end

-- Get/set active model
local function getModelName()
    local saved = ""
    local f = io.open(MODEL_FILE, "r")
    if f then saved = f:read("*a"):gsub("%s+", ""); f:close() end
    if saved ~= "" then
        -- Verify model file exists
        local path = MODELS_DIR .. "/ggml-" .. saved .. ".bin"
        local attr = hs.fs.attributes(path)
        if attr then return saved end
    end
    return "medium"  -- default
end

local function getModelPath()
    return MODELS_DIR .. "/ggml-" .. getModelName() .. ".bin"
end

-- Audio device: ":default" for system default, ":0", ":1" etc. for specific
-- Note: avfoundation requires colon prefix for audio-only (":0" not "0")
local AUDIO_DEVICE = ":default"

-- Auto-fix missing colon prefix (common setup mistake)
if AUDIO_DEVICE ~= ":default" and not AUDIO_DEVICE:match("^:") then
    AUDIO_DEVICE = ":" .. AUDIO_DEVICE
end

-- Trigger key: "rightAlt", "rightCmd", "rightCtrl"
local TRIGGER_KEY = "rightCmd"

-- User preference files (all in CONFIG_DIR)
local LANG_FILE = CONFIG_DIR .. "/lang"
local OUTPUT_FILE = CONFIG_DIR .. "/output"
local THEME_FILE = CONFIG_DIR .. "/theme"
local PREFERRED_LANGS_FILE = CONFIG_DIR .. "/preferred_langs"
local ENTER_FILE = CONFIG_DIR .. "/enter"
local PROMPT_FILE = CONFIG_DIR .. "/prompt"
local RECENT_FILE = CONFIG_DIR .. "/recent.json"
local LOG_FILE = WHISPER_TMP .. "/whisper-dictate.log"

-- Action hooks config
local ACTIONS_FILE = HOME .. "/.hammerspoon/local_whisper_actions.lua"

-- Auto-stop on silence
local AUTO_STOP_SILENCE_SECONDS = 3
local AUTO_STOP_THRESHOLD_DB = -40

-- LLM refinement (requires Ollama)
local REFINE_FILE = CONFIG_DIR .. "/refine"
local REFINE_PROMPT_FILE = CONFIG_DIR .. "/refine_prompt"
local REFINE_MODEL_FILE = CONFIG_DIR .. "/refine_model"
local REFINE_DEFAULT_MODEL = "gemma3:4b"
local REFINE_MIN_CHARS = 50  -- skip refinement for short text
local REFINE_DEFAULT_PROMPT = "You are a text cleanup tool. Output ONLY the cleaned text, nothing else. Fix punctuation and capitalization. Remove ONLY filler words like um, uh, you know, I mean. Do NOT remove sentences or meaningful content. When the text lists sequential items using first/second/third or one/two/three, convert them into a numbered list with each item on a new line. NEVER add commentary or preamble. Just output the cleaned text."

local function getRefineModel()
    local f = io.open(REFINE_MODEL_FILE, "r")
    if f then
        local val = f:read("*a"):gsub("%s+", ""); f:close()
        if val ~= "" then return val end
    end
    return REFINE_DEFAULT_MODEL
end

local function getRefinePrompt()
    local f = io.open(REFINE_PROMPT_FILE, "r")
    if f then
        local content = f:read("*a"); f:close()
        content = content:gsub("^%s+", ""):gsub("%s+$", "")
        if content ~= "" then return content end
    end
    return REFINE_DEFAULT_PROMPT
end

local function hasOllama()
    -- Check if Ollama API is reachable
    local ok = os.execute("curl -s -o /dev/null -w '' http://localhost:11434/api/tags 2>/dev/null")
    if ok then return true end
    -- Fallback: check if binary exists
    return os.execute("command -v ollama >/dev/null 2>&1")
end

local function getRefineMode()
    local f = io.open(REFINE_FILE, "r")
    if not f then return false end
    local val = f:read("*a"):gsub("%s+", ""); f:close()
    return val == "on"
end

local function setRefineMode(on)
    local f = io.open(REFINE_FILE, "w")
    if f then f:write(on and "on" or "off"); f:close() end
end

local function cycleRefine()
    local current = getRefineMode()
    setRefineMode(not current)
end

-- Timing
local PARTIAL_INTERVAL = 2.0   -- seconds between partial transcriptions
local OVERLAY_LINGER = 0.5     -- seconds to show final text before closing

-- Known whisper hallucinations on silence/short audio
local HALLUCINATIONS = {
    "you", "thank you", "thanks for watching", "thanks for listening",
    "bye", "goodbye", "the end", "thank you for watching",
    "subscribe", "like and subscribe", "see you", "you.",
    "(applause)", "(keyboard clicking)", "(typing)", "(silence)",
    "(soft music)", "(lighter clicking)", "(applauding)",
    "[BLANK_AUDIO]", "[silence]",
}

--------------------------------------------------------------------------------
-- Trigger key mapping
--------------------------------------------------------------------------------

local TRIGGER_MASKS = {
    rightAlt  = hs.eventtap.event.rawFlagMasks["deviceRightAlternate"],
    rightCmd  = hs.eventtap.event.rawFlagMasks["deviceRightCommand"],
    rightCtrl = hs.eventtap.event.rawFlagMasks["deviceRightControl"],
}

local triggerMask = TRIGGER_MASKS[TRIGGER_KEY]
if not triggerMask then
    hs.notify.new({ title = "local-whisper", informativeText = "ERROR: Invalid TRIGGER_KEY: " .. TRIGGER_KEY }):send()
    return
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

os.execute("mkdir -p '" .. WHISPER_TMP .. "'")

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
        f:close()
    end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return end
    f:write(content)
    f:close()
end

local function getLang()
    local lang = readFile(LANG_FILE):gsub("%s+", "")
    if lang == "en" or lang == "zh" or lang == "auto" then return lang end
    return "en"
end

local function getOutputMode()
    local mode = readFile(OUTPUT_FILE):gsub("%s+", "")
    if mode == "type" then return "type" end
    return "paste"
end

local function getPreferredLangs()
    local content = readFile(PREFERRED_LANGS_FILE):gsub("%s+$", "")
    if content == "" then return {"en", "pt"} end
    local langs = {}
    for lang in content:gmatch("[^,]+") do
        lang = lang:match("^%s*(.-)%s*$")
        if lang ~= "" then table.insert(langs, lang) end
    end
    return #langs > 0 and langs or {"en", "pt"}
end

local function getEnterMode()
    local mode = readFile(ENTER_FILE):gsub("%s+", "")
    return mode == "on"
end

local function shellQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function expandPath(path)
    if type(path) ~= "string" then return nil end
    if path:sub(1, 2) == "~/" then return HOME .. path:sub(2) end
    return path
end

local function ensureParentDir(path)
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return true end
    local ok = os.execute("mkdir -p " .. shellQuote(parent))
    return ok == true or ok == 0
end

local function normalizeText(text)
    return ((text or ""):gsub("%s+", " ")):gsub("^%s+", ""):gsub("%s+$", "")
end

-- App bundle IDs where auto-capitalize should be skipped (terminals, code editors)
local NO_CAPITALIZE_APPS = {
    ["com.apple.Terminal"] = true,
    ["com.googlecode.iterm2"] = true,
    ["dev.warp.Warp-Stable"] = true,
    ["com.microsoft.VSCode"] = true,
    ["com.apple.dt.Xcode"] = true,
    ["com.jetbrains.intellij"] = true,
    ["com.sublimetext.4"] = true,
    ["com.github.atom"] = true,
    ["dev.zed.Zed"] = true,
}

-- Text post-processing: capitalize, remove fillers, clean whitespace
-- appBundleID is optional; when provided, adjusts behavior per-app
local function postProcess(text, appBundleID)
    -- Trim
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return text end
    -- Remove filler words (standalone, case-insensitive)
    text = text:gsub("%f[%w][Uu][mm]%f[%W]", "")
    text = text:gsub("%f[%w][Uu][hh]%f[%W]", "")
    text = text:gsub("%f[%w][Hh][Mm][Mm]+%f[%W]", "")
    -- Remove "like," used as filler (comma-following)
    text = text:gsub("%f[%w][Ll]ike,%s*", "")
    -- Collapse multiple spaces
    text = text:gsub("%s+", " ")
    -- Trim again after removals
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Auto-capitalize first letter (skip for terminals and code editors)
    if not (appBundleID and NO_CAPITALIZE_APPS[appBundleID]) then
        text = text:gsub("^%l", string.upper)
    end
    return text
end

local function refineWithOllama(text, callback)
    if not getRefineMode() or not hasOllama() or #text < REFINE_MIN_CHARS then
        callback(text)
        return
    end
    log("refine: sending to Ollama API (" .. #text .. " chars)")
    local prompt = getRefinePrompt() .. "\n\n" .. text
    local model = getRefineModel()
    -- Use Ollama HTTP API (more reliable than CLI, avoids version mismatch issues)
    local jsonPayload = hs.json.encode({
        model = model,
        prompt = prompt,
        stream = false,
    })
    local tmpPayload = WHISPER_TMP .. "/refine_payload.json"
    local f = io.open(tmpPayload, "w")
    if f then f:write(jsonPayload); f:close() end
    local task = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
        if code == 0 and stdout and #stdout > 0 then
            local ok, result = pcall(hs.json.decode, stdout)
            if ok and result and result.response then
                local refined = result.response:gsub("^%s+", ""):gsub("%s+$", "")
                -- Strip common LLM preamble
                refined = refined:gsub("^[Hh]ere%s+is%s+the%s+cleaned%s+text:%s*\n?", "")
                refined = refined:gsub("^[Hh]ere'?s?%s+the%s+cleaned[%-]?%s*text:%s*\n?", "")
                refined = refined:gsub("^[Hh]ere%s+is%s+the%s+refined%s+text:%s*\n?", "")
                refined = refined:gsub("^[Ss]ure[,!]?%s*[Hh]?e?r?e?'?s?%s*t?h?e?%s*", "")
                refined = refined:gsub("^%s+", "")
                if refined ~= "" then
                    log("refine: success (" .. #refined .. " chars)")
                    callback(refined)
                    return
                end
            end
        end
        log("refine: failed (code=" .. tostring(code) .. "), using original")
        callback(text)
    end, {
        "-s", "-X", "POST",
        "http://localhost:11434/api/generate",
        "-H", "Content-Type: application/json",
        "-d", "@" .. tmpPayload,
    })
    task:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
    task:start()
end

local function isHallucination(text)
    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- strip trailing period for comparison
    local stripped = lower:gsub("[%.%!%?]+$", "")
    for _, h in ipairs(HALLUCINATIONS) do
        if stripped == h:lower() or lower == h:lower() then return true end
    end
    -- Also filter anything in brackets/parens (whisper noise markers)
    if lower:match("^%[.*%]$") or lower:match("^%(.*%)$") then return true end
    return false
end

local function getChunkFiles()
    local chunks = {}
    local ok, iter, dir = pcall(hs.fs.dir, CHUNK_DIR)
    if not ok then return chunks end
    for file in iter, dir do
        if file:match("^chunk_.*%.wav$") then
            table.insert(chunks, CHUNK_DIR .. "/" .. file)
        end
    end
    table.sort(chunks)
    return chunks
end

-- Cycle helpers
local function cycleLang()
    local cycle = { en = "zh", zh = "auto", auto = "en" }
    local next = cycle[getLang()] or "en"
    writeFile(LANG_FILE, next)
    return next
end

local function cycleModel()
    local models = getAvailableModels()
    if #models == 0 then return getModelName() end
    local current = getModelName()
    local next = models[1]
    for i, m in ipairs(models) do
        if m == current and models[i + 1] then
            next = models[i + 1]
            break
        end
    end
    if next == current then next = models[1] end
    writeFile(MODEL_FILE, next)
    return next
end

local function cycleOutput()
    local next = (getOutputMode() == "paste") and "type" or "paste"
    writeFile(OUTPUT_FILE, next)
    return next
end

-- Overlay theme: "light" (Frosted Light), "paper" (Warm Paper), "dark" (Soft Dark)
local function getTheme()
    local t = readFile(THEME_FILE):gsub("%s+", "")
    if t == "light" or t == "paper" or t == "dark" then return t end
    return "light"
end

local function cycleTheme()
    local cycle = { light = "paper", paper = "dark", dark = "light" }
    local next = cycle[getTheme()] or "light"
    writeFile(THEME_FILE, next)
    return next
end

-- Live preview: rough tiny-model transcription shown in the overlay while
-- recording. OFF by default — it's only a liveness indicator (laggy + uses the
-- least-accurate model), never the final text, which is always re-transcribed
-- with the chosen model on release. Stored in ~/.local-whisper/preview.
local PREVIEW_FILE = CONFIG_DIR .. "/preview"

local function getPreview()
    return readFile(PREVIEW_FILE):gsub("%s+", "") == "on"
end

local function setPreview(on)
    writeFile(PREVIEW_FILE, on and "on" or "off")
end

-- Loading-spinner style shown during transcription. Stored in
-- ~/.local-whisper/spinner: bounce (default) | comet | orbit | pulse.
local function getSpinner()
    local s = readFile(CONFIG_DIR .. "/spinner"):gsub("%s+", "")
    if s == "comet" or s == "orbit" or s == "pulse" or s == "bounce" then return s end
    return "bounce"
end

-- Completion sound (played after text is inserted). Stored in
-- ~/.local-whisper/sound as a macOS system-sound name (e.g. "Glass") or "off".
local SOUND_FILE = CONFIG_DIR .. "/sound"
local SOUND_DIR = "/System/Library/Sounds/"
local DEFAULT_SOUND = "Glass"
local SOUND_CHOICES = {
    "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
    "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
}

local function getSound()
    local s = readFile(SOUND_FILE):gsub("%s+", "")
    if s == "" then return DEFAULT_SOUND end
    return s
end

local function setSound(name)
    writeFile(SOUND_FILE, name)
end

local function playDoneSound()
    local name = getSound()
    if name == "off" then return end
    local snd = hs.sound.getByFile(SOUND_DIR .. name .. ".aiff")
    if snd then snd:play() end
end

local function cycleEnter()
    local next = getEnterMode() and "off" or "on"
    writeFile(ENTER_FILE, next)
    return next
end

-- Pick fastest available model for live partial transcription
local function getPartialModelPath()
    local preferred = { "tiny", "tiny.en", "base", "base.en", "small", "small.en" }
    for _, name in ipairs(preferred) do
        local path = MODELS_DIR .. "/ggml-" .. name .. ".bin"
        if hs.fs.attributes(path) then return path end
    end
    return getModelPath()  -- fall back to main model
end

-- Read custom vocabulary prompt for whisper
local function getPromptArgs()
    local content = readFile(PROMPT_FILE):gsub("%s+$", "")
    if content ~= "" then return { "--prompt", content } end
    return {}
end

--------------------------------------------------------------------------------
-- App-aware context (captured at recording start)
--------------------------------------------------------------------------------

local capturedAppName = nil
local capturedAppBundleID = nil

local function captureActiveApp()
    local app = hs.application.frontmostApplication()
    if app then
        capturedAppName = app:name()
        capturedAppBundleID = app:bundleID()
    else
        capturedAppName = nil
        capturedAppBundleID = nil
    end
end

--------------------------------------------------------------------------------
-- Optional post-dictation action hooks (user config)
--------------------------------------------------------------------------------

local actionConfig = nil
local actionConfigMtime = 0

local function safeHookCall(label, fn, ctx)
    local ok, err = pcall(fn, ctx)
    if not ok then
        log("actions: " .. label .. " failed: " .. tostring(err))
    end
end

-- Auto-reload: check mtime and reload if file changed
local function loadActionConfig()
    local attr = hs.fs.attributes(ACTIONS_FILE)
    if not attr then
        actionConfig = nil
        actionConfigMtime = 0
        return nil
    end

    local mtime = attr.modification or 0
    if actionConfig and mtime == actionConfigMtime then
        return actionConfig
    end

    local chunk, err = loadfile(ACTIONS_FILE)
    if not chunk then
        log("actions: could not load config: " .. tostring(err))
        return nil
    end

    local ok, cfg = pcall(chunk)
    if not ok then
        log("actions: config execution failed: " .. tostring(cfg))
        return nil
    end
    if type(cfg) ~= "table" then
        log("actions: config must return a table")
        return nil
    end

    actionConfig = cfg
    actionConfigMtime = mtime
    log("actions: loaded " .. ACTIONS_FILE)
    return actionConfig
end

local function reloadActionConfig()
    actionConfigMtime = 0
    actionConfig = nil
    return loadActionConfig()
end

local function buildActionContext(text, lang, mode)
    local ctx = {
        text = text,
        textLower = text:lower(),
        originalText = text,
        lang = lang,
        outputMode = mode,
        appName = capturedAppName,
        appBundleID = capturedAppBundleID,
        insert = true,
        inserted = false,
        handled = false,
        timestamp = os.time(),
        isoTime = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    function ctx:setText(newText)
        if type(newText) ~= "string" then return end
        self.text = normalizeText(newText)
        self.textLower = self.text:lower()
    end

    function ctx:disableInsert()
        self.insert = false
    end

    function ctx:enableInsert()
        self.insert = true
    end

    function ctx:launchApp(appName)
        if type(appName) ~= "string" or appName == "" then return false end
        return hs.application.launchOrFocus(appName)
    end

    function ctx:appendToFile(path, line)
        local resolved = expandPath(path)
        if not resolved or resolved == "" then return false, "invalid path" end
        if not ensureParentDir(resolved) then return false, "mkdir failed" end
        local f = io.open(resolved, "a")
        if not f then return false, "open failed" end
        f:write(tostring(line or self.text or "") .. "\n")
        f:close()
        return true
    end

    function ctx:runShell(command, inputText)
        if type(command) ~= "string" or command == "" then
            return false, "", "invalid command", 1
        end
        local token = tostring(os.time()) .. "_" .. tostring(math.random(1000000))
        local stdinPath = WHISPER_TMP .. "/action_stdin_" .. token .. ".txt"
        writeFile(stdinPath, tostring(inputText or self.text or ""))
        local output, ok, kind, rc = hs.execute(command .. " < " .. shellQuote(stdinPath), true)
        os.remove(stdinPath)
        return ok, output, kind, rc
    end

    function ctx:keystroke(mods, key)
        hs.eventtap.keyStroke(mods or {}, key)
    end

    function ctx:notify(message)
        hs.notify.new({ title = "local-whisper", informativeText = tostring(message) }):send()
    end

    function ctx:log(message)
        log("action: " .. tostring(message))
    end

    return ctx
end

local function runActionList(actions, ctx)
    if type(actions) ~= "table" then return end
    for i, action in ipairs(actions) do
        if ctx.handled then break end
        if type(action) == "function" then
            safeHookCall("actions[" .. i .. "]", action, ctx)
        elseif type(action) == "table" and type(action.run) == "function" then
            local name = action.name or ("actions[" .. i .. "]")
            local shouldRun = true
            if type(action.when) == "function" then
                local ok, res = pcall(action.when, ctx)
                if not ok then
                    shouldRun = false
                    log("actions: " .. name .. ".when failed: " .. tostring(res))
                else
                    shouldRun = not not res
                end
            elseif type(action.pattern) == "string" then
                shouldRun = ctx.textLower:match(action.pattern) ~= nil
            end
            if shouldRun then
                safeHookCall(name, action.run, ctx)
            end
        end
    end
end

local function runPreInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.beforeInsert) == "function" then
        safeHookCall("beforeInsert", cfg.beforeInsert, ctx)
    end
    if not ctx.handled then
        runActionList(cfg.actions, ctx)
    end
end

local function runPostInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.afterInsert) == "function" then
        safeHookCall("afterInsert", cfg.afterInsert, ctx)
    end
end

-- Global reload function (used by hotkey and menu bar)
WhisperActions = WhisperActions or {}
function WhisperActions.reload()
    local cfg = reloadActionConfig()
    if cfg then
        hs.notify.new({ title = "local-whisper", informativeText = "Action hooks reloaded" }):send()
    else
        hs.notify.new({ title = "local-whisper", informativeText = "No action hook config found" }):send()
    end
end

--------------------------------------------------------------------------------
-- Overlay UI
--------------------------------------------------------------------------------

local overlay = nil
local startSpinner, stopSpinner  -- forward decls; assigned below. stopSpinner is
                   -- called by hideOverlay so every teardown path stops the
                   -- loading-spinner timer; startSpinner by the menu pick-preview.

-- Three selectable themes (cycle via menu bar). Colors are canvas {r,g,b,a}.
-- Note: hs.canvas can't do real backdrop blur, so the frosted look is
-- approximated with a semi-transparent solid fill.
local THEMES = {
    light = {  -- A · Frosted Light
        panelBg     = { red = 0.97, green = 0.97, blue = 0.98, alpha = 0.95 },
        panelPinBg  = { red = 1,    green = 1,    blue = 1,    alpha = 0.98 },
        panelStroke = { red = 1,    green = 1,    blue = 1,    alpha = 0.60 },
        text        = { red = 0.11, green = 0.12, blue = 0.15, alpha = 1 },
        chipBg      = { red = 0,    green = 0,    blue = 0,    alpha = 0.06 },
        chipText    = { red = 0.29, green = 0.33, blue = 0.39, alpha = 1 },
        accentBg    = { red = 0.15, green = 0.39, blue = 0.92, alpha = 1 },
        accentText  = { red = 1,    green = 1,    blue = 1,    alpha = 1 },
        offBg       = { red = 0,    green = 0,    blue = 0,    alpha = 0.04 },
        offText     = { red = 0.60, green = 0.62, blue = 0.66, alpha = 1 },
        close       = { red = 0.11, green = 0.12, blue = 0.15, alpha = 0.75 },
    },
    paper = {  -- B · Warm Paper
        panelBg     = { red = 0.99, green = 0.97, blue = 0.94, alpha = 0.96 },
        panelPinBg  = { red = 1,    green = 0.99, blue = 0.96, alpha = 0.99 },
        panelStroke = { red = 1,    green = 1,    blue = 1,    alpha = 0.70 },
        text        = { red = 0.16, green = 0.15, blue = 0.14, alpha = 1 },
        chipBg      = { red = 0.47, green = 0.35, blue = 0.24, alpha = 0.10 },
        chipText    = { red = 0.47, green = 0.44, blue = 0.40, alpha = 1 },
        accentBg    = { red = 0.92, green = 0.45, blue = 0.09, alpha = 1 },
        accentText  = { red = 1,    green = 1,    blue = 1,    alpha = 1 },
        offBg       = { red = 0.47, green = 0.35, blue = 0.24, alpha = 0.06 },
        offText     = { red = 0.71, green = 0.67, blue = 0.62, alpha = 1 },
        close       = { red = 0.34, green = 0.33, blue = 0.30, alpha = 1 },
    },
    dark = {   -- C · Soft Dark
        panelBg     = { red = 0.15, green = 0.16, blue = 0.20, alpha = 0.90 },
        panelPinBg  = { red = 0.17, green = 0.18, blue = 0.24, alpha = 0.95 },
        panelStroke = { red = 1,    green = 1,    blue = 1,    alpha = 0.08 },
        text        = { red = 0.95, green = 0.96, blue = 0.98, alpha = 1 },
        chipBg      = { red = 1,    green = 1,    blue = 1,    alpha = 0.10 },
        chipText    = { red = 0.80, green = 0.83, blue = 0.88, alpha = 1 },
        accentBg    = { red = 0.22, green = 0.74, blue = 0.97, alpha = 1 },
        accentText  = { red = 0.03, green = 0.14, blue = 0.23, alpha = 1 },
        offBg       = { red = 1,    green = 1,    blue = 1,    alpha = 0.05 },
        offText     = { red = 0.42, green = 0.45, blue = 0.50, alpha = 1 },
        close       = { red = 0.80, green = 0.83, blue = 0.88, alpha = 1 },
    },
}
local TH = THEMES.light  -- active palette; reassigned in createOverlay()

-- Element indices (order matches createOverlay's appendElements calls):
-- 1=panel bg; 2/3=lang chip bg/txt; 4/5=output; 6/7=enter; 8/9=model;
-- 10/11=refine; 12-16=level meter bars; 17=timer; 18=transcript text;
-- 19=close; 20+=loading-spinner elements (count varies by style — see
-- createOverlay; tracked at runtime via anim.spinFirst/spinCount).
local EL = {
    langTxt = 3, outputTxt = 5,
    enterBg = 6, enterTxt = 7,
    modelTxt = 9, refineBg = 10, refineTxt = 11,
    meter = 12,  -- first of 5 bars (12..16); access as EL.meter + i
    timer = 17, text = 18, close = 19,
}
-- Level-meter geometry, in one table. (Lua caps a function at 200 locals; the
-- init.lua main chunk is near that, so meter/spinner config + state are grouped
-- into tables — METER here, `anim` below — rather than many separate locals.)
local METER = { bars = 5, x = 344, w = 4, gap = 3, base = 27, min = 3, max = 16 }
-- Audio level meter + loading spinner runtime state, in one table. Declared here
-- (before createOverlay, which references it) so it's an in-scope local, not a
-- nil global. phase = meter wave; level = 0..1 mic envelope from checkSilence;
-- spin* = loading-spinner element range/style/center/timer.
local anim = { meterTimer = nil, phase = 0, level = 0, spinTimer = nil, spinAngle = 0 }

local function refreshOverlayLabels()
    if not overlay then return end
    -- Neutral chips just show their current value
    overlay[EL.langTxt].text   = getLang():upper()
    overlay[EL.outputTxt].text = getOutputMode():upper()
    overlay[EL.modelTxt].text  = getModelName()
    -- Toggle chips fill with accent when ON, go ghost when OFF
    local enterOn = getEnterMode()
    overlay[EL.enterBg].fillColor  = enterOn and TH.accentBg or TH.offBg
    overlay[EL.enterTxt].textColor = enterOn and TH.accentText or TH.offText
    local refineOn = getRefineMode() and hasOllama()
    overlay[EL.refineBg].fillColor  = refineOn and TH.accentBg or TH.offBg
    overlay[EL.refineTxt].textColor = refineOn and TH.accentText or TH.offText
end

local function createOverlay()
    TH = THEMES[getTheme()] or THEMES.light
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()
    -- Minimal mode (preview off) is a compact single-row panel — the meter and
    -- spinner share the top-right slot and there's no transcript area. Verbose
    -- mode (preview on) is taller to fit the live transcript / result text.
    local verbose = getPreview()
    local width, height = 460, verbose and 92 or 40
    local padding = 20
    local x = frame.x + (frame.w - width) / 2           -- bottom-CENTER of screen
    local y = frame.y + frame.h - height - padding      -- just above the dock

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- 1: Panel background (click empty area to pin overlay open)
    overlay:appendElements({
        id = "bg",
        type = "rectangle", action = "strokeAndFill",
        roundedRectRadii = { xRadius = 16, yRadius = 16 },
        fillColor = TH.panelBg,
        strokeColor = TH.panelStroke, strokeWidth = 1,
        trackMouseUp = true,
    })

    -- Chips: each is a clickable rounded rect with a centered label on top.
    -- Neutral chips (lang/output/model) show a value; toggle chips
    -- (enter/refine) fill with the accent color when ON, ghost when OFF.
    local cx = 13
    local function chip(id, w, txt, isToggle, isOn)
        local bgColor, txtColor
        if isToggle then
            bgColor  = isOn and TH.accentBg or TH.offBg
            txtColor = isOn and TH.accentText or TH.offText
        else
            bgColor, txtColor = TH.chipBg, TH.chipText
        end
        overlay:appendElements({
            id = id, type = "rectangle", action = "fill",
            roundedRectRadii = { xRadius = 9, yRadius = 9 },
            fillColor = bgColor,
            frame = { x = cx, y = 9, w = w, h = 20 },
            trackMouseUp = true,
        })
        overlay:appendElements({
            id = id .. "Txt", type = "text", text = txt,
            textColor = txtColor, textSize = 11, textAlignment = "center",
            frame = { x = cx, y = 13, w = w, h = 15 },
        })
        cx = cx + w + 6
    end

    chip("lang",   46, getLang():upper(),       false)         -- 2/3
    chip("output", 60, getOutputMode():upper(), false)         -- 4/5
    chip("enter",  32, "⏎",                     true, getEnterMode())  -- 6/7
    chip("model",  92, getModelName(),          false)         -- 8/9
    chip("refine", 64, "refine", true, getRefineMode() and hasOllama())  -- 10/11

    -- 12–16: Audio level meter (5 bars; replaces the old single dot). Bar height
    -- tracks real mic input, so a dead/silent input device reads as flat bars.
    -- Red reads as "recording" on every theme. Animated by startRecordingIndicator.
    for i = 0, METER.bars - 1 do
        overlay:appendElements({
            id = "meter" .. i, type = "rectangle", action = "fill",
            roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
            fillColor = { red = 1, green = 0.3, blue = 0.3, alpha = 0.0 },
            frame = { x = METER.x + i * (METER.w + METER.gap), y = METER.base - METER.min, w = METER.w, h = METER.min },
        })
    end
    -- 17: Elapsed time
    overlay:appendElements({
        id = "timer", type = "text", text = "",
        textColor = { red = 0.9, green = 0.3, blue = 0.3, alpha = 0.0 },
        textSize = 10, textAlignment = "right",
        frame = { x = 384, y = 11, w = 42, h = 16 },
    })
    -- 18: Transcript text (only "Listening..." in verbose/preview mode; minimal
    -- mode leaves it empty — the meter and spinner carry the state visually)
    overlay:appendElements({
        id = "text", type = "text", text = getPreview() and "Listening..." or "",
        textColor = TH.text, textSize = 14,
        frame = { x = 13, y = 40, w = 434, h = 44 },
    })
    -- 19: Close button (X) — renders above the panel/chips so it stays clickable
    overlay:appendElements({
        id = "close", type = "text", text = "✕",
        textColor = TH.close, textSize = 15, textAlignment = "center",
        frame = { x = 434, y = 9, w = 16, h = 18 },
        trackMouseDown = true, trackMouseUp = true,
    })
    -- Loading spinner — built in the chosen style, in the SAME top-right slot as
    -- the meter bars (the meter is hidden by then). Elements are appended after
    -- the close button, hidden (alpha 0) until startSpinner runs; not clickable.
    -- Color matches the meter bars (red) so recording → transcribing is seamless.
    local spinnerCx = METER.x + ((METER.bars - 1) * (METER.w + METER.gap) + METER.w) / 2
    local spinnerCy = METER.base - 9
    local hidden = { red = 1, green = 0.3, blue = 0.3, alpha = 0.0 }
    anim.spinStyle, anim.spinCx, anim.spinCy = getSpinner(), spinnerCx, spinnerCy
    anim.spinFirst = #overlay + 1
    if anim.spinStyle == "bounce" then
        for i = 0, 2 do
            overlay:appendElements({ id = "sp" .. i, type = "oval", action = "fill",
                fillColor = hidden, frame = { x = spinnerCx - 9 + i * 7, y = spinnerCy - 2, w = 4, h = 4 } })
        end
        anim.spinCount = 3
    elseif anim.spinStyle == "orbit" then
        for i = 0, 7 do
            local a = i * math.pi / 4
            overlay:appendElements({ id = "sp" .. i, type = "oval", action = "fill",
                fillColor = hidden,
                frame = { x = spinnerCx + 6 * math.cos(a) - 1.6, y = spinnerCy + 6 * math.sin(a) - 1.6, w = 3.2, h = 3.2 } })
        end
        anim.spinCount = 8
    elseif anim.spinStyle == "pulse" then
        for i = 0, 1 do
            overlay:appendElements({ id = "sp" .. i, type = "circle", action = "stroke",
                strokeColor = hidden, strokeWidth = 2,
                center = { x = spinnerCx, y = spinnerCy }, radius = 3 })
        end
        anim.spinCount = 2
    else  -- comet: faint full-ring track + a bright rotating arc on top
        overlay:appendElements({ id = "sp0", type = "circle", action = "stroke",
            strokeColor = hidden, strokeWidth = 2.5, center = { x = spinnerCx, y = spinnerCy }, radius = 8 })
        overlay:appendElements({ id = "sp1", type = "arc", action = "stroke",
            strokeColor = hidden, strokeWidth = 2.5,
            center = { x = spinnerCx, y = spinnerCy }, radius = 8, startAngle = 0, endAngle = 250 })
        anim.spinCount = 2
    end

    overlay:level(hs.canvas.windowLevels.floating)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- Mouse: click a chip to cycle that setting, click empty panel to pin/unpin,
    -- click ✕ to close. No hover styling — the chip fill shows state directly.
    overlay:canvasMouseEvents(true, true, false, false)  -- mouseDown + mouseUp
    overlay:mouseCallback(function(canvas, event, id, mx, my)
        -- Close button — hide immediately, delete deferred
        if id == "close" then
            if event == "mouseDown" then
                log("overlay: X close → cancel")
                canvas:hide()
                -- Defer: a canvas can't be deleted from inside its own mouse callback
                hs.timer.doAfter(0.01, cancelDictation)
            end
            return
        end

        if event ~= "mouseUp" then return end

        if id == "bg" then
            overlayPinned = not overlayPinned
            canvas[1].fillColor = overlayPinned and TH.panelPinBg or TH.panelBg
            log(overlayPinned and "overlay pinned" or "overlay unpinned")
            if not overlayPinned and not isRecording then hideOverlay() end
            return
        end

        if id == "lang" then cycleLang()
        elseif id == "output" then cycleOutput()
        elseif id == "enter" then cycleEnter()
        elseif id == "model" then cycleModel()
        elseif id == "refine" then cycleRefine()
        end
        refreshOverlayLabels()
    end)
end

local function showOverlay()
    overlayPinned = false
    if overlay then overlay:delete() end
    createOverlay()
    overlay:show()
end

local function hideOverlay()
    if overlayPinned then return end  -- pinned overlay stays open
    if stopSpinner then stopSpinner() end
    if overlay then overlay:delete(); overlay = nil end
end

local function forceHideOverlay()
    overlayPinned = false
    if stopSpinner then stopSpinner() end
    if overlay then overlay:delete(); overlay = nil end
end

local function setOverlayText(text)
    if overlay then overlay[EL.text].text = text end
end

local function setOverlayStatus()
    refreshOverlayLabels()
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local isRecording = false
local dictationCancelled = false  -- set by cancelDictation(); blocks any pending insert
local overlayPinned = false
local ffmpegTask = nil
local partialTimer = nil
local partialBusy = false
local lastChunkCount = 0

-- Menu bar
local menuBar = nil

-- Recording indicator state
local clockTimer = nil
local recordingStartTime = 0

-- Undo state
local lastInsertedText = nil

-- Recent dictations (newest first, max 10)
local MAX_RECENT = 10

local recentDictations = {}

local function loadRecentDictations()
    local f = io.open(RECENT_FILE, "r")
    if not f then return end
    local data = f:read("*a"); f:close()
    local ok, result = pcall(hs.json.decode, data)
    if ok and type(result) == "table" then
        -- Clear and populate in-place (preserve table reference)
        for i = #recentDictations, 1, -1 do recentDictations[i] = nil end
        for i, entry in ipairs(result) do recentDictations[i] = entry end
    end
end

local function saveRecentDictations()
    local ok, json = pcall(hs.json.encode, recentDictations)
    if not ok then return end
    local f = io.open(RECENT_FILE, "w")
    if f then f:write(json); f:close() end
end

loadRecentDictations()

--------------------------------------------------------------------------------
-- Dictation stats (counting, persistence, dashboard webview)
-- All module state/functions live on this single table. It is a GLOBAL (not a
-- `local`) on purpose: the init.lua main chunk is already at Lua's hard limit of
-- 200 locals, so adding even one more top-level `local` tips the whole reload
-- over (MAXVARS) — same convention as the existing `WhisperActions` / `_whisper`
-- globals. Assigned before buildMenuBarMenu / finishInsertion / stopRecording so
-- those functions can reference it (Lua local scope starts after the declaration
-- line — see AGENTS.md).
--------------------------------------------------------------------------------
stats = {
    file = CONFIG_DIR .. "/stats.json",
    data = { since = nil, days = {} },   -- in-memory copy; mutated in place
    lastRecordingSeconds = 0,            -- stashed by stopRecording for the next record
    webview = nil,                       -- retained so it survives GC
}

-- Count words from a string using the hybrid CJK rule:
--   zh = number of CJK codepoints (ideographs + kana)
--   en = number of maximal runs of ASCII word chars (%w)
--   words = zh + en
-- Returns a table { words, zh, en }.
function stats.count(text)
    text = text or ""
    local zh = 0
    -- CJK by codepoint range via utf8.codes. Ranges:
    --   0x4E00-0x9FFF  CJK Unified Ideographs
    --   0x3400-0x4DBF  CJK Extension A
    --   0x3040-0x30FF  Hiragana + Katakana (common kana)
    local ok = pcall(function()
        for _, cp in utf8.codes(text) do
            if (cp >= 0x4E00 and cp <= 0x9FFF)
                or (cp >= 0x3400 and cp <= 0x4DBF)
                or (cp >= 0x3040 and cp <= 0x30FF) then
                zh = zh + 1
            end
        end
    end)
    if not ok then zh = 0 end  -- malformed UTF-8: don't crash, just skip CJK

    -- en = runs of ASCII letters/digits. CJK chars are multi-byte and their
    -- continuation bytes are >= 0x80, so %w (ASCII word chars) never matches
    -- inside them — Latin/number runs are counted cleanly.
    local en = 0
    for _ in text:gmatch("%w+") do
        en = en + 1
    end

    return { words = zh + en, zh = zh, en = en }
end

-- Load stats.json into stats.data (in place). On any failure, start fresh.
function stats.load()
    local f = io.open(stats.file, "r")
    if not f then return end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return end
    local ok, result = pcall(hs.json.decode, raw)
    if ok and type(result) == "table" and type(result.days) == "table" then
        stats.data.since = result.since
        -- repopulate days in place (preserve the table reference)
        for k in pairs(stats.data.days) do stats.data.days[k] = nil end
        for k, v in pairs(result.days) do stats.data.days[k] = v end
    else
        log("stats: decode failed, starting fresh")
    end
end

-- Atomic write: encode to a temp file in the same dir, then os.rename over the
-- real file (rename within a filesystem is atomic — a crash mid-write can never
-- leave a truncated stats.json).
function stats.save()
    local ok, json = pcall(hs.json.encode, stats.data)
    if not ok then log("stats: encode failed"); return end
    local tmp = stats.file .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then log("stats: cannot open temp file"); return end
    f:write(json); f:close()
    local renamed, err = os.rename(tmp, stats.file)
    if not renamed then log("stats: rename failed: " .. tostring(err)) end
end

-- Record one completed dictation into today's bucket and persist.
function stats.record(text, seconds)
    local c = stats.count(text)
    if c.words == 0 and (seconds or 0) <= 0 then return end  -- nothing to record
    local day = os.date("%Y-%m-%d")
    if not stats.data.since then stats.data.since = day end
    local b = stats.data.days[day]
    if not b then
        b = { words = 0, zh = 0, en = 0, seconds = 0, count = 0 }
        stats.data.days[day] = b
    end
    b.words = b.words + c.words
    b.zh = b.zh + c.zh
    b.en = b.en + c.en
    b.seconds = b.seconds + math.floor(seconds or 0)
    b.count = b.count + 1
    stats.save()
    log(string.format("stats: +%d words (%dzh/%den) %.0fs on %s", c.words, c.zh, c.en, seconds or 0, day))
end

-- Sum all day buckets into all-time totals + derived metrics.
-- Returns { words, zh, en, seconds, count, activeDays, avg, best={words,date}, since }.
function stats.allTime()
    local t = { words = 0, zh = 0, en = 0, seconds = 0, count = 0, activeDays = 0,
                avg = 0, best = { words = 0, date = nil }, since = stats.data.since }
    for date, b in pairs(stats.data.days) do
        t.words = t.words + (b.words or 0)
        t.zh = t.zh + (b.zh or 0)
        t.en = t.en + (b.en or 0)
        t.seconds = t.seconds + (b.seconds or 0)
        t.count = t.count + (b.count or 0)
        t.activeDays = t.activeDays + 1
        if (b.words or 0) > t.best.words then
            t.best.words = b.words or 0
            t.best.date = date
        end
    end
    if t.activeDays > 0 then t.avg = math.floor(t.words / t.activeDays) end
    return t
end

-- Today's bucket (or a zeroed one if none yet).
function stats.today()
    return stats.data.days[os.date("%Y-%m-%d")]
        or { words = 0, zh = 0, en = 0, seconds = 0, count = 0 }
end

-- Format a thousands-separated integer, e.g. 186540 -> "186,540".
function stats.fmtNum(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Format seconds as a compact duration: <1h -> "14:32" (mm:ss), >=1h -> "19h 47m".
function stats.fmtTime(sec)
    sec = math.floor(sec or 0)
    if sec >= 3600 then
        return string.format("%dh %dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
    end
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Words recorded on a given "YYYY-MM-DD" (0 if no bucket).
function stats.wordsOn(dateStr)
    local b = stats.data.days[dateStr]
    return b and (b.words or 0) or 0
end

-- Format a "YYYY-MM-DD" string as "Mon DD" (e.g. "Jun 19"). Returns "" for nil.
function stats.fmtDate(dateStr)
    if not dateStr then return "" end
    local y, m, d = dateStr:match("(%d+)-(%d+)-(%d+)")
    if not y then return dateStr end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    return os.date("%b %-d", t)
end

-- Minimal HTML escaping for any text injected into the page.
function stats.esc(s)
    return (tostring(s or ""):gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

-- Build the dashboard HTML with real numbers injected. Static snapshot.
function stats.html()
    local today = stats.today()
    local all = stats.allTime()
    local fnum, ftime, fdate = stats.fmtNum, stats.fmtTime, stats.fmtDate

    -- now (noon today) as the anchor for both charts, walking back by whole days
    local nowParts = os.date("*t")
    local todayKey = os.date("%Y-%m-%d")
    local function dayKey(offsetDays)
        local t = os.time({ year = nowParts.year, month = nowParts.month,
                            day = nowParts.day - offsetDays, hour = 12 })
        return os.date("%Y-%m-%d", t), os.date("*t", t)
    end

    -- 14-day bar chart (oldest -> today). Heights relative to the window max.
    local WDAY = { "S", "M", "T", "W", "T", "F", "S" }  -- os.date wday: 1=Sun..7=Sat
    local barMax = 1
    local barDays = {}
    for i = 13, 0, -1 do
        local key, t = dayKey(i)
        local w = stats.wordsOn(key)
        if w > barMax then barMax = w end
        barDays[#barDays + 1] = { key = key, words = w, wday = t.wday }
    end
    local barsHTML = {}
    for _, dd in ipairs(barDays) do
        local pct = math.floor((dd.words / barMax) * 100 + 0.5)
        if dd.words > 0 and pct < 4 then pct = 4 end  -- keep tiny days visible
        local isToday = (dd.key == todayKey)
        barsHTML[#barsHTML + 1] = string.format(
            '<div class="col%s"><div class="bar" style="height:%d%%"></div><div class="d mono">%s</div></div>',
            isToday and " today" or "", pct, WDAY[dd.wday])
    end

    -- Activity heatmap: 17 columns (weeks) x 7 rows (Sun..Sat). The last column
    -- ends on today; future cells in the current week stay empty. Intensity is
    -- 5 buckets relative to the busiest day in the window.
    local WEEKS = 17
    -- offset of today from the start of its week (Sun=0..Sat=6)
    local todayWdayIdx = nowParts.wday - 1
    local heatMax = 1
    local heatCells = {}  -- [col][row] = { words, future }
    for col = 0, WEEKS - 1 do
        heatCells[col] = {}
        for row = 0, 6 do
            -- days back from today: full weeks to the right + within-week offset
            local back = (WEEKS - 1 - col) * 7 + (todayWdayIdx - row)
            if back < 0 then
                heatCells[col][row] = { words = 0, future = true }
            else
                local key = dayKey(back)
                local w = stats.wordsOn(key)
                if w > heatMax then heatMax = w end
                heatCells[col][row] = { words = w, future = false }
            end
        end
    end
    local function heatLevel(w)
        if w <= 0 then return 0 end
        local r = w / heatMax
        if r < 0.25 then return 1 elseif r < 0.50 then return 2
        elseif r < 0.80 then return 3 else return 4 end
    end
    local heatHTML = {}
    for col = 0, WEEKS - 1 do
        local cells = {}
        for row = 0, 6 do
            local c = heatCells[col][row]
            if c.future then
                cells[#cells + 1] = '<div class="cell"></div>'
            else
                local lvl = heatLevel(c.words)
                cells[#cells + 1] = string.format('<div class="cell%s"></div>',
                    lvl > 0 and (" l" .. lvl) or "")
            end
        end
        heatHTML[#heatHTML + 1] = '<div class="week">' .. table.concat(cells) .. '</div>'
    end
    -- month labels across the heatmap span
    local startKey = dayKey((WEEKS - 1) * 7 + todayWdayIdx)
    local sy, sm = startKey:match("(%d+)-(%d+)")
    local months = {}
    local seen = {}
    for i = 0, 3 do
        local mt = os.time({ year = tonumber(sy), month = tonumber(sm) + i, day = 1, hour = 12 })
        local lbl = os.date("%b", mt)
        if not seen[lbl] then seen[lbl] = true; months[#months + 1] = "<span>" .. lbl .. "</span>" end
    end

    -- empty state hint
    local emptyNote = ""
    if all.count == 0 then
        emptyNote = '<p class="note" style="color:var(--accent)">No dictations recorded yet — start dictating and they\'ll show up here.</p>'
    end

    local bestLabel = all.best.date and ("best day · " .. fdate(all.best.date)) or "best day"
    local sinceLabel = all.since and ("tracking since " .. fdate(all.since)) or "tracking since —"

    return string.format([[<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Dictation stats</title>
<style>
  :root{
    --ground:#0f1115;--panel:#181b22;--panel-2:#1f232c;--line:#282d38;
    --text:#e8eaef;--muted:#878d9b;--accent:#ff5a52;--accent-dim:#7a302e;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--panel);font-family:system-ui,-apple-system,"PingFang SC","Segoe UI",sans-serif;
    -webkit-font-smoothing:antialiased;color:var(--text)}
  .mono{font-family:ui-monospace,"SF Mono",Menlo,monospace}
  .body{padding:20px 22px 22px}
  .eyebrow{font-size:10.5px;letter-spacing:.2em;text-transform:uppercase;color:var(--muted)}
  .split{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:20px}
  .block{background:var(--panel-2);border:1px solid var(--line);border-radius:13px;padding:15px 16px 16px}
  .block.today{border-color:var(--accent-dim)}
  .block .hd{display:flex;align-items:center;justify-content:space-between;margin-bottom:9px}
  .block.today .eyebrow{color:var(--accent)}
  .pill{font-size:10px;color:var(--accent);border:1px solid var(--accent-dim);border-radius:99px;padding:1px 7px}
  .big{font-size:36px;line-height:1;font-weight:600;letter-spacing:-.02em}
  .big .u{font-size:13px;color:var(--muted);font-weight:500;margin-left:5px;letter-spacing:0}
  .block.today .big{color:var(--accent)}
  .brk{font-size:11px;color:var(--muted);margin-top:7px}
  .brk .sep{opacity:.45;margin:0 5px}
  .subs{display:flex;gap:18px;margin-top:13px}
  .sub .n{font-size:15px;font-weight:600}
  .sub .l{font-size:10.5px;color:var(--muted);margin-top:1px}
  .chart{display:flex;align-items:flex-end;gap:6px;height:96px;padding-top:6px}
  .col{flex:1;display:flex;flex-direction:column;align-items:center;gap:6px;height:100%%;justify-content:flex-end}
  .bar{width:100%%;max-width:15px;border-radius:3px 3px 2px 2px;background:var(--accent-dim);min-height:2px}
  .col.today .bar{background:var(--accent)}
  .col .d{font-size:9px;color:var(--muted)}
  .col.today .d{color:var(--accent)}
  .heatwrap{margin-top:6px}
  .hint{font-size:10px;color:var(--muted);margin-bottom:9px}
  .months{display:flex;gap:32px;font-size:9px;color:var(--muted);margin:0 0 5px 20px;font-family:ui-monospace,Menlo,monospace}
  .heatrow{display:flex;gap:6px;align-items:flex-start}
  .wdays{display:flex;flex-direction:column;justify-content:space-between;height:95px;font-size:8px;color:var(--muted);font-family:ui-monospace,Menlo,monospace}
  .heat{display:flex;gap:3px}
  .week{display:flex;flex-direction:column;gap:3px}
  .cell{width:11px;height:11px;border-radius:2px;background:#232730}
  .cell.l1{background:#5e2422}.cell.l2{background:#8f2f2b}.cell.l3{background:#cc433c}.cell.l4{background:#ff5a52}
  .heatlegend{display:flex;align-items:center;gap:4px;justify-content:flex-end;margin-top:9px;font-size:9px;color:var(--muted);font-family:ui-monospace,Menlo,monospace}
  .heatlegend i{width:11px;height:11px;border-radius:2px;display:inline-block}
  .tabs{display:flex;align-items:center;gap:5px;margin:6px 0 16px}
  .tab{font-family:ui-monospace,Menlo,monospace;font-size:11px;letter-spacing:.03em;color:var(--muted);background:none;border:1px solid transparent;border-radius:8px;padding:5px 12px;cursor:pointer}
  .tab:hover{color:var(--text)}
  .tab.active{color:var(--accent);background:rgba(255,90,82,.10);border-color:var(--accent-dim)}
  .tab-meta{margin-left:auto;font-size:10px;color:var(--muted);font-family:ui-monospace,Menlo,monospace}
  .pane.hidden{display:none}
  .foot{display:flex;gap:8px;margin-top:24px;flex-wrap:wrap}
  .stat{flex:1;min-width:120px;background:var(--panel-2);border:1px solid var(--line);border-radius:11px;padding:11px 13px}
  .stat .n{font-size:16px;font-weight:600}
  .stat .l{font-size:10.5px;color:var(--muted);margin-top:2px}
  .note{margin-top:16px;font-size:11px;color:var(--muted);text-align:center;line-height:1.5}
</style></head>
<body>
  <div class="body">
    <div class="split">
      <div class="block today">
        <div class="hd"><span class="eyebrow">Today</span><span class="pill mono">%s</span></div>
        <div class="big mono">%s<span class="u">words</span></div>
        <div class="brk mono">%s 中文<span class="sep">·</span>%s 英文词</div>
        <div class="subs">
          <div class="sub"><div class="n mono">%s</div><div class="l">time</div></div>
          <div class="sub"><div class="n mono">%s</div><div class="l">dictations</div></div>
        </div>
      </div>
      <div class="block">
        <div class="hd"><span class="eyebrow">All time</span></div>
        <div class="big mono">%s<span class="u">words</span></div>
        <div class="brk mono">%s 中文<span class="sep">·</span>%s 英文词</div>
        <div class="subs">
          <div class="sub"><div class="n mono">%s</div><div class="l">time</div></div>
          <div class="sub"><div class="n mono">%s</div><div class="l">dictations</div></div>
        </div>
      </div>
    </div>

    <div class="tabs">
      <button class="tab active" data-tab="bars">14 days</button>
      <button class="tab" data-tab="heat">Activity</button>
      <span class="tab-meta">words / day</span>
    </div>

    <div class="pane" id="pane-bars">
      <div class="chart">%s</div>
    </div>

    <div class="pane hidden" id="pane-heat">
      <div class="heatwrap">
        <div class="hint mono">last 17 weeks</div>
        <div class="months">%s</div>
        <div class="heatrow">
          <div class="wdays"><span>M</span><span>W</span><span>F</span></div>
          <div class="heat" id="heat">%s</div>
        </div>
        <div class="heatlegend">Less <i class="cell"></i><i class="cell l1"></i><i class="cell l2"></i><i class="cell l3"></i><i class="cell l4"></i> More</div>
      </div>
    </div>

    <div class="foot">
      <div class="stat"><div class="n mono">%s</div><div class="l">avg / active day</div></div>
      <div class="stat"><div class="n mono">%s</div><div class="l">%s</div></div>
      <div class="stat"><div class="n mono">%s days</div><div class="l">%s</div></div>
    </div>
    %s
    <p class="note">Counts text inserted at the cursor · cancelled dictations excluded · stored on this Mac only</p>
  </div>

  <script>
  (function(){
    var tabs = document.querySelectorAll('.tab');
    tabs.forEach(function(t){
      t.addEventListener('click', function(){
        tabs.forEach(function(x){ x.classList.remove('active'); });
        t.classList.add('active');
        document.getElementById('pane-bars').classList.toggle('hidden', t.dataset.tab !== 'bars');
        document.getElementById('pane-heat').classList.toggle('hidden', t.dataset.tab !== 'heat');
      });
    });
  })();
  </script>
</body></html>]],
        os.date("%b %-d"),
        fnum(today.words), fnum(today.zh), fnum(today.en), ftime(today.seconds), fnum(today.count),
        fnum(all.words), fnum(all.zh), fnum(all.en), ftime(all.seconds), fnum(all.count),
        table.concat(barsHTML),
        table.concat(months), table.concat(heatHTML),
        fnum(all.avg),
        fnum(all.best.words), stats.esc(bestLabel),
        fnum(all.activeDays), stats.esc(sinceLabel),
        emptyNote)
end

-- Open (or reopen) the stats dashboard window. Static snapshot at open time.
function stats.show()
    local ok = pcall(function()
        if stats.webview then stats.webview:delete(); stats.webview = nil end
        local screen = hs.screen.mainScreen():frame()
        local w, h = 600, 620
        local x = screen.x + (screen.w - w) / 2
        local y = screen.y + (screen.h - h) / 2
        stats.webview = hs.webview.new({ x = x, y = y, w = w, h = h })
        stats.webview:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
        stats.webview:level(hs.canvas.windowLevels.floating)
        stats.webview:windowTitle("Dictation stats")
        stats.webview:html(stats.html())
        stats.webview:show()
        stats.webview:bringToFront()
    end)
    if not ok then
        -- Webview unavailable: fall back to a glance notification.
        local t = stats.today()
        hs.notify.new({ title = "Dictation stats",
            informativeText = string.format("Today: %s 字词 · %s · %s dictations",
                stats.fmtNum(t.words), stats.fmtTime(t.seconds), stats.fmtNum(t.count)) }):send()
    end
end

stats.load()

-- Auto-stop state
local silentChunkCount = 0
local silenceTimer = nil
local lastCheckedChunk = 0

--------------------------------------------------------------------------------
-- Menu bar status icon
--------------------------------------------------------------------------------

local function makeWaveformIcon(color, asTemplate)
    local w, h = 18, 18
    local c = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
    -- Bar heights (symmetric waveform: short-medium-tall-medium-short)
    local bars = { 0.3, 0.55, 1.0, 0.55, 0.3 }
    local barW = 2
    local gap = 1.5
    local totalW = #bars * barW + (#bars - 1) * gap
    local startX = (w - totalW) / 2
    for i, scale in ipairs(bars) do
        local barH = math.floor(h * 0.75 * scale)
        local x = startX + (i - 1) * (barW + gap)
        local y = (h - barH) / 2
        c:appendElements({
            type = "rectangle",
            frame = { x = x, y = y, w = barW, h = barH },
            fillColor = color,
            roundedRectRadii = { xRadius = 1, yRadius = 1 },
            action = "fill",
        })
    end
    local img = c:imageFromCanvas()
    c:delete()
    img:template(asTemplate)
    return img
end

function updateMenuBar()
    if not menuBar then return end
    if isRecording then
        local icon = makeWaveformIcon({ red = 1, green = 0.15, blue = 0.15, alpha = 1 }, false)
        menuBar:setIcon(icon, false)
    else
        local icon = makeWaveformIcon({ red = 0, green = 0, blue = 0, alpha = 1 }, true)
        menuBar:setIcon(icon, true)
    end
end

-- Forward-declare meeting state and functions (defined in Meeting mode section below)
local meetingRecording = false
local meetingStartTime = nil
local startMeeting, stopMeeting

local function buildMenuBarMenu()
    local items = {}

    -- Current status
    table.insert(items, { title = isRecording and "● Recording..." or "Idle", disabled = true })

    -- Today's glance (non-clickable) — e.g. "Today: 2,418 字词"
    local todayStats = stats.today()
    table.insert(items, {
        title = "Today: " .. stats.fmtNum(todayStats.words) .. " 字词",
        disabled = true,
    })

    table.insert(items, { title = "-" })

    -- Language
    local langDisplay = getLang():upper()
    table.insert(items, {
        title = "Language: " .. langDisplay,
        fn = function() cycleLang(); updateMenuBar() end,
    })

    -- Model
    table.insert(items, {
        title = "Model: " .. getModelName(),
        fn = function() cycleModel(); updateMenuBar() end,
    })

    -- Output mode
    table.insert(items, {
        title = "Output: " .. getOutputMode():upper(),
        fn = function() cycleOutput(); updateMenuBar() end,
    })

    -- Enter mode
    local enterState = getEnterMode() and "ON" or "OFF"
    table.insert(items, {
        title = "Enter after insert: " .. enterState,
        fn = function() cycleEnter(); updateMenuBar() end,
    })

    -- Live preview while recording (rough tiny-model text; off by default)
    local previewState = getPreview() and "ON" or "OFF"
    table.insert(items, {
        title = "Live preview: " .. previewState,
        fn = function() setPreview(not getPreview()); updateMenuBar() end,
    })

    -- LLM refinement
    if hasOllama() then
        local refineState = getRefineMode() and "ON" or "OFF"
        table.insert(items, {
            title = "LLM Refine: " .. refineState .. " (" .. getRefineModel() .. ")",
            fn = function() cycleRefine(); updateMenuBar() end,
        })
    else
        table.insert(items, {
            title = "LLM Refine (install ollama.com)",
            disabled = true,
        })
    end

    -- Preferred langs
    local preferred = table.concat(getPreferredLangs(), ", ")
    table.insert(items, { title = "Preferred: " .. preferred, disabled = true })

    table.insert(items, { title = "-" })

    -- Meeting mode
    if meetingRecording then
        local elapsed = hs.timer.secondsSinceEpoch() - (meetingStartTime or 0)
        local mins = math.floor(elapsed / 60)
        table.insert(items, {
            title = "⏹ Stop Meeting Notes (" .. mins .. "m)",
            fn = function() stopMeeting() end,
        })
    else
        table.insert(items, {
            title = "🎙 Start Meeting Notes",
            fn = function() startMeeting() end,
        })
    end

    table.insert(items, { title = "-" })

    -- Theme (cycles Frosted Light → Warm Paper → Soft Dark)
    local themeNames = { light = "Frosted Light", paper = "Warm Paper", dark = "Soft Dark" }
    table.insert(items, {
        title = "Theme: " .. (themeNames[getTheme()] or getTheme()),
        fn = function()
            cycleTheme()
            updateMenuBar()
            -- If the overlay is on screen, recreate it so the new theme shows live
            if overlay then
                local wasPinned = overlayPinned
                forceHideOverlay()
                showOverlay()
                if wasPinned then
                    overlayPinned = true
                    overlay[1].fillColor = THEMES[getTheme()].panelPinBg
                    setOverlayText("Theme: " .. (themeNames[getTheme()] or getTheme()))
                end
            end
        end,
    })

    -- Completion sound (submenu: pick a system sound or Off; picking previews it)
    local currentSound = getSound()
    local soundItems = {}
    for _, name in ipairs(SOUND_CHOICES) do
        table.insert(soundItems, {
            title = name,
            checked = (currentSound == name),
            fn = function() setSound(name); playDoneSound(); updateMenuBar() end,
        })
    end
    table.insert(soundItems, { title = "-" })
    table.insert(soundItems, {
        title = "Off",
        checked = (currentSound == "off"),
        fn = function() setSound("off"); updateMenuBar() end,
    })
    table.insert(items, {
        title = "Done sound: " .. (currentSound == "off" and "Off" or currentSound),
        menu = soundItems,
    })

    -- Loading icon (submenu: pick the transcription spinner style; previews it)
    local spinNames = { bounce = "Bouncing dots", comet = "Comet ring", orbit = "Orbit dots", pulse = "Pulse ring" }
    local currentSpin = getSpinner()
    local spinItems = {}
    for _, key in ipairs({ "bounce", "comet", "orbit", "pulse" }) do
        table.insert(spinItems, {
            title = spinNames[key],
            checked = (currentSpin == key),
            fn = function()
                writeFile(CONFIG_DIR .. "/spinner", key)
                updateMenuBar()
                -- Quick live preview (only when idle, so we don't disturb a dictation)
                if not isRecording then
                    forceHideOverlay(); showOverlay(); startSpinner()
                    hs.timer.doAfter(1.4, forceHideOverlay)
                end
            end,
        })
    end
    table.insert(items, {
        title = "Loading icon: " .. (spinNames[currentSpin] or currentSpin),
        menu = spinItems,
    })

    -- Settings overlay
    table.insert(items, {
        title = "Settings...",
        fn = function()
            if overlay then
                forceHideOverlay()
            else
                showOverlay()
                overlayPinned = true
                overlay[1].fillColor = THEMES[getTheme()].panelPinBg
                setOverlayText("Click labels to change settings")
            end
        end,
    })

    -- Stats dashboard
    table.insert(items, {
        title = "Stats…",
        fn = function() stats.show() end,
    })

    -- Recent dictations
    if #recentDictations > 0 then
        table.insert(items, { title = "-" })
        table.insert(items, { title = "Recent Dictations", disabled = true })
        for _, entry in ipairs(recentDictations) do
            local ago = os.time() - entry.time
            local timeStr
            if ago < 60 then timeStr = "just now"
            elseif ago < 3600 then timeStr = math.floor(ago / 60) .. "m ago"
            else timeStr = math.floor(ago / 3600) .. "h ago"
            end
            local preview = entry.text
            if #preview > 40 then preview = preview:sub(1, 37) .. "..." end
            local icon = entry.inserted and "⏎" or "⚡"
            table.insert(items, {
                title = icon .. " " .. preview .. "  " .. timeStr,
                fn = function()
                    hs.pasteboard.setContents(entry.text)
                    hs.eventtap.keyStroke({"cmd"}, "v")
                    hs.notify.new({ title = "Pasted", informativeText = entry.text }):send()
                end,
            })
        end
    end

    table.insert(items, { title = "-" })

    -- Reload actions
    table.insert(items, {
        title = "Reload Actions",
        fn = function() WhisperActions.reload() end,
    })

    -- Emergency stop
    table.insert(items, { title = "-" })
    table.insert(items, {
        title = "Emergency Stop",
        fn = function() emergencyStop() end,
    })

    return items
end

local function createMenuBar()
    -- Clean up previous instance on reload
    if menuBar then menuBar:delete(); menuBar = nil end
    menuBar = hs.menubar.new()
    if not menuBar then return end
    updateMenuBar()
    menuBar:setMenu(buildMenuBarMenu)
end

--------------------------------------------------------------------------------
-- Recording indicator (audio level meter + timer)
--------------------------------------------------------------------------------

local function startRecordingIndicator()
    if not overlay then return end
    recordingStartTime = hs.timer.secondsSinceEpoch()
    anim.phase = 0
    anim.level = 0

    -- Show meter bars and timer
    for i = 0, METER.bars - 1 do
        overlay[EL.meter + i].fillColor = { red = 1, green = 0.3, blue = 0.3, alpha = 1.0 }
    end
    overlay[EL.timer].textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 1.0 }

    -- Animate the bars: height = real measured level (anim.level, set by
    -- checkSilence) × a per-bar traveling wave. Flat when there's no input, so a
    -- dead mic reads as flat; bouncing when audio is coming in.
    anim.meterTimer = hs.timer.doEvery(0.07, function()
        if not overlay then return end
        for i = 0, METER.bars - 1 do
            local wob = 0.3 + 0.7 * (0.5 + 0.5 * math.sin(anim.phase + i * 1.1))
            local h = METER.min + (METER.max - METER.min) * anim.level * wob
            if h < METER.min then h = METER.min end
            overlay[EL.meter + i].frame = {
                x = METER.x + i * (METER.w + METER.gap),
                y = METER.base - h, w = METER.w, h = h,
            }
        end
        anim.phase = anim.phase + 0.55
    end)

    -- Update elapsed time every second
    clockTimer = hs.timer.doEvery(1, function()
        if not overlay then return end
        local elapsed = math.floor(hs.timer.secondsSinceEpoch() - recordingStartTime)
        local min = math.floor(elapsed / 60)
        local sec = elapsed % 60
        overlay[EL.timer].text = string.format("%d:%02d", min, sec)
    end)
end

local function stopRecordingIndicator()
    if anim.meterTimer then anim.meterTimer:stop(); anim.meterTimer = nil end
    if clockTimer then clockTimer:stop(); clockTimer = nil end
    anim.level = 0
    if overlay then
        for i = 0, METER.bars - 1 do
            overlay[EL.meter + i].fillColor = { red = 1, green = 0.3, blue = 0.3, alpha = 0.0 }
        end
        overlay[EL.timer].textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 0.0 }
        overlay[EL.timer].text = ""
    end
end

-- Loading spinner shown during transcription in minimal mode. Four styles
-- (~/.local-whisper/spinner): bounce (default) | comet | orbit | pulse.
-- createOverlay builds the chosen style's elements and records
-- anim.spinFirst/spinCount/spinStyle/spinCx/spinCy. start/stopSpinner are the
-- forward-declared locals so hideOverlay can always stop the timer, and the
-- menu pick-preview can start one. Color matches the meter bars (red).
startSpinner = function()
    if not overlay or anim.spinTimer or not anim.spinFirst then return end
    local function col(alpha) return { red = 1, green = 0.3, blue = 0.3, alpha = alpha } end
    local first, n, style = anim.spinFirst, anim.spinCount, anim.spinStyle
    local cx, cy = anim.spinCx, anim.spinCy
    local t = 0
    anim.spinTimer = hs.timer.doEvery(0.045, function()
        if not overlay then return end
        if style == "bounce" then
            for i = 0, n - 1 do
                local el = overlay[first + i]
                el.frame = { x = cx - 9 + i * 7, y = cy - 2 + 4.5 * math.sin(t * 0.22 + i * 0.9), w = 4, h = 4 }
                el.fillColor = col(0.9)
            end
        elseif style == "orbit" then
            for i = 0, n - 1 do
                local ph = ((t * 0.04) - i / n) % 1
                overlay[first + i].fillColor = col(0.2 + 0.8 * (1 - ph))
            end
        elseif style == "pulse" then
            for i = 0, n - 1 do
                local ph = ((t * 0.025) + i * 0.5) % 1
                local el = overlay[first + i]
                el.radius = 2 + 7 * ph
                el.strokeColor = col(0.85 * (1 - ph))
            end
        else  -- comet
            overlay[first].strokeColor = col(0.18)
            local a = (t * 9) % 360
            overlay[first + 1].startAngle = a
            overlay[first + 1].endAngle = a + 250
            overlay[first + 1].strokeColor = col(0.9)
        end
        t = t + 1
    end)
end

stopSpinner = function()
    if anim.spinTimer then anim.spinTimer:stop(); anim.spinTimer = nil end
    if overlay and anim.spinFirst then
        for i = 0, (anim.spinCount or 1) - 1 do
            local el = overlay[anim.spinFirst + i]
            if el then
                el.fillColor = { red = 0, green = 0, blue = 0, alpha = 0 }
                el.strokeColor = { red = 0, green = 0, blue = 0, alpha = 0 }
            end
        end
    end
end

-- Show an error, stop the spinner, then auto-hide. Verbose mode has a text area
-- so it shows inline; compact (minimal) mode has none, so use a notification.
local function showOverlayError(msg)
    stopSpinner()
    if getPreview() then
        setOverlayText(msg)
        hs.timer.doAfter(2, hideOverlay)
    else
        hs.notify.new({ title = "local-whisper", informativeText = msg }):send()
        hideOverlay()
    end
end

--------------------------------------------------------------------------------
-- Emergency stop (forward declaration)
--------------------------------------------------------------------------------

function emergencyStop()
    log("emergency stop")
    isRecording = false
    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    stopRecordingIndicator()
    if ffmpegTask and ffmpegTask:isRunning() then ffmpegTask:interrupt() end
    ffmpegTask = nil
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    forceHideOverlay()
    updateMenuBar()
    os.execute("killall whisper-cli 2>/dev/null")
    hs.notify.new({ title = "local-whisper", informativeText = "Stopped" }):send()
end

--------------------------------------------------------------------------------
-- Partial transcription (live preview while recording)
--------------------------------------------------------------------------------

local function doPartialTranscribe()
    if partialBusy or not isRecording then return end

    local chunks = getChunkFiles()
    local numChunks = #chunks
    if numChunks < 3 then return end

    local completed = numChunks - 1  -- skip last chunk (being written)
    if completed <= lastChunkCount then return end

    partialBusy = true

    -- Batch last 4 completed chunks
    local startIdx = math.max(1, completed - 3)
    local batchList = WHISPER_TMP .. "/partial_concat.txt"
    local f = io.open(batchList, "w")
    for i = startIdx, completed do
        f:write("file '" .. chunks[i] .. "'\n")
    end
    f:close()

    local batchWav = WHISPER_TMP .. "/partial_batch.wav"
    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            partialBusy = false
            return
        end
        local lang = getLang()
        -- In auto mode, use first preferred lang for speed during partial transcription
        if lang == "auto" then lang = getPreferredLangs()[1] end
        local whisperArgs = { "-m", getPartialModelPath(), "-f", batchWav, "-l", lang, "-nt", "--no-prints" }
        local promptArgs = getPromptArgs()
        for _, a in ipairs(promptArgs) do table.insert(whisperArgs, a) end
        local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
            partialBusy = false
            lastChunkCount = completed
            if code2 ~= 0 or not isRecording then return end
            local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            if text ~= "" and not isHallucination(text) then
                local display = text
                if #display > 200 then display = "..." .. display:sub(-197) end
                setOverlayText(display)
                log("partial: " .. text)
            end
        end, whisperArgs)
        whisperTask:start()
    end, { "-y", "-f", "concat", "-safe", "0", "-i", batchList, "-c", "copy", batchWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Final transcription
--------------------------------------------------------------------------------

-- Low-level text insertion at cursor
local function insertTextAtCursor(text, mode)
    if mode == "paste" then
        local oldClipboard = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)
        hs.eventtap.keyStroke({"cmd"}, "v")
        hs.timer.doAfter(0.3, function()
            if oldClipboard then hs.pasteboard.setContents(oldClipboard) end
        end)
    else
        hs.eventtap.keyStrokes(text)
    end
end

-- Finish insertion after all processing (post-process, refine, hooks)
local function finishInsertion(text, detectedLang)
    if dictationCancelled then return end
    -- Build action context and run pre-insert hooks
    local ctx = buildActionContext(normalizeText(text), detectedLang or getLang(), getOutputMode())
    runPreInsertActions(ctx)

    local finalText = normalizeText(ctx.text)
    if finalText == "" then
        log("final: empty text after actions")
        hideOverlay()
        return
    end

    if ctx.insert then
        -- Track for undo
        lastInsertedText = finalText
        insertTextAtCursor(finalText, ctx.outputMode)
        ctx.inserted = true

        -- Press Enter after insertion if enter mode is on
        if getEnterMode() then
            hs.timer.doAfter(0.15, function()
                hs.eventtap.keyStroke({}, "return")
            end)
        end
    else
        log("final: insertion disabled by action hooks")
    end

    ctx.text = finalText
    runPostInsertActions(ctx)

    -- Record stats only when text was actually inserted at the cursor.
    -- Cancelled / empty / action-only dictations record nothing.
    -- (The menu is rebuilt lazily on each open via setMenu(buildMenuBarMenu),
    -- so the glance line picks up new totals without an explicit refresh.)
    if ctx.inserted then
        stats.record(finalText, stats.lastRecordingSeconds)
    end

    -- Track in recent dictations
    table.insert(recentDictations, 1, {
        text = ctx.originalText,
        time = os.time(),
        inserted = ctx.inserted,
        app = capturedAppName or "?",
    })
    while #recentDictations > MAX_RECENT do
        table.remove(recentDictations)
    end
    saveRecentDictations()

    playDoneSound()
    if getPreview() then
        -- Verbose mode: show the final text in the overlay, then linger and hide.
        local display = finalText
        if detectedLang then display = display .. " [" .. detectedLang:upper() .. "]" end
        setOverlayText(display)
        hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
    else
        -- Minimal mode: text is already in the input box — just close (stops the
        -- spinner via hideOverlay).
        hideOverlay()
    end
end

-- Insert transcribed text at cursor, with post-processing, optional LLM refinement, and action hooks
local function insertTranscribedText(text, detectedLang)
    if dictationCancelled then hideOverlay(); return end
    if text == "" or isHallucination(text) then
        hideOverlay()
        return
    end

    -- Apply app-aware post-processing
    text = postProcess(text, capturedAppBundleID)
    if text == "" then hideOverlay(); return end

    -- Skip LLM refinement for voice commands (refine would strip the prefix)
    local isVoiceCommand = text:lower():match("voice%s+command")

    -- Optional LLM refinement (async, skips short text and voice commands)
    if not isVoiceCommand and getRefineMode() and #text >= REFINE_MIN_CHARS then
        if getPreview() then setOverlayText("Refining...") end  -- minimal: spinner keeps running
        refineWithOllama(text, function(refined)
            finishInsertion(refined, detectedLang)
        end)
    else
        finishInsertion(text, detectedLang)
    end
end

local function doFinalTranscription()
    local chunks = getChunkFiles()
    if #chunks < 2 then
        log("final: not enough chunks, skipping")
        hideOverlay()
        return
    end

    -- Minimal mode: a loading spinner instead of status text. Verbose mode keeps
    -- the textual status. (The recording-phase meter has already stopped.)
    if getPreview() then setOverlayText("Transcribing...") else startSpinner() end

    local concatFile = WHISPER_TMP .. "/concat.txt"
    local f = io.open(concatFile, "w")
    for _, chunk in ipairs(chunks) do
        f:write("file '" .. chunk .. "'\n")
    end
    f:close()

    local finalWav = WHISPER_TMP .. "/final.wav"
    local lang = getLang()
    local preferred = getPreferredLangs()

    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            log("final: concat failed")
            showOverlayError("Error: concat failed")
            return
        end

        local promptArgs = getPromptArgs()

        if lang == "auto" then
            -- Auto mode: run without --no-prints to capture detected language from stderr
            local autoArgs = { "-m", getModelPath(), "-f", finalWav, "-l", "auto", "-nt" }
            for _, a in ipairs(promptArgs) do table.insert(autoArgs, a) end
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2, err2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    showOverlayError("Error: transcription failed")
                    return
                end

                -- Parse detected language from whisper stderr
                local detected = (err2 or ""):match("auto%-detected language:%s*(%w+)")
                log("auto-detected: " .. tostring(detected))

                local inPreferred = false
                if detected then
                    for _, pl in ipairs(preferred) do
                        if detected == pl then inPreferred = true; break end
                    end
                end

                if inPreferred then
                    local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                    log("final (auto/" .. detected .. "): '" .. text .. "'")
                    insertTranscribedText(text, detected)
                else
                    -- Detected language not in preferred list — re-transcribe with first preferred
                    local fallback = preferred[1]
                    log("auto-detect got '" .. tostring(detected) .. "', re-running with " .. fallback)
                    if getPreview() then setOverlayText("Re-transcribing (" .. fallback:upper() .. ")...") end
                    local retryArgs = { "-m", getModelPath(), "-f", finalWav, "-l", fallback, "-nt", "--no-prints" }
                    for _, a in ipairs(promptArgs) do table.insert(retryArgs, a) end
                    local retryTask = hs.task.new(WHISPER_BIN, function(code3, out3)
                        if code3 ~= 0 then
                            log("final: retry whisper failed")
                            showOverlayError("Error: transcription failed")
                            return
                        end
                        local text = (out3 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                        log("final (retry/" .. fallback .. "): '" .. text .. "'")
                        insertTranscribedText(text, fallback)
                    end, retryArgs)
                    retryTask:start()
                end
            end, autoArgs)
            whisperTask:start()
        else
            -- Specific language mode
            local langArgs = { "-m", getModelPath(), "-f", finalWav, "-l", lang, "-nt", "--no-prints" }
            for _, a in ipairs(promptArgs) do table.insert(langArgs, a) end
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    showOverlayError("Error: transcription failed")
                    return
                end
                local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                log("final: '" .. text .. "'")
                insertTranscribedText(text)
            end, langArgs)
            whisperTask:start()
        end
    end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", finalWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Auto-stop on silence
--------------------------------------------------------------------------------

local function checkSilence()
    if not isRecording then return end
    local chunks = getChunkFiles()
    local numChunks = #chunks
    -- Only check completed chunks (not the one being written)
    local completed = numChunks - 1
    if completed <= lastCheckedChunk then return end

    -- Check the latest completed chunk
    local chunkPath = chunks[completed]
    lastCheckedChunk = completed

    local volTask = hs.task.new(FFMPEG, function(code, out, err)
        if code ~= 0 or not isRecording then return end
        local maxVol = (err or ""):match("max_volume:%s*([-%.%d]+)")
        if maxVol then
            maxVol = tonumber(maxVol)
            -- Drive the level meter: map dB [-60..-10] → [0..1]. A dead/silent
            -- input device sits near -90dB → ~0 → flat bars.
            if maxVol then
                local lvl = (maxVol + 60) / 50
                anim.level = lvl < 0 and 0 or (lvl > 1 and 1 or lvl)
            end
            if maxVol and maxVol < AUTO_STOP_THRESHOLD_DB then
                silentChunkCount = silentChunkCount + 1
                log("silence: chunk " .. completed .. " vol=" .. maxVol .. "dB (count=" .. silentChunkCount .. ")")
                if silentChunkCount >= AUTO_STOP_SILENCE_SECONDS then
                    log("auto-stop: " .. AUTO_STOP_SILENCE_SECONDS .. "s of silence")
                    stopRecording()
                end
            else
                silentChunkCount = 0
            end
        end
    end, { "-i", chunkPath, "-af", "volumedetect", "-f", "null", "-" })
    volTask:start()
end

--------------------------------------------------------------------------------
-- Start / stop recording
--------------------------------------------------------------------------------

local function startRecording()
    if isRecording then return end
    isRecording = true
    dictationCancelled = false
    log("recording: start")

    os.execute("rm -rf '" .. CHUNK_DIR .. "'")
    os.execute("mkdir -p '" .. CHUNK_DIR .. "'")

    captureActiveApp()
    log("recording: app=" .. tostring(capturedAppName) .. " (" .. tostring(capturedAppBundleID) .. ")")

    showOverlay()
    startRecordingIndicator()
    updateMenuBar()
    hs.sound.getByFile("/System/Library/Sounds/Pop.aiff"):play()

    ffmpegTask = hs.task.new(FFMPEG, function(code, out, err)
        log("recording: ffmpeg exited " .. tostring(code))
        if code == 251 or code == 1 then
            log("recording: ERROR — ffmpeg failed to open audio device '" .. AUDIO_DEVICE .. "'. Check device format (should be :default, :0, :1) and microphone permissions.")
        end
    end, {
        "-f", "avfoundation", "-i", AUDIO_DEVICE,
        "-ac", "1", "-ar", "16000",
        "-f", "segment", "-segment_time", "1", "-segment_format", "wav",
        CHUNK_DIR .. "/chunk_%03d.wav"
    })
    ffmpegTask:start()

    lastChunkCount = 0
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    -- Live preview is opt-in; when off, the overlay just shows the recording
    -- dot + timer until the final result lands (saves the per-2s tiny-model run).
    if getPreview() then
        partialTimer = hs.timer.doEvery(PARTIAL_INTERVAL, doPartialTranscribe)
    end
    silenceTimer = hs.timer.doEvery(1.0, checkSilence)
end

local function stopRecording()
    if not isRecording then return end
    isRecording = false
    log("recording: stop")

    -- Stash how long the key was held; stats.record() (in finishInsertion) uses it.
    stats.lastRecordingSeconds = hs.timer.secondsSinceEpoch() - recordingStartTime

    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0

    stopRecordingIndicator()
    updateMenuBar()

    if ffmpegTask and ffmpegTask:isRunning() then
        ffmpegTask:interrupt()
    end
    ffmpegTask = nil

    hs.sound.getByFile("/System/Library/Sounds/Tink.aiff"):play()

    -- Brief delay for ffmpeg to finalize last chunk
    hs.timer.doAfter(0.3, doFinalTranscription)
end

--------------------------------------------------------------------------------
-- Key detection (replaces Karabiner)
--------------------------------------------------------------------------------

-- Map trigger key to generic modifier name for polling
local GENERIC_MOD = { rightAlt = "alt", rightCmd = "cmd", rightCtrl = "ctrl" }
local genericMod = GENERIC_MOD[TRIGGER_KEY]

local releasePoller = nil

-- Global so we can inspect state via hs -c
_whisper = { modTap = nil, recording = false }

local modTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    -- Wrap in pcall so errors don't kill the eventtap
    local ok, err = pcall(function()
        local rawFlags = event:rawFlags()
        local triggered = (rawFlags & triggerMask) > 0

        if triggered and not isRecording then
            startRecording()
            -- Poll for release since flagsChanged doesn't fire on key-up
            if releasePoller then releasePoller:stop() end
            releasePoller = hs.timer.doEvery(0.1, function()
                local mods = hs.eventtap.checkKeyboardModifiers()
                if not mods[genericMod] then
                    releasePoller:stop()
                    releasePoller = nil
                    stopRecording()
                end
            end)
        elseif not triggered and isRecording then
            if releasePoller then releasePoller:stop(); releasePoller = nil end
            stopRecording()
        end
    end)
    if not ok then log("eventtap error: " .. tostring(err)) end

    return false
end)
modTap:start()
_whisper.modTap = modTap

-- Re-enable eventtap if it gets disabled (e.g. by secure input). Retained so the
-- watchdog timer isn't garbage-collected (the tap itself is kept via _whisper.modTap).
_whisper.modWatchdog = hs.timer.doEvery(5, function()
    if not modTap:isEnabled() then
        log("eventtap was disabled, re-enabling")
        modTap:start()
    end
end)

-- Cancel the current dictation entirely (Esc key or the ✕ button): tears down
-- recording/transcription and sets a flag so any in-flight pipeline that
-- finishes later inserts nothing. Safe to call at any stage.
function cancelDictation()
    if not (isRecording or overlay) then return end
    log("dictation cancelled — discarding")
    dictationCancelled = true
    isRecording = false
    if releasePoller then releasePoller:stop(); releasePoller = nil end
    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    stopRecordingIndicator()
    if ffmpegTask and ffmpegTask:isRunning() then ffmpegTask:interrupt() end
    ffmpegTask = nil
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    os.execute("killall whisper-cli 2>/dev/null")
    forceHideOverlay()
    updateMenuBar()
    hs.notify.new({ title = "local-whisper", informativeText = "Discarded ✕" }):send()
end

-- Esc cancels an in-progress dictation (while recording OR transcribing). When
-- no dictation is active, Esc passes straight through to the focused app.
local escKeyCode = hs.keycodes.map["escape"] or 53
local escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if event:getKeyCode() ~= escKeyCode then return false end
    local active = isRecording or (overlay and not overlayPinned)
    if not active then return false end
    local ok, err = pcall(cancelDictation)
    if not ok then log("cancel error: " .. tostring(err)) end
    return true  -- consume Esc so it doesn't also reach the app
end)
escTap:start()
-- Retain in the persistent table — a bare local would be garbage-collected and
-- the tap would silently stop firing (modTap is kept alive the same way).
_whisper.escTap = escTap

-- Keep the Esc tap alive if macOS disables it (e.g. secure input fields).
-- Also retained, so the watchdog (and the escTap reference it holds) survives GC.
_whisper.escWatchdog = hs.timer.doEvery(5, function()
    if not escTap:isEnabled() then escTap:start() end
end)

--------------------------------------------------------------------------------
-- Meeting mode
--------------------------------------------------------------------------------

local MEETINGS_DIR = CONFIG_DIR .. "/meetings"
local MEETING_CHUNK_SECONDS = 8                       -- step between window starts
local MEETING_OVERLAP_SECONDS = 4                     -- audio reused at the head of each window for context
local MEETING_TRANSCRIBE_POLL_SECONDS = 2
local MEETING_WINDOW_TIMEOUT_SECONDS = 60             -- watchdog: kill task if it runs longer than this
local MEETING_PCM_BYTES_PER_SEC = 16000 * 2           -- 16 kHz, mono, 16-bit
local MEETING_AGGREGATE_NAME = "local-whisper Output"
local MEETING_HELPER_BIN = CONFIG_DIR .. "/bin/aggregate-audio"
-- meetingRecording and meetingStartTime are forward-declared before buildMenuBarMenu
local meetingFfmpegTask = nil
local meetingChunkDir = WHISPER_TMP .. "/meeting_chunks"
local meetingPcmPath = meetingChunkDir .. "/recording.pcm"
local meetingTranscript = {}
local meetingNotepad = nil
local meetingTranscribeTimer = nil
local meetingControlTimer = nil
local meetingNextWindowIdx = 1
local meetingLastEmittedText = ""
local meetingStopFlushed = false
local meetingWindowQueue = {}        -- pending windows waiting to slice+transcribe
local meetingProcessing = false      -- one slice+whisper pipeline at a time
local meetingPendingTranscriptions = 0
local meetingStopping = false
local meetingSavingOutput = false
local meetingPriorOutputUID = nil
-- Strong refs to in-flight hs.task objects so they can't be garbage-collected
-- before their callbacks fire. Hammerspoon's hs.task wraps a Lua userdata
-- whose __gc tears down the callback; without this table, locals in the
-- slice/whisper closures may be reaped between spawn and completion and
-- silently drop the callback. Keyed by an opaque token; cleared in callback.
local meetingActiveTasks = {}
local meetingActiveTasksSeq = 0
local saveMeetingOutput

-- Run the aggregate-audio helper synchronously; returns (stdout, exitCode).
local function runAudioHelper(...)
    if not hs.fs.attributes(MEETING_HELPER_BIN) then return nil, -1 end
    local args = { ... }
    local quoted = {}
    for _, a in ipairs(args) do table.insert(quoted, "'" .. tostring(a):gsub("'", "'\\''") .. "'") end
    local cmd = "'" .. MEETING_HELPER_BIN .. "' " .. table.concat(quoted, " ")
    local out, ok, _, code = hs.execute(cmd)
    if out then out = out:gsub("%s+$", "") end
    if ok then return out, 0 end
    return out, code or -1
end

-- Check that everything meeting mode needs is in place.
local function hasBlackHole()
    if not hs.audiodevice.findInputByName("BlackHole 2ch") then return false end
    if not hs.fs.attributes(MEETING_HELPER_BIN) then return false end
    return true
end

-- Get BlackHole device string for ffmpeg (audio-only via avfoundation)
local function getBlackHoleDevice()
    local devices = hs.audiodevice.allInputDevices()
    for _, dev in ipairs(devices) do
        if dev:name() == "BlackHole 2ch" then
            return ":BlackHole 2ch"
        end
    end
    return nil
end

-- Show setup instructions when meeting mode wasn't enabled at install time.
local function showBlackHoleSetup()
    local msg = "Meeting mode is disabled.\n\n"
        .. "To enable it, re-run the installer and answer 'y' when asked\n"
        .. "about meeting recording mode:\n\n"
        .. "  cd ~/code/local-free-openwhisper && ./install.sh\n\n"
        .. "The installer will:\n"
        .. "  1. Install BlackHole 2ch (virtual audio driver)\n"
        .. "  2. Build a small helper at ~/.local-whisper/bin/aggregate-audio\n"
        .. "  3. Create a Multi-Output Device automatically\n\n"
        .. "No manual Audio MIDI Setup steps required."
    hs.dialog.blockAlert("Meeting Mode Setup", msg, "OK")
end

-- Pick a sensible audible fallback output (anything that's not the
-- aggregate and not BlackHole). Used when the user is stranded on the
-- aggregate (e.g., a previous meeting got stuck and didn't restore).
local function pickFallbackOutput()
    local out, code = runAudioHelper("list")
    if code ~= 0 or not out then return nil end
    for line in out:gmatch("[^\n]+") do
        local uid, name = line:match("^([^\t]+)\t(.+)$")
        if uid and name
           and uid ~= "com.local-whisper.aggregate-output"
           and not name:find("BlackHole") then
            return uid
        end
    end
    return nil
end

-- Switch system default output to a freshly-built aggregate so audio
-- flows to both the user's current speakers and BlackHole. Always
-- recreates the aggregate so it tracks the user's current audible
-- device (handles disconnected monitors, headphones plugged in mid-day,
-- etc.). Saves the previous default for restoration on stopMeeting.
local function switchToAggregateOutput()
    local prior, code = runAudioHelper("default-uid")
    if code ~= 0 or not prior or prior == "" then
        log("meeting: cannot read system default output")
        return false
    end

    -- If the user is already stranded on our aggregate (previous meeting
    -- failed to restore), pick a fallback as the audible side first so
    -- the recreated aggregate has a real audible sub-device.
    if prior == "com.local-whisper.aggregate-output" then
        local fallback = pickFallbackOutput()
        if not fallback then
            log("meeting: stranded on aggregate, no audible fallback available")
            return false
        end
        log("meeting: stranded on aggregate, falling back to " .. fallback)
        runAudioHelper("set-default", fallback)
        prior = fallback
    end

    -- Tear down the old aggregate and rebuild against current default.
    local aggUid, aggCode = runAudioHelper("recreate")
    if aggCode ~= 0 or not aggUid or aggUid == "" then
        log("meeting: aggregate recreate failed (helper missing or BlackHole gone)")
        return false
    end

    meetingPriorOutputUID = prior
    local _, setCode = runAudioHelper("set-default", aggUid)
    if setCode ~= 0 then
        log("meeting: failed to switch system output to aggregate")
        meetingPriorOutputUID = nil
        return false
    end
    log("meeting: rebuilt aggregate, switched system output to it (was " .. prior .. ")")
    return true
end

-- On Hammerspoon load, if we boot with system default already on the
-- aggregate, a previous meeting got stuck and never restored. Drop us
-- onto a sensible fallback so the user has audible sound at startup.
local function recoverIfStrandedOnAggregate()
    if not hs.fs.attributes(MEETING_HELPER_BIN) then return end
    local prior = runAudioHelper("default-uid")
    if prior ~= "com.local-whisper.aggregate-output" then return end
    local fallback = pickFallbackOutput()
    if fallback then
        runAudioHelper("set-default", fallback)
        log("meeting: startup recovery — switched stranded output to " .. fallback)
    end
end

-- Restore the system default output saved by switchToAggregateOutput.
local function restorePriorOutput()
    if not meetingPriorOutputUID then return end
    local prior = meetingPriorOutputUID
    meetingPriorOutputUID = nil
    local _, code = runAudioHelper("set-default", prior)
    if code == 0 then
        log("meeting: restored system output to " .. prior)
    else
        log("meeting: failed to restore system output to " .. prior)
    end
end

-- Notepad HTML
local function meetingNotepadHTML(meetingTitle)
    return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        background: #1a1a2e;
        color: #e0e0e0;
        display: flex;
        flex-direction: column;
        height: 100vh;
        overflow: hidden;
    }
    .header {
        padding: 10px 14px;
        background: #16213e;
        border-bottom: 1px solid #0f3460;
        display: flex;
        justify-content: space-between;
        align-items: center;
        flex-shrink: 0;
    }
    .header h2 {
        font-size: 13px;
        color: #e94560;
        font-weight: 600;
    }
    .header-right {
        display: flex;
        align-items: center;
        gap: 10px;
    }
    .timer {
        font-size: 12px;
        color: #888;
        font-family: monospace;
    }
    .stop-btn {
        border: none;
        border-radius: 6px;
        background: #e94560;
        color: #fff;
        font-size: 11px;
        font-weight: 600;
        padding: 6px 10px;
        cursor: pointer;
    }
    .stop-btn:hover { background: #f15c74; }
    .stop-btn:disabled {
        background: #5b2a34;
        color: #c9a7af;
        cursor: default;
    }
    .tabs {
        display: flex;
        background: #16213e;
        border-bottom: 1px solid #0f3460;
        flex-shrink: 0;
    }
    .tab {
        padding: 6px 14px;
        font-size: 12px;
        cursor: pointer;
        color: #888;
        border-bottom: 2px solid transparent;
    }
    .tab.active {
        color: #e94560;
        border-bottom-color: #e94560;
    }
    .tab:hover { color: #ccc; }
    .panel {
        flex: 1;
        display: none;
        overflow: hidden;
    }
    .panel.active { display: flex; flex-direction: column; }
    .notes-hint {
        padding: 10px 14px 0 14px;
        font-size: 11px;
        line-height: 1.4;
        color: #7f8aa3;
    }
    #notes {
        flex: 1;
        background: #1a1a2e;
        color: #e0e0e0;
        border: none;
        padding: 12px 14px;
        font-size: 13px;
        line-height: 1.5;
        resize: none;
        outline: none;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    #notes::placeholder { color: #555; }
    #transcript {
        flex: 1;
        padding: 12px 14px;
        font-size: 12px;
        line-height: 1.6;
        overflow-y: auto;
        color: #bbb;
        white-space: pre-wrap;
    }
    .transcript-empty {
        padding: 12px 14px;
        color: #6e7890;
        font-size: 12px;
    }
    .chunk {
        margin-bottom: 8px;
        padding-bottom: 8px;
        border-bottom: 1px solid #222;
    }
    .chunk-time {
        font-size: 10px;
        color: #e94560;
        margin-bottom: 2px;
    }
    .status {
        padding: 4px 14px;
        font-size: 11px;
        color: #555;
        background: #16213e;
        border-top: 1px solid #0f3460;
        flex-shrink: 0;
    }
</style>
</head>
<body>
    <div class="header">
        <h2>]] .. meetingTitle .. [[</h2>
        <div class="header-right">
            <span class="timer" id="timer">0:00</span>
            <button class="stop-btn" id="stop-btn" onclick="requestStop()">Stop &amp; Save</button>
        </div>
    </div>
    <div class="tabs">
        <div class="tab active" onclick="switchTab('notes')">My Notes</div>
        <div class="tab" onclick="switchTab('transcript')">Live Transcript</div>
    </div>
    <div class="panel active" id="panel-notes">
        <div class="notes-hint">Use this pane for your own notes. The live transcript appears in the Transcript tab every few seconds.</div>
        <textarea id="notes" placeholder="Type your meeting notes here...&#10;&#10;Tips:&#10;- Key decisions&#10;- Action items&#10;- Questions to follow up"></textarea>
    </div>
    <div class="panel" id="panel-transcript">
        <div class="transcript-empty" id="transcript-empty">Listening... first transcript chunk should appear in about ]] .. tostring(MEETING_CHUNK_SECONDS) .. [[ seconds.</div>
        <div id="transcript"></div>
    </div>
    <div class="status" id="status">Recording from BlackHole 2ch... waiting for first transcript chunk.</div>
<script>
    window.stopRequested = false;

    function switchTab(name) {
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        document.querySelector('.tab[onclick*="' + name + '"]').classList.add('active');
        document.getElementById('panel-' + name).classList.add('active');
    }

    // Timer
    let startTime = Date.now();
    let timerInterval = setInterval(() => {
        let elapsed = Math.floor((Date.now() - startTime) / 1000);
        let min = Math.floor(elapsed / 60);
        let sec = elapsed % 60;
        document.getElementById('timer').textContent = min + ':' + (sec < 10 ? '0' : '') + sec;
    }, 1000);

    function stopTimer() {
        if (timerInterval) { clearInterval(timerInterval); timerInterval = null; }
    }

    // Called from Lua to append transcript chunks
    function appendTranscript(time, text) {
        let empty = document.getElementById('transcript-empty');
        if (empty) empty.remove();
        let div = document.createElement('div');
        div.className = 'chunk';
        let timeDiv = document.createElement('div');
        timeDiv.className = 'chunk-time';
        timeDiv.textContent = time;
        let textDiv = document.createElement('div');
        textDiv.textContent = text;
        div.appendChild(timeDiv);
        div.appendChild(textDiv);
        let container = document.getElementById('transcript');
        container.appendChild(div);
        container.scrollTop = container.scrollHeight;
    }

    function setStatus(msg) {
        document.getElementById('status').textContent = msg;
    }

    function requestStop() {
        window.stopRequested = true;
        let button = document.getElementById('stop-btn');
        button.disabled = true;
        button.textContent = 'Stopping...';
        setStatus('Stopping meeting and saving notes...');
        stopTimer();
    }

    function setStoppingState() {
        let button = document.getElementById('stop-btn');
        button.disabled = true;
        button.textContent = 'Stopping...';
        stopTimer();
    }

    function setSavedState() {
        let button = document.getElementById('stop-btn');
        button.disabled = true;
        button.textContent = 'Saved';
        stopTimer();
    }

    function getNotes() {
        return document.getElementById('notes').value;
    }
</script>
</body>
</html>]]
end

-- Create and show the notepad window
local function showMeetingNotepad()
    if meetingNotepad then meetingNotepad:delete(); meetingNotepad = nil end

    local screen = hs.screen.mainScreen():frame()
    local w, h = 380, 500
    local x = screen.x + screen.w - w - 20
    local y = screen.y + 60

    local title = os.date("Meeting — %H:%M")

    meetingNotepad = hs.webview.new({ x = x, y = y, w = w, h = h })
    meetingNotepad:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    meetingNotepad:level(hs.canvas.windowLevels.floating)
    meetingNotepad:allowTextEntry(true)
    meetingNotepad:windowTitle("Meeting Notes")
    meetingNotepad:html(meetingNotepadHTML(title))
    meetingNotepad:show()
    meetingNotepad:bringToFront()
end

-- Get user notes from the notepad
local function getMeetingNotes(callback)
    if not meetingNotepad then callback(""); return end
    meetingNotepad:evaluateJavaScript("getNotes()", function(result, err)
        callback(result or "")
    end)
end

-- Append a transcript chunk to the notepad
local function appendTranscriptToNotepad(timeStr, text)
    if not meetingNotepad then return end
    local escaped = text:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n"):gsub("\r", "")
    local timeEscaped = timeStr:gsub("'", "\\'")
    meetingNotepad:evaluateJavaScript("appendTranscript('" .. timeEscaped .. "', '" .. escaped .. "')")
end

local function setNotepadStatus(msg)
    if not meetingNotepad then return end
    local escaped = msg:gsub("\\", "\\\\"):gsub("'", "\\'")
    meetingNotepad:evaluateJavaScript("setStatus('" .. escaped .. "')")
end

local function setNotepadStoppingState()
    if not meetingNotepad then return end
    meetingNotepad:evaluateJavaScript("setStoppingState()")
end

local function setNotepadSavedState()
    if not meetingNotepad then return end
    meetingNotepad:evaluateJavaScript("setSavedState()")
end

local function pollMeetingControls()
    if not meetingNotepad or not meetingRecording or meetingStopping then return end
    meetingNotepad:evaluateJavaScript("window.stopRequested === true", function(result, err)
        if result == true or result == "true" or result == 1 then
            stopMeeting()
        end
    end)
end

local function maybeFinalizeMeetingSave()
    if not meetingStopping or meetingSavingOutput or meetingPendingTranscriptions > 0 then return end
    meetingSavingOutput = true
    setNotepadStatus("Saving meeting notes...")
    getMeetingNotes(function(notes)
        saveMeetingOutput(notes, function(filepath)
            meetingStopping = false
            if meetingControlTimer then meetingControlTimer:stop(); meetingControlTimer = nil end
            restorePriorOutput()
            setNotepadSavedState()
            updateMenuBar()
            hs.notify.new({
                title = "Meeting notes saved",
                informativeText = filepath,
            }):send()
        end)
    end)
end

-- Bounds (in seconds) of the Nth transcription window. Windows after the
-- first start MEETING_OVERLAP_SECONDS earlier than the previous one ended,
-- giving whisper context across word boundaries.
local function meetingWindowBounds(idx)
    if idx == 1 then return 0, MEETING_CHUNK_SECONDS end
    local startSec = MEETING_CHUNK_SECONDS * (idx - 1) - MEETING_OVERLAP_SECONDS
    local endSec   = MEETING_CHUNK_SECONDS * idx
    return startSec, endSec
end

-- Remove the duplicated overlap region from the start of `curr`. Whisper's
-- output for the same audio shifts with context, so an exact suffix/prefix
-- match almost never fires. Instead: search for the last K words of `prev`
-- anywhere in the first half of `curr`, and strip everything up to and
-- including that match. K decreases from 6 down to 3 to allow for word
-- drops; below 3 false-positive risk on common phrases is too high.
local function stripOverlap(prev, curr)
    if prev == "" or curr == "" then return curr end
    local function words(s)
        local out = {}
        for w in s:gmatch("%S+") do table.insert(out, w) end
        return out
    end
    local function norm(w)
        local s = w:lower():gsub("^[%p]+", ""):gsub("[%p]+$", "")
        return s  -- discard gsub's replacement-count second return value
    end
    local p, c = words(prev), words(curr)
    if #p < 3 or #c < 3 then return curr end
    local searchLimit = math.min(#c - 1, math.max(8, math.floor(#c * 0.6)))
    for k = math.min(6, #p), 3, -1 do
        local tail = {}
        for i = #p - k + 1, #p do table.insert(tail, norm(p[i])) end
        for startPos = 1, searchLimit - k + 1 do
            local match = true
            for j = 1, k do
                if norm(c[startPos + j - 1]) ~= tail[j] then match = false; break end
            end
            if match then
                local out = {}
                for i = startPos + k, #c do table.insert(out, c[i]) end
                return table.concat(out, " ")
            end
        end
    end
    return curr
end

local sliceAndTranscribeWindow  -- forward decl

-- Pop the next pending window off the queue and run it. Whisper.cpp on
-- Apple Silicon Metal doesn't tolerate concurrent invocations well (they
-- deadlock racing for the GPU), so the pipeline serializes here.
local function processNextWindow()
    if meetingProcessing then return end
    if #meetingWindowQueue == 0 then return end
    local job = table.remove(meetingWindowQueue, 1)
    meetingProcessing = true
    sliceAndTranscribeWindow(job.idx, job.startSec, job.endSec)
end

-- Slice [startSec, endSec) from the growing PCM recording into a temp WAV,
-- then run whisper on it; on success, dedupe overlap and append to the
-- transcript. Two-stage hs.task pipeline: ffmpeg → whisper. Serialized
-- via meetingProcessing/meetingWindowQueue.
sliceAndTranscribeWindow = function(idx, startSec, endSec)
    local windowPath = string.format("%s/window_%04d.wav", meetingChunkDir, idx)
    local outPrefix  = string.format("%s/window_%04d", meetingChunkDir, idx)
    local outTxtPath = outPrefix .. ".txt"
    local startLabelSec = MEETING_CHUNK_SECONDS * (idx - 1)
    local timeStr = string.format("%d:%02d",
        math.floor(startLabelSec / 60), startLabelSec % 60)

    -- pending count was already incremented by enqueueWindow

    local released = false
    local taskToken
    local watchdog
    local function release(reason)
        if released then return end
        released = true
        if watchdog then watchdog:stop(); watchdog = nil end
        if taskToken then meetingActiveTasks[taskToken] = nil; taskToken = nil end
        os.remove(windowPath)
        os.remove(outTxtPath)
        meetingPendingTranscriptions = math.max(0, meetingPendingTranscriptions - 1)
        meetingProcessing = false
        if reason then log("meeting: window " .. idx .. " released: " .. reason) end
        maybeFinalizeMeetingSave()
        processNextWindow()
    end

    -- Single shell pipeline: ffmpeg slices PCM → whisper writes -otxt file.
    -- Replaces the previous nested hs.task (slice's callback spawning whisper),
    -- which was hanging on the second window — whisper exited cleanly but the
    -- inner hs.task callback never fired. With one task we get one reliable
    -- exit callback; whisper output is read from the file, not piped stdout.
    local model = getModelPath()
    local function shquote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local cmd = string.format(
        "set -e\n" ..
        "%s -y -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -ss %.3f -i %s -t %.3f %s\n" ..
        "%s -m %s -f %s -otxt -of %s --no-prints -t 4 -l auto >/dev/null 2>&1\n",
        shquote(FFMPEG), startSec, shquote(meetingPcmPath), endSec - startSec, shquote(windowPath),
        shquote(WHISPER_BIN), shquote(model), shquote(windowPath), shquote(outPrefix)
    )

    meetingActiveTasksSeq = meetingActiveTasksSeq + 1
    taskToken = "win_" .. idx .. "_" .. meetingActiveTasksSeq

    local task = hs.task.new("/bin/sh", function(code, _stdout, _stderr)
        if released then return end  -- watchdog already handled this
        if code ~= 0 then
            log("meeting: window " .. idx .. " pipeline exited " .. tostring(code))
            release(nil)
            return
        end
        local ok, err = pcall(function()
            local f = io.open(outTxtPath, "r")
            if not f then
                log("meeting: window " .. idx .. " no output file")
                return
            end
            local raw = f:read("*all") or ""
            f:close()
            local text = raw:gsub("%[.*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" or isHallucination(text) then return end
            local emit = stripOverlap(meetingLastEmittedText, text)
            meetingLastEmittedText = text
            if emit ~= "" then
                table.insert(meetingTranscript, { time = timeStr, text = emit })
                appendTranscriptToNotepad(timeStr, emit)
                log("meeting: window " .. idx .. " → " .. #emit .. " chars (raw " .. #text .. ")")
            end
        end)
        if not ok then
            log("meeting: window " .. idx .. " emit error: " .. tostring(err))
        end
        release(nil)
    end, { "-c", cmd })
    task:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" })
    meetingActiveTasks[taskToken] = task

    -- Watchdog: if a window's pipeline runs longer than the timeout (whisper
    -- hangs, OS-level pipe stuck, whatever), kill it and release the lock so
    -- subsequent windows aren't blocked forever.
    watchdog = hs.timer.doAfter(MEETING_WINDOW_TIMEOUT_SECONDS, function()
        if released then return end
        log("meeting: window " .. idx .. " timed out after " .. MEETING_WINDOW_TIMEOUT_SECONDS .. "s, killing")
        if task and task:isRunning() then task:terminate() end
        release("watchdog timeout")
    end)

    log("meeting: window " .. idx .. " starting [" .. string.format("%.1f, %.1f", startSec, endSec) .. "]")
    if not task:start() then
        release("pipeline failed to start")
    end
end

-- Enqueue a window job and inc the pending count up front (so save logic
-- waits for it). Actual slicing+whisper runs serialized via processNextWindow.
local function enqueueWindow(idx, startSec, endSec)
    meetingPendingTranscriptions = meetingPendingTranscriptions + 1
    table.insert(meetingWindowQueue, { idx = idx, startSec = startSec, endSec = endSec })
end

-- Tick: enqueue any windows whose audio has fully arrived in recording.pcm.
local function emitReadyWindows()
    if not meetingRecording and not meetingStopping then return end
    local attr = hs.fs.attributes(meetingPcmPath)
    if not attr or attr.size <= 0 then return end
    local recordedSec = attr.size / MEETING_PCM_BYTES_PER_SEC
    local startSec, endSec = meetingWindowBounds(meetingNextWindowIdx)
    while recordedSec >= endSec do
        log(string.format("meeting: enqueue window %d [%.1f, %.1f] (recorded %.1fs, queue=%d, processing=%s)",
            meetingNextWindowIdx, startSec, endSec, recordedSec,
            #meetingWindowQueue, tostring(meetingProcessing)))
        enqueueWindow(meetingNextWindowIdx, startSec, endSec)
        meetingNextWindowIdx = meetingNextWindowIdx + 1
        startSec, endSec = meetingWindowBounds(meetingNextWindowIdx)
    end
    processNextWindow()
end

-- Stop-time flush: enqueue one last partial window for [next.start, recording-end).
local function emitFinalPartialWindow()
    if meetingStopFlushed then return end
    meetingStopFlushed = true
    local attr = hs.fs.attributes(meetingPcmPath)
    if not attr or attr.size <= 0 then return end
    local recordedSec = attr.size / MEETING_PCM_BYTES_PER_SEC
    local startSec, _ = meetingWindowBounds(meetingNextWindowIdx)
    if recordedSec - startSec < 1.0 then return end  -- skip tail under 1s
    enqueueWindow(meetingNextWindowIdx, startSec, recordedSec)
    meetingNextWindowIdx = meetingNextWindowIdx + 1
    processNextWindow()
end

-- Save meeting output as markdown
saveMeetingOutput = function(notes, callback)
    os.execute("mkdir -p '" .. MEETINGS_DIR .. "'")
    local filename = os.date("%Y-%m-%d-%H%M") .. ".md"
    local filepath = MEETINGS_DIR .. "/" .. filename

    -- Build transcript text
    local transcriptText = ""
    for _, chunk in ipairs(meetingTranscript) do
        transcriptText = transcriptText .. "[" .. chunk.time .. "] " .. chunk.text .. "\n\n"
    end

    -- Build the markdown
    local md = "# Meeting Notes — " .. os.date("%Y-%m-%d %H:%M") .. "\n\n"

    if notes and notes:gsub("%s+", "") ~= "" then
        md = md .. "## My Notes\n\n" .. notes .. "\n\n"
    end

    if transcriptText ~= "" then
        md = md .. "## Transcript\n\n" .. transcriptText
    end

    -- Try to summarize with Ollama
    if getRefineMode() and hasOllama() and #transcriptText > 100 then
        setNotepadStatus("Generating summary with Ollama...")
        local summaryPrompt = "Summarize this meeting transcript into: 1) Key Points (bullet list), 2) Action Items (bullet list), 3) Decisions Made (bullet list). Be concise. Output ONLY the summary in markdown format.\n\n" .. transcriptText:sub(1, 4000)
        local jsonPayload = hs.json.encode({
            model = getRefineModel(),
            prompt = summaryPrompt,
            stream = false,
        })
        local tmpPayload = WHISPER_TMP .. "/meeting_summary_payload.json"
        local f = io.open(tmpPayload, "w")
        if f then f:write(jsonPayload); f:close() end
        local task = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
            if code == 0 and stdout and #stdout > 0 then
                local ok, result = pcall(hs.json.decode, stdout)
                if ok and result and result.response then
                    local summary = result.response:gsub("^%s+", ""):gsub("%s+$", "")
                    if summary ~= "" then
                        md = "# Meeting Notes — " .. os.date("%Y-%m-%d %H:%M") .. "\n\n"
                            .. "## Summary\n\n" .. summary .. "\n\n"
                        if notes and notes:gsub("%s+", "") ~= "" then
                            md = md .. "## My Notes\n\n" .. notes .. "\n\n"
                        end
                        md = md .. "## Full Transcript\n\n" .. transcriptText
                        log("meeting: summary generated (" .. #summary .. " chars)")
                    end
                end
            end
            -- Save regardless of summary success
            local fout = io.open(filepath, "w")
            if fout then fout:write(md); fout:close() end
            log("meeting: saved to " .. filepath)
            setNotepadStatus("Saved to " .. filepath)
            callback(filepath)
        end, {
            "-s", "-X", "POST",
            "http://localhost:11434/api/generate",
            "-H", "Content-Type: application/json",
            "-d", "@" .. tmpPayload,
            "--max-time", "60",
        })
        task:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
        task:start()
    else
        local fout = io.open(filepath, "w")
        if fout then fout:write(md); fout:close() end
        log("meeting: saved to " .. filepath)
        setNotepadStatus("Saved to " .. filepath)
        callback(filepath)
    end
end

-- Start meeting recording
startMeeting = function()
    if meetingRecording then return end
    if not hasBlackHole() then
        showBlackHoleSetup()
        return
    end

    meetingRecording = true
    meetingStartTime = hs.timer.secondsSinceEpoch()
    meetingTranscript = {}
    meetingNextWindowIdx = 1
    meetingLastEmittedText = ""
    meetingStopFlushed = false
    meetingWindowQueue = {}
    meetingProcessing = false
    meetingPendingTranscriptions = 0
    meetingStopping = false
    meetingSavingOutput = false

    os.execute("rm -rf '" .. meetingChunkDir .. "'")
    os.execute("mkdir -p '" .. meetingChunkDir .. "'")

    log("meeting: start")

    -- Route system audio through the aggregate so BlackHole receives it.
    switchToAggregateOutput()

    -- Show notepad
    showMeetingNotepad()

    -- Record system audio (via BlackHole) AND the user's microphone, mixed
    -- into a single growing raw PCM file. A Lua-side slicer (emitReadyWindows)
    -- pulls overlapping windows out of this file and runs whisper on them,
    -- so words straddling chunk boundaries don't get cut.
    local bhDevice = getBlackHoleDevice()
    local micDev = hs.audiodevice.defaultInputDevice()
    local micName = micDev and micDev:name() or nil
    if micName == "BlackHole 2ch" then micName = nil end

    local args = { "-y", "-f", "avfoundation", "-i", bhDevice }
    if micName then
        table.insert(args, "-f")
        table.insert(args, "avfoundation")
        table.insert(args, "-i")
        table.insert(args, ":" .. micName)
        table.insert(args, "-filter_complex")
        table.insert(args, "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0")
        log("meeting: capturing system audio + mic '" .. micName .. "'")
    else
        log("meeting: capturing system audio only (no default input device)")
    end
    for _, a in ipairs({
        "-ac", "1", "-ar", "16000",
        "-f", "s16le",
        meetingPcmPath,
    }) do table.insert(args, a) end

    meetingFfmpegTask = hs.task.new(FFMPEG, function(code, out, err)
        log("meeting: ffmpeg exited " .. tostring(code))
    end, args)
    meetingFfmpegTask:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" })
    meetingFfmpegTask:start()

    -- Periodically slice ready overlapping windows out of the growing PCM
    meetingTranscribeTimer = hs.timer.doEvery(MEETING_TRANSCRIBE_POLL_SECONDS, emitReadyWindows)
    if meetingControlTimer then meetingControlTimer:stop(); meetingControlTimer = nil end
    meetingControlTimer = hs.timer.doEvery(0.5, pollMeetingControls)

    updateMenuBar()
    hs.notify.new({ title = "local-whisper", informativeText = "Meeting recording started" }):send()
end

-- Stop meeting recording
stopMeeting = function()
    if not meetingRecording then return end
    meetingRecording = false
    log("meeting: stop")

    -- Stop ffmpeg
    if meetingFfmpegTask and meetingFfmpegTask:isRunning() then
        meetingFfmpegTask:interrupt()
    end
    meetingFfmpegTask = nil

    -- Stop the slice/poll timers
    if meetingTranscribeTimer then meetingTranscribeTimer:stop(); meetingTranscribeTimer = nil end
    if meetingControlTimer then meetingControlTimer:stop(); meetingControlTimer = nil end
    meetingStopping = true
    setNotepadStoppingState()

    setNotepadStatus("Transcribing final window...")
    hs.timer.doAfter(2, function()
        emitReadyWindows()         -- catch any complete windows still pending
        emitFinalPartialWindow()   -- flush trailing audio shorter than a full step
        maybeFinalizeMeetingSave()
    end)

    updateMenuBar()
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

-- Request mic permission (child processes via hs.task inherit it)
if type(hs.microphoneState) == "function" and not hs.microphoneState() then
    log("requesting microphone permission")
    hs.microphoneState(true)
end

-- If a previous Hammerspoon session left us stranded on the meeting
-- aggregate (e.g., the meeting got stuck and never restored), drop us
-- onto an audible fallback so the user has sound at startup.
recoverIfStrandedOnAggregate()

-- Global state-dump callable from outside Hammerspoon via:
--   /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "meetingDoctor()"
-- Used by tools/meeting-doctor.sh. Prints a one-shot snapshot of meeting
-- state — exactly what's needed to debug a stuck meeting without poking
-- around init.lua internals.
function _G.meetingDoctor()
    local lines = {}
    local function add(k, v) table.insert(lines, k .. "=" .. tostring(v)) end
    add("meetingRecording", meetingRecording)
    add("meetingStopping", meetingStopping)
    add("meetingSavingOutput", meetingSavingOutput)
    add("meetingProcessing", meetingProcessing)
    add("meetingPendingTranscriptions", meetingPendingTranscriptions)
    add("meetingNextWindowIdx", meetingNextWindowIdx)
    add("meetingQueueLen", #meetingWindowQueue)
    add("meetingPriorOutputUID", meetingPriorOutputUID or "<nil>")
    add("meetingFfmpegRunning", meetingFfmpegTask and meetingFfmpegTask:isRunning() or false)
    local active = 0
    for _ in pairs(meetingActiveTasks) do active = active + 1 end
    add("meetingActiveTasks", active)
    local activeKeys = {}
    for k, t in pairs(meetingActiveTasks) do
        table.insert(activeKeys, k .. "(running=" .. tostring(t and t:isRunning()) .. ")")
    end
    add("meetingActiveTasksDetail", table.concat(activeKeys, ","))
    local attr = hs.fs.attributes(meetingPcmPath)
    add("recordingPcmBytes", attr and attr.size or 0)
    if attr and attr.size > 0 then
        add("recordingPcmSeconds", string.format("%.1f", attr.size / MEETING_PCM_BYTES_PER_SEC))
    end
    return table.concat(lines, "\n")
end

-- Also restore on Hammerspoon shutdown / reload, in case a meeting is
-- mid-flight when the user reloads config.
hs.shutdownCallback = function()
    if meetingRecording or meetingStopping then
        if meetingFfmpegTask and meetingFfmpegTask:isRunning() then
            meetingFfmpegTask:interrupt()
        end
        if meetingPriorOutputUID then
            runAudioHelper("set-default", meetingPriorOutputUID)
        end
    end
end

-- Create default preferred langs file if it doesn't exist
if readFile(PREFERRED_LANGS_FILE) == "" then
    writeFile(PREFERRED_LANGS_FILE, "en,pt")
end

-- Create menu bar icon
createMenuBar()

-- Load action hooks
local actionsEnabled = loadActionConfig() ~= nil
log("actions: " .. (actionsEnabled and "enabled" or "disabled"))

local enterStatus = getEnterMode() and "⏎" or ""
local actionsFlag = actionsEnabled and " +actions" or ""
log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. getModelName() .. ", preferred=" .. table.concat(getPreferredLangs(), ",") .. ")")
hs.notify.new({
    title = "local-whisper",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. enterStatus .. " / " .. getModelName() .. actionsFlag .. ") — hold " .. TRIGGER_KEY
}):send()
