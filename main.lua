VERSION = "2.2.0"

mp.commandv('script-message', 'uosc_danmaku-version', VERSION)

local msg = require('mp.msg')
local utils = require("mp.utils")

AES = require("modules/aes")
Base64 = require("modules/base64")
MD5 = require("modules/md5")
Sha256 = require("modules/hash")

require("modules/options")
require("modules/utils")
require("modules/parse")
require("modules/guess")
require('modules/render')
require('modules/menu')
require("modules/update")

require("apis/dandanplay")
require('apis/extra')

require("sites/bilibili")
require("sites/bahamut")
require("sites/iqiyi")
require("sites/mgtv")
require("sites/tencentvideo")
require("sites/youku")

DANMAKU_PATH = os.getenv("TEMP") or "/tmp/"
HISTORY_PATH = mp.command_native({"expand-path", options.history_path})
PID = utils.getpid()
DANMAKU = {sources = {}, count = 1}
ENABLED, AUTO_MATCHING, FALLBACK_TRIGGER, COMMENTS, DELAY = false, false, false, nil, 0
AUTO_MATCHING_STAGE = "idle"

-- 自动匹配总开关与弹幕显示开关一样写入 history，因而在切换文件或重启
-- mpv 后仍保持用户最后一次选择。没有历史记录时才使用配置文件默认值。
local function read_history_boolean(key, default)
    local history_json = read_file(HISTORY_PATH)
    local history = history_json and (utils.parse_json(history_json) or {}) or {}
    if history[key] == nil then
        history[key] = default == true
        write_json_file(HISTORY_PATH, history)
        return default == true
    end
    return history[key] == true
end

function set_auto_matching_visibility(flag)
    local history_json = read_file(HISTORY_PATH)
    local history = history_json and (utils.parse_json(history_json) or {}) or {}
    history.auto_matching = flag == true
    write_json_file(HISTORY_PATH, history)
end

-- 自动匹配总开关。它只控制新视频是否进行联网自动搜索，不影响本地 XML 自动加载、
-- 弹幕显示开关或手动搜索。
AUTO_MATCHING_SWITCH = read_history_boolean("auto_matching", options.auto_matching ~= false)
if type(update_auto_matching_button) == "function" then
    update_auto_matching_button(AUTO_MATCHING_SWITCH)
end
DELAY_PROPERTY = string.format("user-data/%s/danmaku-delay", mp.get_script_name())
mp.set_property_native(DELAY_PROPERTY, 0)
HAS_DANMAKU = string.format("user-data/%s/has-danmaku", mp.get_script_name())
mp.set_property_bool(HAS_DANMAKU, false)
DANMAKU_SWITCH_ON = string.format("user-data/%s/danmaku-switch-on", mp.get_script_name())
mp.set_property_bool(DANMAKU_SWITCH_ON, false)
DANMAKU_COUNT = string.format("user-data/%s/danmaku-count", mp.get_script_name())
mp.set_property_native(DANMAKU_COUNT, 0)
KEY = table_to_zero_indexed({
    0x00,0x01,0x02,0x03,0x04,
    0x05,0x06,0x07,0x08,0x09,
    0x0a,0x0b,0x0c,0x0d,0x0e,
    0x0f,0x10,0x11,0x12,0x13,
    0x14,0x15,0x16,0x17,0x18,
    0x19,0x1a,0x1b,0x1c,0x1d,
    0x1e,0x1f
})

PLATFORM = (function()
    local platform = mp.get_property_native("platform")
    if platform then
        if itable_index_of({ "windows", "darwin" }, platform) then
            return platform
        end
    else
        if os.getenv("windir") ~= nil then
            return "windows"
        end
        local homedir = os.getenv("HOME")
        if homedir ~= nil and string.sub(homedir, 1, 6) == "/Users" then
            return "darwin"
        end
    end
    return "linux"
end)()

local rebuild_convert_timer = nil
local auto_retry_path = nil
local auto_retry_active = false
local auto_retry_last_title = nil
local auto_retry_timer = nil

-- 自动搜索正在等待标题/视频属性或已有异步请求时，显示开关切换只恢复提示，
-- 不应再次调用 init() 发起重复搜索。
function auto_matching_in_progress()
    return AUTO_MATCHING and COMMENTS == nil and
        (AUTO_MATCHING_STAGE == "matching" or AUTO_MATCHING_STAGE == "loading" or
            auto_retry_active or (type(is_async_running) == "function" and is_async_running()))
end

function auto_matching_status_text()
    if AUTO_MATCHING_STAGE == "loading" then
        return "弹幕加载中..."
    end
    return "自动搜索匹配弹幕中..."
end

-- COMMENTS 可能在一次失败/空结果后被置为空表。只有确实含有弹幕事件时，
-- 才算当前视频已经完成加载；空表不能阻止重新开启自动匹配后的重试。
local function has_loaded_comments()
    return type(COMMENTS) == "table" and #COMMENTS > 0
end

-- 只有在当前视频确实恢复了弹幕源记录，且记录中的每个源都被用户屏蔽时，
-- 才视为“主动禁用弹幕源”，不应把空结果报告为自动匹配失败。
function all_danmaku_sources_blocked()
    local has_sources = false
    for _, source in pairs(DANMAKU.sources or {}) do
        has_sources = true
        if type(source) ~= "table" or not source.blocked then
            return false
        end
    end
    return has_sources
