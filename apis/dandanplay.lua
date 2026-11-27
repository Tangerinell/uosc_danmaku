local msg = require('mp.msg')
local utils = require("mp.utils")
local unpack = unpack or table.unpack

-- 提前声明，供 match_episode 在函数定义之前引用。
local classify_search_result_type

-- 光盘/镜像媒体不适合先做哈希探测：镜像体积大、哈希通常不在弹弹库中，
-- 且标题搜索本来就能稳定匹配。
local function is_disc_media_path(path)
    if type(path) ~= "string" or path == "" then return false end
    local lower = path:lower()
    return lower:match("%.iso$") ~= nil
        or lower:find("bd://", 1, true) ~= nil
        or lower:find("dvd://", 1, true) ~= nil
        or lower:find("bluray://", 1, true) ~= nil
        or lower:find("dvdread://", 1, true) ~= nil
        or lower:find("[/\\]bdmv[/\\]", 1, true) ~= nil
        or lower:find("[/\\]video_ts[/\\]", 1, true) ~= nil
end

local function extract_url(url)
    local path = url:match("^https?://[^/]+(/[^%?]*)")
    return path
end

local function generateXSignature(url, time, appid, app_accept)
    local url_path = extract_url(url)
    if not url_path then
        return nil
    end

    local dataToHash = string.format("%s%d%s%s", AES.ECB.decrypt(KEY, Base64.decode(appid)),
    time, url_path, AES.ECB.decrypt(KEY, Base64.decode(app_accept)))
    local hash = Sha256(dataToHash)
    local base64Hash = Base64.encode(hex_to_bin(hash))
    return base64Hash
end

-- 写入history.json
-- 读取episodeId获取danmaku
function set_episode_id(input, from_menu, api_server)
    from_menu = from_menu or false
    DANMAKU.source = "dandanplay"
    local selected_server = api_server
    if not from_menu then
        for url, source in pairs(DANMAKU.sources) do
            if source.from == "api_server" then
                if not source.from_history then
                    DANMAKU.sources[url] = nil
                else
                    DANMAKU.sources[url]["data"] = nil
                end
            end
        end
    end

    if not api_server then
        if DANMAKU.api_server ~= nil then
            selected_server = DANMAKU.api_server
        else
            local servers = get_api_server_list(options.api_server)
            if servers and #servers > 0 then
                selected_server = servers[1]
            end
        end
    end

    DANMAKU.api_server = selected_server

    local episodeId = tonumber(input)
    write_history(episodeId, selected_server)
    set_danmaku_button()
    fetch_danmaku(episodeId, from_menu, selected_server)
end

