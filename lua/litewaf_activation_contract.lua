local contract = {}

contract.schema_version = 1
contract.max_status_message_len = 480

local known_states = {
    generated = true,
    validating = true,
    activating = true,
    activated = true,
    validation_failed = true,
    reload_failed = true,
    probe_failed = true,
    activation_timeout = true,
    superseded = true,
    rollback_failed = true,
}

local required_artifacts = {
    ["active.json"] = true,
    ["nginx.conf"] = true,
    ["listeners/applications.conf"] = true,
    ["listeners/body-size.conf"] = true,
}

local function valid_version(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 128
        and value:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

local function valid_checksum(value)
    return type(value) == "string"
        and #value == 71
        and value:match("^sha256:[0-9a-f]+$") ~= nil
end

local function valid_timestamp(value)
    if type(value) ~= "string" then
        return false
    end
    local base = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"
    return value:match(base .. "Z$") ~= nil
        or value:match(base .. "%.%d+Z$") ~= nil
        or value:match(base .. "[+%-]%d%d:%d%d$") ~= nil
        or value:match(base .. "%.%d+[+%-]%d%d:%d%d$") ~= nil
end

local function valid_schema_and_version(value, kind)
    if type(value) ~= "table" then
        return nil, kind .. " must be an object"
    end
    if value.schema_version ~= contract.schema_version then
        return nil, kind .. " has an unsupported schema_version"
    end
    if not valid_version(value.version) then
        return nil, kind .. " version is invalid"
    end
    return true
end

function contract.validate_manifest(value)
    local ok, err = valid_schema_and_version(value, "manifest")
    if not ok then
        return nil, err
    end
    if not valid_timestamp(value.generated_at) then
        return nil, "manifest generated_at is invalid"
    end
    if type(value.artifacts) ~= "table" or #value.artifacts == 0 then
        return nil, "manifest artifacts are required"
    end
    local required = {}
    local seen = {}
    for name in pairs(required_artifacts) do
        required[name] = false
    end
    for _, artifact in ipairs(value.artifacts) do
        if type(artifact) ~= "table" or type(artifact.path) ~= "string" or artifact.path == "" then
            return nil, "manifest artifact path is required"
        end
        if artifact.path:sub(1, 1) == "/" or artifact.path:find("\\", 1, true) or artifact.path:find("..", 1, true) or artifact.path:find("[\r\n\t]") then
            return nil, "manifest artifact path is unsafe"
        end
        if seen[artifact.path] then
            return nil, "manifest artifact path is duplicated"
        end
        if not valid_checksum(artifact.sha256) then
            return nil, "manifest artifact checksum is invalid"
        end
        if type(artifact.size) ~= "number" or artifact.size < 0 then
            return nil, "manifest artifact size is invalid"
        end
        seen[artifact.path] = true
        if required[artifact.path] ~= nil then
            required[artifact.path] = true
        end
    end
    for name, present in pairs(required) do
        if not present then
            return nil, "manifest required artifact is missing: " .. name
        end
    end
    if type(value.listeners) ~= "table" then
        return nil, "manifest listeners must be an array"
    end
    local listeners = {}
    for _, listener in ipairs(value.listeners) do
        if type(listener) ~= "table" or type(listener.port) ~= "number" or listener.port < 1 or listener.port > 65535 then
            return nil, "manifest listener port is invalid"
        end
        if listener.protocol ~= "http" and listener.protocol ~= "https" then
            return nil, "manifest listener protocol is invalid"
        end
        if type(listener.host) ~= "string" or listener.host == "" or listener.host:find("*", 1, true) or listener.host:find(" ", 1, true) then
            return nil, "manifest listener host must be exact"
        end
        local key = tostring(listener.port) .. "/" .. listener.protocol
        if listeners[key] then
            return nil, "manifest listener group is duplicated"
        end
        listeners[key] = true
    end
    return true
end

function contract.validate_request(value)
    local ok, err = valid_schema_and_version(value, "activation request")
    if not ok then
        return nil, err
    end
    if not valid_checksum(value.checksum) then
        return nil, "activation request checksum is invalid"
    end
    if not valid_timestamp(value.requested_at) then
        return nil, "activation request requested_at is invalid"
    end
    if value.previous_version ~= nil and value.previous_version ~= "" then
        if not valid_version(value.previous_version) or value.previous_version == value.version then
            return nil, "activation request previous_version is invalid"
        end
    end
    return true
end

function contract.validate_status(value)
    local ok, err = valid_schema_and_version(value, "activation status")
    if not ok then
        return nil, err
    end
    if not valid_checksum(value.checksum) then
        return nil, "activation status checksum is invalid"
    end
    if not known_states[value.status] then
        return nil, "activation status is unknown"
    end
    if type(value.stage) ~= "string" or #value.stage < 1 or #value.stage > 64 or not value.stage:match("^[a-z][a-z0-9_-]*$") then
        return nil, "activation status stage is invalid"
    end
    if value.message ~= nil and (type(value.message) ~= "string" or #value.message > contract.max_status_message_len) then
        return nil, "activation status message is too long"
    end
    if not valid_timestamp(value.updated_at) then
        return nil, "activation status updated_at is invalid"
    end
    if value.previous_version ~= nil and value.previous_version ~= "" and not valid_version(value.previous_version) then
        return nil, "activation status previous_version is invalid"
    end
    return true
end

function contract.status_matches_request(status, request)
    return type(status) == "table"
        and type(request) == "table"
        and status.version == request.version
        and status.checksum == request.checksum
end

return contract