end

-- 自动匹配由独立总开关叠加 auto_load / autoload_for_url 控制，
-- 与弹幕显示开关相互独立。
function auto_matching_enabled(path)
    return AUTO_MATCHING_SWITCH and
        (options.auto_load or (options.autoload_for_url and is_protocol(path)))
end

function get_danmaku_visibility()
    local default_visibility = options.show_danmaku_default == true
    local history_json = read_file(HISTORY_PATH)
    local history
    if history_json ~= nil then
        history = utils.parse_json(history_json) or {}
        local flag = history["show_danmaku"]
        if flag == nil then
            history["show_danmaku"] = default_visibility
            write_json_file(HISTORY_PATH, history)
        else
            return flag == true
        end
    else
        history = {}
        history["show_danmaku"] = default_visibility
        write_json_file(HISTORY_PATH, history)
    end
    return default_visibility
end

function set_danmaku_visibility(flag)
    local history = {}
    local history_json = read_file(HISTORY_PATH)
    if history_json ~= nil then
        history = utils.parse_json(history_json) or {}
    end
    history["show_danmaku"] = flag
    write_json_file(HISTORY_PATH, history)
end

-- 脚本启动时就同步全局显示状态，避免网络资源尚未触发 file-loaded 时按钮暂显示为关闭。
if type(update_danmaku_button) == "function" then
    update_danmaku_button(get_danmaku_visibility())
end

-- 自动匹配过程的状态提示不改变弹幕显示状态。
function show_auto_match_status(text, time)
    if AUTO_MATCHING and AUTO_MATCHING_STAGE ~= "waiting" then
        local status = text
        if AUTO_MATCHING_STAGE == "loading" then
            status = "弹幕加载中..."
        end
        show_message(status, time)
    end
end

-- ENABLED 表示脚本仍需处理弹幕，不等同于“弹幕当前可见”。
-- 自动匹配或已有弹幕时，即使显示开关关闭，也不能阻止后台状态刷新。
function refresh_danmaku_processing_state()
    ENABLED = get_danmaku_visibility() or AUTO_MATCHING or COMMENTS ~= nil
    return ENABLED
end

-- 统一处理弹幕显示开关，避免快捷键和 uosc 控件各自维护一套状态。
-- 开启显示时只在自动匹配允许联网时启动网络请求；已有本地 XML 仍会优先加载。
function set_danmaku_display_state(visible)
    visible = visible == true
    local current = get_danmaku_visibility()
    if current == visible then
        refresh_danmaku_processing_state()
        if not visible and auto_matching_in_progress() then
            show_auto_match_status(auto_matching_status_text(), 30)
        end
        return
    end

    set_danmaku_visibility(visible)
    toggle_danmaku_switch(visible and "on" or "off")

    if visible then
        refresh_danmaku_processing_state()
        if not has_loaded_comments() then
            local path = mp.get_property("path")
            local allow_network = auto_matching_enabled(path)
            local loading = auto_matching_in_progress()
            if loading and AUTO_MATCHING_STAGE ~= "waiting" then
                show_message(auto_matching_status_text(), 30)
            else
                show_message("打开弹幕", 2)
            end
            if not loading then
                init(path, allow_network)
            end
        else
            show_message("打开弹幕", 2)
            show_loaded()
            show_danmaku_func()
        end
    else
        refresh_danmaku_processing_state()
        hide_danmaku_func(true)
        if auto_matching_in_progress() and AUTO_MATCHING_STAGE ~= "waiting" then
            show_message("关闭弹幕\\N" .. auto_matching_status_text(), 30)
        else
            show_message("关闭弹幕", 2)
        end
    end
end

function set_danmaku_button()
    if get_danmaku_visibility() then
        toggle_danmaku_switch("on")
    end
end

