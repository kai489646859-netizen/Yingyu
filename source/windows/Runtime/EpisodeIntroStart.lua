local mp = require "mp"
local preroll

local function playlist_id()
    local position = mp.get_property_number("playlist-pos", -1)
    if position >= 0 then
        return mp.get_property_number("playlist/" .. position .. "/id")
    end
end

mp.add_hook("on_preloaded", 50, function()
    preroll = nil
    local options = mp.get_property_native("options/script-opts", {})
    local target = tonumber(options.yingyu_intro_start)
    if not target or target <= 0 or target >= math.huge then
        return
    end

    local duration = mp.get_property_number("duration", 0)
    local resume = tonumber(mp.get_property("options/start")) or 0
    if mp.get_property_native("seekable") and target > resume
        and (duration <= 0 or target < duration) then
        local format = mp.get_property("file-format")
        -- These demuxers can land on the next keyframe unless they are asked
        -- for a little earlier data. MPV still decodes to the exact target.
        if format == "mpegts" or format == "hls" or format == "disc" then
            local offset_property = "hr-seek-demuxer-offset"
            local previous = mp.get_property_number("options/" .. offset_property)
            local id = playlist_id()
            if id and previous and previous < 1
                and mp.set_property_number("file-local-options/" .. offset_property, 1) then
                preroll = {id = id, previous = previous}
            end
        end
        mp.set_property("file-local-options/start", tostring(target))
    end
end)

mp.register_event("playback-restart", function()
    local pending = preroll
    preroll = nil
    if pending and pending.id == playlist_id()
        and mp.get_property_number("options/hr-seek-demuxer-offset") == 1 then
        mp.set_property_number("file-local-options/hr-seek-demuxer-offset", pending.previous)
    end
end)

mp.set_property("user-data/yingyu-intro-start-ready", "ready")
