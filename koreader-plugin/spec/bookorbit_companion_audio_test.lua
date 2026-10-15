-- Companion audiobook downloads: a single-file audiobook stored with an ebook
-- is saved next to it under the same base name (Title.epub + Title.m4b).

local shown = {}
local scheduled = {}
local existing = {}
local settings_store = {}

local function identity(value) return value end

local Widget = {
    new = function(_, opts)
        function opts:setTitle(title) self.title = title end
        return opts
    end,
}
package.loaded["ui/bidi"] = { dirpath = identity, filepath = identity }
package.loaded["ui/widget/buttondialog"] = Widget
package.loaded["ui/widget/confirmbox"] = Widget
package.loaded["ui/widget/infomessage"] = Widget
package.loaded["ui/widget/inputdialog"] = Widget
package.loaded["ui/widget/notification"] = Widget
package.loaded["ui/uimanager"] = {
    show = function(_, widget) table.insert(shown, widget) end,
    close = function() end,
    nextTick = function(_, callback) table.insert(scheduled, callback) end,
    forceRePaint = function() end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, mode)
        if existing[path] then return mode == "mode" and "file" or { mode = "file" } end
        return nil
    end,
}
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
package.loaded["ffi/util"] = {
    template = function(value, ...)
        local result = value
        for index = 1, select("#", ...) do
            local replacement = tostring(select(index, ...))
            result = result:gsub("%%" .. index, function() return replacement end)
        end
        return result
    end,
}
package.loaded["util"] = {
    makePath = function() end,
    getSafeFilename = function(filename) return filename end,
    trim = function(value) return tostring(value or ""):match("^%s*(.-)%s*$") end,
}
package.loaded["gettext"] = identity
package.loaded["bookorbit_catalog_util"] = {
    formatBytes = function(bytes) return tostring(math.floor(bytes / 1048576)) .. " MB" end,
    safeFilenameBase = function(detail) return detail.fallbackFilename end,
}

package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path

local CompanionAudio = require("bookorbit_companion_audio")

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end
local function assertContains(value, expected, label)
    if not tostring(value):find(expected, 1, true) then
        error(string.format("%s: expected %q in %q", label, expected, tostring(value)))
    end
end
local function drain()
    while #scheduled > 0 do table.remove(scheduled, 1)() end
end

-- pick / pathFor / label ---------------------------------------------------

local epub = { id = 10, format = "epub", devicePath = "Frank Herbert/Dune.epub" }
local m4b = { id = 11, format = "M4B", sizeBytes = 412 * 1048576 }
local book = { id = 1, title = "Dune", fallbackFilename = "Dune - Frank Herbert", files = { epub, m4b } }

assertEqual(CompanionAudio.pick(book), m4b, "the single audio file is picked")
local none, why = CompanionAudio.pick({ files = { epub } })
assertEqual(none, nil, "an ebook-only book has no companion")
assertEqual(why, "none", "no-audio reason")
local multi, multi_why = CompanionAudio.pick({ files = { epub, { format = "mp3" }, { format = "mp3" } } })
assertEqual(multi, nil, "multi-track audiobooks are not paired")
assertEqual(multi_why, "multiple", "multi-track reason")
assertEqual(CompanionAudio.pathFor("/mnt/onboard/Books/Dune - Frank Herbert.epub", m4b),
    "/mnt/onboard/Books/Dune - Frank Herbert.m4b", "audio lands next to the ebook with the same base name")
assertEqual(CompanionAudio.pathFor("/mnt/onboard/A.B/Title v1.2.epub", { format = "m4b" }),
    "/mnt/onboard/A.B/Title v1.2.m4b", "only the extension is replaced")
assertEqual(CompanionAudio.label(m4b), "M4B, 412 MB", "label shows format and size")
assertEqual(CompanionAudio.isAudioFormat("EPUB"), false, "epub is not audio")

-- offerCompanionAudio --------------------------------------------------------

local Catalog = { settings = settings_store }
function Catalog:persistSetting(key, value) self.settings[key] = value end
function Catalog:errorText(err) return "error: " .. tostring(err) end
function Catalog:supportedFiles(detail)
    local files = {}
    for _, f in ipairs(detail.files or {}) do
        if not CompanionAudio.isAudioFormat(f.format) then table.insert(files, f) end
    end
    return files
end
local downloads = {}
local download_result = "ok"
function Catalog:downloadFile(path, detail, file, opts)
    table.insert(downloads, { path = path, file = file, opts = opts })
    if download_result == "ok" then
        opts.on_success(path)
    elseif download_result == "cancelled" then
        opts.on_cancel()
    else
        opts.on_failure(download_result)
    end
end
CompanionAudio.install(Catalog)

local ebook_path = "/mnt/onboard/Books/Dune - Frank Herbert.epub"
local audio_path = "/mnt/onboard/Books/Dune - Frank Herbert.m4b"

