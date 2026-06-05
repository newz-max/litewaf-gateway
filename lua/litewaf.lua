local cjson = require "cjson.safe"
local bit = require "bit"

local _M = {}

local config_path = os.getenv("LITEWAF_CONFIG_PATH") or "/etc/litewaf/active.json"
local ingestion_url = os.getenv("LITEWAF_INGESTION_URL") or ""
local ingestion_token = os.getenv("LITEWAF_INGESTION_TOKEN") or ""
local metrics_enabled = (os.getenv("LITEWAF_METRICS_ENABLED") or "") == "true"
local sensitive_headers = os.getenv("LITEWAF_SENSITIVE_HEADERS") or "authorization,cookie,set-cookie"
local max_summary_len = tonumber(os.getenv("LITEWAF_LOG_VALUE_MAX_LEN") or "160") or 160
local challenge_secret = os.getenv("LITEWAF_CHALLENGE_SECRET") or ""
local dynamic_secret = os.getenv("LITEWAF_DYNAMIC_SECRET") or ""

local sensitive_header_set = {}
for header in string.gmatch(sensitive_headers, "([^,]+)") do
    sensitive_header_set[string.lower((header:gsub("^%s+", ""):gsub("%s+$", "")))] = true
end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local content = file:read("*a")
    file:close()
    return content, nil
end

local function load_config()
    local content, err = read_file(config_path)
    if not content then
        ngx.log(ngx.ERR, "litewaf config read failed: ", err)
        return { sites = {} }
    end

    local decoded, json_err = cjson.decode(content)
    if not decoded then
        ngx.log(ngx.ERR, "litewaf config decode failed: ", json_err)
        return { sites = {} }
    end

    return decoded
end

local function host_without_port(host)
    if not host then
        return ""
    end
    return string.lower((host:gsub(":%d+$", "")))
end

local function find_site(config, host)
    local normalized = host_without_port(host)
    for _, site in ipairs(config.sites or {}) do
        if string.lower(site.host or "") == normalized then
            return site
        end
    end
    return nil
end

local function bounded(value)
    value = tostring(value or "")
    if #value <= max_summary_len then
        return value
    end
    return string.sub(value, 1, max_summary_len) .. "...truncated"
end

