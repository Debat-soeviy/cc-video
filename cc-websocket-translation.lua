local args = {...}
local arg1, arg2 = table.unpack(args)
local CONFIG_FILE = "monitors.cfg"

local allMonitors = { peripheral.find("monitor") }
if #allMonitors < 4 then
    error("Connect at least 4 monitors! Found: " .. #allMonitors)
end

local function calibrateMonitors()
    local order = { "tl", "tr", "bl", "br" }
    local names = {
        tl = "TOP LEFT (1/4)",
        tr = "TOP RIGHT (2/4)",
        bl = "BOTTOM LEFT (3/4)",
        br = "BOTTOM RIGHT (4/4)"
    }
    local mapped = {}
    local used = {}

    for _, m in ipairs(allMonitors) do
        m.setBackgroundColor(colors.blue)
        m.setTextColor(colors.white)
        m.setTextScale(1)
        m.clear()
        m.setCursorPos(2, 2)
        m.write("Right-click the screen...")
    end

    for _, key in ipairs(order) do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== MONITOR CALIBRATION ===")
        print("Right-click in-game on screen:")
        print(">> " .. names[key])

        while true do
            local _, side = os.pullEvent("monitor_touch")
            if not used[side] then
                used[side] = true
                mapped[key] = side
                local m = peripheral.wrap(side)
                m.setBackgroundColor(colors.green)
                m.clear()
                m.setCursorPos(2, 2)
                m.write("OK: " .. key:upper())
                break
            end
        end
    end

    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize(mapped))
    f.close()
    sleep(0.5)
    return mapped
end

local function loadMonitors()
    if arg1 == "reset" or not fs.exists(CONFIG_FILE) then
        return calibrateMonitors()
    end
    local f = fs.open(CONFIG_FILE, "r")
    local data = textutils.unserialize(f.readAll())
    f.close()
    if not data or not data.tl or not data.tr or not data.bl or not data.br then
        return calibrateMonitors()
    end
    return data
end

local monNames = loadMonitors()
local mons = {
    tl = peripheral.wrap(monNames.tl),
    tr = peripheral.wrap(monNames.tr),
    bl = peripheral.wrap(monNames.bl),
    br = peripheral.wrap(monNames.br)
}

for _, m in pairs(mons) do
    m.setBackgroundColor(colors.black)
    m.setTextColor(colors.white)
    m.setTextScale(0.5)
    m.clear()
end

local speakers = { peripheral.find("speaker") }
local dfpwm = require("cc.audio.dfpwm")

local VIDEO_URL = (arg1 ~= "reset") and arg1 or nil
if not VIDEO_URL or VIDEO_URL == "" then
    term.clear()
    term.setCursorPos(1, 1)
    write("Enter video URL (.nfv): ")
    VIDEO_URL = read()
end

local AUDIO_URL = (arg1 ~= "reset") and arg2 or nil
if not AUDIO_URL then
    write("Enter audio URL (.dfpwm) [Enter - skip]: ")
    AUDIO_URL = read()
end

-- Потоковое чтение любого большого файла кусками по 8 МБ (обход Response is too large)
local function createChunkedStream(url, isBinary)
    local offset = 0
    local chunkSize = 8 * 1024 * 1024 -- 8 МБ за один запрос
    local buffer = ""
    local eof = false

    local function fetchNext()
        if eof then return false end
        local headers = { ["Range"] = ("bytes=%d-%d"):format(offset, offset + chunkSize - 1) }
        local res, err = http.get(url, headers, isBinary)
        if not res then
            if offset == 0 then error("Download error: " .. tostring(err)) end
            eof = true
            return false
        end
        local code = res.getResponseCode()
        local data = res.readAll()
        res.close()

        if not data or #data == 0 or code == 416 then
            eof = true
            return false
        end
        buffer = buffer .. data
        offset = offset + #data
        if #data < chunkSize then eof = true end
        return true
    end

    return {
        readLine = function()
            while true do
                local nl = buffer:find("\n", 1, true)
                if nl then
                    local line = buffer:sub(1, nl - 1):gsub("\r$", "")
                    buffer = buffer:sub(nl + 1)
                    return line
                end
                if not fetchNext() then
                    if #buffer > 0 then
                        local line = buffer:gsub("\r$", "")
                        buffer = ""
                        return line
                    end
                    return nil
                end
            end
        end,
        read = function(bytes)
            while #buffer < bytes and fetchNext() do end
            if #buffer == 0 then return nil end
            local out = buffer:sub(1, bytes)
            buffer = buffer:sub(bytes + 1)
            return out
        end
    }
end

local function playVideo()
    local stream = createChunkedStream(VIDEO_URL, false)
    local header = stream.readLine()
    if not header then error("Video file is empty or invalid URL") end

    local width, height, fps = header:match("(%d+) (%d+) (%d+)")
    width, height, fps = tonumber(width), tonumber(height), tonumber(fps)

    local halfW = math.floor(width / 2)
    local halfH = math.floor(height / 2)
    local frameDelay = 1 / (fps or 10)

    while true do
        local startTime = os.clock()
        for y = 1, height do
            local line = stream.readLine()
            if not line then return end

            local isTop = y <= halfH
            local localY = isTop and y or (y - halfH)
            local leftMon = isTop and mons.tl or mons.bl
            local rightMon = isTop and mons.tr or mons.br

            local text, fg, bg = line:match("([^|]+)|([^|]+)|([^|]+)")
            if text and fg and bg then
                leftMon.setCursorPos(1, localY)
                leftMon.blit(text:sub(1, halfW), fg:sub(1, halfW), bg:sub(1, halfW))
                rightMon.setCursorPos(1, localY)
                rightMon.blit(text:sub(halfW + 1, width), fg:sub(halfW + 1, width), bg:sub(halfW + 1, width))
            else
                leftMon.setCursorPos(1, localY)
                leftMon.write(line:sub(1, halfW))
                rightMon.setCursorPos(1, localY)
                rightMon.write(line:sub(halfW + 1, width))
            end
        end

        local elapsed = os.clock() - startTime
        local sleepTime = frameDelay - elapsed
        sleep(sleepTime > 0 and sleepTime or 0.05)
    end
end

local function playAudio()
    if not AUDIO_URL or AUDIO_URL == "" or #speakers == 0 then return end
    local stream = createChunkedStream(AUDIO_URL, true)
    local decoder = dfpwm.make_decoder()

    while true do
        local chunk = stream.read(6 * 1024)
        if not chunk then break end
        local buffer = decoder(chunk)

        for i, spk in ipairs(speakers) do
            while not spk.playAudio(buffer, 3.0) do
                if i == 1 then
                    os.pullEvent("speaker_audio_empty")
                else
                    sleep(0.05)
                end
            end
        end
    end
end

print("Starting video on 4 screens...")
parallel.waitForAll(playVideo, playAudio)
for _, m in pairs(mons) do m.clear() end
print("Playback finished.")