local function offer(file)
    local done = 0
    shown, downloads = {}, {}
    Catalog:offerCompanionAudio(ebook_path, book, file or epub, function() done = done + 1 end)
    return function() drain(); return done end
end

-- Default mode is "ask".
assertEqual(Catalog:companionAudioMode().id, "ask", "default mode asks")
local finish = offer()
drain()
assertEqual(#shown, 1, "ask mode shows a confirmation")
assertContains(shown[1].text, "M4B, 412 MB", "confirmation names the audiobook")
assertContains(shown[1].text, audio_path, "confirmation shows the paired path")
shown[1].ok_callback()
local done_count = finish()
assertEqual(#downloads, 1, "accepting downloads the audiobook")
assertEqual(downloads[1].path, audio_path, "download uses the paired path")
assertEqual(downloads[1].file, m4b, "download uses the audio file")
assertEqual(done_count, 1, "the ebook flow continues once after the audiobook")

-- Skipping continues the ebook flow without downloading.
finish = offer()
drain()
shown[1].cancel_callback()
assertEqual(finish(), 1, "skip continues the ebook flow")
assertEqual(#downloads, 0, "skip downloads nothing")

-- "always" downloads without asking.
Catalog:persistSetting(CompanionAudio.SETTING_KEY, "always")
finish = offer()
assertEqual(finish(), 1, "always mode continues once")
assertEqual(#downloads, 1, "always mode downloads")
for _, widget in ipairs(shown) do
    assertEqual(widget.ok_callback, nil, "always mode does not ask")
end

-- "never" skips silently.
Catalog:persistSetting(CompanionAudio.SETTING_KEY, "never")
finish = offer()
assertEqual(finish(), 1, "never mode continues once")
assertEqual(#downloads, 0, "never mode downloads nothing")
assertEqual(#shown, 0, "never mode shows nothing")

-- Already on the device: nothing to do.
Catalog:persistSetting(CompanionAudio.SETTING_KEY, "always")
existing[audio_path] = true
finish = offer()
assertEqual(finish(), 1, "existing audiobook continues once")
assertEqual(#downloads, 0, "existing audiobook is not downloaded again")
existing[audio_path] = nil

-- Downloading the audio file itself never chains another companion.
finish = offer(m4b)
assertEqual(finish(), 1, "an audio download continues once")
assertEqual(#downloads, 0, "an audio download does not chain")

-- A failed or cancelled audiobook download still continues the ebook flow.
download_result = "network_error"
finish = offer()
assertEqual(finish(), 1, "a failed audiobook download continues once")
assertContains(shown[#shown].text, "could not be downloaded", "failure is reported")
download_result = "cancelled"
finish = offer()
assertEqual(finish(), 1, "a cancelled audiobook download continues once")
download_result = "ok"

-- Book menu ------------------------------------------------------------------

function Catalog:detailReadPath() return ebook_path end
assertEqual(Catalog:companionAudioButtonText(book), "Download audiobook (M4B, 412 MB)", "menu offers the download")
existing[audio_path] = true
assertEqual(Catalog:companionAudioButtonText(book), "Audiobook on device (M4B)", "menu shows it is on the device")
existing[audio_path] = nil
assertEqual(Catalog:companionAudioButtonText({ files = { epub } }), nil, "no audiobook, no menu entry")

shown, downloads = {}, {}
Catalog:downloadCompanionAudioForDetail(book)
drain()
assertEqual(#downloads, 1, "menu action downloads the audiobook")
assertEqual(downloads[1].path, audio_path, "menu action pairs with the ebook on the device")

-- Without the ebook on the device, the audio goes where the ebook would go.
function Catalog:detailReadPath() return nil end
function Catalog:getLocalDownloadPath(name, filetype, device_path)
    return "/mnt/onboard/Books/" .. (device_path or (name .. "." .. filetype))
end
function Catalog:getLocalDownloadPreview(name, filetype, device_path)
    return "/mnt/onboard/Books/Frank Herbert", "Dune"
end
assertEqual(Catalog:companionAudioButtonText(book), "Download audiobook (M4B, 412 MB)", "menu works before the ebook is downloaded")
shown, downloads = {}, {}
Catalog:downloadCompanionAudioForDetail(book)
drain()
assertEqual(downloads[1].path, "/mnt/onboard/Books/Frank Herbert/Dune.m4b", "audio follows the ebook's naming pattern")

-- Mode setting dialog.
shown = {}
local reopened = false
Catalog:showCompanionAudioModeDialog(function() reopened = true end)
shown[1].buttons[3][1].callback()
assertEqual(Catalog:companionAudioMode().id, "never", "mode is persisted")
assertEqual(reopened, true, "settings dialog reopens")

print("bookorbit_companion_audio_test.lua: ok")
