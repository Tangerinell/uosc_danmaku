local utils = require 'mp.utils'
local msg = require 'mp.msg'

local cached_series_playlinks = {}

local Source = {
    ["b 站"] = "bilibili1",
    ["芒果TV"] = "imgo",
    ["腾讯"] = "qq",
    ["爱奇艺"] = "qiyi",
    ["优酷"] = "youku",
}

-- 为外部搜索请求增加超时，避免单个源无响应时阻断整个搜索流程。
local function call_async_with_timeout(args, timeout, callback)
    local finished = false
    local cancelled = false
    local timer = nil
    local abort = nil
    local unregister = nil

    local function finish(err, stdout)
        if finished then return end
        finished = true
        if timer then timer:kill(); timer = nil end
        if unregister then unregister(); unregister = nil end
        if cancelled then return end
        callback(err, stdout or "")
    end

    abort = call_cmd_async(args, finish)
    local function cancel()
        if finished then return end
        cancelled = true
        finished = true
        if timer then timer:kill(); timer = nil end
        if unregister then unregister(); unregister = nil end
        if abort then pcall(abort) end
    end
    if AUTO_MATCHING and type(register_auto_matching_request) == "function" then
        unregister = register_auto_matching_request(cancel)
    end
    timer = mp.add_timeout(timeout or 30, function()
        if finished then return end
        if abort then pcall(abort) end
        finish("timeout", "")
    end)

    return cancel
end

local function load_extra_danmaku(url, episode, number, class, id, site, title, year)
    local play_url = nil
    if url:match("^.-%.html") then
        play_url = url:match("^(.-%.html).*")
    elseif url:match("^https?://v%.youku%.com/") and url:match("[?&]vid=") then
        -- 转换 youku 的短链接形式 video?vid=... 到真实播放页 v_show/id_*.html
        local vid = url:match("[?&]vid=([^&]+)")
        if vid then
            play_url = "https://v.youku.com/v_show/id_" .. vid .. ".html"
        else
            play_url = url:gsub("%?bsource=360ogvys$",""):gsub("&.*$","")
        end
    else
        play_url = url:gsub("%?bsource=360ogvys$",""):gsub("&.*$","")
    end

    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episode .. "话"
    DANMAKU.source = site
    DANMAKU.extra = {
        id = id,
        site = site,
        year = year,
        class = class,
        title = title,
        number = tonumber(number),
        episodenum = tonumber(episode),
    }
    write_history()
    add_danmaku_source(play_url, true)
end

local function query_tmdb(title, class, menu)
    local encoded_title = url_encode(title)
    local url = string.format("https://api.tmdb.org/3/search/%s?api_key=%s&query=%s&language=zh-CN",
    class, Base64.decode(options.tmdb_api_key), encoded_title)

    local cmd = {
        "curl",
        "-s",
        "-H", "accept: application/json",
        url
    }

    if options.proxy ~= "" then
        table.insert(cmd, '-x')
        table.insert(cmd, options.proxy)
    end

    local res = mp.command_native({
        name = "subprocess",
        args = cmd,
        capture_stdout = true,
        capture_stderr = true,
    })

    local data = res and utils.parse_json(res.stdout or "") or nil
    if not res or not res.status or res.status ~= 0 or not data or not data.results or #data.results == 0 then
        local message = "获取 tmdb 中文数据失败"
        if uosc_available then
            update_menu_uosc(menu.type, menu.title, message, menu.footnote, menu.cmd, title)
        else
            show_message(message, 3)
        end
        msg.error("获取 tmdb 中文数据失败：" .. tostring(res and res.stdout or ""))
    else
        if class == "tv" then
            return data.results[1].name
        else
            return data.results[1].title
        end
    end
end

-- 异步查询 TMDB，用于非中文标题，避免阻塞 mpv 菜单事件。
local function query_tmdb_async(title, class, callback)
    local encoded_title = url_encode(title)
    local url = string.format("https://api.tmdb.org/3/search/%s?api_key=%s&query=%s&language=zh-CN",
        class, Base64.decode(options.tmdb_api_key), encoded_title)
    local args = make_danmaku_request_args("GET", url)
    call_async_with_timeout(args, 30, function(err, stdout)
        if err then
            callback(nil)
            return
        end
        local data = utils.parse_json(stdout or "")
        if not data or not data.results or #data.results == 0 then
            callback(nil)
            return
        end
        callback(class == "tv" and data.results[1].name or data.results[1].title)
    end)
