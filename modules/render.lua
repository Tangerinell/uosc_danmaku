-- modified from https://github.com/rkscv/danmaku/blob/main/danmaku.lua
local msg = require('mp.msg')
local utils = require("mp.utils")
local unpack = unpack or table.unpack

local osd_width, osd_height, pause = 0, 0, true
local time_pos_observer_active = false
local overlay_low = mp.create_osd_overlay('ass-events')
local overlay_high = mp.create_osd_overlay('ass-events')

local function danmaku_is_visible()
    -- 主脚本初始化完成后使用共享属性；初始化早期则安全回退到历史状态。
    if DANMAKU_SWITCH_ON then
        return mp.get_property_bool(DANMAKU_SWITCH_ON, false)
    end
    if type(get_danmaku_visibility) == "function" then
        return get_danmaku_visibility()
    end
    return false
end

local function realtime_position_text(event, pos, displayarea)
    if not event.move then
        local _, current_y = unpack(event.pos)
        if not current_y or tonumber(current_y) > displayarea then return end
        if event.style ~= "SP" and event.style ~= "MSG" then
            return string.format("{\\an8}%s", event.text)
        else
            return string.format("{\\an7}%s", event.text)
        end
    end

    local x1, y1, x2, y2 = unpack(event.move)
    -- 计算移动的时间范围
    local duration = event.end_time - event.start_time  --mean: options.scrolltime
    local progress = (pos - event.start_time) / duration  -- 移动进度 [0, 1]

    -- 计算当前坐标
    local current_x = tonumber(x1 + (x2 - x1) * progress)
    local current_y = tonumber(y1 + (y2 - y1) * progress)

    -- 移除 \move 标签并应用当前坐标
    local clean_text = event.text:gsub("\\move%(.-%)", "")
    if current_y > displayarea then return end
    if event.style ~= "SP" and event.style ~= "MSG" then
        return string.format("{\\pos(%.1f,%.1f)\\an8}%s", current_x, current_y, clean_text)
    else
        return string.format("{\\pos(%.1f,%.1f)\\an7}%s", current_x, current_y, clean_text)
    end
end

function render(pos_arg)
    if COMMENTS == nil then return end

    local pos, err
    if pos_arg == nil then
        pos, err = mp.get_property_number('time-pos')
        if err ~= nil then
            return msg.error(err)
        end
    else
        pos = pos_arg
    end

    if not pos then
        overlay_low:remove()
        overlay_high:remove()
        return
    end

    local fontname = options.fontname
    local fontsize = options.fontsize
    local opacity = tonumber(options.opacity)
    local alpha = string.format("%02X", (1 - (opacity or 0)) * 255)

    local width, height = 1920, 1080
    local ratio = osd_width / osd_height
    if width / height < ratio then
        height = width / ratio
        fontsize = options.fontsize - ratio * 2
    end

    local ass_events_low = {}
    local ass_events_high = {}
    local max_display = math.max(options.scrolltime, options.fixtime)
    local window_start = pos - max_display

    -- 跳过已结束的弹幕
    local lo = binary_search(COMMENTS, window_start, function(item) return item.start_time end)

    local re_entity = "&#%d+;"
    local re_fs = "\\fs(%d+)"
    local ass_prefix = string.format("{\\rDefault\\fn%s\\fs%d\\c&HFFFFFF&\\alpha&H%s\\bord%s\\shad%s\\b%s\\q2}",
        fontname, fontsize, alpha, options.outline, options.shadow, options.bold and "1" or "0")

    for i = lo, #COMMENTS do
        local event = COMMENTS[i]
        if not event then break end

        if event.start_time > pos then break end  -- 后续弹幕提前退出
        if event.end_time >= pos then
            local text = realtime_position_text(event, pos, height * options.displayarea)
            if text then
                text = text:gsub(re_entity, "")
            end

            if text and text:match(re_fs) then
                text = text:gsub(re_fs, function(size)
                    local n = tonumber(size) or 0
                    return string.format("\\fs%d", math.floor(n * 1.5))
                end)
            end

            -- 构建 ASS 字符串
            local event_font_prefix = ""
            if event.font_size then
                local configured_size = tonumber(options.fontsize) or fontsize
                local adjusted_size = math.max(1, math.floor(event.font_size + fontsize - configured_size))
                event_font_prefix = string.format("{\\fs%d}", adjusted_size)
            end
            local ass_text = text and (ass_prefix .. event_font_prefix .. text)
            if ass_text then
                if event.layer == nil or tonumber(event.layer) == 0 then
                    table.insert(ass_events_low, ass_text)
                else
                    table.insert(ass_events_high, ass_text)
                end
            end
        end
    end

    -- 写入低层（滚动）和高层（顶/底）overlay，并设置 z 值以控制堆叠
    overlay_low.res_x = width
    overlay_low.res_y = height
    overlay_low.z = 0
    overlay_low.data = table.concat(ass_events_low, '\n')
    overlay_low:update()

    overlay_high.res_x = width
    overlay_high.res_y = height
    overlay_high.z = 1
    overlay_high.data = table.concat(ass_events_high, '\n')
    overlay_high:update()
