--[[--
Companion audiobook downloads for the BookOrbit catalog browser.

A BookOrbit book can hold an ebook and a single-file audiobook side by side
("Audiobook with companion ebook" in the library layout docs). KOReader cannot
open audio, so supportedFiles() hides those files and they were never offered
on the device. This mixin downloads the audio file next to the ebook under the
same base name:

    Dune - Frank Herbert.epub
    Dune - Frank Herbert.m4b

That pairing is what audio player plugins such as audiobook.koplugin look for
("Play aligned/enriched audiobook" finds a same-named audio file in the same
folder), so the audiobook is ready to play without any manual file handling.

Only single-file audiobooks are paired. Multi-track books (one file per
chapter) are skipped, because a same-name pairing cannot express a playlist.
]]

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local CatalogUtil = require("bookorbit_catalog_util")

local formatBytes = CatalogUtil.formatBytes
local safeFilenameBase = CatalogUtil.safeFilenameBase

local AUDIO_FORMATS = {
    m4b = true, m4a = true, mp3 = true, ogg = true, opus = true, flac = true,
}

local SETTING_KEY = "catalog_companion_audio"
local DEFAULT_MODE = "ask"

local MODES = {
    { id = "ask", label = _("Ask") },
    { id = "always", label = _("Always") },
    { id = "never", label = _("Never") },
}

local CompanionAudio = {}
CompanionAudio.MODES = MODES
CompanionAudio.SETTING_KEY = SETTING_KEY

function CompanionAudio.isAudioFormat(format)
    return type(format) == "string" and AUDIO_FORMATS[string.lower(format)] == true
end

--- The book's single audio file, or nil plus a reason ("none" / "multiple").
function CompanionAudio.pick(detail)
    local found
    for _, file in ipairs(detail and detail.files or {}) do
        if CompanionAudio.isAudioFormat(file.format) then
            if found then return nil, "multiple" end
            found = file
        end
    end
    if not found then return nil, "none" end
    return found
end

--- Same folder and base name as the ebook, with the audio file's extension.
function CompanionAudio.pathFor(ebook_path, audio_file)
    local base = ebook_path:match("^(.*)%.[^./]+$") or ebook_path
    return base .. "." .. string.lower(audio_file.format or "m4b")
end

function CompanionAudio.label(audio_file)
    local parts = { string.upper(audio_file.format or "audio") }
    local size = tonumber(audio_file.sizeBytes)
    if size and size > 0 then
        table.insert(parts, formatBytes(size))
    end
    return table.concat(parts, ", ")
end