end

-- 为自动匹配提供与手动搜索相同的 TMDB 中文标题转换。
-- media_type 取 movie 或 tv；未配置有效 key 时直接返回 nil。
function get_tmdb_title_async(title, media_type, callback)
    if options.tmdb_api_key == "" or #Base64.decode(options.tmdb_api_key) < 32 then
        callback(nil)
        return
    end

    local class = media_type == "movie" and "movie" or "tv"
    query_tmdb_async(title, class, callback)
end

-- 从单个 seriesPlaylinks 项解析出有效的播放 URL
local function extract_episode_url(item, playlink)
    if not item then return nil end
    if type(item) == 'string' then
        return playlink or item
    elseif type(item) == 'table' then
        return item.url or nil
    end
    return nil
end

-- 将 seriesPlaylinks 转换为统一的 episode_rows 列表：{ index=string, url=string }
local function build_episode_rows(seriesPlaylinks, playlink)
    if not seriesPlaylinks or type(seriesPlaylinks) ~= 'table' then return nil end
    local rows = {}
    for i, it in ipairs(seriesPlaylinks) do
        local url = extract_episode_url(it, playlink)
        if url and url ~= '' then
            table.insert(rows, { index = tostring(i), url = url })
        end
    end
    if #rows == 0 then return nil end
    return rows
end

local function get_number(cat, id, site)
    local url = string.format("https://api.web.360kan.com/v1/detail?cat=%s&id=%s&site=%s",
        cat, id, site)

    local cmd = { "curl", "-s", url }
    local res = mp.command_native({
        name = "subprocess",
        args = cmd,
        capture_stdout = true,
        capture_stderr = true,
    })

    if not res.status or res.status ~= 0 then
        msg.error("Failed to fetch data: " .. (res.stderr or "unknown error"))
        return nil
    end

    local result = utils.parse_json(res.stdout)
    if result and result.data and result.data.allupinfo then
        return tonumber(result.data.allupinfo[site])
    end
    return nil
end

-- 使用 /v1/detail 分批获取集数（每批最多200集）
local function get_episodes_v1(cat, id, site, number)
    if not number or tonumber(number) == 0 then
        return nil
    end

    local batch_size = 200
    local start_idx = 1
    local episodes = {}
    while start_idx <= tonumber(number) do
        local end_idx = math.min(start_idx + batch_size - 1, tonumber(number))
        local url = string.format("https://api.web.360kan.com/v1/detail?cat=%s&id=%s&start=%s&end=%s&site=%s",
            cat, id, start_idx, end_idx, site)

        local cmd = { "curl", "-s", url }
        local res = mp.command_native({
            name = "subprocess",
            args = cmd,
            capture_stdout = true,
            capture_stderr = true,
        })

        if not res.status or res.status ~= 0 then
            msg.error(string.format("Failed to fetch detail batch %d-%d: %s", start_idx, end_idx, res.stderr or "unknown"))
            if start_idx == 1 then
                return nil
            else
                break
            end
        end

        local result = utils.parse_json(res.stdout)
        if result and result.data and result.data.allepidetail and result.data.allepidetail[site] then
            for _, it in ipairs(result.data.allepidetail[site]) do
                table.insert(episodes, { index = tostring(it.playlink_num), url = it.url })
            end
        end

        start_idx = end_idx + 1
    end

    if #episodes == 0 then
        return nil
    end
    return episodes
end