local function hash_bounded(value)
    value = tostring(value or "")
    local hash = 2166136261
    for i = 1, #value do
        hash = bit.bxor(hash, string.byte(value, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function html_escape(value)
    value = tostring(value or "")
    value = string.gsub(value, "&", "&amp;")
    value = string.gsub(value, "<", "&lt;")
    value = string.gsub(value, ">", "&gt;")
    value = string.gsub(value, "\"", "&quot;")
    value = string.gsub(value, "'", "&#39;")
    return value
end

local function accepted_request_id(value)
    value = tostring(value or "")
    if value == "" or #value > 128 then
        return nil
    end
    if not string.match(value, "^[A-Za-z0-9._:-]+$") then
        return nil
    end
    return value
end

local function ensure_request_id()
    if ngx.ctx.request_id then
        return ngx.ctx.request_id
    end
    local request_id = accepted_request_id(ngx.var.http_x_request_id)
    if not request_id then
        local dict = ngx.shared.litewaf_metrics
        local seq = 0
        if dict then
            seq = dict:incr("request_id_seq", 1, 0) or 0
        end
        request_id = table.concat({ ngx.now(), ngx.worker.pid(), seq }, "-")
    end
    ngx.ctx.request_id = request_id
    ngx.var.litewaf_request_id = request_id
    return request_id
end

local function increment_metric(name, labels)
    local dict = ngx.shared.litewaf_metrics
    if not dict then
        return
    end
    labels = labels or {}
    local key = name
    for _, label in ipairs(labels) do
        key = key .. "|" .. tostring(label or "")
    end
    local _, err = dict:incr(key, 1, 0)
    if err then
        ngx.log(ngx.ERR, "litewaf metric increment failed: ", err)
    end
end

local function parse_ingestion_url(path)
    if ingestion_url == "" or ingestion_token == "" then
        return nil
    end
    local scheme, host, port, base_path = string.match(ingestion_url, "^(https?)://([^/:]+):?(%d*)(/?.*)$")
    if not scheme or scheme ~= "http" then
        return nil
    end
    if port == "" then
        port = "80"
    end
    base_path = base_path or ""
    if base_path == "/" then
        base_path = ""
    end
    return {
        host = host,
        port = tonumber(port),
        path = base_path .. path
    }
end

local function post_ingestion(premature, path, payload)
    if premature then
        return
    end
    local target = parse_ingestion_url(path)
    if not target then
        return
    end
    local body = cjson.encode(payload)
    if not body then
        return
    end
    local sock = ngx.socket.tcp()
    sock:settimeout(1000)
    local ok, err = sock:connect(target.host, target.port)
    if not ok then
        ngx.log(ngx.WARN, "litewaf ingestion connect failed: ", err)
        return
    end
    local request = table.concat({
        "POST ", target.path, " HTTP/1.1\r\n",
        "Host: ", target.host, "\r\n",
        "Authorization: Bearer ", ingestion_token, "\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", #body, "\r\n",
        "Connection: close\r\n\r\n",
        body
    })
    local sent, send_err = sock:send(request)
    if not sent then
        ngx.log(ngx.WARN, "litewaf ingestion send failed: ", send_err)
        sock:close()
        return
    end
    sock:receive("*l")
    sock:close()
end

local function schedule_ingestion(path, payload)
    if ingestion_url == "" or ingestion_token == "" then
        return
    end
    local ok, err = ngx.timer.at(0, post_ingestion, path, payload)
    if not ok then
        ngx.log(ngx.WARN, "litewaf ingestion timer failed: ", err)
    end
end

local function log_json(level, payload)
    ngx.log(level, cjson.encode(payload))
end

local function client_ip()
    return ngx.var.remote_addr or ngx.var.realip_remote_addr or ""
end

local function waf_event(site, data)
    local payload = {
        event = "waf_event",
        request_id = ensure_request_id(),
        site_id = site and site.id or 0,
        event_type = data.event_type or "rule",
        rule_id = data.rule_id or 0,
        rule_type = data.rule_type or "",
        target = data.target or "",
        action = data.action or "",
        disposition = data.disposition or "observed",
        client_ip = client_ip(),
        method = ngx.req.get_method(),
        uri = ngx.var.request_uri,
        summary = bounded(data.summary or ""),
        access_list_id = data.access_list_id or 0,
        rate_limit_id = data.rate_limit_id or 0,
        module = data.module or "",
        category = data.category or "",
        rule_name = data.rule_name or "",
        attack_type = data.attack_type or "",
        group_name = data.group_name or "",
        counter = data.counter or "",
        window_sec = data.window_sec or 0,
        advanced_target = data.advanced_target or "",
        normalized_value = bounded(data.normalized_value or ""),
        score = data.score or 0,
        threshold = data.threshold or 0,
        matched_rule_ids = data.matched_rule_ids or "",
        body_metadata = bounded(data.body_metadata or ""),
        upload_metadata = bounded(data.upload_metadata or ""),
        ban_reason = data.ban_reason or "",
        ban_duration_sec = data.ban_duration_sec or 0,
        ban_remaining_sec = data.ban_remaining_sec or 0,
        challenge_mode = data.challenge_mode or "",
        challenge_result = data.challenge_result or "",
        bot_result = data.bot_result or "",
        bot_reason = bounded(data.bot_reason or ""),
        device_signal = data.device_signal or ""
    }
    log_json(ngx.WARN, payload)
    schedule_ingestion("/api/v1/ingest/waf-events", payload)
    increment_metric("waf_matches", { payload.site_id, payload.event_type, payload.disposition })
end

local function policy_for_site(site)
    local policy = site.policy or {}
    if policy.risk_threshold == nil or tonumber(policy.risk_threshold or 0) == 0 then
        policy.risk_threshold = 100
    end
    if policy.default_action == nil or policy.default_action == "" then
        policy.default_action = "block"
    end
    if policy.normalization_enabled == nil then
        policy.normalization_enabled = true
    end
    policy.normalization_decode_passes = tonumber(policy.normalization_decode_passes or 2) or 2
    policy.normalization_max_value_bytes = tonumber(policy.normalization_max_value_bytes or 4096) or 4096
    policy.body_inspection_max_bytes = tonumber(policy.body_inspection_max_bytes or 65536) or 65536
    if policy.oversized_body_action == nil or policy.oversized_body_action == "" then
        policy.oversized_body_action = "log-only"
    end
    policy.upload_max_bytes = tonumber(policy.upload_max_bytes or 10485760) or 10485760
    if policy.upload_size_action == nil or policy.upload_size_action == "" then
        policy.upload_size_action = "block"
    end
    policy.dynamic_ban_duration_sec = tonumber(policy.dynamic_ban_duration_sec or 300) or 300
    policy.dynamic_ban_score_threshold = tonumber(policy.dynamic_ban_score_threshold or 200) or 200
    policy.dynamic_ban_trigger_count = tonumber(policy.dynamic_ban_trigger_count or 3) or 3
    policy.dynamic_ban_window_sec = tonumber(policy.dynamic_ban_window_sec or 60) or 60
    return policy
end

local function clamp_value(value, limit)
    value = tostring(value or "")
    limit = tonumber(limit or 4096) or 4096
    if #value <= limit then
        return value
    end
    return string.sub(value, 1, limit)
end

local function decode_once(value)
    value = tostring(value or "")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function normalize_value(value, policy)
    value = clamp_value(value, policy.normalization_max_value_bytes)
    if not policy.normalization_enabled then
        return value
    end
    local passes = policy.normalization_decode_passes or 2
    for _ = 1, passes do
        local decoded = decode_once(value)
        if decoded == value then
            break
        end
        value = clamp_value(decoded, policy.normalization_max_value_bytes)
    end
    return value
end

local function normalize_path(value, policy)
    local path = normalize_value(value, policy)
    path = path:gsub("\\", "/")
    path = path:gsub("/+", "/")
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
        if part == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    return "/" .. table.concat(parts, "/")
end

local function inspect_value(rule, value)
    if not value then
        return false, nil
    end
    local from, _, err = ngx.re.find(tostring(value), rule.expression or "", "ijo")
    if err then
        ngx.log(ngx.ERR, "litewaf rule expression failed: ", err)
        return false, nil
    end
    if from ~= nil then
        return true, bounded(value)
    end
    return false, nil
end

local function inspect_values(rule, values)
    for _, value in ipairs(values or {}) do
        local matched, summary = inspect_value(rule, value.value)
        if matched then
            return true, summary, value.normalized_value or value.value, value.advanced_target or rule.target or ""
        end
    end
    return false, nil, nil, nil
end

local function ipv4_to_number(value)
    local a, b, c, d = string.match(value or "", "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or not b or not c or not d then
        return nil
    end
    if a > 255 or b > 255 or c > 255 or d > 255 then
        return nil
    end
    return a * 16777216 + b * 65536 + c * 256 + d
end

local function cidr_matches(ip, cidr)
    local base, bits = string.match(cidr or "", "^([^/]+)/(%d+)$")
    bits = tonumber(bits)
    local ip_num = ipv4_to_number(ip)
    local base_num = ipv4_to_number(base)
    if not ip_num or not base_num or not bits or bits < 0 or bits > 32 then
        return false
    end
    if bits == 0 then
        return true
    end
    local mask = bit.lshift(0xffffffff, 32 - bits)
    return bit.band(ip_num, mask) == bit.band(base_num, mask)
end

local path_prefix_matches
local methods_match

local function access_list_matches(entry)
    local target = entry.target or ""
    local value = tostring(entry.value or "")
    if value == "" then
        return false
    end

    if target == "ip" then
        return client_ip() == value
    end

    if target == "cidr" then
        return cidr_matches(client_ip(), value)
    end

    if target == "uri" then
        local operator = entry.match_operator or ""
        if operator == "prefix" then
            return path_prefix_matches(value, ngx.var.uri or "")
        end
        if operator == "exact" then
            return (ngx.var.uri or "") == value
        end
        return string.find(ngx.var.uri or "", value, 1, true) ~= nil
    end

    if target == "ua" then
        return string.find(ngx.var.http_user_agent or "", value, 1, true) ~= nil
    end

    if target == "header" then
        local header_name = tostring(entry.header_name or "")
        if header_name == "" then
            return false
        end
        local headers = ngx.req.get_headers()
        local header_value = tostring(headers[header_name] or headers[string.lower(header_name)] or "")
        if entry.match_operator == "contains" then
            return string.find(header_value, value, 1, true) ~= nil
        end
        return header_value == value
    end

    if target == "host" then
        local host = host_without_port(ngx.var.host)
        value = string.lower(value)
        if entry.match_operator == "suffix" then
            return host == value or string.sub(host, -#("." .. value)) == "." .. value
        end
        return host == value
    end

    return false
end

local function entry_for_site(entry, site)
    local site_id = tonumber(entry.site_id or 0) or 0
    return site_id == 0 or site_id == tonumber(site.id or 0)
end

local enforce_rate_limits
local dynamic_ban_key

local function enforce_access_lists(config, site)
    for _, entry in ipairs(config.access_lists or {}) do
        if entry_for_site(entry, site) and entry.kind == "whitelist" and access_list_matches(entry) then
            return "allow", entry
        end
    end

    for _, entry in ipairs(config.access_lists or {}) do
        if entry_for_site(entry, site) and entry.kind == "blacklist" and access_list_matches(entry) then
            waf_event(site, {
                event_type = "access-list",
                action = entry.action or "block",
                disposition = "blocked",
                access_list_id = entry.id or 0,
                summary = entry.name or entry.value or ""
            })
            return "block", entry
        end
    end

    return nil, nil
end

local function enabled_access_control_rules(config)
    local rules = {}
    for _, rule in ipairs(config.protection_rules or {}) do
        if rule.module == "access-control" and rule.category == "access-control" and rule.enabled ~= false then
            table.insert(rules, rule)
        end
    end
    return rules
end

local function access_control_rule_matches(rule, site)
    if not entry_for_site(rule, site) then
        return false
    end
    local match = rule.match or {}
    if not methods_match(match.methods) then
        return false
    end
    local target = tostring(match.target or "")
    local value = tostring(match.value or "")
    if target == "ip" then
        return client_ip() == value
    end
    if target == "cidr" then
        return cidr_matches(client_ip(), value)
    end
    if target == "path" then
        local path = tostring(match.path or value)
        local path_match = tostring(match.path_match or match.operator or "exact")
        if path_match == "prefix" then
            return path_prefix_matches(path, ngx.var.uri or "")
        end
        return (ngx.var.uri or "") == path
    end
    if target == "header" then
        local header_name = tostring(match.header_name or "")
        if header_name == "" then
            return false
        end
        local headers = ngx.req.get_headers()
        local header_value = tostring(headers[header_name] or headers[string.lower(header_name)] or "")
        if tostring(match.operator or "exact") == "contains" then
            return string.find(header_value, value, 1, true) ~= nil
        end
        return header_value == value
    end
    if target == "host" then
        local host = host_without_port(ngx.var.host)
        local expected = string.lower(tostring(match.host or value))
        if tostring(match.operator or "exact") == "suffix" then
            return host == expected or string.sub(host, -#("." .. expected)) == "." .. expected
        end
        return host == expected
    end
    return false
end

local function access_control_summary(rule)
    local match = rule.match or {}
    local target = tostring(match.target or "")
    if target == "path" then
        return "path " .. tostring(match.path_match or match.operator or "exact") .. " " .. tostring(match.path or match.value or "")
    end
    if target == "header" then
        return "header " .. tostring(match.header_name or "") .. " " .. tostring(match.operator or "exact")
    end
    if target == "host" then
        return "host " .. tostring(match.operator or "exact") .. " " .. tostring(match.host or match.value or "")
    end
    return target .. " " .. tostring(match.value or "")
end

local function enforce_access_control(config, site)
    local rules = enabled_access_control_rules(config)
    if #rules == 0 then
        return enforce_access_lists(config, site)
    end
    for _, rule in ipairs(rules) do
        if access_control_rule_matches(rule, site) then
            local action = ((rule.action or {}).type) or "block"
            local disposition = "blocked"
            if action == "allow" then
                disposition = "proxied"
            elseif action == "log-only" then
                disposition = "observed"
            end
            waf_event(site, {
                event_type = "access-control",
                module = "access-control",
                category = "access-control",
                rule_id = rule.id or 0,
                rule_name = rule.name or "",
                action = action,
                disposition = disposition,
                access_list_id = rule.id or 0,
                target = ((rule.match or {}).target) or "",
                summary = access_control_summary(rule)
            })
            if action == "allow" then
                return "allow", rule
            end
            if action == "block" then
                return "block", rule
            end
        end
    end
    return nil, nil
end

local function rate_limit_key(rule, site)
    local scope = rule.scope or "ip"
    if scope == "uri" then
        return table.concat({ "uri", site.id or 0, rule.id or 0, ngx.var.uri or "" }, ":")
    end
    if scope == "site" then
        return table.concat({ "site", site.id or 0, rule.id or 0 }, ":")
    end
    return table.concat({ "ip", site.id or 0, rule.id or 0, client_ip() }, ":")
end

path_prefix_matches = function(prefix, uri)
    prefix = tostring(prefix or "")
    uri = tostring(uri or "")
    if prefix == "" then
        return false
    end
    if prefix == "/" then
        return true
    end
    if string.sub(prefix, -1) == "/" then
        local base = string.sub(prefix, 1, #prefix - 1)
        return uri == base or uri == prefix or string.sub(uri, 1, #prefix) == prefix
    end
    return uri == prefix or string.sub(uri, 1, #prefix + 1) == prefix .. "/"
end

methods_match = function(methods)
    if type(methods) ~= "table" or #methods == 0 then
        return true
    end
    local request_method = ngx.req.get_method()
    for _, method in ipairs(methods) do
        if tostring(method) == request_method then
            return true
        end
    end
    return false
end

local function cc_rule_matches(rule, site)
    if not entry_for_site(rule, site) then
        return false
    end
    local match = rule.match or {}
    if not methods_match(match.methods) then
        return false
    end
    local path = tostring(match.path or "/")
    local path_match = tostring(match.path_match or "exact")
    local uri = ngx.var.uri or ""
    if path_match == "prefix" then
        return path_prefix_matches(path, uri)
    end
    if path_match == "glob" then
        local pattern = "^" .. string.gsub(string.gsub(string.gsub(path, "([%.%+%-%^%$%(%)%%])", "%%%1"), "%*", "[^/]*"), "%?", "[^/]") .. "$"
        return string.match(uri, pattern) ~= nil
    end
    return uri == path
end

local function cc_session_value(limit)
    local source = tostring(limit.session_source or "cookie")
    local name = tostring(limit.session_name or "")
    if name == "" then
        return ""
    end
    if source == "header" then
        return ngx.var["http_" .. string.lower((name:gsub("-", "_")))] or ""
    end
    local cookie = ngx.var.http_cookie or ""
    for part in string.gmatch(cookie, "([^;]+)") do
        local key, value = string.match(part, "^%s*([^=]+)=?(.*)$")
        if key == name then
            return value or ""
        end
    end
    return ""
end

local function cc_device_value()
    return hash_bounded(table.concat({
        ngx.var.http_user_agent or "",
        ngx.var.http_accept_language or "",
        ngx.var.http_accept or ""
    }, "|"))
end

local function cc_rate_limit_key(rule, site)
    local limit = rule.limit or {}
    local counter = tostring(limit.counter or "client_ip")
    if counter == "client_ip_path" then
        return table.concat({ "cc", "client_ip_path", site.id or 0, rule.id or 0, client_ip(), ngx.var.uri or "" }, ":")
    end
    if counter == "global" then
        return table.concat({ "cc", "global", site.id or 0, rule.id or 0 }, ":")
    end
    if counter == "session" then
        return table.concat({ "cc", "session", site.id or 0, rule.id or 0, hash_bounded(cc_session_value(limit)) }, ":")
    end
    if counter == "device" then
        return table.concat({ "cc", "device", site.id or 0, rule.id or 0, cc_device_value() }, ":")
    end
    if counter == "not_found_frequency" then
        return table.concat({ "cc", "not_found_frequency", site.id or 0, rule.id or 0, client_ip(), ngx.var.uri or "" }, ":")
    end
    if counter == "attack_frequency" then
        return table.concat({ "cc", "attack_frequency", site.id or 0, rule.id or 0, client_ip() }, ":")
    end
    return table.concat({ "cc", "client_ip", site.id or 0, rule.id or 0, client_ip() }, ":")
end

local function enabled_cc_rules(config)
    local rules = {}
    for _, rule in ipairs(config.protection_rules or {}) do
        if rule.module == "cc-protection" and rule.category == "rate-limit" and rule.enabled ~= false then
            table.insert(rules, rule)
        end
    end
    return rules
end

local function cc_counter_ready(rule, phase)
    local counter = tostring((rule.limit or {}).counter or "client_ip")
    if counter == "not_found_frequency" then
        return phase == "not-found-log" or phase == "precheck"
    end
    if counter == "attack_frequency" then
        return phase == "attack-hit" or phase == "precheck"
    end
    return phase == "access"
end

local function cc_emit_event(site, rule, limit, action, disposition, threshold, window, current, summary)
    waf_event(site, {
        event_type = "rate-limit",
        module = "cc-protection",
        category = "rate-limit",
        rule_id = rule.id or 0,
        rule_name = rule.name or "",
        action = action,
        disposition = disposition,
        rate_limit_id = rule.id or 0,
        counter = tostring(limit.counter or "client_ip"),
        threshold = threshold,
        window_sec = window,
        summary = summary or ("cc protection threshold=" .. tostring(threshold) .. ", window=" .. tostring(window) .. ", current=" .. tostring(current or 0))
    })
end

local function cc_apply_rule_counter(site, rule, phase, increment)
    local dict = ngx.shared.litewaf_rate_limit
    if not dict or not cc_counter_ready(rule, phase) then
        return nil
    end
    local limit = rule.limit or {}
    local threshold = tonumber(limit.threshold or 0) or 0
    local window = tonumber(limit.window_sec or 0) or 0
    if threshold <= 0 or window <= 0 then
        return nil
    end
    local action = ((rule.action or {}).type) or "rate-limit"
    local key = cc_rate_limit_key(rule, site)
    local current
    if increment then
        local err
        current, err = dict:incr(key, 1, 0, window)
        if err then
            ngx.log(ngx.ERR, "litewaf cc protection counter failed: ", err)
            return nil
        end
    else
        current = tonumber(dict:get(key) or 0) or 0
    end
    if current <= threshold then
        return nil
    end
    local disposition = "rate-limited"
    if action == "log-only" then
        disposition = "observed"
    elseif action == "block" or action == "ban" then
        disposition = "blocked"
    end
    local ban_duration = tonumber(limit.ban_duration_sec or 0) or 0
    local ban_created = false
    if action == "ban" and ban_duration > 0 then
        local ban_dict = ngx.shared.litewaf_dynamic_ban
        if ban_dict then
            ban_dict:set(dynamic_ban_key(site), "cc-protection:" .. tostring(rule.id or 0), ban_duration)
            ban_created = true
        end
    end
    cc_emit_event(site, rule, limit, action, disposition, threshold, window, current)
    if ban_created then
        waf_event(site, {
            event_type = "dynamic-ban",
            module = "cc-protection",
            category = "rate-limit",
            rule_id = rule.id or 0,
            rule_name = rule.name or "",
            action = action,
            disposition = disposition,
            counter = tostring(limit.counter or "client_ip"),
            threshold = threshold,
            window_sec = window,
            ban_reason = "cc-protection:" .. tostring(rule.id or 0),
            ban_duration_sec = ban_duration,
            summary = "cc protection temporary ban created"
        })
    end
    if action ~= "log-only" then
        return "block"
    end
    return nil
end

local function apply_matching_cc_counters(config, site, phase, increment)
    local rules = enabled_cc_rules(config)
    if #rules == 0 then
        return nil
    end
    for _, rule in ipairs(rules) do
        if cc_rule_matches(rule, site) then
            if cc_apply_rule_counter(site, rule, phase, increment) == "block" then
                return "block", rule
            end
        end
    end
    return nil, nil
end

local function enforce_cc_protection(config, site)
    local rules = enabled_cc_rules(config)
    if #rules == 0 then
        return enforce_rate_limits(config, site)
    end
    ngx.ctx.config = config
    local precheck_decision, precheck_rule = apply_matching_cc_counters(config, site, "precheck", false)
    if precheck_decision == "block" then
        return precheck_decision, precheck_rule
    end
    return apply_matching_cc_counters(config, site, "access", true)
end

local function rate_limit_matches(rule, site)
    if not entry_for_site(rule, site) then
        return false
    end
    local scope = rule.scope or "ip"
    local match_value = tostring(rule.match_value or "")
    if scope == "uri" and match_value ~= "" then
        return string.find(ngx.var.uri or "", match_value, 1, true) ~= nil
    end
    if scope == "site" then
        return true
    end
    if match_value ~= "" then
        return client_ip() == match_value
    end
    return true
end

enforce_rate_limits = function(config, site)
    local dict = ngx.shared.litewaf_rate_limit
    if not dict then
        return nil, nil
    end

    for _, rule in ipairs(config.rate_limits or {}) do
        if rate_limit_matches(rule, site) then
            local threshold = tonumber(rule.threshold or 0) or 0
            local window = tonumber(rule.window_sec or 0) or 0
            if threshold > 0 and window > 0 then
                local key = rate_limit_key(rule, site)
                local current, err = dict:incr(key, 1, 0, window)
                if err then
                    ngx.log(ngx.ERR, "litewaf rate limit counter failed: ", err)
                elseif current > threshold then
                    local ban_created = false
                    local violation_threshold = tonumber(rule.violation_threshold or 0) or 0
                    local violation_window = tonumber(rule.violation_window_sec or 0) or 0
                    local ban_duration = tonumber(rule.ban_duration_sec or 0) or 0
                    if violation_threshold > 0 and violation_window > 0 and ban_duration > 0 and rule.action ~= "log-only" then
                        local violation_key = "rate-violation:" .. rate_limit_key(rule, site)
                        local violations = dict:incr(violation_key, 1, 0, violation_window) or 0
                        if violations >= violation_threshold then
                            local ban_dict = ngx.shared.litewaf_dynamic_ban
                            if ban_dict then
                                ban_dict:set("ip:" .. tostring(site.id or 0) .. ":" .. client_ip(), "rate-limit:" .. tostring(rule.id or 0), ban_duration)
                                ban_created = true
                            end
                        end
                    end
                    waf_event(site, {
                        event_type = "rate-limit",
                        action = rule.action or "block",
                        disposition = rule.action == "log-only" and "observed" or "rate-limited",
                        rate_limit_id = rule.id or 0,
                        summary = "threshold=" .. tostring(threshold) .. ", window=" .. tostring(window),
                        ban_reason = ban_created and ("rate-limit:" .. tostring(rule.id or 0)) or "",
                        ban_duration_sec = ban_created and ban_duration or 0
                    })
                    if ban_created then
                        waf_event(site, {
                            event_type = "dynamic-ban",
                            action = "block",
                            disposition = "blocked",
                            rate_limit_id = rule.id or 0,
                            summary = "created from repeated rate-limit violations",
                            ban_reason = "rate-limit:" .. tostring(rule.id or 0),
                            ban_duration_sec = ban_duration
                        })
                    end
                    if rule.action ~= "log-only" then
                        return "block", rule
                    end
                end
            end
        end
    end

    return nil, nil
end

dynamic_ban_key = function(site)
    return "ip:" .. tostring(site.id or 0) .. ":" .. client_ip()
end

local function enforce_dynamic_ban(site)
    local dict = ngx.shared.litewaf_dynamic_ban
    if not dict then
        return nil
    end
    local key = dynamic_ban_key(site)
    local reason = dict:get(key)
    if not reason then
        return nil
    end
    local ttl = 0
    if dict.ttl then
        ttl = dict:ttl(key) or 0
    end
    waf_event(site, {
        event_type = "dynamic-ban",
        action = "block",
        disposition = "blocked",
        summary = "active temporary ban",
        ban_reason = tostring(reason),
        ban_remaining_sec = ttl > 0 and ttl or 0
    })
    return "block"
end

local function create_dynamic_ban(site, reason, duration)
    local dict = ngx.shared.litewaf_dynamic_ban
    duration = tonumber(duration or 0) or 0
    if not dict or duration <= 0 then
        return
    end
    dict:set(dynamic_ban_key(site), reason, duration)
    waf_event(site, {
        event_type = "dynamic-ban",
        action = "block",
        disposition = "blocked",
        summary = "created temporary ban",
        ban_reason = reason,
        ban_duration_sec = duration
    })
end

local function list_contains_prefix(values, path)
    if not values or #values == 0 then
        return true
    end
    for _, prefix in ipairs(values) do
        prefix = tostring(prefix or "")
        if prefix == "" or string.sub(path, 1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local function list_contains_value(values, value)
    if not values or #values == 0 then
        return true
    end
    value = string.lower(tostring(value or ""))
    for _, item in ipairs(values) do
        if value:find(string.lower(tostring(item or "")), 1, true) then
            return true
        end
    end
    return false
end

local function request_body(policy)
    if ngx.ctx.litewaf_body_loaded then
        return ngx.ctx.litewaf_body, ngx.ctx.litewaf_body_too_large
    end
    ngx.ctx.litewaf_body_loaded = true
    ngx.req.read_body()
    local body = ngx.req.get_body_data() or ""
    local max_bytes = tonumber(policy.body_inspection_max_bytes or 65536) or 65536
    if #body > max_bytes then
        ngx.ctx.litewaf_body = string.sub(body, 1, max_bytes)
        ngx.ctx.litewaf_body_too_large = true
    else
        ngx.ctx.litewaf_body = body
        ngx.ctx.litewaf_body_too_large = false
    end
    return ngx.ctx.litewaf_body, ngx.ctx.litewaf_body_too_large
end

local function body_enabled(policy)
    if not policy.body_inspection_enabled then
        return false
    end
    local content_type = ngx.var.content_type or ""
    if not list_contains_value(policy.body_inspection_content_types, content_type) then
        return false
    end
    return list_contains_prefix(policy.body_inspection_path_prefixes, ngx.var.uri or "")
end

local function upload_metadata(policy)
    local body, too_large = request_body(policy)
    local metadata = {}
    if too_large then
        table.insert(metadata, { kind = "upload_size", value = tostring(#body), advanced_target = "upload_size" })
    end
    for disposition in string.gmatch(body or "", "Content%-Disposition:%s*([^\r\n]+)") do
        local filename = string.match(disposition, 'filename="([^"]*)"') or string.match(disposition, "filename=([^;]+)")
        if filename and filename ~= "" then
            filename = filename:gsub("^%s+", ""):gsub("%s+$", "")
            local extension = string.match(filename, "%.([A-Za-z0-9_-]+)$") or ""
            table.insert(metadata, { kind = "upload_filename", value = filename, advanced_target = "upload_filename" })
            table.insert(metadata, { kind = "upload_extension", value = extension, advanced_target = "upload_extension" })
        end
    end
    for content_type in string.gmatch(body or "", "Content%-Type:%s*([^\r\n]+)") do
        table.insert(metadata, { kind = "upload_mime", value = content_type, advanced_target = "upload_mime" })
    end
    return metadata, too_large
end

local function enabled_upload_protection_rules(config)
    local rules = {}
    for _, rule in ipairs(config.protection_rules or {}) do
        if rule.module == "upload-protection" and rule.category == "upload" and rule.enabled ~= false then
            table.insert(rules, rule)
        end
    end
    return rules
end

local function upload_rule_scope_matches(rule, site)
    if not entry_for_site(rule, site) then
        return false
    end
    local match = rule.match or {}
    if not methods_match(match.methods) then
        return false
    end
    local path = tostring(match.path or "/")
    local path_match = tostring(match.path_match or "prefix")
    local uri = ngx.var.uri or ""
    if path_match == "exact" then
        return uri == path
    end
    return path_prefix_matches(path, uri)
end

local function extension_set(values)
    local set = {}
    for _, value in ipairs(values or {}) do
        local item = string.lower(tostring(value or ""))
        item = string.gsub(item, "^%.", "")
        if item ~= "" then
            set[item] = true
        end
    end
    return set
end

local function upload_rule_match_detail(rule, policy)
    local upload = rule.upload or {}
    local max_bytes = tonumber(upload.max_bytes or 0) or 0
    local content_length = tonumber(ngx.var.content_length or 0) or 0
    if max_bytes > 0 and content_length > max_bytes then
        return "upload_size",
            "content_length=" .. tostring(content_length) .. ", max_bytes=" .. tostring(max_bytes),
            max_bytes
    end

    local extensions = extension_set(upload.extensions)
    if next(extensions) ~= nil then
        local metadata = upload_metadata(policy)
        local filename = ""
        for _, item in ipairs(metadata) do
            if item.kind == "upload_filename" then
                filename = item.value
            end
            if item.kind == "upload_extension" then
                local extension = string.lower(tostring(item.value or ""))
                if extensions[extension] then
                    return "upload_extension",
                        "filename=" .. bounded(filename) .. ", extension=" .. bounded(extension),
                        0
                end
            end
        end
    end

    return nil, nil, 0
end

local function enforce_upload_protection(config, site, policy)
    local rules = enabled_upload_protection_rules(config)
    if #rules == 0 then
        return nil, nil
    end
    for _, rule in ipairs(rules) do
        if upload_rule_scope_matches(rule, site) then
            local target, metadata, threshold = upload_rule_match_detail(rule, policy)
            if target then
                local action = ((rule.action or {}).type) or "block"
                local disposition = action == "block" and "blocked" or "observed"
                waf_event(site, {
                    event_type = "upload-protection",
                    module = "upload-protection",
                    category = "upload",
                    rule_id = rule.id or 0,
                    rule_name = rule.name or "",
                    rule_type = "upload",
                    target = target,
                    advanced_target = target,
                    action = action,
                    disposition = disposition,
                    threshold = threshold or 0,
                    summary = metadata or "",
                    upload_metadata = metadata or ""
                })
                if action == "block" then
                    return "block", rule
                end
            end
        end
    end
    return nil, nil
end

local function enabled_bot_protection_rules(config)
    local rules = {}
    for _, rule in ipairs(config.protection_rules or {}) do
        if rule.module == "bot-protection" and rule.category == "challenge" and rule.enabled ~= false then
            table.insert(rules, rule)
        end
    end
    table.sort(rules, function(a, b)
        return (tonumber(a.priority or 100) or 100) < (tonumber(b.priority or 100) or 100)
    end)
    return rules
end

local function bot_rule_matches(rule, site)
    if not entry_for_site(rule, site) then
        return false
    end
    local match = rule.match or {}
    if not methods_match(match.methods) then
        return false
    end
    local path = tostring(match.path or "/")
    local path_match = tostring(match.path_match or "prefix")
    local uri = ngx.var.uri or ""
    if path_match == "exact" then
        return uri == path
    end
    return path_prefix_matches(path, uri)
end

local function bot_secret(config)
    if challenge_secret ~= "" then
        return challenge_secret
    end
    return tostring((config or {}).version or "litewaf-local-challenge")
end

local function bot_cookie_name(site, rule)
    return "litewaf_bot_" .. tostring(site.id or 0) .. "_" .. tostring(rule.id or 0)
end

local function bot_device_signal(rule)
    local challenge = rule.challenge or {}
    if challenge.device_binding ~= true then
        return ""
    end
    local base = table.concat({
        tostring(ngx.var.http_user_agent or ""),
        tostring(ngx.var.http_accept_language or "")
    }, ":")
    return ngx.encode_base64(ngx.sha1_bin(base))
end

local function bot_signature(secret, site, rule, expires)
    local base = table.concat({
        tostring(site.id or 0),
        tostring(rule.id or 0),
        client_ip(),
        tostring(expires or 0),
        bot_device_signal(rule)
    }, ":")
    local digest = ngx.hmac_sha1(secret, base)
    return ngx.encode_base64(digest)
end

local function bot_captcha_answer(site, rule, expires)
    local a = (tonumber(rule.id or 0) or 0) % 9 + 1
    local b = (tonumber(site.id or 0) or 0) % 7 + 2
    local c = (tonumber(expires or 0) or 0) % 5
    return a + b + c
end

local function bot_captcha_signature(config, site, rule, expires, answer)
    local base = table.concat({
        tostring(site.id or 0),
        tostring(rule.id or 0),
        client_ip(),
        tostring(expires or 0),
        tostring(answer or 0),
        bot_device_signal(rule)
    }, ":")
    return ngx.encode_base64(ngx.hmac_sha1(bot_secret(config), base))
end

local function bot_captcha_state(config, site, rule)
    local args = ngx.req.get_uri_args()
    local expires = tonumber(args.litewaf_captcha_expires or 0)
    local answer = tonumber(args.litewaf_captcha_answer or -1)
    local signature = tostring(args.litewaf_captcha_signature or "")
    if not expires or expires == 0 or signature == "" then
        return "missing"
    end
    if expires < ngx.time() then
        return "expired"
    end
    local expected = bot_captcha_answer(site, rule, expires)
    local expected_signature = bot_captcha_signature(config, site, rule, expires, expected)
    if answer == expected and signature == expected_signature then
        return "valid"
    end
    return "invalid"
end

local function parse_cookie_header(name)
    local header = ngx.var.http_cookie or ""
    for part in string.gmatch(header, "([^;]+)") do
        local cookie_name, cookie_value = string.match(part, "^%s*([^=]+)=(.*)%s*$")
        if cookie_name == name then
            return cookie_value
        end
    end
    return nil
end

local function append_set_cookie(value)
    local current = ngx.header["Set-Cookie"]
    if not current then
        ngx.header["Set-Cookie"] = value
        return
    end
    if type(current) == "table" then
        table.insert(current, value)
        ngx.header["Set-Cookie"] = current
        return
    end
    ngx.header["Set-Cookie"] = { current, value }
end

local function parse_bot_cookie(site, rule)
    local name = bot_cookie_name(site, rule)
    local value = ngx.var["cookie_" .. name] or parse_cookie_header(name)
    if not value or value == "" then
        return nil, nil
    end
    local expires, signature = string.match(value, "^(%d+)%.([A-Za-z0-9+/=]+)$")
    return tonumber(expires or 0), signature
end

local function bot_challenge_state(config, site, rule)
    local expires, signature = parse_bot_cookie(site, rule)
    if not expires or not signature then
        return "missing"
    end
    if expires < ngx.time() then
        return "expired"
    end
    if signature == bot_signature(bot_secret(config), site, rule, expires) then
        return "valid"
    end
    if (rule.challenge or {}).device_binding == true then
        return "device-mismatch"
    end
    return "invalid"
end

local function set_bot_cookie(config, site, rule)
    local challenge = rule.challenge or {}
    local ttl = tonumber(challenge.verify_ttl_sec or 300) or 300
    local expires = ngx.time() + ttl
    local signature = bot_signature(bot_secret(config), site, rule, expires)
    local name = bot_cookie_name(site, rule)
    append_set_cookie(name .. "=" .. tostring(expires) .. "." .. signature .. "; Path=/; Max-Age=" .. tostring(ttl) .. "; HttpOnly; SameSite=Lax")
end

local function issue_bot_challenge(config, site, rule)
    set_bot_cookie(config, site, rule)
    local target = ngx.escape_uri(ngx.var.request_uri or "/")
    local body = table.concat({
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>LiteWaf Challenge</title></head>",
        "<body><script>location.replace(decodeURIComponent('",
        target,
        "'));</script><noscript>JavaScript is required to continue.</noscript></body></html>"
    })
    ngx.status = ngx.HTTP_OK
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(body)
end

local function issue_bot_captcha(config, site, rule)
    local challenge = rule.challenge or {}
    local ttl = tonumber(challenge.verify_ttl_sec or 300) or 300
    local expires = ngx.time() + ttl
    local answer = bot_captcha_answer(site, rule, expires)
    local signature = bot_captcha_signature(config, site, rule, expires, answer)
    local message = tostring(challenge.failure_message or "Please complete verification to continue.")
    local privacy = tostring(challenge.privacy_notice or "LiteWaf uses local challenge signals for this verification.")
    local target = ngx.escape_uri(ngx.var.uri or "/")
    local body = table.concat({
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>LiteWaf Verification</title></head><body>",
        "<h1>LiteWaf Verification</h1><p>", html_escape(message), "</p>",
        "<form method=\"get\" action=\"", ngx.var.uri or "/", "\">",
        "<label>", tostring((tonumber(rule.id or 0) or 0) % 9 + 1), " + ", tostring((tonumber(site.id or 0) or 0) % 7 + 2), " + ", tostring((tonumber(expires or 0) or 0) % 5), " = ",
        "<input name=\"litewaf_captcha_answer\" inputmode=\"numeric\"></label>",
        "<input type=\"hidden\" name=\"litewaf_captcha_expires\" value=\"", tostring(expires), "\">",
        "<input type=\"hidden\" name=\"litewaf_captcha_signature\" value=\"", signature, "\">",
        "<input type=\"hidden\" name=\"litewaf_captcha_target\" value=\"", target, "\">",
        "<button type=\"submit\">Continue</button></form><p>", html_escape(privacy), "</p></body></html>"
    })
    ngx.status = ngx.HTTP_OK
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(body)
end

local function bot_behavior_score()
    local score = 0
    local ua = tostring(ngx.var.http_user_agent or "")
    local accept = tostring(ngx.var.http_accept or "")
    local accept_language = tostring(ngx.var.http_accept_language or "")
    if ua == "" then score = score + 60 end
    local lower_ua = string.lower(ua)
    if string.find(lower_ua, "curl", 1, true) or string.find(lower_ua, "python", 1, true) or string.find(lower_ua, "bot", 1, true) then
        score = score + 40
    end
    if accept == "" then score = score + 20 end
    if accept_language == "" then score = score + 10 end
    if score > 100 then score = 100 end
    return score
end

local function is_known_search_engine()
    local ua = string.lower(tostring(ngx.var.http_user_agent or ""))
    return string.find(ua, "googlebot", 1, true) or string.find(ua, "bingbot", 1, true) or string.find(ua, "baiduspider", 1, true)
end

local function enforce_bot_protection(config, site)
    local rules = enabled_bot_protection_rules(config)
    if #rules == 0 then
        return nil, nil
    end
    for _, rule in ipairs(rules) do
        if bot_rule_matches(rule, site) then
            local challenge = rule.challenge or {}
            local mode = tostring(challenge.mode or "js-challenge")
            local action = tostring(challenge.failure_action or ((rule.action or {}).type) or "block")
            if mode ~= "js-challenge" and mode ~= "captcha" then
                return nil, nil
            end
            if challenge.search_engine_bypass == true and is_known_search_engine() then
                waf_event(site, {
                    event_type = "bot-protection",
                    module = "bot-protection",
                    category = "challenge",
                    rule_id = rule.id or 0,
                    rule_name = rule.name or "",
                    rule_type = "challenge",
                    target = "path",
                    action = "pass",
                    disposition = "proxied",
                    challenge_mode = mode,
                    challenge_result = "passed",
                    bot_result = "search-engine-bypass",
                    bot_reason = "known search engine user-agent",
                    summary = "bot search engine bypass"
                })
                return nil, nil
            end
            local score = bot_behavior_score()
            local threshold = tonumber(challenge.behavior_threshold or 0) or 0
            if challenge.behavior_enabled == true and threshold > 0 and score < threshold then
                waf_event(site, {
                    event_type = "bot-protection",
                    module = "bot-protection",
                    category = "challenge",
                    rule_id = rule.id or 0,
                    rule_name = rule.name or "",
                    rule_type = "challenge",
                    target = "path",
                    action = "pass",
                    disposition = "proxied",
                    challenge_mode = mode,
                    challenge_result = "passed",
                    bot_result = "behavior-pass",
                    bot_reason = "behavior score below threshold",
                    score = score,
                    threshold = threshold,
                    summary = "bot behavior score passed"
                })
                return nil, nil
            end
            local challenge_state = bot_challenge_state(config, site, rule)
            if mode == "captcha" and challenge_state == "missing" then
                challenge_state = bot_captcha_state(config, site, rule)
                if challenge_state == "valid" then
                    set_bot_cookie(config, site, rule)
                end
            end
            if challenge_state == "valid" then
                waf_event(site, {
                    event_type = "bot-protection",
                    module = "bot-protection",
                    category = "challenge",
                    rule_id = rule.id or 0,
                    rule_name = rule.name or "",
                    rule_type = "challenge",
                    target = "path",
                    action = "pass",
                    disposition = "proxied",
                    challenge_mode = mode,
                    challenge_result = "passed",
                    bot_result = mode == "captcha" and "captcha-passed" or "challenge-passed",
                    bot_reason = "challenge token accepted",
                    device_signal = challenge.device_binding == true and "matched" or "",
                    score = score,
                    threshold = threshold,
                    summary = "bot challenge passed"
                })
                return nil, nil
            end
            if challenge_state == "missing" and action ~= "log-only" then
                waf_event(site, {
                    event_type = "bot-protection",
                    module = "bot-protection",
                    category = "challenge",
                    rule_id = rule.id or 0,
                    rule_name = rule.name or "",
                    rule_type = "challenge",
                    target = "path",
                    action = action,
                    disposition = "blocked",
                    challenge_mode = mode,
                    challenge_result = "issued",
                    bot_result = mode == "captcha" and "captcha-issued" or "challenge-issued",
                    bot_reason = challenge.behavior_enabled == true and "behavior score reached threshold" or "missing pass token",
                    score = score,
                    threshold = threshold,
                    summary = "bot challenge issued"
                })
                if mode == "captcha" then
                    issue_bot_captcha(config, site, rule)
                else
                    issue_bot_challenge(config, site, rule)
                end
                return "challenge", rule
            end
            local disposition = action == "log-only" and "observed" or "blocked"
            waf_event(site, {
                event_type = "bot-protection",
                module = "bot-protection",
                category = "challenge",
                rule_id = rule.id or 0,
                rule_name = rule.name or "",
                rule_type = "challenge",
                target = "path",
                action = action,
                disposition = disposition,
                challenge_mode = mode,
                challenge_result = "failed",
                bot_result = challenge_state == "device-mismatch" and "device-mismatch" or (mode == "captcha" and "captcha-failed" or "challenge-failed"),
                bot_reason = challenge_state == "expired" and "challenge expired" or "challenge verification failed",
                device_signal = challenge_state == "device-mismatch" and "mismatch" or (challenge.device_binding == true and "matched" or ""),
                score = score,
                threshold = threshold,
                summary = challenge_state == "expired" and "bot challenge expired" or "bot challenge failed"
            })
            if action == "log-only" then
                return nil, nil
            end
            return "block", rule
        end
    end
    return nil, nil
end

local function enabled_dynamic_protection_rules(config, category)
    local rules = {}
    for _, rule in ipairs(config.protection_rules or {}) do
        if rule.module == "dynamic-protection" and rule.enabled ~= false then
            if not category or rule.category == category then
                table.insert(rules, rule)
            end
        end
    end
    table.sort(rules, function(a, b)
        return (tonumber(a.priority or 100) or 100) < (tonumber(b.priority or 100) or 100)
    end)
    return rules
end

local function dynamic_rule_matches(rule, site)
    if not entry_for_site(rule, site) then
        return false
    end
    local match = rule.match or {}
    if not methods_match(match.methods) then
        return false
    end
    local path = tostring(match.path or "/")
    local path_match = tostring(match.path_match or "prefix")
    local uri = ngx.var.uri or ""
    if path_match == "exact" then
        return uri == path
    end
    return path_prefix_matches(path, uri)
end

local function dynamic_rule_config(rule)
    local dynamic = rule.dynamic or {}
    if tonumber(dynamic.token_ttl_sec or 0) == 0 then
        dynamic.token_ttl_sec = 300
    end
    if tostring(dynamic.token_placement or "") == "" then
        dynamic.token_placement = "cookie"
    end
    if tostring(dynamic.failure_action or "") == "" then
        dynamic.failure_action = ((rule.action or {}).type) or "block"
    end
    if tostring(dynamic.mutation_marker or "") == "" then
        dynamic.mutation_marker = "body-end"
    end
    if tonumber(dynamic.mutation_max_bytes or 0) == 0 then
        dynamic.mutation_max_bytes = 262144
    end
    if tonumber(dynamic.queue_capacity or 0) == 0 then
        dynamic.queue_capacity = 100
    end
    if tonumber(dynamic.admission_ttl_sec or 0) == 0 then
        dynamic.admission_ttl_sec = 300
    end
    if tonumber(dynamic.retry_interval_sec or 0) == 0 then
        dynamic.retry_interval_sec = 5
    end
    if tostring(dynamic.overflow_action or "") == "" then
        dynamic.overflow_action = ((rule.action or {}).type) or "waiting-room"
    end
    return dynamic
end

local function dynamic_signing_secret(config)
    if dynamic_secret ~= "" then
        return dynamic_secret
    end
    if challenge_secret ~= "" then
        return challenge_secret .. ":dynamic"
    end
    return tostring((config or {}).version or "litewaf-local-dynamic")
end

local function dynamic_cookie_name(prefix, site, rule)
    return prefix .. "_" .. tostring(site.id or 0) .. "_" .. tostring(rule.id or 0)
end

local function dynamic_signature(secret, site, rule, expires, purpose)
    local base = table.concat({
        tostring(purpose or "token"),
        tostring(site.id or 0),
        tostring(rule.id or 0),
        client_ip(),
        tostring(expires or 0)
    }, ":")
    return ngx.encode_base64(ngx.hmac_sha1(secret, base))
end

local function build_dynamic_token(config, site, rule, ttl, purpose)
    local expires = ngx.time() + (tonumber(ttl or 300) or 300)
    local signature = dynamic_signature(dynamic_signing_secret(config), site, rule, expires, purpose)
    return tostring(expires) .. "." .. signature, expires
end

local function parse_dynamic_token_value(value)
    if not value or value == "" then
        return nil, nil
    end
    local expires, signature = string.match(value, "^(%d+)%.([A-Za-z0-9+/=]+)$")
    return tonumber(expires or 0), signature
end

local function dynamic_token_name(site, rule)
    return dynamic_cookie_name("litewaf_dyn", site, rule)
end

local function get_dynamic_token(rule, site)
    local dynamic = dynamic_rule_config(rule)
    local placement = tostring(dynamic.token_placement or "cookie")
    local name = dynamic_token_name(site, rule)
    if placement == "header" then
        local headers = ngx.req.get_headers()
        return headers["X-LiteWaf-Dynamic-Token"] or headers["x-litewaf-dynamic-token"] or headers[name] or headers[string.lower(name)]
    end
    if placement == "query" then
        local args = ngx.req.get_uri_args(20)
        return args["litewaf_dynamic_token"] or args[name]
    end
    return ngx.var["cookie_" .. name] or parse_cookie_header(name)
end

local function set_dynamic_token(config, site, rule)
    local dynamic = dynamic_rule_config(rule)
    local ttl = tonumber(dynamic.token_ttl_sec or 300) or 300
    local token = build_dynamic_token(config, site, rule, ttl, "token")
    local placement = tostring(dynamic.token_placement or "cookie")
    local name = dynamic_token_name(site, rule)
    if placement == "cookie" then
        append_set_cookie(name .. "=" .. token .. "; Path=/; Max-Age=" .. tostring(ttl) .. "; HttpOnly; SameSite=Lax")
    else
        ngx.header["X-LiteWaf-Dynamic-Token"] = token
        ngx.header["X-LiteWaf-Dynamic-Token-Name"] = placement == "query" and "litewaf_dynamic_token" or "X-LiteWaf-Dynamic-Token"
    end
end

local function dynamic_token_state(config, site, rule)
    local value = get_dynamic_token(rule, site)
    local expires, signature = parse_dynamic_token_value(value)
    if not expires or not signature then
        return "missing"
    end
    if expires < ngx.time() then
        return "expired"
    end
    if signature == dynamic_signature(dynamic_signing_secret(config), site, rule, expires, "token") then
        return "valid"
    end
    return "invalid"
end

local function dynamic_event(site, rule, result, action, disposition, summary)
    waf_event(site, {
        event_type = "dynamic-protection",
        module = "dynamic-protection",
        category = rule.category or "",
        rule_id = rule.id or 0,
        rule_name = rule.name or "",
        rule_type = rule.category or "",
        target = "path",
        advanced_target = result,
        action = action or "",
        disposition = disposition or "observed",
        summary = summary or result
    })
end

local function enforce_dynamic_token(config, site, rule)
    local dynamic = dynamic_rule_config(rule)
    local action = tostring(dynamic.failure_action or ((rule.action or {}).type) or "block")
    local state = dynamic_token_state(config, site, rule)
    if state == "valid" then
        dynamic_event(site, rule, "token-passed", "pass", "proxied", "dynamic token passed")
        return nil, nil
    end
    if state == "missing" then
        set_dynamic_token(config, site, rule)
        dynamic_event(site, rule, "token-issued", action, "proxied", "dynamic token issued")
        return nil, nil
    end
    local disposition = action == "log-only" and "observed" or "blocked"
    dynamic_event(site, rule, "token-failed", action, disposition, state == "expired" and "dynamic token expired" or "dynamic token invalid")
    if action == "log-only" then
        return nil, nil
    end
    return "block", rule
end

local function waiting_room_cookie_name(site, rule)
    return dynamic_cookie_name("litewaf_wr", site, rule)
end

local function set_waiting_room_cookie(config, site, rule, ttl)
    local token = build_dynamic_token(config, site, rule, ttl, "waiting-room")
    local name = waiting_room_cookie_name(site, rule)
    append_set_cookie(name .. "=" .. token .. "; Path=/; Max-Age=" .. tostring(ttl) .. "; HttpOnly; SameSite=Lax")
end

local function waiting_room_cookie_valid(config, site, rule)
    local name = waiting_room_cookie_name(site, rule)
    local expires, signature = parse_dynamic_token_value(ngx.var["cookie_" .. name] or parse_cookie_header(name))
    if not expires or not signature or expires < ngx.time() then
        return false
    end
    return signature == dynamic_signature(dynamic_signing_secret(config), site, rule, expires, "waiting-room")
end

local function enforce_waiting_room(config, site, rule)
    local dynamic = dynamic_rule_config(rule)
    local ttl = tonumber(dynamic.admission_ttl_sec or 300) or 300
    if waiting_room_cookie_valid(config, site, rule) then
        dynamic_event(site, rule, "queue-admitted", "pass", "proxied", "waiting-room admission valid")
        return nil, nil
    end

    local dict = ngx.shared.litewaf_dynamic_protection
    if not dict then
        dynamic_event(site, rule, "queue-observed", "log-only", "observed", "waiting-room state unavailable")
        return nil, nil
    end

    local key = table.concat({ "wr", site.id or 0, rule.id or 0 }, ":")
    local current, err = dict:incr(key, 1, 0, ttl)
    if err then
        ngx.log(ngx.ERR, "litewaf waiting-room counter failed: ", err)
        dynamic_event(site, rule, "queue-observed", "log-only", "observed", "waiting-room counter unavailable")
        return nil, nil
    end
    if current == 1 then
        dict:expire(key, ttl)
    end

    local capacity = tonumber(dynamic.queue_capacity or 100) or 100
    if current <= capacity then
        set_waiting_room_cookie(config, site, rule, ttl)
        dynamic_event(site, rule, "queue-admitted", "pass", "proxied", "waiting-room admission issued")
        return nil, nil
    end

    local action = tostring(dynamic.overflow_action or ((rule.action or {}).type) or "waiting-room")
    if action == "log-only" then
        dynamic_event(site, rule, "queue-observed", action, "observed", "waiting-room overflow observed")
        return nil, nil
    end
    if action == "block" then
        ngx.ctx.dynamic_waiting_room_rule = rule
        dynamic_event(site, rule, "queue-blocked", action, "blocked", "waiting-room overflow blocked")
        return "block", rule
    end
    ngx.ctx.dynamic_waiting_room_rule = rule
    dynamic_event(site, rule, "queue-queued", action, "blocked", "waiting-room overflow queued")
    return "waiting-room", rule
end

local function select_dynamic_mutation_rule(config, site)
    local rules = enabled_dynamic_protection_rules(config, "page-mutation")
    for _, rule in ipairs(rules) do
        if dynamic_rule_matches(rule, site) then
            return rule
        end
    end
    return nil
end

local function enforce_dynamic_protection(config, site)
    local rules = enabled_dynamic_protection_rules(config)
    if #rules == 0 then
        return nil, nil
    end

    ngx.ctx.dynamic_mutation_rule = select_dynamic_mutation_rule(config, site)
    for _, rule in ipairs(rules) do
        if rule.category ~= "page-mutation" and dynamic_rule_matches(rule, site) then
            if rule.category == "dynamic-token" then
                local decision = enforce_dynamic_token(config, site, rule)
                if decision then
                    return decision, rule
                end
            elseif rule.category == "waiting-room" then
                local decision = enforce_waiting_room(config, site, rule)
                if decision then
                    return decision, rule
                end
            end
        end
    end
    return nil, nil
end

local function html_content_type()
    local content_type = tostring(ngx.header["Content-Type"] or ngx.header.content_type or "")
    return string.find(string.lower(content_type), "text/html", 1, true) ~= nil
end

local function mutation_snippet(rule)
    return "<script data-litewaf-dynamic=\"" .. tostring(rule.id or 0) .. "\">document.documentElement.dataset.litewafDynamic=\"1\";</script>"
end

local function inject_before_marker(body, marker, snippet)
    local lower = string.lower(body)
    local token = marker == "head-end" and "</head>" or "</body>"
    local start_at, end_at = string.find(lower, token, 1, true)
    if not start_at then
        return nil
    end
    return string.sub(body, 1, start_at - 1) .. snippet .. string.sub(body, start_at)
end

local function values_for_rule(rule, policy)
    local target = rule.target or "args"
    if target == "uri" then
        return { { value = ngx.var.uri, advanced_target = "uri" } }
    end
    if target == "normalized_uri" then
        local value = normalize_value(ngx.var.request_uri or ngx.var.uri, policy)
        return { { value = value, normalized_value = value, advanced_target = target } }
    end
    if target == "normalized_path" then
        local value = normalize_path(ngx.var.uri or "", policy)
        return { { value = value, normalized_value = value, advanced_target = target } }
    end

    if target == "headers" or target == "normalized_headers" then
        local headers = ngx.req.get_headers()
        local values = {}
        for name, value in pairs(headers) do
            if sensitive_header_set[string.lower(tostring(name or ""))] then
                goto continue_header
            end
            local inspected = target == "normalized_headers" and normalize_value(value, policy) or value
            table.insert(values, { value = inspected, normalized_value = inspected, advanced_target = target })
            ::continue_header::
        end
        return values
    end

    if target == "body" or target == "body_json" or target == "body_form" then
        if not body_enabled(policy) then
            return {}
        end
        local body, too_large = request_body(policy)
        if too_large then
            ngx.ctx.litewaf_body_too_large_action = policy.oversized_body_action
        end
        local value = normalize_value(body, policy)
        return { { value = value, normalized_value = value, advanced_target = target } }
    end

    if target == "upload_filename" or target == "upload_extension" or target == "upload_mime" or target == "upload_size" then
        if not policy.upload_inspection_enabled then
            return {}
        end
        local metadata = upload_metadata(policy)
        local values = {}
        for _, item in ipairs(metadata) do
            if item.kind == target then
                table.insert(values, item)
            end
        end
        return values
    end

    local args = ngx.req.get_uri_args()
    local values = {}
    for _, value in pairs(args) do
        if type(value) == "table" then
            for _, item in ipairs(value) do
                local inspected = target == "normalized_args" and normalize_value(item, policy) or item
                table.insert(values, { value = inspected, normalized_value = inspected, advanced_target = target })
            end
        else
            local inspected = target == "normalized_args" and normalize_value(value, policy) or value
            table.insert(values, { value = inspected, normalized_value = inspected, advanced_target = target })
        end
    end
    return values
end

local function rule_matches(rule, policy)
    if rule.module == "attack-protection" and rule.enabled == false then
        return false
    end
    if (rule.target or "") == "upload_size" then
        for _, item in ipairs(values_for_rule(rule, policy)) do
            local limit = tonumber(rule.expression or 0) or 0
            local size = tonumber(item.value or 0) or 0
            if limit >= 0 and size > limit then
                return true, tostring(size), tostring(size), "upload_size"
            end
        end
        return false
    end
    return inspect_values(rule, values_for_rule(rule, policy))
end

local function is_attack_protection_rule(rule)
    return rule.module == "attack-protection" and rule.category == "managed"
end

function _M.access()
    ngx.ctx.started_at = ngx.now()
    ngx.ctx.disposition = "proxied"
    ensure_request_id()
    ngx.var.litewaf_client_ip = client_ip()
    local config = load_config()
    local site = find_site(config, ngx.var.host)
    if not site then
        ngx.ctx.disposition = "rejected"
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.header.content_type = "application/json"
        ngx.say('{"error":{"code":"not_found","message":"site not configured"}}')
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    ngx.var.litewaf_upstream = site.upstream
    ngx.ctx.site = site
    local policy = policy_for_site(site)

    if site.mode == "off" then
        return
    end

    if enforce_dynamic_ban(site) == "block" then
        ngx.ctx.disposition = "blocked"
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.header.content_type = "application/json"
        ngx.say('{"error":{"code":"forbidden","message":"temporarily banned by LiteWaf"}}')
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local access_decision = enforce_access_control(config, site)
    if access_decision == "allow" then
        ngx.ctx.disposition = "proxied"
        return
    end
    if access_decision == "block" then
        ngx.ctx.disposition = "blocked"
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.header.content_type = "application/json"
        ngx.say('{"error":{"code":"forbidden","message":"blocked by LiteWaf access list"}}')
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local rate_decision = enforce_cc_protection(config, site)
    if rate_decision == "block" then
        ngx.ctx.disposition = "rate-limited"
        ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
        ngx.header.content_type = "application/json"
        ngx.say('{"error":{"code":"rate_limited","message":"rate limited by LiteWaf"}}')
        return ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    local upload_decision = enforce_upload_protection(config, site, policy)
    if upload_decision == "block" then
        ngx.ctx.disposition = "blocked"
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.header.content_type = "application/json"
        ngx.say('{"error":{"code":"forbidden","message":"blocked by LiteWaf upload protection"}}')
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local bot_decision = enforce_bot_protection(config, site)
    if bot_decision == "challenge" then
        ngx.ctx.disposition = "blocked"
        return ngx.exit(ngx.HTTP_OK)
    end
    if bot_decision == "block" then
        ngx.ctx.disposition = "blocked"
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.header.content_type = "application/json"
        ngx.say('{"error":{"code":"forbidden","message":"blocked by LiteWaf bot protection"}}')
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local dynamic_decision = enforce_dynamic_protection(config, site)
    if dynamic_decision == "block" then
        ngx.ctx.disposition = "blocked"
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.header.content_type = "application/json"
        ngx.say('{"error":{"code":"forbidden","message":"blocked by LiteWaf dynamic protection"}}')
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
    if dynamic_decision == "waiting-room" then
        local rule = ngx.ctx.dynamic_waiting_room_rule
        local dynamic = rule and dynamic_rule_config(rule) or {}
        ngx.ctx.disposition = "blocked"
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.header["Retry-After"] = tostring(tonumber(dynamic.retry_interval_sec or 5) or 5)
        ngx.say('<!doctype html><html><head><meta charset="utf-8"><title>LiteWaf Waiting Room</title></head><body><h1>Waiting room</h1><p>Please retry shortly.</p></body></html>')
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end

    local score = 0
    local matched_rule_ids = {}
    local threshold = tonumber(policy.risk_threshold or 100) or 100
    local threshold_action = policy.default_action or "block"

    if body_enabled(policy) then
        local _, too_large = request_body(policy)
        if too_large then
            local action = policy.oversized_body_action or "log-only"
            waf_event(site, {
                event_type = "body-inspection",
                target = "body",
                advanced_target = "body",
                action = action,
                disposition = action == "block" and "blocked" or "observed",
                summary = "request body exceeded inspection limit",
                body_metadata = "max_bytes=" .. tostring(policy.body_inspection_max_bytes or 0)
            })
            if action == "block" and site.mode == "protect" then
                ngx.ctx.disposition = "blocked"
                ngx.status = ngx.HTTP_FORBIDDEN
                ngx.header.content_type = "application/json"
                ngx.say('{"error":{"code":"forbidden","message":"request body too large for LiteWaf policy"}}')
                return ngx.exit(ngx.HTTP_FORBIDDEN)
            end
        end
    end

    if policy.upload_inspection_enabled and tonumber(policy.upload_max_bytes or 0) > 0 then
        local content_length = tonumber(ngx.var.content_length or 0) or 0
        if content_length > tonumber(policy.upload_max_bytes or 0) then
            local action = policy.upload_size_action or "block"
            waf_event(site, {
                event_type = "upload-inspection",
                target = "upload_size",
                advanced_target = "upload_size",
                action = action,
                disposition = action == "block" and "blocked" or "observed",
                summary = "upload exceeded configured size",
                upload_metadata = "content_length=" .. tostring(content_length) .. ", max_bytes=" .. tostring(policy.upload_max_bytes)
            })
            if action == "block" and site.mode == "protect" then
                ngx.ctx.disposition = "blocked"
                ngx.status = ngx.HTTP_FORBIDDEN
                ngx.header.content_type = "application/json"
                ngx.say('{"error":{"code":"forbidden","message":"upload too large for LiteWaf policy"}}')
                return ngx.exit(ngx.HTTP_FORBIDDEN)
            end
        end
    end

    local function evaluate_rule(rule)
        local matched, summary, normalized_value, advanced_target = rule_matches(rule, policy)
        if matched then
            score = score + (tonumber(rule.score or 0) or 0)
            table.insert(matched_rule_ids, tostring(rule.id or 0))
            if is_attack_protection_rule(rule) then
                apply_matching_cc_counters(ngx.ctx.config or config, site, "attack-hit", true)
            end
            local disposition = (rule.action == "block" and site.mode == "protect") and "blocked" or "observed"
            waf_event(site, {
                event_type = "rule",
                rule_id = rule.id or 0,
                rule_type = rule.type or "",
                target = rule.target or "",
                action = rule.action or "",
                disposition = disposition,
                module = rule.module or "",
                category = rule.category or "",
                attack_type = rule.attack_type or "",
                group_name = rule.group or "",
                rule_name = rule.name or "",
                summary = summary or rule.name or "",
                advanced_target = advanced_target or "",
                normalized_value = normalized_value or "",
                score = score,
                threshold = threshold,
                matched_rule_ids = table.concat(matched_rule_ids, ","),
                body_metadata = (advanced_target == "body" or advanced_target == "body_json" or advanced_target == "body_form") and ("max_bytes=" .. tostring(policy.body_inspection_max_bytes or 0)) or "",
                upload_metadata = (advanced_target == "upload_filename" or advanced_target == "upload_extension" or advanced_target == "upload_mime" or advanced_target == "upload_size") and (summary or "") or ""
            })
            if rule.action == "block" and site.mode == "protect" then
                if policy.dynamic_ban_enabled and score >= (tonumber(policy.dynamic_ban_score_threshold or 0) or 0) then
                    create_dynamic_ban(site, "waf-rule:" .. tostring(rule.id or 0), policy.dynamic_ban_duration_sec)
                end
                ngx.ctx.disposition = "blocked"
                ngx.status = ngx.HTTP_FORBIDDEN
                ngx.header.content_type = "application/json"
                ngx.say('{"error":{"code":"forbidden","message":"blocked by LiteWaf"}}')
                ngx.exit(ngx.HTTP_FORBIDDEN)
                return "blocked"
            end
        end
        return nil
    end

    for _, rule in ipairs(site.rules or {}) do
        if is_attack_protection_rule(rule) then
            if evaluate_rule(rule) == "blocked" then
                return
            end
        end
    end

    for _, rule in ipairs(site.rules or {}) do
        if not is_attack_protection_rule(rule) then
            if evaluate_rule(rule) == "blocked" then
                return
            end
        end
    end

    if score >= threshold then
        local disposition = (threshold_action == "block" and site.mode == "protect") and "blocked" or "observed"
        waf_event(site, {
            event_type = "score-threshold",
            action = threshold_action,
            disposition = disposition,
            summary = "score threshold reached",
            score = score,
            threshold = threshold,
            matched_rule_ids = table.concat(matched_rule_ids, ",")
        })
        if policy.dynamic_ban_enabled and score >= (tonumber(policy.dynamic_ban_score_threshold or 0) or 0) then
            create_dynamic_ban(site, "score-threshold", policy.dynamic_ban_duration_sec)
        end
        if threshold_action == "block" and site.mode == "protect" then
            ngx.ctx.disposition = "blocked"
            ngx.status = ngx.HTTP_FORBIDDEN
            ngx.header.content_type = "application/json"
            ngx.say('{"error":{"code":"forbidden","message":"blocked by LiteWaf score threshold"}}')
            return ngx.exit(ngx.HTTP_FORBIDDEN)
        end
    end
end

function _M.header_filter()
    local rule = ngx.ctx.dynamic_mutation_rule
    if not rule then
        return
    end
    local site = ngx.ctx.site or {}
    local dynamic = dynamic_rule_config(rule)
    local max_bytes = tonumber(dynamic.mutation_max_bytes or 262144) or 262144
    local content_length = tonumber(ngx.header["Content-Length"] or ngx.header.content_length or 0) or 0

    if not html_content_type() then
        dynamic_event(site, rule, "mutation-skipped", "log-only", "observed", "dynamic mutation skipped: non-html response")
        ngx.ctx.dynamic_mutation_rule = nil
        return
    end
    if content_length > 0 and content_length > max_bytes then
        dynamic_event(site, rule, "mutation-skipped", "log-only", "observed", "dynamic mutation skipped: response too large")
        ngx.ctx.dynamic_mutation_rule = nil
        return
    end

    ngx.ctx.dynamic_mutation_buffer = {}
    ngx.ctx.dynamic_mutation_bytes = 0
    ngx.header["Content-Length"] = nil
end

function _M.body_filter()
    local rule = ngx.ctx.dynamic_mutation_rule
    local buffer = ngx.ctx.dynamic_mutation_buffer
    if not rule or not buffer then
        return
    end

    local chunk = ngx.arg[1] or ""
    local eof = ngx.arg[2]
    local dynamic = dynamic_rule_config(rule)
    local max_bytes = tonumber(dynamic.mutation_max_bytes or 262144) or 262144
    local next_size = (tonumber(ngx.ctx.dynamic_mutation_bytes or 0) or 0) + #chunk

    if next_size > max_bytes then
        table.insert(buffer, chunk)
        ngx.arg[1] = table.concat(buffer)
        ngx.arg[2] = eof
        ngx.ctx.dynamic_mutation_rule = nil
        ngx.ctx.dynamic_mutation_buffer = nil
        dynamic_event(ngx.ctx.site or {}, rule, "mutation-skipped", "log-only", "observed", "dynamic mutation skipped: response exceeded buffer")
        return
    end

    ngx.ctx.dynamic_mutation_bytes = next_size
    table.insert(buffer, chunk)
    if not eof then
        ngx.arg[1] = nil
        return
    end

    local body = table.concat(buffer)
    local injected = inject_before_marker(body, tostring(dynamic.mutation_marker or "body-end"), mutation_snippet(rule))
    if injected then
        ngx.arg[1] = injected
        dynamic_event(ngx.ctx.site or {}, rule, "mutation-applied", "log-only", "proxied", "dynamic mutation applied")
    else
        ngx.arg[1] = body
        dynamic_event(ngx.ctx.site or {}, rule, "mutation-skipped", "log-only", "observed", "dynamic mutation skipped: marker not found")
    end
    ngx.arg[2] = true
    ngx.ctx.dynamic_mutation_rule = nil
    ngx.ctx.dynamic_mutation_buffer = nil
end

function _M.log()
    local site = ngx.ctx.site or {}
    local disposition = ngx.ctx.disposition or "proxied"
    local status = tonumber(ngx.var.status) or 0
    if status == 404 and ngx.ctx.config and site.id then
        apply_matching_cc_counters(ngx.ctx.config, site, "not-found-log", true)
    end
    local started_at = ngx.ctx.started_at or ngx.now()
    local payload = {
        event = "access_log",
        request_id = ensure_request_id(),
        site_id = site.id or 0,
        host = host_without_port(ngx.var.host),
        method = ngx.req.get_method(),
        uri = ngx.var.request_uri,
        status = status,
        upstream_status = tonumber(ngx.var.upstream_status) or 0,
        duration_ms = math.floor((ngx.now() - started_at) * 1000),
        client_ip = client_ip(),
        user_agent = ngx.var.http_user_agent,
        disposition = disposition
    }
    log_json(ngx.INFO, payload)
    schedule_ingestion("/api/v1/ingest/access-logs", payload)
    increment_metric("requests", { payload.site_id, disposition, payload.status })
    if disposition == "blocked" or disposition == "rejected" or disposition == "rate-limited" then
        increment_metric("blocked_requests", { payload.site_id, disposition })
    end
end

function _M.metrics()
    if not metrics_enabled then
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.say("not found")
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end
    ngx.header.content_type = "text/plain; version=0.0.4; charset=utf-8"
    ngx.say("# HELP litewaf_gateway_up Gateway process health.")
    ngx.say("# TYPE litewaf_gateway_up gauge")
    ngx.say("litewaf_gateway_up 1")
    local dict = ngx.shared.litewaf_metrics
    if not dict then
        return
    end
    ngx.say("# HELP litewaf_gateway_requests_total Gateway requests.")
    ngx.say("# TYPE litewaf_gateway_requests_total counter")
    ngx.say("# HELP litewaf_gateway_blocked_requests_total Gateway blocked or rejected requests.")
    ngx.say("# TYPE litewaf_gateway_blocked_requests_total counter")
    ngx.say("# HELP litewaf_gateway_waf_matches_total Gateway WAF matches.")
    ngx.say("# TYPE litewaf_gateway_waf_matches_total counter")
    for _, key in ipairs(dict:get_keys(0)) do
        local value = dict:get(key)
        if type(value) == "number" then
            local parts = {}
            for part in string.gmatch(key, "([^|]+)") do
                table.insert(parts, part)
            end
            if parts[1] == "requests" then
                ngx.say(string.format('litewaf_gateway_requests_total{site_id="%s",disposition="%s",status="%s"} %d', parts[2] or "", parts[3] or "", parts[4] or "", value))
            elseif parts[1] == "blocked_requests" then
                ngx.say(string.format('litewaf_gateway_blocked_requests_total{site_id="%s",disposition="%s"} %d', parts[2] or "", parts[3] or "", value))
            elseif parts[1] == "waf_matches" then
                ngx.say(string.format('litewaf_gateway_waf_matches_total{site_id="%s",event_type="%s",disposition="%s"} %d', parts[2] or "", parts[3] or "", parts[4] or "", value))
            end
        end
    end
end

return _M