function CompanionAudio.install(Catalog)
    function Catalog:companionAudioMode()
        local value = self.settings and self.settings[SETTING_KEY]
        for _, mode in ipairs(MODES) do
            if mode.id == value then return mode end
        end
        for _, mode in ipairs(MODES) do
            if mode.id == DEFAULT_MODE then return mode end
        end
    end

    function Catalog:showCompanionAudioModeDialog(on_closed)
        local current = self:companionAudioMode().id
        local dialog
        local buttons = {}
        for _, mode in ipairs(MODES) do
            table.insert(buttons, {
                {
                    text = mode.label .. (current == mode.id and " *" or ""),
                    callback = function()
                        UIManager:close(dialog)
                        self:persistSetting(SETTING_KEY, mode.id)
                        if on_closed then on_closed() end
                    end,
                },
            })
        end
        dialog = ButtonDialog:new{
            title = _("When an ebook also has an audiobook, download the audiobook next to it with the same name:"),
            buttons = buttons,
        }
        UIManager:show(dialog)
    end

    --- Where the audiobook belongs for this book: next to the ebook on the
    --- device, or next to where the ebook would be downloaded.
    --- create_dirs: also create the destination folder (only when actually
    --- downloading; computing a menu label must not touch the filesystem).
    function Catalog:companionAudioTarget(detail, audio, create_dirs)
        local ebook_path = self.detailReadPath and self:detailReadPath(detail)
        if ebook_path then
            return CompanionAudio.pathFor(ebook_path, audio)
        end
        local ebook = self:supportedFiles(detail)[1]
        if not ebook then return nil end
        local filetype = string.lower(ebook.format or "epub")
        if create_dirs then
            local ebook_target = self:getLocalDownloadPath(safeFilenameBase(detail), filetype, ebook.devicePath)
            return CompanionAudio.pathFor(ebook_target, audio)
        end
        local folder, name = self:getLocalDownloadPreview(safeFilenameBase(detail), filetype, ebook.devicePath)
        return (folder ~= "/" and folder or "") .. "/" .. name .. "." .. string.lower(audio.format or "m4b")
    end

    --- Called after an ebook download completed. Always ends by calling
    --- on_done exactly once (on the UI loop), whatever the user picks.
    function Catalog:offerCompanionAudio(ebook_path, detail, file, on_done)
        local function done()
            if on_done then UIManager:nextTick(on_done) end
        end
        if not file or CompanionAudio.isAudioFormat(file.format) then return done() end

        local audio, reason = CompanionAudio.pick(detail)
        if not audio then
            if reason == "multiple" then
                logger.info("BookOrbit: companion audio skipped, book has several audio files", detail and detail.id)
            end
            return done()
        end

        local target = CompanionAudio.pathFor(ebook_path, audio)
        if lfs.attributes(target, "mode") == "file" then return done() end

        local mode = self:companionAudioMode().id
        if mode == "never" then return done() end

        local function start()
            UIManager:nextTick(function()
                self:downloadCompanionAudio(target, detail, audio, on_done)
            end)
        end
        if mode == "always" then return start() end

        UIManager:nextTick(function()
            UIManager:show(ConfirmBox:new{
                text = T(_("This book also has an audiobook (%1).\n\nDownload it next to the ebook as:\n%2"),
                    CompanionAudio.label(audio), BD.filepath(target)),
                ok_text = _("Download"),
                cancel_text = _("Skip"),
                ok_callback = start,
                cancel_callback = done,
            })
        end)
    end

    function Catalog:downloadCompanionAudio(target, detail, audio, on_done)
        local function finish()
            if on_done then UIManager:nextTick(on_done) end
        end
        self:downloadFile(target, detail, audio, {
            on_success = function(path)
                UIManager:show(InfoMessage:new{
                    text = T(_("Audiobook saved:\n%1"), BD.filepath(path)),
                    timeout = 3,
                })
                finish()
            end,
            on_cancel = finish,
            on_failure = function(err)
                UIManager:show(InfoMessage:new{
                    text = T(_("The audiobook could not be downloaded:\n%1\n\nYou can try again from the book menu with \"Download audiobook\"."),
                        self:errorText(err)),
                })
                finish()
            end,
        })
    end

    --- Book menu action: fetch the audiobook for a book on its own, e.g. when
    --- the ebook was downloaded earlier.
    function Catalog:downloadCompanionAudioForDetail(detail)
        local audio, reason = CompanionAudio.pick(detail)
        if not audio then
            UIManager:show(InfoMessage:new{
                text = reason == "multiple"
                    and _("This audiobook is split into several files. Only single-file audiobooks (for example one M4B) can be paired with the ebook.")
                    or _("This book has no audiobook file."),
                timeout = 4,
            })
            return
        end
        local target = self:companionAudioTarget(detail, audio, true)
        if not target then
            UIManager:show(InfoMessage:new{ text = _("This book has no ebook to pair the audiobook with."), timeout = 3 })
            return
        end
        local function download()
            UIManager:nextTick(function()
                self:downloadCompanionAudio(target, detail, audio)
            end)
        end
        if lfs.attributes(target, "mode") == "file" then
            UIManager:show(ConfirmBox:new{
                text = T(_("The audiobook is already on this device:\n%1\n\nDownload it again?"), BD.filepath(target)),
                ok_text = _("Overwrite"),
                ok_callback = download,
            })
        else
            download()
        end
    end

    --- Label for the book menu button, or nil when the book has no audiobook.
    function Catalog:companionAudioButtonText(detail)
        local audio = CompanionAudio.pick(detail)
        if not audio then return nil end
        local target = self:companionAudioTarget(detail, audio)
        if target and lfs.attributes(target, "mode") == "file" then
            return T(_("Audiobook on device (%1)"), string.upper(audio.format or ""))
        end
        return T(_("Download audiobook (%1)"), CompanionAudio.label(audio))
    end
end

return CompanionAudio