local function get_episodes_v2(cat, id, site)
    local s_param = string.format('[{"cat_id":"%s","ent_id":"%s","site":"%s"}]', tostring(cat), tostring(id), tostring(site))

    local url = string.format("https://api.so.360kan.com/episodesv2?v_ap=1&s=%s", url_encode(s_param))

    local cmd = { "curl", "-s", url }
    local res = mp.command_native({
        name = "subprocess",
        args = cmd,
        capture_stdout = true,
        capture_stderr = true,
    })

    if not res.status or res.status ~= 0 then
        msg.warn("Failed to fetch episodesv2: " .. (res.stderr or "unknown error"))
        return nil
    end

    local parsed = utils.parse_json(res.stdout)
    if not parsed then
        msg.warn("episodesv2: 解析返回失败: " .. (res.stdout or ""))
        return nil
    end

    local episodes = {}
    if parsed.code == 0 and parsed.data and #parsed.data > 0 then
        local seriesHTML = parsed.data[1] and parsed.data[1].seriesHTML
        if seriesHTML and seriesHTML.seriesPlaylinks then
            local rows = build_episode_rows(seriesHTML.seriesPlaylinks)
            if rows then
                for _, r in ipairs(rows) do
                    table.insert(episodes, { index = tonumber(r.index), url = r.url })
                end
            end
        end
    end

    if #episodes == 0 then
        return nil
    end
    return episodes
end

function get_details(class, id, site, title, year, number, episodenum, auto_select_first)
    local function report_auto_failure()
        if auto_select_first and AUTO_MATCHING then
            mp.commandv("script-message", "auto_load_fallback")
        end
    end

    local message = episodenum and "查询弹幕中..." or "加载数据中..."
    local menu_type = "menu_details"
    local menu_title = "剧集信息"
    local footnote = "使用 / 打开筛选"
    if uosc_available and not episodenum and not auto_select_first then
        update_menu_uosc(menu_type, menu_title, message, footnote, nil, nil, "spinner")
    else
        show_message(message, auto_select_first and AUTO_MATCHING and 30 or 3)
    end

    local cat = 0
    if class == "电影" then
        cat = 1
    elseif class == "电视剧" then
        cat = 2
--  elseif class == "综艺" then
--      cat = 3
    elseif class == "动漫" then
        cat = 4
    end

    local items = {}
    local episodes = nil
    local episode_rows = nil

    -- 优先尝试使用搜索时缓存的 seriesPlaylinks（若存在且站点匹配）
    if cat == 2 or cat == 4 then
        local cid = tostring(id)
        local cached = cached_series_playlinks[cid]
        if cached and cached.seriesPlaylinks and cached.seriesSite and tostring(cached.seriesSite) == tostring(site) then
            local rows = build_episode_rows(cached.seriesPlaylinks, cached.playlink)
            if rows then
                episode_rows = rows
            end
        end
    end

    -- 若未命中缓存，则继续使用 episodesv2/v1 的原有流程
    if not episode_rows then
        if cat == 2 or cat == 4 then
            episodes = get_episodes_v2(cat, id, site)
        end

        -- 统一构建 episode_rows：优先使用 episodesv2 返回的数据，否则使用 v1/detail
        if episodes then
            episode_rows = {}
            for _, ep in ipairs(episodes) do
                table.insert(episode_rows, { index = tostring(ep.index), url = ep.url })
            end
        else
            if not number and cat ~= 0 then
                number = get_number(cat, id, site)
            end
            if not number or cat == 0 then
                local message = "无结果"
                if uosc_available and not episodenum and not auto_select_first then
                    update_menu_uosc(menu_type, menu_title, message, footnote)
                else
                    show_message(message, 3)
                end
                msg.verbose("无结果")
                report_auto_failure()
                return
            end

            episode_rows = get_episodes_v1(cat, id, site, number)
            if not episode_rows or #episode_rows == 0 then
                local message = "无结果"
                if uosc_available and not episodenum and not auto_select_first then
                    update_menu_uosc(menu_type, menu_title, message, footnote)
                else
                    show_message(message, 3)
                end
                msg.verbose("无结果")
                report_auto_failure()
                return
            end
        end
    end

    if episode_rows and #episode_rows > 0 then
        if episodenum then
            for _, ep in ipairs(episode_rows) do
                if tonumber(ep.index) == tonumber(episodenum) then
                    load_extra_danmaku(ep.url, ep.index, number, class, id, site, title, year)
                    return
                end
            end
        end

        -- 自动匹配不能把后台搜索流程切换成手动选集；没有明确集数时直接取第一集。
        -- 若解析出的集数在站点返回列表中不存在，也使用第一集作为可用回退。
        if auto_select_first then
            local first_episode = episode_rows[1]
            if first_episode then
                load_extra_danmaku(first_episode.url, first_episode.index, number, class, id, site, title, year)
                return
            end
        end

        table.insert(items, {
            title = "↩️ 返回搜索结果",
            value = { "script-message-to", mp.get_script_name(), "open-latest-menu-anime" },
            keep_open = false,
            selectable = true,
        })

        for _, ep in ipairs(episode_rows) do
            table.insert(items, {
                title = "第" .. ep.index .. "集",
                hint = ep.index,
                value = {
                    "script-message-to",
                    mp.get_script_name(),
                    "add-extra-event",
                    ep.url, ep.index, tostring(number), class, id, site, title, year
                },
            })
        end
    end
    if #items > 0 then
        if uosc_available and not episodenum and not auto_select_first then
            update_menu_uosc(menu_type, menu_title, items, footnote)
        elseif not episodenum then
            show_message("", 0)
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    else
        local message = "无结果"
        if uosc_available and not episodenum and not auto_select_first then
            update_menu_uosc(menu_type, menu_title, message, footnote)
        else
            show_message(message, 3)
        end
        msg.verbose("无结果")
        report_auto_failure()
    end
