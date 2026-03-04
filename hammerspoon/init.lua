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

-- External binaries (absolute paths)
local FFMPEG = "/opt/homebrew/bin/ffmpeg"
local WHISPER_BIN = HOME .. "/whisper.cpp/build/bin/whisper-cli"
local MODELS_DIR = HOME .. "/whisper.cpp/models"
local MODEL_FILE = HOME .. "/.whisper_dictation_model"

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
local AUDIO_DEVICE = ":1"

-- Trigger key: "rightAlt", "rightCmd", "rightCtrl"
local TRIGGER_KEY = "rightCmd"

-- User preference files
local LANG_FILE = HOME .. "/.whisper_dictation_lang"
local OUTPUT_FILE = HOME .. "/.whisper_dictation_output"
local PREFERRED_LANGS_FILE = HOME .. "/.whisper_dictation_preferred_langs"
local ENTER_FILE = HOME .. "/.whisper_dictation_enter"
local LOG_FILE = WHISPER_TMP .. "/whisper-dictate.log"

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
    if lang == "en" or lang == "pt" or lang == "auto" then return lang end
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

local function isHallucination(text)
    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- strip trailing period for comparison
    local stripped = lower:gsub("%.$", "")
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
    local cycle = { en = "pt", pt = "auto", auto = "en" }
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

local function cycleEnter()
    local next = getEnterMode() and "off" or "on"
    writeFile(ENTER_FILE, next)
    return next
end

--------------------------------------------------------------------------------
-- Overlay UI
--------------------------------------------------------------------------------

local overlay = nil
local btnColor = { red = 0.5, green = 0.8, blue = 1.0, alpha = 1.0 }
local btnHover = { red = 0.7, green = 0.9, blue = 1.0, alpha = 1.0 }

-- Element indices: 1=bg, 2=lang, 3=sep1, 4=output, 5=sep2, 6=enter, 7=sep3, 8=model, 9=close, 10=text
local EL = { lang = 2, output = 4, enter = 6, model = 8, close = 9, text = 10 }

local enterOnColor = { red = 0.3, green = 1.0, blue = 0.3, alpha = 1.0 }
local enterOffColor = { red = 0.5, green = 0.5, blue = 0.5, alpha = 0.5 }

local function refreshOverlayLabels()
    if not overlay then return end
    overlay[EL.lang].text = getLang():upper()
    overlay[EL.output].text = getOutputMode():upper()
    overlay[EL.enter].text = "⏎"
    overlay[EL.enter].textColor = getEnterMode() and enterOnColor or enterOffColor
    overlay[EL.model].text = getModelName()
end

