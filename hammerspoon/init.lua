-- init.lua — local-whisper Hammerspoon module
-- Provides: overlay preview, text insertion, language/output hotkeys

-- Enable CLI (hs command) — needed for bash script communication
require("hs.ipc")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

-- Use macOS per-user TMPDIR (same as bash scripts) for security
local WHISPER_TMP  = (os.getenv("TMPDIR") or "/tmp") .. "/whisper-dictate"
local PARTIAL_FILE = WHISPER_TMP .. "/partial.txt"
local FINAL_FILE   = WHISPER_TMP .. "/final.txt"
local LANG_FILE    = os.getenv("HOME") .. "/.whisper_dictation_lang"
local OUTPUT_FILE  = os.getenv("HOME") .. "/.whisper_dictation_output"
local POLL_INTERVAL = 0.25  -- seconds

--------------------------------------------------------------------------------
-- WhisperOverlay module
--------------------------------------------------------------------------------

WhisperOverlay = {}

local overlay = nil       -- hs.canvas object
local pollTimer = nil     -- timer for reading partial file
local lastPartialText = ""

-- Read a file's contents, return empty string on failure
local function readFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

-- Write a string to a file
local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return end
    f:write(content)
    f:close()
end

-- Get current language mode
local function getLang()
    local lang = readFile(LANG_FILE):gsub("%s+", "")
    if lang == "" then return "en" end
    return lang
end

-- Get current output mode
local function getOutputMode()
    local mode = readFile(OUTPUT_FILE):gsub("%s+", "")
    if mode == "" then return "paste" end
    return mode
end

-- Build status line for overlay header
local function statusLine()
    return string.format("[%s | %s]", getLang():upper(), getOutputMode():upper())
end

--------------------------------------------------------------------------------
-- Overlay UI (hs.canvas)
--------------------------------------------------------------------------------

local function createOverlay()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    local width = 400
    local height = 100
    local padding = 20
    local x = frame.x + frame.w - width - padding
    local y = frame.y + frame.h - height - padding - 50  -- above dock

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- Background
    overlay:appendElements({
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 },
    })

    -- Status line (lang + output mode)
    overlay:appendElements({
        type = "text",
        text = statusLine(),
        textColor = { red = 0.5, green = 0.8, blue = 1.0, alpha = 1.0 },
        textSize = 11,
        frame = { x = "5%", y = "8%", w = "90%", h = "25%" },
    })

    -- Partial transcript text
    overlay:appendElements({
        type = "text",
        text = "Listening...",
        textColor = { red = 1, green = 1, blue = 1, alpha = 1.0 },
        textSize = 14,
        frame = { x = "5%", y = "35%", w = "90%", h = "60%" },
    })

    overlay:level(hs.canvas.windowLevels.overlay)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
end

local function updateOverlayText(text)
    if not overlay then return end
    -- Element 3 = transcript text (1-indexed: 1=bg, 2=status, 3=text)
    overlay[3].text = text
end

local function updateOverlayStatus(status)
    if not overlay then return end
    -- Element 2 = status line
    overlay[2].text = status
end

--------------------------------------------------------------------------------
-- Polling for partial transcript
--------------------------------------------------------------------------------

local function pollPartial()
    local text = readFile(PARTIAL_FILE):gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= lastPartialText then
        lastPartialText = text
        if text == "" then
            updateOverlayText("Listening...")
        else
            -- Show last ~200 chars to keep overlay readable
            local display = text
            if #display > 200 then
                display = "..." .. display:sub(-197)
            end
            updateOverlayText(display)
        end
    end
end

--------------------------------------------------------------------------------
-- Public API (called from bash via hs -c)
--------------------------------------------------------------------------------

function WhisperOverlay.start()
    -- Clean up any existing overlay
    WhisperOverlay.stop()

    lastPartialText = ""
    createOverlay()
    updateOverlayStatus(statusLine())
    overlay:show()

    -- Start polling partial file
    pollTimer = hs.timer.doEvery(POLL_INTERVAL, pollPartial)
end

function WhisperOverlay.stop()
    if pollTimer then
        pollTimer:stop()
        pollTimer = nil
    end
    if overlay then
        overlay:delete()
        overlay = nil
    end
end

function WhisperOverlay.setStatus(msg)
    updateOverlayText(msg)
end

function WhisperOverlay.insertFinal()
    local text = readFile(FINAL_FILE):gsub("^%s+", ""):gsub("%s+$", "")

    if text == "" then
        WhisperOverlay.stop()
        return
    end

    local mode = getOutputMode()

    if mode == "paste" then
        -- Save clipboard, paste transcribed text, restore clipboard after paste completes
        local oldClipboard = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)
        hs.eventtap.keyStroke({"cmd"}, "v")
        hs.timer.doAfter(0.3, function()
            if oldClipboard then
                hs.pasteboard.setContents(oldClipboard)
            end
        end)
    else
        -- Type mode: simulate keystrokes
        hs.eventtap.keyStrokes(text)
    end

    -- Brief delay then close overlay
    hs.timer.doAfter(0.5, function()
        WhisperOverlay.stop()
    end)
end

--------------------------------------------------------------------------------
-- Language hotkeys
--------------------------------------------------------------------------------

local function setLang(lang)
    writeFile(LANG_FILE, lang)
    hs.notify.new({ title = "local-whisper", informativeText = "Language: " .. lang:upper() }):send()
end

hs.hotkey.bind({"ctrl", "alt"}, "E", function() setLang("en") end)
hs.hotkey.bind({"ctrl", "alt"}, "P", function() setLang("pt") end)
hs.hotkey.bind({"ctrl", "alt"}, "A", function() setLang("auto") end)

hs.hotkey.bind({"ctrl", "alt"}, "T", function()
    local current = getLang()
    local cycle = { en = "pt", pt = "auto", auto = "en" }
    local next = cycle[current] or "en"
    setLang(next)
end)

--------------------------------------------------------------------------------
-- Output mode hotkey
--------------------------------------------------------------------------------

hs.hotkey.bind({"ctrl", "alt"}, "O", function()
    local current = getOutputMode()
    local next = (current == "paste") and "type" or "paste"
    writeFile(OUTPUT_FILE, next)
    hs.notify.new({ title = "local-whisper", informativeText = "Output: " .. next:upper() }):send()
end)

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

hs.notify.new({ title = "local-whisper", informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. ")" }):send()