end

-- 搜索 360 影视数据并返回可直接放入 uosc 菜单的结果项。
local function search_query(query, class)
    local url = string.format("https://api.so.360kan.com/index?force_v=1&kw=%s", url_encode(query))
    if class ~= nil then
        url = url .. "&type=" .. class
    end
    local cmd = { "curl", "-s", url }

    local res = mp.command_native({
        name = "subprocess",
        args = cmd,
        capture_stdout = true,
        capture_stderr = true,
    })

    if not res or not res.status or res.status ~= 0 then
        msg.debug("360 搜索失败：" .. tostring(class or "all"))
        return {}
    end

    local result = utils.parse_json(res.stdout)
    local items = {}
    local seen = {}
    if result and result.data and result.data.longData and result.data.longData.rows then
        for _, item in ipairs(result.data.longData.rows) do
            if item.playlinks then
                -- 如果搜索结果中包含 seriesPlaylinks，则缓存它（使用 en_id 作为 key）
                if item.seriesPlaylinks and item.en_id then
                    local playlink = nil
                    if item.playlinks and item.seriesSite then
                        playlink = item.playlinks[item.seriesSite]
                    end
                    cached_series_playlinks[tostring(item.en_id)] = {
                        seriesPlaylinks = item.seriesPlaylinks,
                        seriesSite = item.seriesSite,
                        playlink = playlink,
                    }
                end
                for source_name, source_id in pairs(Source) do
                    if item.playlinks[source_id] then
                        local key = table.concat({ tostring(item.cat_name), tostring(item.en_id), source_id }, "\0")
                        if not seen[key] then
                            seen[key] = true
                            table.insert(items, {
                                title = item.titleTxt,
                                hint = item.cat_name .. " | " .. item.year .. " | 来源：" .. source_name,
                                value = {
                                    "script-message-to",
                                    mp.get_script_name(),
                                    "get-extra-event",
                                    item.cat_name, item.en_id, item.playlinks[source_id], source_id,
                                    item.titleTxt, item.year,
                                },
                            })
                        end
                    end
                end
            end
        end
    end
    return items
end

-- 异步搜索单个 360 影视分类，并返回统一菜单项。
local function search_query_async(query, class, callback)
    local url = string.format("https://api.so.360kan.com/index?force_v=1&kw=%s", url_encode(query))
    if class ~= nil then
        url = url .. "&type=" .. class
    end
    local args = make_danmaku_request_args("GET", url)
    call_async_with_timeout(args, 30, function(err, stdout)
        if err then
            msg.debug("360 搜索失败：" .. tostring(class or "all"))
            callback({})
            return
        end

        local result = utils.parse_json(stdout or "")
        local items, seen = {}, {}
        local rows = result and result.data and result.data.longData and result.data.longData.rows
        if rows then
            for _, item in ipairs(rows) do
                if item.playlinks then
                    if item.seriesPlaylinks and item.en_id then
                        local playlink = item.seriesSite and item.playlinks[item.seriesSite] or nil
                        cached_series_playlinks[tostring(item.en_id)] = {
                            seriesPlaylinks = item.seriesPlaylinks,
                            seriesSite = item.seriesSite,
                            playlink = playlink,
                        }
                    end
                    for source_name, source_id in pairs(Source) do
                        if item.playlinks[source_id] then
                            local key = table.concat({ tostring(item.cat_name), tostring(item.en_id), source_id }, "\0")
                            if not seen[key] then
                                seen[key] = true
                                table.insert(items, {
                                    title = item.titleTxt,
                                    hint = item.cat_name .. " | " .. item.year .. " | 来源：" .. source_name,
                                    value = {
                                        "script-message-to", mp.get_script_name(), "get-extra-event",
                                        item.cat_name, item.en_id, item.playlinks[source_id], source_id,
                                        item.titleTxt, item.year,
                                    },
                                })
                            end
                        end
                    end
                end
            end
        end
        callback(items)
    end)