local function createOverlay()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()
    local width, height = 420, 100
    local padding = 20
    local x = frame.x + frame.w - width - padding
    local y = frame.y + frame.h - height - padding - 50

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- 1: Background (click to pin overlay open)
    overlay:appendElements({
        id = "bg",
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 },
        trackMouseUp = true,
    })

    -- Clickable status labels (each cycles on click)
    local sepColor = { red = 0.4, green = 0.4, blue = 0.4, alpha = 1 }

    -- 2: Language
    overlay:appendElements({
        id = "lang", type = "text", text = getLang():upper(),
        textColor = btnColor, textSize = 11,
        frame = { x = "4%", y = "6%", w = "10%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 3: Separator
    overlay:appendElements({
        id = "sep1", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "13%", y = "6%", w = "2%", h = "25%" },
    })
    -- 4: Output mode
    overlay:appendElements({
        id = "output", type = "text", text = getOutputMode():upper(),
        textColor = btnColor, textSize = 11,
        frame = { x = "15%", y = "6%", w = "13%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 5: Separator
    overlay:appendElements({
        id = "sep2", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "27%", y = "6%", w = "2%", h = "25%" },
    })
    -- 6: Enter mode (⏎ green=on, gray=off)
    overlay:appendElements({
        id = "enter", type = "text", text = "⏎",
        textColor = getEnterMode() and enterOnColor or enterOffColor, textSize = 11,
        frame = { x = "29%", y = "6%", w = "5%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 7: Separator
    overlay:appendElements({
        id = "sep3", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "34%", y = "6%", w = "2%", h = "25%" },
    })
    -- 8: Model
    overlay:appendElements({
        id = "model", type = "text", text = getModelName(),
        textColor = btnColor, textSize = 11,
        frame = { x = "36%", y = "6%", w = "50%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 9: Close button (X)
    overlay:appendElements({
        id = "close", type = "text", text = "✕",
        textColor = { red = 1, green = 1, blue = 1, alpha = 0.5 },
        textSize = 14, textAlignment = "right",
        frame = { x = "88%", y = "4%", w = "10%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 10: Transcript text
    overlay:appendElements({
        id = "text", type = "text", text = "Listening...",
        textColor = { red = 1, green = 1, blue = 1, alpha = 1.0 },
        textSize = 14,
        frame = { x = "5%", y = "35%", w = "90%", h = "60%" },
    })

    overlay:level(hs.canvas.windowLevels.overlay)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- Map string IDs to numeric indices for element access
    local idMap = { bg = 1, lang = EL.lang, output = EL.output, enter = EL.enter, model = EL.model, close = EL.close }

    -- Mouse handler: click bg to pin, click labels to cycle settings, X to close
    overlay:canvasMouseEvents(false, true, true, false)  -- mouseUp + enterExit
    overlay:mouseCallback(function(canvas, event, id, mx, my)
        if event == "mouseUp" then
            if id == "bg" then
                overlayPinned = not overlayPinned
                if overlayPinned then
                    canvas[1].fillColor = { red = 0.15, green = 0.15, blue = 0.2, alpha = 0.92 }
                    log("overlay pinned")
                else
                    canvas[1].fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 }
                    log("overlay unpinned")
                    if not isRecording then hideOverlay() end
                end
                return
            end

            if id == "close" then
                overlayPinned = false
                if isRecording then emergencyStop() else hideOverlay() end
                return
            end

            if id == "lang" then cycleLang()
            elseif id == "output" then cycleOutput()
            elseif id == "enter" then cycleEnter()
            elseif id == "model" then cycleModel()
            end
            refreshOverlayLabels()

        elseif event == "mouseEnter" then
            local idx = idMap[id]
            if not idx or id == "bg" then return end
            if id == "close" then
                canvas[idx].textColor = { red = 1, green = 0.3, blue = 0.3, alpha = 1 }
            elseif id == "enter" then
                canvas[idx].textColor = enterOnColor
            else
                canvas[idx].textColor = btnHover
            end

        elseif event == "mouseExit" then
            local idx = idMap[id]
            if not idx or id == "bg" then return end
            if id == "close" then
                canvas[idx].textColor = { red = 1, green = 1, blue = 1, alpha = 0.5 }
            elseif id == "enter" then
                canvas[idx].textColor = getEnterMode() and enterOnColor or enterOffColor
            else
                canvas[idx].textColor = btnColor
            end
        end
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
    if overlay then overlay:delete(); overlay = nil end
end

local function forceHideOverlay()
    overlayPinned = false
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
local overlayPinned = false
local ffmpegTask = nil
local partialTimer = nil
local partialBusy = false
local lastChunkCount = 0

--------------------------------------------------------------------------------
-- Emergency stop (forward declaration)
--------------------------------------------------------------------------------

function emergencyStop()
    log("emergency stop")
    isRecording = false
    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if ffmpegTask and ffmpegTask:isRunning() then ffmpegTask:interrupt() end
    ffmpegTask = nil
    partialBusy = false
    forceHideOverlay()
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
        end, { "-m", getModelPath(), "-f", batchWav, "-l", lang, "-nt", "--no-prints" })
        whisperTask:start()
    end, { "-y", "-f", "concat", "-safe", "0", "-i", batchList, "-c", "copy", batchWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Final transcription
--------------------------------------------------------------------------------

-- Insert transcribed text at cursor, optionally press Enter, show in overlay
local function insertTranscribedText(text, detectedLang)
    if text == "" or isHallucination(text) then
        hideOverlay()
        return
    end

    local mode = getOutputMode()
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

    -- Press Enter after insertion if enter mode is on
    if getEnterMode() then
        hs.timer.doAfter(0.15, function()
            hs.eventtap.keyStroke({}, "return")
        end)
    end

    local display = text
    if detectedLang then display = display .. " [" .. detectedLang:upper() .. "]" end
    setOverlayText(display)
    hs.sound.getByFile("/System/Library/Sounds/Glass.aiff"):play()
    hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
end

local function doFinalTranscription()
    local chunks = getChunkFiles()
    if #chunks < 2 then
        log("final: not enough chunks, skipping")
        hideOverlay()
        return
    end

    setOverlayText("Transcribing...")

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
            setOverlayText("Error: concat failed")
            hs.timer.doAfter(2, hideOverlay)
            return
        end

        if lang == "auto" then
            -- Auto mode: run without --no-prints to capture detected language from stderr
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2, err2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    setOverlayText("Error: transcription failed")
                    hs.timer.doAfter(2, hideOverlay)
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
                    setOverlayText("Re-transcribing (" .. fallback:upper() .. ")...")
                    local retryTask = hs.task.new(WHISPER_BIN, function(code3, out3)
                        if code3 ~= 0 then
                            log("final: retry whisper failed")
                            setOverlayText("Error: transcription failed")
                            hs.timer.doAfter(2, hideOverlay)
                            return
                        end
                        local text = (out3 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                        log("final (retry/" .. fallback .. "): '" .. text .. "'")
                        insertTranscribedText(text, fallback)
                    end, { "-m", getModelPath(), "-f", finalWav, "-l", fallback, "-nt", "--no-prints" })
                    retryTask:start()
                end
            end, { "-m", getModelPath(), "-f", finalWav, "-l", "auto", "-nt" })
            whisperTask:start()
        else
            -- Specific language mode
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    setOverlayText("Error: transcription failed")
                    hs.timer.doAfter(2, hideOverlay)
                    return
                end
                local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                log("final: '" .. text .. "'")
                insertTranscribedText(text)
            end, { "-m", getModelPath(), "-f", finalWav, "-l", lang, "-nt", "--no-prints" })
            whisperTask:start()
        end
    end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", finalWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Start / stop recording
--------------------------------------------------------------------------------

local function startRecording()
    if isRecording then return end
    isRecording = true
    log("recording: start")

    os.execute("rm -rf '" .. CHUNK_DIR .. "'")
    os.execute("mkdir -p '" .. CHUNK_DIR .. "'")

    showOverlay()
    hs.sound.getByFile("/System/Library/Sounds/Pop.aiff"):play()

    ffmpegTask = hs.task.new(FFMPEG, function(code, out, err)
        log("recording: ffmpeg exited " .. tostring(code))
    end, {
        "-f", "avfoundation", "-i", AUDIO_DEVICE,
        "-ac", "1", "-ar", "16000",
        "-f", "segment", "-segment_time", "1", "-segment_format", "wav",
        CHUNK_DIR .. "/chunk_%03d.wav"
    })
    ffmpegTask:start()

    lastChunkCount = 0
    partialBusy = false
    partialTimer = hs.timer.doEvery(PARTIAL_INTERVAL, doPartialTranscribe)
end

local function stopRecording()
    if not isRecording then return end
    isRecording = false
    log("recording: stop")

    if partialTimer then partialTimer:stop(); partialTimer = nil end
    partialBusy = false

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

-- Re-enable eventtap if it gets disabled (e.g. by secure input)
hs.timer.doEvery(5, function()
    if not modTap:isEnabled() then
        log("eventtap was disabled, re-enabling")
        modTap:start()
    end
end)

--------------------------------------------------------------------------------
-- Language hotkeys
--------------------------------------------------------------------------------

local function setLang(lang)
    writeFile(LANG_FILE, lang)
    setOverlayStatus()  -- update overlay if visible
    hs.notify.new({ title = "local-whisper", informativeText = "Language: " .. lang:upper() }):send()
end

hs.hotkey.bind({"ctrl", "alt"}, "E", function() setLang("en") end)
hs.hotkey.bind({"ctrl", "alt"}, "P", function() setLang("pt") end)
hs.hotkey.bind({"ctrl", "alt"}, "A", function() setLang("auto") end)

hs.hotkey.bind({"ctrl", "alt"}, "T", function()
    local cycle = { en = "pt", pt = "auto", auto = "en" }
    setLang(cycle[getLang()] or "en")
end)

--------------------------------------------------------------------------------
-- Model hotkey (Ctrl+Alt+M)
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "M", function()
    local new = cycleModel()
    setOverlayStatus()
    hs.notify.new({ title = "local-whisper", informativeText = "Model: " .. new }):send()
end)

--------------------------------------------------------------------------------
-- Output mode hotkey (Ctrl+Alt+O)
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "O", function()
    local new = cycleOutput()
    setOverlayStatus()
    hs.notify.new({ title = "local-whisper", informativeText = "Output: " .. new:upper() }):send()
end)

--------------------------------------------------------------------------------
-- Settings overlay hotkey (Ctrl+Alt+S) — open pinned overlay without recording
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "S", function()
    if overlay then
        forceHideOverlay()
    else
        showOverlay()
        overlayPinned = true
        overlay[1].fillColor = { red = 0.15, green = 0.15, blue = 0.2, alpha = 0.92 }
        setOverlayText("Click labels to change settings")
    end
end)

--------------------------------------------------------------------------------
-- Enter mode hotkey (Ctrl+Alt+Return)
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "return", function()
    local new = cycleEnter()
    setOverlayStatus()
    hs.notify.new({ title = "local-whisper", informativeText = "Enter after insert: " .. new:upper() }):send()
end)

--------------------------------------------------------------------------------
-- Emergency stop hotkey (Ctrl+Alt+X)
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "X", function() emergencyStop() end)

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

-- Request mic permission (child processes via hs.task inherit it)
if type(hs.microphoneState) == "function" and not hs.microphoneState() then
    log("requesting microphone permission")
    hs.microphoneState(true)
end

-- Create default preferred langs file if it doesn't exist
if readFile(PREFERRED_LANGS_FILE) == "" then
    writeFile(PREFERRED_LANGS_FILE, "en,pt")
end

local enterStatus = getEnterMode() and "⏎" or ""
log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. getModelName() .. ", preferred=" .. table.concat(getPreferredLangs(), ",") .. ")")
hs.notify.new({
    title = "local-whisper",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. enterStatus .. " / " .. getModelName() .. ") — hold " .. TRIGGER_KEY
}):send()