end

local function time_pos_callback(_, time_pos)
    if time_pos then
        render(time_pos)
    else
        overlay_low:remove()
        overlay_high:remove()
    end
end

local function start_time_observer()
    if not time_pos_observer_active then
        mp.observe_property('time-pos', 'number', time_pos_callback)
        time_pos_observer_active = true
    end
end

local function stop_time_observer()
    if time_pos_observer_active then
        mp.unobserve_property(time_pos_callback)
        time_pos_observer_active = false
    end
end

function render_danmaku(from_menu, no_osd, manual_refresh)
    -- 自动匹配得到的结果不因内部 from_menu 标记而强制显示；显示状态由开关控制。
    -- 手动菜单操作仍可在关闭持久化开关时主动显示结果。
    local manual_display = from_menu and not AUTO_MATCHING and danmaku_is_visible()
    local blocked_only = AUTO_MATCHING and not manual_refresh and
        type(all_danmaku_sources_blocked) == "function" and all_danmaku_sources_blocked()
    if blocked_only and type(COMMENTS) == "table" and #COMMENTS == 0 then
        -- 屏蔽全部已记录源是用户选择，不应留下失败提示或改变显示开关。
        hide_danmaku_func(true)
        show_message("")
        return
    end
    local auto_refresh = AUTO_MATCHING and not manual_refresh and not blocked_only
    local hidden_auto_match = auto_refresh and not danmaku_is_visible()
    local empty_auto_match = auto_refresh and type(COMMENTS) == "table" and #COMMENTS == 0
    local hidden_loaded = not danmaku_is_visible() and
        type(COMMENTS) == "table" and #COMMENTS > 0
    if empty_auto_match then
        -- 自动流程即使把空响应转换成了空事件表，也不能显示成“加载成功 0 条”；
        -- 统一给出未匹配提示，并保持弹幕显示开关原来的状态。
        show_message("自动匹配未找到弹幕", 3)
        hide_danmaku_func(true)
        return
    end
    if ENABLED and (manual_display or danmaku_is_visible()) then
        if not no_osd then
            show_loaded(true)
        end
        toggle_danmaku_switch("on")
        show_danmaku_func()
    else
        -- 弹幕显示关闭时仍保留自动匹配的结果状态，避免 render 的清屏操作
        -- 把“加载中”后的最终结果一并擦掉。弹幕内容为空则明确提示未匹配。
        if hidden_auto_match and type(COMMENTS) == "table" then
            if #COMMENTS > 0 then
                if DANMAKU.anime and DANMAKU.episode then
                    show_message("匹配内容：" .. DANMAKU.anime .. "-" .. DANMAKU.episode ..
                        "\\N弹幕已准备好，共计" .. #COMMENTS .. "条弹幕", 3)
                else
                    show_message("弹幕已准备好，共计" .. #COMMENTS .. "条弹幕", 3)
                end
            else
                show_message("自动匹配未找到弹幕", 3)
            end
        elseif hidden_loaded then
            show_message("弹幕已准备好，共计" .. #COMMENTS .. "条弹幕", 3)
        else
            show_message("")
        end
        hide_danmaku_func()
    end
end

local function filter_state(label, name)
    local filters = mp.get_property_native("vf")
    for _, filter in pairs(filters) do
        if filter.label == label or filter.name == name
        or filter.params[name] ~= nil then
            return true
        end
    end
    return false
end

function show_danmaku_func()
    mp.set_property_bool(HAS_DANMAKU, true)
    set_danmaku_visibility(true)
    render()
    if not pause then
        start_time_observer()
    end
    if options.vf_fps then
        local display_fps = mp.get_property_number('display-fps')
        local video_fps = mp.get_property_number('estimated-vf-fps')
        if (display_fps and display_fps < 58) or (video_fps and video_fps > 58) then
            return
        end
        if not filter_state("danmaku", "fps") then
            mp.commandv("vf", "append", string.format("@danmaku:fps=fps=%s", options.fps))
        end
    end
end

function hide_danmaku_func(preserve_visibility)
    stop_time_observer()
    mp.set_property_bool(HAS_DANMAKU, false)
    if not preserve_visibility then
        set_danmaku_visibility(false)
    end
    overlay_low:remove()
    overlay_high:remove()
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end
end

local message_overlay = mp.create_osd_overlay('ass-events')
local message_timer = mp.add_timeout(3, function()
    message_overlay:remove()
end, true)

function show_message(text, time)
    message_timer.timeout = time or 3
    message_timer:kill()
    message_overlay:remove()
    local message = string.format("{\\an%d\\pos(%d,%d)}%s", options.message_anlignment,
       options.message_x, options.message_y, text)
    local width, height = 1920, 1080
    local ratio = osd_width / osd_height
    if width / height < ratio then
        height = width / ratio
    end
    message_overlay.res_x = width
    message_overlay.res_y = height
    message_overlay.data = message
    message_overlay:update()
    message_timer:resume()
end

mp.observe_property('osd-width', 'number', function(_, value) osd_width = value or osd_width end)
mp.observe_property('osd-height', 'number', function(_, value) osd_height = value or osd_height end)
mp.observe_property('pause', 'bool', function(_, value)
    if value ~= nil then
        pause = value
    end
    local visible = danmaku_is_visible()
    if ENABLED and visible and COMMENTS ~= nil then
        if pause then
            stop_time_observer()
        else
            start_time_observer()
        end
    else
        -- 隐藏弹幕时不能让 pause 观察器重新启动渲染，也要清掉可能残留的 overlay。
        stop_time_observer()
        overlay_low:remove()
        overlay_high:remove()
    end
end)

mp.register_event('playback-restart', function(event)
    if event.error then
        return msg.error(event.error)
    end
    if ENABLED and danmaku_is_visible() and COMMENTS ~= nil then
        render()
    else
        stop_time_observer()
        overlay_low:remove()
        overlay_high:remove()
    end
end)

mp.add_hook("on_unload", 50, function()
    if type(cancel_auto_matching_requests) == "function" then
        cancel_auto_matching_requests()
    end
    AUTO_MATCHING = false
    AUTO_MATCHING_STAGE = "idle"
    FALLBACK_TRIGGER, COMMENTS, DELAY = false, nil, 0
    stop_time_observer()
    overlay_low:remove()
    overlay_high:remove()
    mp.set_property_native(DELAY_PROPERTY, 0)
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end

    local files_to_remove = {
        file1 = utils.join_path(DANMAKU_PATH, "temp-" .. PID .. ".mp4"),
    }

    if options.save_danmaku then
        save_danmaku(true)
    end

    for _, file in pairs(files_to_remove) do
        if file_exists(file) then
            os.remove(file)
        end
    end

    DANMAKU = {sources = {}, count = 1}
    mp.set_property_native(DANMAKU_COUNT, 0)
    mp.set_property_bool(HAS_DANMAKU, false)
end)
