--[[
    Music Player for KOReader (written for the Kindle Keyboard / K3)

    * Audio files show up in the normal KOReader file browser.
      Tap one: it plays with mplayer, and every audio file in the same
      folder becomes the playlist.
    * The only setting is the location of mplayer (file or folder).
    * Volume = the Kindle's hardware buttons.
    * Playback keeps going while you read, and moves on to the next
      track by itself.
--]]

local ButtonDialog     = require("ui/widget/buttondialog")
local DataStorage      = require("datastorage")
local Dispatcher       = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage      = require("ui/widget/infomessage")
local InputDialog      = require("ui/widget/inputdialog")
local LuaSettings      = require("luasettings")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local lfs              = require("libs/libkoreader-lfs")
local logger           = require("logger")
local util             = require("util")
local _                = require("gettext")
local T                = require("ffi/util").template

local PROVIDER_KEY = "musicplayer"
local FIFO_PATH    = "/tmp/mplayer_ko.fifo"
local PID_PATH     = "/tmp/mplayer_ko.pid"
local LOG_PATH     = "/tmp/mplayer_ko.log"

local AUDIO_EXTS = {
    mp3 = true, ogg = true, flac = true, wav = true, aac = true,
    m4a = true, opus = true, wma = true, ape = true, mka = true,
}

-- Playback state lives here (not on the plugin object) because KOReader
-- creates a separate plugin object for the file browser and for the reader.
-- This way music keeps its state when you open or close a book.
local S = {
    playlist   = {},
    index      = 0,
    state      = "stopped",   -- "stopped" | "playing" | "paused"
    shuffle    = false,
    repeat_all = false,
    poll_gen   = 0,
    started_at = 0,
}

-- ── small helpers ───────────────────────────────────────────────────────────