function show_loaded(init)
    if not has_loaded_comments() then
        show_message("comments无数据", 3)
        msg.error("comments无数据")
        return
    end
    if DANMAKU.anime and DANMAKU.episode then
        show_message("匹配内容：" .. DANMAKU.anime .. "-" .. DANMAKU.episode .. "\\N弹幕加载成功，共计" .. #COMMENTS .. "条弹幕", 3)
        if init then
            msg.info(DANMAKU.anime .. "-" .. DANMAKU.episode .. " 弹幕加载成功，共计" .. #COMMENTS .. "条弹幕")
        end
    else
        show_message("弹幕加载成功，共计" .. #COMMENTS .. "条弹幕", 3)
    end
    mp.set_property_native(DANMAKU_COUNT, #COMMENTS)
end

-- 获取指定时间的延迟
-- 返回该时间点之前所有延迟段的总和
function get_delay_for_time(delay_segments, time)
    if not delay_segments or #delay_segments == 0 then return 0 end

    local segs = {}
    for i = 1, #delay_segments do segs[i] = delay_segments[i] end
    table.sort(segs, function(a, b) return a.start < b.start end)

    local applied_delay = 0
    for i = 1, #segs do
        local seg = segs[i]
        local delay = tonumber(seg.delay)
        if time >= seg.start and delay then
            applied_delay = applied_delay + delay
        else
            break
        end
    end
    return applied_delay
end

local function merge_delay_segments(segments)
    if not segments or #segments == 0 then return {} end

    local NEAREST_THRESHOLD = 10  -- 最邻近段合并阈值
    local MERGE_THRESHOLD = 30    -- 跨段合并阈值
    local EPSILON = 1e-6          -- 判断接近 0 的阈值

    table.sort(segments, function(a, b) return a.start < b.start end)

    local partially_merged = {}
    local i = 1
    while i <= #segments do
        local cur = segments[i]
        local next_seg = segments[i + 1]

        if next_seg and (next_seg.start - cur.start) <= NEAREST_THRESHOLD then
            local combined_delay = tonumber(cur.delay) + tonumber(next_seg.delay)
            if math.abs(combined_delay) > EPSILON then
                table.insert(partially_merged, {
                    start = cur.start,
                    delay = combined_delay
                })
            end
            i = i + 2
        else
            if math.abs(tonumber(cur.delay)) > EPSILON then
                table.insert(partially_merged, cur)
            end
            i = i + 1
        end
    end

    local merged = {}
    for _, seg in ipairs(partially_merged) do
        local merged_flag = false
        for idx, m in ipairs(merged) do
            if math.abs(seg.start - m.start) <= MERGE_THRESHOLD then
                m.delay = tonumber(m.delay) + tonumber(seg.delay)
                if math.abs(m.delay) <= EPSILON then
                    table.remove(merged, idx)
                end
                merged_flag = true
                break
            end
        end
        if not merged_flag then
            if math.abs(tonumber(seg.delay)) > EPSILON then
                table.insert(merged, {
                    start = seg.start,
                    delay = seg.delay
                })
            end
        end
    end

    table.sort(merged, function(a, b) return a.start < b.start end)
    return merged
end

function parse_delay_input(text)
    if not text then return nil end
    local s = tostring(text):gsub("%s+", "")
    if s == "" then return nil end
    -- XmYs 格式，允许负号在分钟部分
    local m, sec = string.match(s, "^(%-?%d+)m(%d+)s$")
    if m and sec then
        m = tonumber(m)
        sec = tonumber(sec)
        if not m or not sec then return nil end
        if m < 0 then sec = -sec end
        return m * 60 + sec
    end
    -- 普通数字（整数或小数），支持负数
    local n = tonumber(s)
    if n ~= nil then return n end
    return nil
end

local function set_danmaku_delay(dly, time, specific_source)
    if specific_source then
        local source = DANMAKU.sources[specific_source]
        if source and source.data and not source.blocked then
            source.delay_segments = source.delay_segments or {}
            if dly == 0 then
                source.delay_segments = {}
            elseif time then
                table.insert(source.delay_segments, {start = time, delay = dly})
            else
                table.insert(source.delay_segments, {start = 0, delay = dly})
            end
            source.delay = nil
            source.delay_segments = merge_delay_segments(source.delay_segments)
            add_source_to_history(specific_source, source)
        end
    else
        for url, source in pairs(DANMAKU.sources) do
            if source.data and not source.blocked then
                source.delay_segments = source.delay_segments or {}
                if dly == 0 then
                    source.delay_segments = {}
                elseif time then
                    table.insert(source.delay_segments, {start = time, delay = dly})
                else
                    table.insert(source.delay_segments, {start = 0, delay = dly})
                end

                source.delay = nil
                source.delay_segments = merge_delay_segments(source.delay_segments)
                add_source_to_history(url, source)
            end
        end
    end

    if not specific_source then
        if dly == 0 then
            DELAY = 0
        else
            DELAY = DELAY + dly
        end
    end

    if ENABLED and COMMENTS ~= nil then
        if get_danmaku_visibility() then
            render()
        else
            hide_danmaku_func(true)
        end
    end

    -- 防抖：批量重建 ASS 事件并渲染，避免频繁变更导致重复重建
    if rebuild_convert_timer then
        rebuild_convert_timer:kill()
        rebuild_convert_timer = nil
    end
    rebuild_convert_timer = mp.add_timeout(0.1, function()
        if convert_danmaku_to_ass_events then
            convert_danmaku_to_ass_events(true)
        end
        if ENABLED and COMMENTS ~= nil and get_danmaku_visibility() then
            render()
        elseif ENABLED and COMMENTS ~= nil then
            hide_danmaku_func(true)
        end
        rebuild_convert_timer = nil
    end)

    if specific_source then
        local source = DANMAKU.sources[specific_source]
        local source_delay = get_delay_for_time(source and source.delay_segments, time or 0)
        show_message('设置弹幕源延迟: ' .. string.format("%.1f", source_delay + 1e-10) .. ' s')
    else
        show_message('设置弹幕延迟: ' .. string.format("%.1f", DELAY + 1e-10) .. ' s')
        mp.set_property_native(DELAY_PROPERTY, DELAY)
    end
end

local function clear_source()
    local path = mp.get_property("path")
    local history_json = read_file(HISTORY_PATH)

    if not path or not history_json then return end

    local history = utils.parse_json(history_json) or {}
    if history[path] == nil then return end

    history[path] = nil
    write_json_file(HISTORY_PATH, history)

    for url, source in pairs(DANMAKU.sources) do
        if source.from == "user_custom" then
            DANMAKU.sources[url] = nil
        end
    end

    load_danmaku(false)

    show_message("已重置当前视频所有弹幕源更改", 3)
    msg.verbose("已重置当前视频所有弹幕源更改")
end

function write_history(episodeid, api_server)
    local history = {}
    local path = mp.get_property("path")
    local dir = get_parent_directory(path)
    local fname = mp.get_property('filename/no-ext')
    local episodeNumber = 0
    if episodeid then
        episodeNumber = tonumber(episodeid) % 1000
    elseif DANMAKU.extra then
        episodeNumber = DANMAKU.extra.episodenum
    end

    if is_protocol(path) then
        local title, season_num, episod_num = parse_title()
        if title and episod_num then
            if season_num then
                dir = title .." Season".. season_num
            else
                dir = title
            end
            fname = url_decode(mp.get_property("media-title"))
            episodeNumber = episod_num
        end
    end

    if dir ~= nil then
        local history_json = read_file(HISTORY_PATH)
        if history_json ~= nil then
            history = utils.parse_json(history_json) or {}
        end
        history[dir] = {}
        history[dir].fname = fname
        history[dir].source = DANMAKU.source
        history[dir].animeTitle = DANMAKU.anime
        history[dir].episodeTitle = DANMAKU.episode
        history[dir].episodeNumber = episodeNumber
        if episodeid then
            history[dir].episodeId = episodeid
        elseif DANMAKU.extra then
            history[dir].extra = DANMAKU.extra
        end
        if api_server then
            history[dir].api_server = api_server
        end
        write_json_file(HISTORY_PATH, history)
    end
end

function remove_source_from_history(rm_source)
    local history_json = read_file(HISTORY_PATH)
    local path = mp.get_property("path")

    if is_protocol(path) then
        path = remove_query(path)
    end

    if history_json then
        local history = utils.parse_json(history_json) or {}

        if history[path] ~= nil and history[path]["sources"] ~= nil then
            for source in pairs(history[path]["sources"]) do
                if source == rm_source then
                    history[path]["sources"][source] = nil
                    break
                end
            end
        end

        write_json_file(HISTORY_PATH, history)
    end
end

function add_source_to_history(add_url, add_source)
    local history_json = read_file(HISTORY_PATH)
    local path = mp.get_property("path")

    if is_protocol(path) then
        path = remove_query(path)
    end

    local history = {}
    if history_json then
        history = utils.parse_json(history_json) or {}
    end

    history[path] = history[path] or {}
    history[path]["sources"] = history[path]["sources"] or {}
    history[path]["sources"][add_url] = history[path]["sources"][add_url] or {}

    local record = history[path]["sources"][add_url]
    record.from = add_source.from or "user_custom"
    record.blocked = add_source.blocked or false

   local delay_segments = shallow_copy(add_source.delay_segments or {})
    if #delay_segments > 0 then
        record.delay_segments = merge_delay_segments(delay_segments)
        if #record.delay_segments == 0 then
            record.delay_segments = nil
        end
    else
        record.delay_segments = nil
    end

    record.delay = nil
    write_json_file(HISTORY_PATH, history)
end

function read_danmaku_source_record(path)
    if is_protocol(path) then
        path = remove_query(path)
    end

    local history_json = read_file(HISTORY_PATH)
    if not history_json then return end

    local history = utils.parse_json(history_json) or {}
    local record = history[path]

    if not record or not record.sources then return end

    local sources = record.sources
    local upgraded_sources = {}

    if is_nested_table(sources) then
        for source, data in pairs(sources) do
            local from = data.from or "user_custom"
            local blocked = data.blocked or false
            local delay_segments = shallow_copy(data.delay_segments or {})
            if data.delay ~= nil then
                for i = #delay_segments, 1, -1 do
                    if delay_segments[i].start == 0 then
                        table.remove(delay_segments, i)
                    end
                end
                table.insert(delay_segments, 1, { start = 0, delay = tonumber(data.delay) })
            end
            if #delay_segments > 0 then
                delay_segments = merge_delay_segments(delay_segments)
            else
                delay_segments = nil
            end

            DANMAKU.sources[source] = {
                from = from,
                blocked = blocked,
                delay_segments = delay_segments,
                from_history = true,
            }
        end
    else
        for _, raw in ipairs(sources) do
            local source = raw
            local blocked = false
            local from = raw:match("<(.-)>")
            local delay = raw:match("{{(.-)}}")

            source = source:gsub("<.->", ""):gsub("{{.-}}", "")

            if source:match("^%-") then
                source = source:sub(2)
                blocked = true
                from = from or "api_server"
            end

            local delay_segments = nil
            if delay ~= nil then
                delay_segments = {
                    { start = 0, delay = tonumber(delay) }
                }
            end

            DANMAKU.sources[source] = {
                from = from or "user_custom",
                blocked = blocked,
                delay_segments = delay_segments,
                from_history = true,
            }

            upgraded_sources[source] = shallow_copy(DANMAKU.sources[source])
        end

        if next(upgraded_sources) then
            record.sources = upgraded_sources
            write_json_file(HISTORY_PATH, history)
        end
    end
end

-- ISO 文件以及 dvd://、bd:// 等协议媒体没有可写的视频文件位置，
-- 因此使用 save_danmaku_path；普通本地视频按 save_danmaku_local_mode 决定位置。
local function is_iso_media(path)
    if type(path) ~= "string" or is_protocol(path) then return false end
    local clean_path = path:gsub("[?#].*$", "")
    return clean_path:lower():match("%.iso$") ~= nil
end

local function get_custom_danmaku_directory()
    if options.save_danmaku_path == "" then return nil end
    local directory = mp.command_native({"expand-path", options.save_danmaku_path})
    if type(directory) ~= "string" or directory == "" then return nil end
    return directory
end

local function local_danmaku_uses_custom_directory(custom_dir)
    if not custom_dir then return false end
    local mode = tostring(options.save_danmaku_local_mode or "same_dir"):lower()
    return mode == "specified_dir" or mode == "custom_dir" or mode == "custom" or mode == "path"
end

local function get_save_danmaku_output(path, filename)
    if not path or not filename then return nil end

    local is_url = is_protocol(path)
    local is_iso = is_iso_media(path)
    local custom_dir = get_custom_danmaku_directory()
    local needs_custom_dir = is_url or is_iso or local_danmaku_uses_custom_directory(custom_dir)

    if needs_custom_dir then
        -- ISO/光盘/网络资源没有普通文件位置；普通本地视频在未指定目录时回退到同目录。
        if not custom_dir and (is_url or is_iso) then return nil end
        if not custom_dir then needs_custom_dir = false end
    end

    if needs_custom_dir then

        local output_name = sanitize_filename(filename)
        if not is_url then
            local dir = get_parent_directory(path)
            local _, parent_name = dir and utils.split_path(dir:sub(1, -2))
            if parent_name and parent_name ~= "" then
                output_name = sanitize_filename(parent_name .. "_" .. filename)
            end
        end
        return utils.join_path(custom_dir, output_name .. ".xml")
    end

    local dir = get_parent_directory(path)
    if not dir then
        return nil
    end
    return utils.join_path(dir, filename .. ".xml")
end

-- 保存前创建指定目录，支持多级目录；默认视频目录不做额外创建。
local function ensure_danmaku_directory(directory)
    if not directory or directory == "" then return false end
    local info = utils.file_info(directory)
    if info and info.is_dir then return true end

    local args
    if PLATFORM == "windows" then
        local escaped = tostring(directory):gsub("'", "''")
        local command = "[System.IO.Directory]::CreateDirectory('" .. escaped .. "') | Out-Null"
        args = { "powershell", "-NoProfile", "-NonInteractive", "-Command", command }
    else
        args = { "mkdir", "-p", directory }
    end

    local result = mp.command_native({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    })
    info = utils.file_info(directory)
    if not (info and info.is_dir) then
        msg.error("创建弹幕保存目录失败：" .. tostring(directory) .. "，" ..
            tostring(result and (result.stderr or result.stdout) or "未知错误"))
        return false
    end
    return true
end

-- 查找保存过的本地 XML。普通本地视频优先查视频同目录；ISO、光盘和 URL
-- 直接按 get_save_danmaku_output 查询指定目录，避免再次发起网络请求。
-- 文件名必须与当前完整标题对应，不使用标题搜索的逐步缩短候选或归一化扫描。
local function find_saved_danmaku(path, filename)
    if not options.autoload_local_danmaku or not path then return nil end

    local search_filename = filename
    if is_protocol(path) then
        search_filename = mp.get_property("media-title")
    end
    if not search_filename or search_filename == "" then return nil end

    -- 保存和查找始终使用同一个路径决策；指定目录为空时由
    -- get_save_danmaku_output 回退到普通本地视频同目录。
    local saved_xml = get_save_danmaku_output(path, search_filename)
    if saved_xml and file_exists(saved_xml) then return saved_xml end
    return nil
end

local function load_saved_danmaku(path, filename)
    local danmaku_xml = find_saved_danmaku(path, filename)
    if not danmaku_xml then return false end

    ENABLED = true
    msg.info("从本地字幕目录加载弹幕：" .. danmaku_xml)
    add_danmaku_source_local(danmaku_xml)
    return true
end

-- 视频播放时保存弹幕
function save_danmaku(not_forced)
    local path = mp.get_property("path")
    local filename = is_protocol(path) and mp.get_property("media-title") or mp.get_property('filename/no-ext')
    local danmaku_out = get_save_danmaku_output(path, filename)
    local output_dir = danmaku_out and utils.split_path(danmaku_out)
    local custom_dir = options.save_danmaku_path ~= "" and
        mp.command_native({"expand-path", options.save_danmaku_path}) or nil
    local function comparable_directory(value)
        value = tostring(value or ""):gsub("\\", "/"):gsub("/+%s*$", "")
        return PLATFORM == "windows" and value:lower() or value
    end
    local using_custom_dir = custom_dir and output_dir and
        comparable_directory(custom_dir) == comparable_directory(output_dir)
    local directory_ready = not using_custom_dir or ensure_danmaku_directory(output_dir)
    if not danmaku_out or not directory_ready or (not file_exists(danmaku_out)
    and not is_writable(danmaku_out)) then
        show_message("此弹幕文件不支持保存至本地")
        msg.warn("此弹幕文件不支持保存至本地")
    else
        if not_forced and file_exists(danmaku_out) then
            show_message("已存在同名弹幕文件：" .. danmaku_out)
            msg.info("已存在同名弹幕文件：" .. danmaku_out)
            return
        else
            convert_danmaku_to_xml(danmaku_out)
        end
    end
end

-- 加载弹幕
function load_danmaku(from_menu, no_osd, manual_refresh)
    local manual_load = from_menu and not AUTO_MATCHING
    convert_danmaku_to_ass_events()
    if AUTO_MATCHING and not manual_refresh and type(COMMENTS) == "table" then
        AUTO_MATCHING_STAGE = #COMMENTS > 0 and "ready" or "failed"
    end
    -- 部分站点会在请求成功但没有弹幕时直接调用 load_danmaku，未经过
    -- dandanplay 的统一响应处理；自动流程在这里补上统一的未匹配提示。
    if AUTO_MATCHING and not manual_refresh and type(COMMENTS) == "table" and #COMMENTS == 0 then
        mp.commandv("script-message", "auto_load_fallback")
    end
    render_danmaku(from_menu, no_osd, manual_refresh)

    -- 多个手动源并行加载时，先让当前源的“已准备好”提示完整显示；
    -- 提示结束后若仍有其他异步请求，再恢复“弹幕加载中...”状态。
    if manual_load and not no_osd and type(is_async_running) == "function" and is_async_running() then
        mp.add_timeout(3.05, function()
            if not AUTO_MATCHING and is_async_running() then
                show_message("弹幕加载中...", 30)
            end
        end)
    end
end

function load_danmaku_for_url(path)
    local function report_auto_failure(success)
        if not success and AUTO_MATCHING then
            mp.commandv("script-message", "auto_load_fallback")
        end
    end

    if path:find('bilibili.com') or path:find('bilivideo.c[nom]+') then
        if AUTO_MATCHING then
            AUTO_MATCHING_STAGE = "loading"
            show_auto_match_status("弹幕加载中...", 30)
        end
        load_danmaku_for_bilibili(path, report_auto_failure)
        return
    end

    if path:find('bahamut.akamaized.net') then
        if AUTO_MATCHING then
            AUTO_MATCHING_STAGE = "loading"
            show_auto_match_status("弹幕加载中...", 30)
        end
        load_danmaku_for_bahamut(path, report_auto_failure)
        return
    end

    local title, season_num, episod_num = parse_title()
    local filename = url_decode(mp.get_property("media-title")) or title
    local episod_number = nil
    if title and episod_num then
        if season_num then
            dir = title .." Season".. season_num
            episod_number = episod_num
        else
            dir = title
        end
        auto_load_danmaku(path, dir, filename, episod_number)
        addon_danmaku(dir, false)
        return
    end
    get_danmaku_with_hash(filename, path)
    addon_danmaku()
end

local function cancel_auto_match_retry()
    if auto_retry_timer then
        auto_retry_timer:kill()
        auto_retry_timer = nil
    end
end

-- 播放属性可能在 file-loaded 之后才到达，延迟到标题和视频属性可用后再统一搜索。
-- 不区分本地文件、网络资源或任何协议。
local function schedule_auto_match_retry(path, force_start)
    cancel_auto_match_retry()
    local attempts = 0

    local function retry()
        auto_retry_timer = nil
        if not auto_retry_active or auto_retry_path ~= path then return end
        if mp.get_property("path") ~= path or has_loaded_comments() or not auto_matching_enabled(path) then
            auto_retry_active = false
            return
        end

        local title = parse_title()
        local video = mp.get_property_native("current-tracks/video")
        if not title or title == "" or not video or video["image"] or video["albumart"] then
            attempts = attempts + 1
            if attempts < 20 then
                auto_retry_timer = mp.add_timeout(0.5, retry)
            end
            return
        end

        -- 重新开启开关是用户明确要求重新检测当前视频。此时不应被
        -- 关闭期间遗留的异步请求卡住；正常的 file-loaded 重试仍等待
        -- 当前请求完成，避免同一视频在初始化阶段重复发起搜索。
        if is_async_running() and not force_start then
            attempts = attempts + 1
            if attempts < 20 then
                auto_retry_timer = mp.add_timeout(0.5, retry)
            end
            return
        end

        auto_retry_active = false
        ENABLED = true
        init(path)
    end

    auto_retry_timer = mp.add_timeout(0.5, retry)
end

-- 开关重新开启时，对当前无弹幕的视频复用 file-loaded 使用的自动入口。
-- 用户手动打开弹幕时只在自动匹配开关开启时进行联网搜索。
local function start_auto_matching_for_current_file()
    local path = mp.get_property("path")
    -- 只有已经成功解析出弹幕时才跳过；空表表示上一次匹配无结果，
    -- 重新开启自动匹配时仍应允许重试。
    if not path or has_loaded_comments() or not auto_matching_enabled(path) then
        return false
    end

    AUTO_MATCHING = true
    AUTO_MATCHING_STAGE = "matching"
    ENABLED = true
    FALLBACK_TRIGGER = false
    auto_retry_path = path
    auto_retry_last_title = mp.get_property("media-title")
    local title = parse_title()
    local video = mp.get_property_native("current-tracks/video")
    local ready = title and title ~= "" and video and not video["image"] and
        not video["albumart"]

    if ready then
        -- 当前视频已经具备匹配所需属性，立即复用自动匹配入口。
        -- 这里不检查全局异步计数：旧请求不能阻止这次开关重新开启后的检测。
        auto_retry_active = false
        init(path)
    else
        AUTO_MATCHING_STAGE = "waiting"
        auto_retry_active = true
        schedule_auto_match_retry(path, true)
        show_message("自动匹配已开启", 2)
    end
    return true
end

local function set_auto_matching_switch(enabled)
    enabled = enabled == true
    if AUTO_MATCHING_SWITCH == enabled then
        if type(update_auto_matching_button) == "function" then
            update_auto_matching_button(enabled)
        end
        refresh_danmaku_processing_state()
        return
    end

    AUTO_MATCHING_SWITCH = enabled
    set_auto_matching_visibility(enabled)

    if type(update_auto_matching_button) == "function" then
        update_auto_matching_button(enabled)
    end

    if enabled then
        local started = start_auto_matching_for_current_file()
        if not started then
            show_message("自动匹配已开启", 2)
        end
    else
        -- 关闭总开关后立即中断自动搜索、剧集详情和弹幕获取请求；
        -- 尚未执行的重试也一并取消，手动搜索请求不会被登记在此处。
        if type(cancel_auto_matching_requests) == "function" then
            cancel_auto_matching_requests()
        end
        cancel_auto_match_retry()
        auto_retry_active = false
        auto_retry_path = nil
        auto_retry_last_title = nil
        AUTO_MATCHING = false
        AUTO_MATCHING_STAGE = "idle"
        show_message("自动匹配已关闭", 2)
    end
    refresh_danmaku_processing_state()
end

-- 自动加载上次匹配的弹幕
function auto_load_danmaku(path, dir, filename, number)
    if dir ~= nil then
        local history_json = read_file(HISTORY_PATH)
        if history_json ~= nil then
            local history = utils.parse_json(history_json) or {}
            -- 1.判断父文件名是否存在
            local history_dir = history[dir]
            if history_dir ~= nil then
                --2.如果存在，则获取number和id
                DANMAKU.anime = history_dir.animeTitle
                local episode_number = history_dir.episodeTitle and history_dir.episodeTitle:match("%d+")
                local history_number = history_dir.episodeNumber
                local history_id = history_dir.episodeId
                local history_fname = history_dir.fname
                local history_extra = history_dir.extra
                local history_api_server = history_dir.api_server
                local playing_number = nil

                if history_fname then
                    if filename ~= history_fname then
                        if number then
                            playing_number = number
                        else
                            history_number, playing_number = get_episode_number(filename, history_fname)
                        end
                    else
                        playing_number = history_number
                    end
                else
                    playing_number = get_episode_number(filename)
                end
                if playing_number ~= nil then
                    local x = playing_number - history_number --获取集数差值
                    DANMAKU.episode = episode_number and string.format("第%s话", episode_number + x) or history_dir.episodeTitle
                    DANMAKU.api_server = history_api_server or nil
                    show_message("自动加载上次匹配的弹幕", 3)
                    msg.verbose("自动加载上次匹配的弹幕")
                    if history_id then
                        local tmp_id = tostring(x + history_id)
                        set_episode_id(tmp_id)
                    elseif history_extra then
                        local episodenum = history_extra.episodenum + x
                        get_details(history_extra.class, history_extra.id, history_extra.site,
                            history_extra.title, history_extra.year, history_extra.number, episodenum,
                            AUTO_MATCHING)
                    end
                else
                    get_danmaku_with_hash(filename, path)
                end
            else
                get_danmaku_with_hash(filename, path)
            end
        else
            get_danmaku_with_hash(filename, path)
        end
    end
end

function init(path, allow_network)
    if not path then return end
    if allow_network == nil then allow_network = true end
    local dir = get_parent_directory(path)
    local filename = mp.get_property('filename/no-ext')
    local video = mp.get_property_native("current-tracks/video")
    if not video or video["image"] or video["albumart"] then
        msg.info("不支持的播放内容（非视频）")
        return
    end
    if load_saved_danmaku(path, filename) then return end
    if not allow_network then return end
    if AUTO_MATCHING then
        AUTO_MATCHING_STAGE = "matching"
        show_auto_match_status("自动搜索匹配弹幕中...", 30)
    end
    if is_protocol(path) then
        load_danmaku_for_url(path)
    end
    if dir and filename and not is_iso_media(path) then
        local danmaku_xml = get_save_danmaku_output(path, filename)
        if file_exists(danmaku_xml) then
            add_danmaku_source_local(danmaku_xml, true)
        else
            auto_load_danmaku(path, dir, filename)
            addon_danmaku(dir, true)
        end
    end
end

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    local dir = get_parent_directory(path)
    local filename = mp.get_property('filename/no-ext')
    local video = mp.get_property_native("current-tracks/video")
    local fps = mp.get_property_number("container-fps", 0)
    local saved_visibility = get_danmaku_visibility()
    local should_auto_match = auto_matching_enabled(path)
    local should_load_saved_local = options.autoload_local_danmaku == true

    -- 开关状态是全局持久化设置，不随视频切换或 mpv 重启恢复为默认值。
    -- ENABLED 仅表示脚本允许继续加载/处理弹幕；是否显示由 saved_visibility 决定。
    ENABLED = saved_visibility or should_auto_match
    AUTO_MATCHING = should_auto_match
    AUTO_MATCHING_STAGE = should_auto_match and "matching" or "idle"
    toggle_danmaku_switch(saved_visibility and "on" or "off")

    cancel_auto_match_retry()
    auto_retry_active = false
    auto_retry_path = nil
    auto_retry_last_title = nil
    if should_auto_match then
        auto_retry_path = path
        auto_retry_active = true
        auto_retry_last_title = mp.get_property("media-title")
        if not parse_title() or not video or video["image"] or video["albumart"] or fps < 23 then
            AUTO_MATCHING_STAGE = "waiting"
            schedule_auto_match_retry(path)
        end
    end

    if not video or video["image"] or video["albumart"] or fps < 23 then
        return
    end

    read_danmaku_source_record(path)

    -- 本地 XML 查找不受自动匹配总开关影响；开关只控制后续联网搜索。
    -- 普通文件查同目录或指定目录，ISO、光盘和 URL 按保存目录查找。
    if should_load_saved_local and load_saved_danmaku(path, filename) then
        return
    end

    if not should_auto_match then
        return
    end

    if options.autoload_for_url and is_protocol(path) then
        ENABLED = true
        show_auto_match_status("自动搜索匹配弹幕中...", 30)
        load_danmaku_for_url(path)
    end

    if filename == nil or dir == nil then
        -- 没有普通文件目录时仍进入同一个自动标题匹配入口。
        -- 若前面的加载分支已经启动请求，避免重复触发。
        if should_auto_match and not is_async_running() then
            ENABLED = true
            show_auto_match_status("自动搜索匹配弹幕中...", 30)
            init(path)
        end
        return
    end
    if should_auto_match then
        ENABLED = true
        if options.auto_load then
            show_auto_match_status("自动搜索匹配弹幕中...", 30)
            auto_load_danmaku(path, dir, filename)
            addon_danmaku(dir, false)
        else
            show_auto_match_status("自动搜索匹配弹幕中...", 30)
            init(path)
        end
        return
    end

    -- 本地 XML 已在联网搜索前独立处理；自动匹配关闭时到此结束，
    -- 不会因为弹幕显示开关或本地缓存加载而发起网络搜索。
end)

mp.observe_property("media-title", "string", function(_, value)
    if not auto_retry_active or value == auto_retry_last_title then return end
    auto_retry_last_title = value
    if value and value ~= "" then
        schedule_auto_match_retry(auto_retry_path)
    end
end)

-------------- 键位绑定 --------------
mp.add_key_binding(options.open_search_danmaku_menu_key, "open_search_danmaku_menu", function()
    mp.commandv("script-message", "open_search_danmaku_menu")
end)
mp.add_key_binding(options.show_danmaku_keyboard_key, "show_danmaku_keyboard", function()
    mp.commandv("script-message", "show_danmaku_keyboard")
end)
if options.auto_matching_keyboard_key and options.auto_matching_keyboard_key ~= "" then
    mp.add_key_binding(options.auto_matching_keyboard_key, "toggle_auto_matching", function()
        mp.commandv("script-message", "toggle-auto-matching")
    end)
end

-------------- 事件注册 --------------
mp.register_script_message("danmaku-delay", function(...)
    local commands = {...}
    local delay_str, time_str = commands[1], commands[2]
    local source_arg = commands[3]
    local dly = parse_delay_input(delay_str)
    local time = time_str and tonumber(time_str)
    if type(dly) ~= "number" then
        show_message("参数错误：缺少有效的延迟秒数", 3)
        return
    end
    if source_arg and source_arg ~= "nil" then
        set_danmaku_delay(dly, time, source_arg)
    else
        set_danmaku_delay(dly, time)
    end
end)

mp.register_script_message("show_danmaku_keyboard", function()
    set_danmaku_display_state(not get_danmaku_visibility())
end)

mp.register_script_message("toggle-auto-matching", function()
    set_auto_matching_switch(not AUTO_MATCHING_SWITCH)
end)

mp.register_script_message("auto_load_fallback", function()
    if has_loaded_comments() or FALLBACK_TRIGGER then return end

    -- 所有源都被用户屏蔽时，空列表是预期状态，不显示“未匹配到弹幕”。
    if AUTO_MATCHING and all_danmaku_sources_blocked() then
        FALLBACK_TRIGGER = true
        AUTO_MATCHING_STAGE = "failed"
        return
    end

    -- 所有自动匹配路径最终失败时统一提示一次；手动搜索不会触发此消息。
    FALLBACK_TRIGGER = true
    if AUTO_MATCHING then
        AUTO_MATCHING_STAGE = "failed"
    end
    show_message("自动匹配未找到弹幕", 3)
    msg.info("自动加载弹幕失败")

    if options.auto_fallback_search then
        msg.info("自动加载弹幕失败，自动弹出搜索框")
        mp.commandv("script-message", "open_search_danmaku_menu")
    end
end)

mp.register_script_message("check-update", check_for_update)
mp.register_script_message("clear-source", clear_source)
mp.register_script_message("immediately_save_danmaku", save_danmaku)
mp.register_script_message("open_source_delay_menu", open_delay_menu)
mp.register_script_message("open_search_danmaku_menu", open_input_menu)
mp.register_script_message("open_add_source_menu", open_add_menu)
mp.register_script_message("open_add_total_menu", open_add_total_menu)
mp.register_script_message("show_danmaku_count", show_loaded)