-- 回退使用额外的弹幕获取方式
function get_danmaku_fallback(query)
    if AUTO_MATCHING then
        AUTO_MATCHING_STAGE = "loading"
    end
    local function report_auto_failure()
        if AUTO_MATCHING then
            mp.commandv("script-message", "auto_load_fallback")
        end
    end

    local function do_fallback()
        if options.fallback_server == "" then
            report_auto_failure()
            return
        end
        local url = options.fallback_server .. "/?ac=dm&url=" .. query
        msg.verbose("尝试获取弹幕：" .. url)

        local args = make_danmaku_request_args("GET", url)
        if not args then
            report_auto_failure()
            return
        end

        show_message("弹幕加载中...", 30)

        fetch_danmaku_data(args, function(data)
            if data ~= nil and data["xml"] ~= nil then
                if DANMAKU.sources[query] ~= nil then
                    DANMAKU.sources[query]["data"] = data["xml"]
                else
                    DANMAKU.sources[query] = {from = "user_custom", data = data["xml"]}
                end
                load_danmaku(true)
                return
            end

            if not data or not data["comments"] or data["count"] <= 1 then
                msg.info("备用服务器无数据或返回格式不正确")
                show_message("备用服务器无数据或返回格式不正确", 3)
                report_auto_failure()
                return
            end

            save_danmaku_data(data["comments"], query, "user_custom")
            load_danmaku(true)
        end)
    end

    if query:find('bilibili.com') or query:find('bilivideo.c[nom]+') then
        load_danmaku_for_bilibili(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('bahamut.akamaized.net') then
        load_danmaku_for_bahamut(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('mgtv.com') then
        load_danmaku_for_mgtv(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('iqiyi.com') then
        load_danmaku_for_iqiyi(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('v.qq.com') then
        load_danmaku_for_tencent(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    if query:find('v.youku.com') then
        load_danmaku_for_youku(query, function(success)
            if not success then do_fallback() end
        end)
        return
    end

    do_fallback()
end

-- 返回弹幕请求参数
function make_danmaku_request_args(method, url, headers, body)
    local args = {
        "curl",
        "--ssl-no-revoke",
        "-L",
        "-X",
        method,
        "-H",
        "Accept: application/json",
        "-H",
        "User-Agent: " .. options.user_agent,
    }

    if headers then
        for k, v in pairs(headers) do
            table.insert(args, '-H')
            table.insert(args, string.format('%s: %s', k, v))
        end
    end

    if body then
        table.insert(args, '-d')
        table.insert(args, utils.format_json(body))
        table.insert(args, '-H')
        table.insert(args, 'Content-Type: application/json')
    end

    table.insert(args, '--compressed')

    if url:find("api%.dandanplay%.") then
        local time = os.time()
        local appid = "UgjRIH45lE1BBLNmir1WKw=="
        local app_accept = "SzuWlFZAPRMqeWf9qmfp8dcvYr3hvxuSrIRZuAeEfko="
        table.insert(args, '-H')
        table.insert(args, string.format('X-AppId: %s', AES.ECB.decrypt(KEY, Base64.decode(appid))))
        table.insert(args, '-H')
        table.insert(args, string.format('X-Signature: %s', generateXSignature(url, time, appid, app_accept)))
        table.insert(args, '-H')
        table.insert(args, string.format('X-Timestamp: %s', time))
    end

    if options.proxy ~= "" then
        table.insert(args, '-x')
        table.insert(args, options.proxy)
    end

    table.insert(args, url)

    return args
end

local function normalize_danmaku_response(d)
    if not d then return d end
    -- 已经是 comments/count 格式则直接返回
    if d.comments or d.count then return d end

    if d.danmuku and type(d.danmuku) == "table" then
        local out = {}
        for _, item in ipairs(d.danmuku) do
            -- item 预期为数组，索引: 1=time, 2=pos(right/top/bottom), 3=color(hex), 5=content
            local time = tonumber(item[1]) or 0
            local pos = item[2] or "right"
            local color = item[3] or ""
            local content = item[5] or item[4] or ""

            local mode = 1
            if pos == "right" then
                mode = 1
            elseif pos == "top" then
                mode = 4
            elseif pos == "bottom" then
                mode = 5
            end

            local colorDec = 16777215
            if type(color) == "number" then
                colorDec = color
            elseif type(color) == "string" then
                colorDec = hex_to_int_color(color)
            end

            local p = string.format("%.2f,%d,%d", time, mode, colorDec)
            table.insert(out, { p = p, m = content })
        end
        return { comments = out, count = tonumber(d.danum) or #out }
    end

    return d
end

-- 尝试通过解析文件名匹配剧集
local function match_episode(animeTitle, bangumiId, episode_num, api_server, result_type)
    local url = api_server .. "/api/v2/bangumi/" .. bangumiId
    local args = make_danmaku_request_args("GET", url)

    if args == nil then
        if AUTO_MATCHING then
            mp.commandv("script-message", "auto_load_fallback")
        end
        return
    end

    call_cmd_async(args, function(error, json)
        if error then
            show_message("HTTP 请求失败，打开控制台查看详情", 5)
            msg.error(error)
            if AUTO_MATCHING then
                mp.commandv("script-message", "auto_load_fallback")
            end
            return
        end

        local data = utils.parse_json(json)
        if not data or not data.bangumi or not data.bangumi.episodes then
            msg.info("无结果")
            if AUTO_MATCHING then
                mp.commandv("script-message", "auto_load_fallback")
            end
            return
        end

        if result_type ~= "series" and result_type ~= "movie" then
            result_type = classify_search_result_type(nil, nil, result_type)
        end

        local numeric_count = 0
        for _, episode in ipairs(data.bangumi.episodes) do
            if tonumber(episode.episodeNumber) then
                numeric_count = numeric_count + 1
            end
        end
        -- 类型未知时，用“是否有多条带数字的剧集记录”推断是否为连续剧。
        if not result_type and numeric_count > 1 then
            result_type = "series"
        end

        -- 标题没有集数、目录没有历史、且确认是多集剧集时，不再默认选择第一集。
        if not episode_num and result_type == "series" and numeric_count > 1
            and auto_match_episode_unknown() then
            local action = get_auto_match_ambiguous_action()
            if action == "menu" then
                enter_auto_match_episode_menu()
                mp.commandv("script-message", "search-episodes-event",
                    animeTitle, tostring(bangumiId), api_server)
                return
            elseif action == "skip" then
                finish_auto_match_ambiguous()
                return
            end
        end

        local matched_episode = nil
        local first_episode = data.bangumi.episodes[1]
        for _, episode in ipairs(data.bangumi.episodes) do
            local ep_num = tonumber(episode.episodeNumber)
            if episode_num and ep_num and ep_num == tonumber(episode_num) then
                matched_episode = episode
                break
            elseif not episode_num and ep_num and not matched_episode then
                -- 电影没有单集歧义，优先选择第一条带数字集数的记录。
                matched_episode = episode
            end
        end
        if not episode_num and not matched_episode then
            matched_episode = first_episode
        end
        if matched_episode then
            DANMAKU.anime = animeTitle
            DANMAKU.episode = matched_episode.episodeTitle
            set_episode_id(matched_episode.episodeId, nil, api_server)
        elseif AUTO_MATCHING then
            -- 标题存在但没有可用集数时也要结束自动流程并提示，避免隐藏
            -- 弹幕状态下看起来像一直没有响应。
            mp.commandv("script-message", "auto_load_fallback")
        end
    end)
end

-- 规范化自动匹配用的标题，兼容 360 搜索结果中的年份和季数后缀。
local function normalize_auto_match_title(value)
    local title = tostring(value or "")
    title = title:gsub("（", "("):gsub("）", ")")
    title = title:gsub("^%s*(.-)%s*$", "%1")
    title = title:gsub("%s*第%s*[一二三四五六七八九十百千万%d]+[季部]%s*$", "")
    title = title:gsub("%s*[sS]%d+%s*$", "")
    return title:gsub("^%s*(.-)%s*$", "%1")
end

-- 只从搜索结果自身提供的分类/类型描述判断是否为剧集，避免把标题文字
-- 当成类型。返回 nil 表示类型未知，未知类型仍按原有候选顺序处理。
function classify_search_result_type(category, description, type_value)
    local category_text = tostring(category or "")
    local description_text = tostring(description or "")
    local type_text = tostring(type_value or "")
    local text = (category_text .. " " .. description_text .. " " .. type_text):lower()

    -- 电影优先判定，避免“动画电影”等描述被识别为剧集。
    if category_text == "电影" or text:find("电影", 1, true)
        or text:find("movie", 1, true) or text:find("film", 1, true)
        or text:find("theatrical", 1, true) or text:find("剧场版", 1, true) then
        return "movie"
    end

    if category_text == "电视剧" or category_text == "动漫" or category_text == "综艺"
        or text:find("电视剧", 1, true) or text:find("连续剧", 1, true)
        or text:find("番剧", 1, true) or text:find("tv", 1, true)
        or text:find("series", 1, true) or text:find("anime", 1, true)
        or text:find("动画", 1, true) or text:find("动漫", 1, true)
        or text:find("ova", 1, true) or text:find("ona", 1, true) then
        return "series"
    end

    return nil
end

-- 弹弹 Play 没有结果时，自动尝试统一外部搜索源。
local function match_extra_anime(title, season_num, episode_num, callback)
    if type(get_extra_search_items_async) ~= "function" then
        callback(false)
        return
    end

    local target_title = normalize_auto_match_title(title)
    if target_title == "" then
        callback(false)
        return
    end

    get_extra_search_items_async(title, nil, function(items)
        local candidates = {}
        local series_candidates = {}
        for _, item in ipairs(items or {}) do
            local value = item and item.value
            if type(value) == "table" and value[1] == "script-message-to" and
                value[3] == "get-extra-event" then
                local candidate_title = normalize_auto_match_title(value[8] or item.title)
                if candidate_title ~= "" then
                    local score = jaro_winkler(target_title, candidate_title)
                    if candidate_title == target_title then score = 1 end
                    if score >= 0.75 then
                        local source_priority = {
                            bilibili1 = 1,
                            imgo = 2,
                            qq = 3,
                            qiyi = 4,
                            youku = 5,
                        }
                        table.insert(candidates, {
                            value = value,
                            score = score,
                            priority = source_priority[tostring(value[7] or "")] or 99,
                        })
                        if classify_search_result_type(value[4], item.hint) == "series" then
                            table.insert(series_candidates, candidates[#candidates])
                        end
                    end
                end
            end
        end

        local ranked_candidates = episode_num and #series_candidates > 0 and series_candidates or candidates
        table.sort(ranked_candidates, function(a, b)
            if a.score == b.score then return a.priority < b.priority end
            return a.score > b.score
        end)

        local best = ranked_candidates[1]
        if not best then
            callback(false)
            return
        end

        local value = best.value
        local category, id, source_id = value[4], value[5], value[7]
        local result_title, year = value[8], value[9]
        msg.info(("外部源自动匹配：%s（相似度 %.2f）"):format(tostring(result_title), best.score))

        if category == "电影" then
            -- 复用已有的外部电影处理逻辑，直接加载播放页弹幕。
            -- 必须显式标记为自动操作，否则会弹出“弹幕源添加成功”的手动菜单。
            local auto_value = {}
            for i, arg in ipairs(value) do auto_value[i] = arg end
            auto_value[#auto_value + 1] = "true"
            auto_value[#auto_value + 1] = ""
            auto_value[#auto_value + 1] = ""
            mp.commandv(unpack(auto_value))
        else
            -- 外部剧集按当前媒体集数加载；无集数时由 get_details 根据歧义策略处理。
            local ambiguous_action = nil
            if not episode_num and auto_match_episode_unknown() then
                ambiguous_action = get_auto_match_ambiguous_action()
                if ambiguous_action == "menu" then
                    enter_auto_match_episode_menu()
                end
            end
            get_details(category, id, source_id, result_title, year, nil, episode_num, true, ambiguous_action)
        end
        callback(true)
    end)
end

-- 直接查询弹弹 Play 的标题匹配，作为后台统一搜索失败时的兜底。
local function match_anime_by_title()
    local title, season_num, episode_num = parse_title()
    if not title then
        mp.commandv("script-message", "auto_load_fallback")
        msg.error("无法解析媒体标题")
        return
    end

    local function search_with_title(search_title)
        -- 并发搜索多个 api_server，汇总候选后统一选择最佳匹配
        local encoded_query = url_encode(search_title)
        local servers = get_api_server_list(options.api_server)

        local matched = false
        local cancel_fn = nil
        local candidates = {}
        local candidate_seen = {}

        local function build_args(server)
            local url = server .. "/api/v2/search/anime"
            local full_url = url .. "?keyword=" .. encoded_query
            return make_danmaku_request_args("GET", full_url)
        end

        local function per_response(server, err, out)
            if matched then return end
            if err then
                msg.debug(("search anime failed for %s: %s"):format(server, tostring(err)))
                return
            end
            local data = utils.parse_json(out)
            if not data or not data.animes then
                return
            end
            for _, anime in ipairs(data.animes) do
                local key = anime.bangumiId or anime.animeTitle
                if key and not candidate_seen[tostring(key)] then
                    candidate_seen[tostring(key)] = true
                    table.insert(candidates, {
                        anime = anime,
                        server = server,
                        result_type = classify_search_result_type(nil, anime.typeDescription, anime.type),
                    })
                end
            end
        end

        local function final_cb()
            if matched then return end

            local best_match, best_server, best_score = nil, nil, -1
            local target_title = search_title
            if season_num and tonumber(season_num) > 1 then
                target_title = search_title .. " 第" .. number_to_chinese(season_num) .. "季"
            end
            local scoring_candidates = candidates
            if episode_num then
                local series_candidates = {}
                for _, candidate in ipairs(candidates) do
                    if candidate.result_type == "series" then
                        table.insert(series_candidates, candidate)
                    end
                end
                if #series_candidates > 0 then
                    scoring_candidates = series_candidates
                end
            end

            for _, candidate in ipairs(scoring_candidates) do
                local anime = candidate.anime
                local anime_title = tostring(anime.animeTitle or "")
                anime_title = anime_title:gsub("^%s*(.-)%s*$", "%1")
                    :gsub("%s*%(.-%)%s*$", "")
                    :gsub("%s*（.-）%s*$", "")
                    :gsub("%s*【.-】.*$", "")
                local candidate_target = target_title
                if season_num and anime_title:match("第一[季部]") and tonumber(season_num) == 1 then
                    candidate_target = search_title .. " 第一季"
                end
                local score = jaro_winkler(candidate_target, anime_title)
                msg.debug(("候选: %s -> 相似度 %.3f"):format(anime_title, score))
                if score > best_score then
                    best_score = score
                    best_match = anime
                    best_server = candidate.server
                end
            end

            -- 英文标题可能对应中文条目，文字相似度本身会很低；当接口只返回
            -- 一个候选时，直接采用该语义搜索结果。
            local unique_non_chinese_match = not is_chinese(title) and #candidates == 1
            if best_match and (best_score >= 0.75 or unique_non_chinese_match) then
                matched = true
                msg.info(("模糊匹配选中: %s (score=%.2f)"):format(best_match.animeTitle, best_score))
                match_episode(best_match.animeTitle, best_match.bangumiId, episode_num, best_server,
                    classify_search_result_type(nil, best_match.typeDescription, best_match.type))
                if cancel_fn then pcall(cancel_fn) end
                return
            end

            match_extra_anime(title, season_num, episode_num, function(extra_matched)
                if not extra_matched then
                    mp.commandv("script-message", "auto_load_fallback")
                    msg.info("没有找到合适的匹配结果")
                end
            end)
        end

        cancel_fn = parallel_requests(servers, build_args, per_response, final_cb, { concurrency = 5, per_request_timeout = 60 })
    end

    -- 手动搜索对英文标题会先用 TMDB 转成中文，再查询弹弹 Play；自动匹配
    -- 复用同一转换，避免英文名和中文条目之间的相似度误判。
    if not is_chinese(title) and type(get_tmdb_title_async) == "function" then
        get_tmdb_title_async(title, episode_num and "tv" or "movie", function(translated_title)
            search_with_title(translated_title or title)
        end)
    else
        search_with_title(title)
    end
end

local function is_background_search_item_actionable(item)
    local value = item and item.value
    if type(value) ~= "table" or value[1] ~= "script-message-to" then
        return false
    end

    return value[3] == "get-extra-event" or value[3] == "search-episodes-event"
end

local function is_background_search_item_series(item)
    local value = item and item.value
    if type(value) ~= "table" then return false end
    if value[3] == "get-extra-event" then
        return classify_search_result_type(value[4], item.hint) == "series"
    end
    return classify_search_result_type(nil, item.hint, item.auto_type) == "series"
end

-- 以手动选集方式打开后台搜索到的剧集列表。
local function open_ambiguous_episode_menu(item)
    local value = item.value
    if value[3] == "search-episodes-event" then
        -- 弹弹 Play：直接进入剧集列表。
        mp.commandv("script-message", "search-episodes-event", value[4], value[5], value[6])
    elseif value[3] == "get-extra-event" then
        -- 外部源：以手动选集方式打开详情菜单。
        enter_auto_match_episode_menu()
        get_details(value[4], value[5], value[7], value[8], value[9], nil, nil, true, "menu")
    end
end

-- 从与手动搜索完全相同的结果列表中选择可直接加载的条目。
-- 有集数时优先剧集；没有剧集结果时回退到原顺序中的首个条目。
local function select_background_search_item(items, episode_num, episode_unknown)
    local function select_item(item)
        if not is_background_search_item_actionable(item) then return false end

        local value = item.value
        local ambiguous = episode_unknown and is_background_search_item_series(item)
        local ambiguous_action = ambiguous and get_auto_match_ambiguous_action() or nil

        -- menu 直接打开剧集列表；skip/first 交给下层根据实际集数判断，
        -- 单集剧集仍然可以正常自动加载。
        if ambiguous_action == "menu" then
            open_ambiguous_episode_menu(item)
            return true
        end

        if value[3] == "get-extra-event" then
            -- 通过事件入口加载外部源，并显式标记为自动操作，避免事件
            -- 把 AUTO_MATCHING 错误地切换成手动模式；剧集使用当前集数。
            local auto_value = {}
            for i, arg in ipairs(value) do auto_value[i] = arg end
            auto_value[#auto_value + 1] = "true"
            auto_value[#auto_value + 1] = episode_num and tostring(episode_num) or ""
            auto_value[#auto_value + 1] = ambiguous_action or ""
            mp.commandv(unpack(auto_value))
        else
            match_episode(value[4], value[5], episode_num, value[6],
                classify_search_result_type(nil, item.hint, item.auto_type))
        end
        return true
    end

    if episode_num then
        for _, item in ipairs(items or {}) do
            if is_background_search_item_series(item) and select_item(item) then
                return true
            end
        end
    end
    for _, item in ipairs(items or {}) do
        if select_item(item) then
            return true
        end
    end
    return false
end

-- 自动匹配统一复用手动搜索的结果；整个过程不打开搜索菜单。
local function match_anime(on_failed, skip_background)
    if AUTO_MATCHING then
        AUTO_MATCHING_STAGE = "matching"
    end
    local title, _, episode_num = parse_title()
    if not title then
        if on_failed then
            on_failed()
        else
            mp.commandv("script-message", "auto_load_fallback")
            msg.error("无法解析媒体标题")
        end
        return
    end

    -- 自动匹配开始查询时给出状态提示；手动搜索入口不调用此函数。
    -- 通过统一提示函数检查当前自动匹配开关，避免用户关闭开关后，
    -- 旧异步请求回调又把“搜索中”提示显示回来。
    show_auto_match_status("自动搜索匹配弹幕中...", 30)

    local episode_unknown = auto_match_episode_unknown()

    if not skip_background and type(search_anime_background) == "function" then
        search_anime_background(title, function(items)
            if type(cache_anime_search_results) == "function" then
                cache_anime_search_results(title, items)
            end
            if select_background_search_item(items, episode_num, episode_unknown) then
                msg.info("后台手动搜索已自动关联弹幕")
                return
            end

            if on_failed then
                on_failed()
            else
                -- 没有可直接加载的外部条目时，保留原有弹弹 Play 标题匹配兜底。
                match_anime_by_title()
            end
        end)
        return
    end

    if on_failed then
        on_failed()
    else
        match_anime_by_title()
    end
end

-- 执行哈希匹配获取弹幕
local function match_file(file_path, file_name, callback)
    -- 计算文件哈希
    local hash = nil
    local file_info = utils.file_info(file_path)
    if file_info and file_info.size >= 16 * 1024 * 1024 then
        local file, error = io.open(normalize(file_path), 'rb')
        if file and not error then
            local m = MD5.new()
            for _ = 1, 16 * 1024 do
                local content = file:read(1024)
                if not content then
                    break
                end
                m:update(content)
            end
            file:close()
            hash = m:finish()
        end
    end

    if hash then msg.info('hash:', hash) end

    local title, season_num, episode_num = parse_title()
    if title and episode_num then
        if season_num then
            file_name = title .. " S" .. season_num .. "E" .. episode_num
        else
            file_name = title .. " E" .. episode_num
        end
    else
        file_name = title
    end

    local servers = get_api_server_list(options.api_server)

    local matched = false
    local cancel_fn = nil
    local episode_unknown = auto_match_episode_unknown()
    local ambiguous_action = episode_unknown and get_auto_match_ambiguous_action() or nil
    -- 标题无集数且目录无历史时，先确认是否存在精确哈希匹配。
    -- first 模式不需要探测，保持原有的快速路径。
    local probe_hash_only = episode_unknown and ambiguous_action ~= "first" and hash ~= nil

    local function apply_match(match, server)
        DANMAKU.anime = match.animeTitle
        DANMAKU.episode = match.episodeTitle
        set_episode_id(match.episodeId, nil, server)
    end

    -- 文件名匹配到的第一集仍然可能是默认第一集；先确认该条目是否真的只有一集。
    local function resolve_ambiguous_match(match, server)
        local bangumi_id = match.animeId or match.bangumiId
        local function stop_without_loading()
            if ambiguous_action == "menu" and bangumi_id then
                enter_auto_match_episode_menu()
                mp.commandv("script-message", "search-episodes-event",
                    match.animeTitle, tostring(bangumi_id), server)
            else
                finish_auto_match_ambiguous()
            end
            if callback then pcall(callback) end
        end

        if not bangumi_id then
            stop_without_loading()
            return
        end
        local args = make_danmaku_request_args("GET", server .. "/api/v2/bangumi/" .. bangumi_id)
        if not args then
            stop_without_loading()
            return
        end
        call_cmd_async(args, function(error, json)
            local detail = (not error) and utils.parse_json(json) or nil
            local numeric_count = 0
            if detail and detail.bangumi and detail.bangumi.episodes then
                for _, episode in ipairs(detail.bangumi.episodes) do
                    if tonumber(episode.episodeNumber) then
                        numeric_count = numeric_count + 1
                    end
                end
            end
            -- 只有明确查到一集正片时才按单集剧集直接加载；
            -- 查询失败或集数信息缺失时仍按歧义处理，避免又猜第一集。
            if numeric_count == 1 then
                apply_match(match, server)
                if callback then pcall(callback) end
            else
                stop_without_loading()
            end
        end)
    end

    local function handle_response(server, err, out, exact_hash_only)
        if matched then return end
        if err then
            msg.debug(("match failed for %s: %s"):format(server, tostring(err)))
            return
        end
        local data = utils.parse_json(out)
        if not data or not data.isMatched or not data.matches or not data.matches[1] then
            return
        end

        local match = data.matches[1]
        matched = true
        if cancel_fn then pcall(cancel_fn) end

        -- hashOnly 命中就是文件内容精确匹配，不管第几集都直接采用。
        if exact_hash_only then
            apply_match(match, server)
            if callback then pcall(callback) end
            return
        end

        local match_type = classify_search_result_type(nil, match.typeDescription, match.type)
        local episode_id = tonumber(match.episodeId)
        local episode_index = episode_id and (episode_id % 1000) or nil
        -- 文件名匹配到第一集（或无法判断集数）时才可能是默认第一集；
        -- 匹配到其它集数时，说明文件名已经明确指向该集，直接采用。
        if ambiguous_action and ambiguous_action ~= "first" and match_type == "series"
            and (episode_index == nil or episode_index <= 1) then
            resolve_ambiguous_match(match, server)
            return
        end

        apply_match(match, server)
        if callback then pcall(callback) end
    end

    local function run_requests(mode, exact_hash_only, on_no_match)
        local function build_args(server)
            local url = server .. "/api/v2/match"
            return make_danmaku_request_args("POST", url, { ["Content-Type"] = "application/json" }, {
                fileName = file_name,
                fileHash = hash or "a1b2c3d4e5f67890abcd1234ef567890",
                matchMode = mode
            })
        end

        local function final_cb()
            if matched then return end
            if on_no_match then pcall(on_no_match) end
        end

        cancel_fn = parallel_requests(servers, build_args, function(server, err, out)
            handle_response(server, err, out, exact_hash_only)
        end, final_cb, { concurrency = 5, per_request_timeout = 60 })
    end

    local function run_filename_matching()
        run_requests("hashAndFileName", false, function()
            if matched then return end
            -- 哈希优先后还要继续标题搜索，不能在这里提前显示“自动匹配未找到弹幕”。
            if not (episode_unknown and ambiguous_action ~= "first") then
                mp.commandv("script-message", "auto_load_fallback")
            end
            if callback then pcall(callback, "没有找到hash匹配的剧集") end
        end)
    end

    if probe_hash_only then
        run_requests("hashOnly", true, run_filename_matching)
    else
        run_filename_matching()
    end
end

-- 异步获取弹幕数据
function fetch_danmaku_data(args, callback)
    call_cmd_async(args, function(error, json)
        if error then
            show_message("获取数据失败", 3)
            msg.error("HTTP 请求失败：" .. error)
            -- 自动匹配的请求失败也必须结束在统一回退路径，避免隐藏弹幕
            -- 时没有任何结果提示；手动搜索仍由调用方自行处理。
            callback(nil)
            return
        end
        local data = utils.parse_json(json)
        if data ~= nil then
            data = normalize_danmaku_response(data)
        else
            local danmaku = parse_xml_danmaku(json)
            if #danmaku > 0 then
                data = {}
                data["xml"] = danmaku
            end
        end
        callback(data)
    end)
end

-- 保存弹幕数据
function save_danmaku_data(comments, query, danmaku_source)
    local danmaku_list = save_danmaku_to_list(comments)

    if DANMAKU.sources[query] ~= nil then
        DANMAKU.sources[query]["data"] = danmaku_list
    else
        DANMAKU.sources[query] = {from = danmaku_source, data = danmaku_list}
    end
end

function save_danmaku_xml(url, xml_string)
    local danmaku_list = parse_xml_danmaku(xml_string)

    if DANMAKU.sources[url] ~= nil then
        DANMAKU.sources[url]["data"] = danmaku_list
    else
        DANMAKU.sources[url] = {from = "user_custom", data = danmaku_list}
    end
end

function save_danmaku_json(url, json_string)
    local danmaku_list = parse_json_danmaku(json_string)

    if DANMAKU.sources[url] ~= nil then
        DANMAKU.sources[url]["data"] = danmaku_list
    else
        DANMAKU.sources[url] = {from = "user_custom", data = danmaku_list}
    end
end

function save_danmaku_downloaded(url, downloaded_file)
    local danmaku_list = parse_danmaku_file(downloaded_file)
    if file_exists(downloaded_file) then
        os.remove(downloaded_file)
    end
    if DANMAKU.sources[url] ~= nil then
        DANMAKU.sources[url]["data"] = danmaku_list
    else
        DANMAKU.sources[url] = {from = "user_custom", data = danmaku_list}
    end
end

-- 处理获取到的数据
function handle_fetched_danmaku(data, url, from_menu)
    if data and data["comments"] then
        if data["count"] == 0 then
            if DANMAKU.sources[url] == nil then
                DANMAKU.sources[url] = {from = "api_server"}
            end
            show_message("该集弹幕内容为空，结束加载", 3)
            msg.info("该集弹幕内容为空，结束加载")
            if not from_menu then
                mp.commandv("script-message", "auto_load_fallback")
            end
            return
        end
        save_danmaku_data(data["comments"], url, "api_server")
        load_danmaku(from_menu)
    else
        show_message("无数据", 3)
        msg.info("无数据")
        if not from_menu then
            mp.commandv("script-message", "auto_load_fallback")
        end
    end
end

-- 匹配弹幕库 comment, 仅匹配dandan本身弹幕库
-- 通过danmaku api（url）+id获取弹幕
function fetch_danmaku(episodeId, from_menu, api_server)
    if AUTO_MATCHING then
        AUTO_MATCHING_STAGE = "loading"
    end
    local url = api_server .. "/api/v2/comment/" .. episodeId .. "?withRelated=true&chConvert=0"
    msg.verbose("尝试获取弹幕：" .. url)
    local args = make_danmaku_request_args("GET", url)

    if args == nil then
        if not from_menu and AUTO_MATCHING then
            mp.commandv("script-message", "auto_load_fallback")
        end
        return
    end

    show_message("弹幕加载中...", 30)

    fetch_danmaku_data(args, function(data)
        handle_fetched_danmaku(data, url, from_menu)
    end)
end

-- 从用户添加过的弹幕源添加弹幕
function addon_danmaku(dir, from_menu)
    if dir then
        local history_json = read_file(HISTORY_PATH)
        local history = utils.parse_json(history_json) or {}
        if history[dir] and history[dir].extra ~= nil then
            return
        end
    end
    for url, source in pairs(DANMAKU.sources) do
        if source.from ~= "api_server" then
            add_danmaku_source(url, from_menu)
        end
    end
end

--通过输入源url获取弹幕库
function add_danmaku_source(query, from_menu)
    if DANMAKU.sources[query] == nil then
        DANMAKU.sources[query] = {from = "user_custom"}
    end

    from_menu = from_menu or false
    if from_menu then
        add_source_to_history(query, DANMAKU.sources[query])
    end

    if is_protocol(query) then
        add_danmaku_source_online(query, from_menu)
    else
        add_danmaku_source_local(query, from_menu)
    end
end

function add_danmaku_source_local(query, from_menu)
    local path = normalize(query)
    if not file_exists(path) then
        msg.warn("无效的文件路径")
        return
    end
    if not (string.match(path, "%.xml$") or string.match(path, "%.json$")) then
        msg.warn("仅支持弹幕文件")
        return
    end

    if DANMAKU.sources[query] ~= nil then
        DANMAKU.sources[query]["from"] = "user_local"
        DANMAKU.sources[query]["data"] = parse_danmaku_file(path)
    else
        DANMAKU.sources[query] = {from = "user_local", data = parse_danmaku_file(path)}
    end

    set_danmaku_button()
    load_danmaku(from_menu)
end

--通过输入源url获取弹幕库
function add_danmaku_source_online(query, from_menu)
    if AUTO_MATCHING then
        AUTO_MATCHING_STAGE = "loading"
    end
    set_danmaku_button()
    show_message("弹幕加载中...", 30)
    msg.verbose("尝试获取弹幕：" .. query)

    local servers = get_api_server_list(options.api_server)

    -- 过滤掉指向 dandanplay.net 的服务器
    local filtered = {}
    for _, s in ipairs(servers) do
        if type(s) == "string" and not s:lower():find("dandanplay%.net") then
            table.insert(filtered, s)
        end
    end
    servers = filtered
    if #servers == 0 then
        get_danmaku_fallback(query)
        return
    end

    local matched = false
    local cancel_fn = nil

    local function build_args(server)
        local url = server .. "/api/v2/extcomment?url=" .. url_encode(query)
        return make_danmaku_request_args("GET", url)
    end

    local function per_response(server, err, out)
        if matched then return end
        if err then
            msg.debug(("extcomment failed for %s: %s"):format(server, tostring(err)))
            return
        end
        local data = utils.parse_json(out)
        data = normalize_danmaku_response(data)
        if not data or not data["comments"] or data["count"] <= 1 then
            return
        end
        matched = true
        -- 保存并加载弹幕
        save_danmaku_data(data["comments"], query, "user_custom")
        load_danmaku(from_menu)
        -- 取消其他未完成请求
        if cancel_fn then pcall(cancel_fn) end
    end

    local function final_cb()
        if not matched then
            -- 所有服务器都未返回有效弹幕，回退到备用服务器
            msg.info("所有服务器均无有效弹幕，尝试备用服务器")
            get_danmaku_fallback(query)
        end
    end

    cancel_fn = parallel_requests(servers, build_args, per_response, final_cb, { concurrency = 3, per_request_timeout = 60 })
end

-- 将弹幕转换为 Lua table
function save_danmaku_to_list(comments)
    local danmaku_list = {}

    for _, comment in ipairs(comments) do
        local p = comment["p"]
        local shift = comment["shift"]
        if p then
            local fields = split(p, ",")
            if shift ~= nil then
                fields[1] = tonumber(fields[1]) + tonumber(shift)
            end
            local time = tonumber(fields[1])
            local type = tonumber(fields[2])
            local color = tonumber(fields[3]) or 0xFFFFFF
            local size = 25
            local m_value = comment["m"]
                            :gsub("[%z\1-\31]", "")
                            :gsub("\\", "")
                            :gsub("\"", "")
            table.insert(danmaku_list, {
                time = time,
                type = type,
                size = size,
                color = color,
                text = m_value
            })
        end
    end

    return danmaku_list
end

-- 通过文件前 16M 的 hash 值进行弹幕匹配
function get_danmaku_with_hash(file_name, file_path)
    if AUTO_MATCHING then
        AUTO_MATCHING_STAGE = "matching"
        show_auto_match_status("自动搜索匹配弹幕中...", 30)
    end
    local title, season_num, episode_num = parse_title()

    local function run_hash_matching()
        if type(MD5) ~= "table" or not MD5.sum then
            msg.warn("MD5 模块不支持 Lua 5.1，回退到文件名匹配")
            match_anime(nil, true)
            return
        end
        if is_protocol(file_path) then
            set_danmaku_button()
            local temp_file = "temp-" .. PID .. ".mp4"
            local arg = {
                "curl",
                "--connect-timeout",
                "10",
                "--max-time",
                "30",
                "--range",
                "0-16777215",
                "--user-agent",
                options.user_agent,
                "--output",
                utils.join_path(DANMAKU_PATH, temp_file),
                "-L",
                file_path,
            }

            if options.proxy ~= "" then
                table.insert(arg, '-x')
                table.insert(arg, options.proxy)
            end

            call_cmd_async(arg, function(error)
                file_path = utils.join_path(DANMAKU_PATH, temp_file)

                match_file(file_path, file_name, function(error)
                    if error then
                        msg.error(error)
                        msg.info("尝试通过解析文件名获取弹幕")
                        match_anime(nil, true)
                    end
                end)
            end)
        else
            local dir = get_parent_directory(file_path)
            local excluded_path = utils.parse_json(options.excluded_path)
            if PLATFORM == "windows" then
                for i, path in pairs(excluded_path) do
                    excluded_path[i] = path:gsub("/", "\\")
                end
            end
            if contains_any(excluded_path, dir) then
                match_anime(nil, true)
                return
            end
            match_file(file_path, file_name, function(error)
                if error then
                    msg.error(error)
                    msg.info("尝试通过解析文件名获取弹幕")
                    match_anime(nil, true)
                end
            end)
        end
    end

    if title then
        local current_path = mp.get_property("path") or file_path
        local disc_media = is_disc_media_path(current_path) or is_disc_media_path(file_path)
        if not disc_media and auto_match_episode_unknown()
            and get_auto_match_ambiguous_action() ~= "first" then
            -- 普通视频标题无法确定集数且目录无历史时，先确认是否存在精确哈希匹配，
            -- 避免标题搜索得到的“第一集”结论覆盖掉精确的非第一集结果。
            run_hash_matching()
        else
            -- 光盘/镜像和其他情况保持原顺序：先标题搜索，失败后再哈希兜底。
            match_anime(run_hash_matching)
        end
    else
        run_hash_matching()
    end
end