local function shellEscape(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellOk(cmd)
    local ret = os.execute(cmd)
    return ret == 0 or ret == true
end

local function isAudio(file)
    local ext = util.getFileNameSuffix(file or "")
    return ext ~= nil and AUDIO_EXTS[ext:lower()] == true
end

local function trackName(path)
    local base = path:match("([^/]+)$") or path
    return (base:gsub("%.[^%.]+$", ""))
end

local function pathMode(path)
    return lfs.attributes(path, "mode")
end

-- ── settings ────────────────────────────────────────────────────────────────

local settings
local function getSettings()
    if not settings then
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/musicplayer.lua")
    end
    return settings
end

--- Accepts either the mplayer binary or the folder containing it.
--- Returns the real binary path, or nil.
local function resolveBinary(path)
    path = trim(path)
    if path == "" then return nil end
    local mode = pathMode(path)
    if mode == "file" then return path end
    if mode == "directory" then
        path = path:gsub("/+$", "")
        for _i, candidate in ipairs({ path .. "/mplayer", path .. "/bin/mplayer" }) do
            if pathMode(candidate) == "file" then return candidate end
        end
    end
    return nil
end

local function getBinary()
    return resolveBinary(getSettings():readSetting("mplayer_path") or "")
end

-- ── process control ─────────────────────────────────────────────────────────

local function readPid()
    local f = io.open(PID_PATH, "r")
    if not f then return nil end
    local pid = tonumber(f:read("*l"))
    f:close()
    return pid
end

local function procAlive()
    local pid = readPid()
    if not pid then return false end
    local f = io.open("/proc/" .. pid .. "/stat", "r")
    if not f then return false end
    local stat = f:read("*l") or ""
    f:close()
    -- "<pid> (<name>) <state> ...": a zombie (Z) has already exited.
    local state = stat:match("^%d+ %b() (%a)")
    return state ~= nil and state ~= "Z" and state ~= "X"
end

--- Send one slave-mode command to mplayer.
--- Opening the FIFO read/write ("r+") means this can never block, even if
--- mplayer has died, which would otherwise freeze KOReader.
local function sendCmd(cmd)
    if pathMode(FIFO_PATH) == nil then return false end
    local ok = pcall(function()
        local f = assert(io.open(FIFO_PATH, "r+"))
        f:write(cmd .. "\n")
        f:close()
    end)
    return ok
end

local function killPlayer()
    if procAlive() then
        sendCmd("quit")
        local pid = readPid()
        if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
    end
    os.remove(PID_PATH)
    os.remove(FIFO_PATH)
end

-- ── playlist ────────────────────────────────────────────────────────────────

local function buildPlaylist(file)
    local dir = file:match("^(.*)/[^/]+$") or "."
    local files = {}
    local ok, iter, dirobj = pcall(lfs.dir, dir)
    if ok then
        for entry in iter, dirobj do
            if entry ~= "." and entry ~= ".." and isAudio(entry) then
                table.insert(files, dir .. "/" .. entry)
            end
        end
    end
    table.sort(files)
    local idx = 1
    for i, f in ipairs(files) do
        if f == file then idx = i; break end
    end
    if #files == 0 then files = { file } end
    return files, idx
end

--- Shuffle everything except the current track, which moves to the front.
local function shufflePlaylist()
    if S.index < 1 or #S.playlist < 2 then return end
    local current = table.remove(S.playlist, S.index)
    math.randomseed(os.time())
    for i = #S.playlist, 2, -1 do
        local j = math.random(i)
        S.playlist[i], S.playlist[j] = S.playlist[j], S.playlist[i]
    end
    table.insert(S.playlist, 1, current)
    S.index = 1
end

-- ── the plugin ──────────────────────────────────────────────────────────────

local MusicPlayer = WidgetContainer:extend{
    name     = PROVIDER_KEY,          -- must equal PROVIDER_KEY
    fullname = _("Music Player"),
}

function MusicPlayer:init()
    self.ui.menu:registerToMainMenu(self)
    self:registerActions()
    self:registerWithKOReader()
end

--- Make audio files visible in the file browser and openable by tapping.
--- KOReader's file list only shows files that have a "provider", and only
--- "document" providers count; plugins can't be one. So we teach the registry
--- about audio files. Done once, no matter how many times the plugin loads.
function MusicPlayer:registerWithKOReader()
    DocumentRegistry:addAuxProvider({
        provider_name = self.fullname,
        provider      = PROVIDER_KEY,
        order         = 50,           -- position in the "Open with" dialog
        disable_file  = true,
        disable_type  = false,
    })

    if DocumentRegistry._musicplayer_patched then return end
    DocumentRegistry._musicplayer_patched = true

    local orig_hasProvider = DocumentRegistry.hasProvider
    function DocumentRegistry:hasProvider(file, mimetype, include_aux)
        if file and isAudio(file) then return true end
        return orig_hasProvider(self, file, mimetype, include_aux)
    end

    local orig_getProvider = DocumentRegistry.getProvider
    function DocumentRegistry:getProvider(file, include_aux)
        if include_aux and file and isAudio(file) then
            local provider = self.known_providers[PROVIDER_KEY]
            if provider then return provider, true end
        end
        return orig_getProvider(self, file, include_aux)
    end
end

function MusicPlayer:isFileTypeSupported(file)
    return isAudio(file)
end

-- Called by KOReader when you tap an audio file.
function MusicPlayer:openFile(file)
    if not getBinary() then
        self:promptSetup(function() self:openFile(file) end)
        return
    end
    S.playlist, S.index = buildPlaylist(file)
    if S.shuffle then shufflePlaylist() end
    self:playIndex(S.index)
    self:showControls()
end

-- ── playback ────────────────────────────────────────────────────────────────

function MusicPlayer:stop()
    S.poll_gen = S.poll_gen + 1   -- cancels the auto-advance timer
    killPlayer()
    S.state = "stopped"
end

function MusicPlayer:launch(path)
    self:stop()

    local bin = getBinary()
    if not bin then
        self:promptSetup(function() self:launch(path) end)
        return
    end

    -- Create the control FIFO (mknod is the fallback if mkfifo is missing).
    os.execute(string.format("rm -f %s; mkfifo %s 2>/dev/null || mknod %s p 2>/dev/null",
        FIFO_PATH, FIFO_PATH, FIFO_PATH))
    os.execute("chmod +x " .. shellEscape(bin) .. " 2>/dev/null")

    -- LD_LIBRARY_PATH: KOReader sets its own, which can break mplayer.
    -- Point it at mplayer's own folder instead (harmless for static builds).
    local bindir = bin:match("^(.*)/[^/]+$") or "."
    local cmd = string.format(
        "LD_LIBRARY_PATH=%s:/lib:/usr/lib %s -slave -really-quiet -ao alsa "
        .. "-input file=%s %s </dev/null >%s 2>&1 & echo $! >%s",
        shellEscape(bindir), shellEscape(bin), FIFO_PATH, shellEscape(path),
        LOG_PATH, PID_PATH)
    os.execute(cmd)

    S.state = "playing"
    S.started_at = os.time()
    logger.info("MusicPlayer: playing " .. path)
    self:startWatching()
end

--- Checks every couple of seconds whether mplayer finished the track, and
--- moves on to the next one.
function MusicPlayer:startWatching()
    S.poll_gen = S.poll_gen + 1
    local gen = S.poll_gen
    local this = self
    local function tick()
        if gen ~= S.poll_gen or S.state == "stopped" then return end
        if procAlive() then
            UIManager:scheduleIn(2, tick)
            return
        end
        -- mplayer is gone.
        if os.time() - S.started_at <= 3 then
            -- It died right after starting: bad binary, no audio, unreadable
            -- file... Don't skip through the whole playlist failing.
            this:stop()
            UIManager:show(InfoMessage:new{
                text = T(_("mplayer stopped right after starting.\n\nDetails are in:\n%1"), LOG_PATH),
            })
            return
        end
        this:advance(true)
    end
    UIManager:scheduleIn(2, tick)
end

function MusicPlayer:playIndex(idx)
    if #S.playlist == 0 then return end
    idx = ((idx - 1) % #S.playlist) + 1
    S.index = idx
    self:launch(S.playlist[idx])
end

--- `auto` is true when the previous track simply ended.
function MusicPlayer:advance(auto)
    if #S.playlist == 0 then return end
    local nxt = S.index + 1
    if nxt > #S.playlist then
        if S.repeat_all then
            nxt = 1
        else
            self:stop()
            if auto then
                UIManager:show(InfoMessage:new{ text = _("Playlist finished."), timeout = 2 })
            end
            return
        end
    end
    self:playIndex(nxt)
end

function MusicPlayer:previous()
    if #S.playlist == 0 then return end
    self:playIndex(S.index - 1)
end

function MusicPlayer:togglePause()
    if S.state == "stopped" then
        if S.index > 0 and #S.playlist > 0 then self:playIndex(S.index) end
        return
    end
    if not procAlive() then self:stop(); return end
    sendCmd("pause")
    S.state = (S.state == "playing") and "paused" or "playing"
end

function MusicPlayer:seek(seconds)
    if S.state ~= "stopped" then sendCmd(string.format("seek %d 0", seconds)) end
end

-- ── events (so keys/gestures can be bound in KOReader's own settings) ───────

function MusicPlayer:registerActions()
    Dispatcher:registerAction("musicplayer_toggle",
        { category = "none", event = "MusicToggle", title = _("Music: play/pause"), general = true })
    Dispatcher:registerAction("musicplayer_next",
        { category = "none", event = "MusicNext", title = _("Music: next track"), general = true })
    Dispatcher:registerAction("musicplayer_prev",
        { category = "none", event = "MusicPrev", title = _("Music: previous track"), general = true })
end

function MusicPlayer:onMusicToggle() self:togglePause(); return true end
function MusicPlayer:onMusicNext()   self:advance(false); return true end
function MusicPlayer:onMusicPrev()   self:previous(); return true end

-- ── UI ──────────────────────────────────────────────────────────────────────

function MusicPlayer:promptSetup(on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Where is mplayer?"),
        description = _("Enter the mplayer file, or the folder that contains it."),
        input = getSettings():readSetting("mplayer_path") or "/mnt/us/mplayer",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local entered = trim(dialog:getInputText())
                    if not resolveBinary(entered) then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Couldn't find mplayer at:\n%1"), entered),
                        })
                        return   -- keep the dialog open so it can be fixed
                    end
                    getSettings():saveSetting("mplayer_path", entered)
                    getSettings():flush()
                    UIManager:close(dialog)
                    if on_done then on_done() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MusicPlayer:showControls()
    local title
    if S.index > 0 and S.playlist[S.index] then
        local label = ({ playing = _("Playing"), paused = _("Paused"), stopped = _("Stopped") })[S.state]
        title = label .. "\n" .. trackName(S.playlist[S.index])
            .. string.format("  (%d/%d)", S.index, #S.playlist)
    else
        title = _("Nothing playing\nTap an audio file in the file browser.")
    end

    local dialog
    local function reopen() UIManager:close(dialog); self:showControls() end
    dialog = ButtonDialog:new{
        title = title,
        buttons = {
            {
                { text = _("Prev"), callback = function() UIManager:close(dialog); self:previous(); self:showControls() end },
                { text = (S.state == "playing") and _("Pause") or _("Play"),
                  callback = function() self:togglePause(); reopen() end },
                { text = _("Next"), callback = function() UIManager:close(dialog); self:advance(false); self:showControls() end },
            },
            {
                { text = _("-30s"), callback = function() self:seek(-30) end },
                { text = _("+30s"), callback = function() self:seek(30) end },
            },
            {
                { text = _("Shuffle: ") .. (S.shuffle and _("on") or _("off")),
                  callback = function()
                      S.shuffle = not S.shuffle
                      if S.shuffle then shufflePlaylist() end
                      reopen()
                  end },
                { text = _("Repeat: ") .. (S.repeat_all and _("on") or _("off")),
                  callback = function() S.repeat_all = not S.repeat_all; reopen() end },
            },
            {
                { text = _("Stop"), callback = function() self:stop(); reopen() end },
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end

function MusicPlayer:addToMainMenu(menu_items)
    menu_items.music_player = {
        text = self.fullname,
        sorting_hint = "more_tools",
        sub_item_table = {
            { text = _("Controls"),       callback = function() self:showControls() end },
            { text = _("Play / pause"),   callback = function() self:togglePause() end },
            { text = _("Next track"),     callback = function() self:advance(false) end },
            { text = _("Previous track"), callback = function() self:previous() end },
            { text = _("Stop"),           callback = function() self:stop() end },
            { text = _("mplayer location…"), callback = function() self:promptSetup() end },
        },
    }
end

function MusicPlayer:onExit()
    self:stop()
end

return MusicPlayer