end

local function append_unique_items(target, source, seen)
    for _, item in ipairs(source) do
        local value = item.value or {}
        local key = table.concat({ tostring(value[4]), tostring(value[5]), tostring(value[7]) }, "\0")
        if not seen[key] then
            seen[key] = true
            table.insert(target, item)
        end
    end
end

-- 返回电视剧、电影、国漫三类外部搜索结果，供主搜索菜单统一展示。
function get_extra_search_items_async(name, class, callback)
    local title = nil
    local class = class and class:lower()
    local menu = {
        type = "menu_anime",
        title = "在此处输入视频名称",
        footnote = "使用enter或ctrl+enter进行搜索"
    }
    menu.cmd = { "script-message-to", mp.get_script_name(), "search-anime-event" }

    local items, seen = {}, {}
    local function finish()
        callback(items)
    end
    local function add_results(query, classes, done)
        local remaining = #classes
        if remaining == 0 then done(); return end
        for _, category in ipairs(classes) do
            search_query_async(query, category, function(result)
                append_unique_items(items, result, seen)
                remaining = remaining - 1
                if remaining == 0 then done() end
            end)
        end
    end

    if is_chinese(name) then
        add_results(name, class and { class } or { "ds", "dy", "dm" }, finish)
        return
    end

    if options.tmdb_api_key == "" or #Base64.decode(options.tmdb_api_key) < 32 then
        msg.info("未配置 tmdb_api_key，跳过非中文的外部影视搜索")
        finish()
        return
    end

    if class then
        query_tmdb_async(name, class == "dy" and "movie" or "tv", function(tmdb_title)
            if tmdb_title then add_results(tmdb_title, { class }, finish) else finish() end
        end)
        return
    end

    local pending = 2
    local movie_title, tv_title
    local function tmdb_done()
        pending = pending - 1
        if pending > 0 then return end
        if movie_title then
            add_results(movie_title, { "dy" }, function()
                if tv_title then add_results(tv_title, { "ds", "dm" }, finish) else finish() end
            end)
        elseif tv_title then
            add_results(tv_title, { "ds", "dm" }, finish)
        else
            finish()
        end
    end
    query_tmdb_async(name, "movie", function(value) movie_title = value; tmdb_done() end)
    query_tmdb_async(name, "tv", function(value) tv_title = value; tmdb_done() end)
end

mp.register_script_message("get-extra-event", function(cat, id, playlink, source_id, title, year, auto_matching, auto_episode_num)
    -- 后台自动匹配会传入第 7 个参数，保留自动流程的状态；普通菜单
    -- 点击没有该参数，仍按手动操作处理。
    local is_auto = auto_matching == true or tostring(auto_matching):lower() == "true"
    if not is_auto then
        AUTO_MATCHING = false
    end
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end
    if cat == "电影" then
        if playlink:match("^.-%.html") then
            playlink = playlink:match("^(.-%.html).*")
        else
            playlink = playlink:gsub("%?bsource=360ogvys$","")
        end
        DANMAKU.anime = title .. " (" .. year .. ")"
        DANMAKU.episode = "电影"
        DANMAKU.source = source_id
        write_history()
        add_danmaku_source(playlink, true)
    else
        local episode_num = auto_episode_num and auto_episode_num ~= "" and auto_episode_num or nil
        get_details(cat, id, source_id, title, year, nil, episode_num, is_auto)
    end
end)

mp.register_script_message("add-extra-event", function(url, episode, number, class, id, site, title, year)
    AUTO_MATCHING = false
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_extra_danmaku(url, episode, number, class, id, site, title, year)
end)
