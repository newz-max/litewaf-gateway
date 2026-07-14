local cjson = require "cjson.safe"
local contract = require "litewaf_activation_contract"

local function fail(message)
    io.stderr:write(tostring(message or "activation contract error") .. "\n")
    os.exit(1)
end

local function read_json(path)
    local file, err = io.open(path, "rb")
    if not file then
        fail("open JSON failed: " .. tostring(err))
    end
    local payload = file:read("*a")
    file:close()
    local value, decode_err = cjson.decode(payload)
    if not value then
        fail("decode JSON failed: " .. tostring(decode_err))
    end
    return value
end

local command = arg[1]
local file_path = arg[2]
if not command or not file_path then
    fail("usage: activation-contract-cli.lua <request|manifest|status-match> <path> [path-or-version]")
end

if command == "request" then
    local request = read_json(file_path)
    local ok, err = contract.validate_request(request)
    if not ok then fail(err) end
    io.write(request.version, "\t", request.checksum, "\t", request.previous_version or "", "\n")
elseif command == "manifest" then
    local manifest = read_json(file_path)
    local ok, err = contract.validate_manifest(manifest)
    if not ok then fail(err) end
    local expected_version = arg[3]
    if expected_version and manifest.version ~= expected_version then
        fail("manifest version does not match activation request")
    end
    for _, artifact in ipairs(manifest.artifacts) do
        io.write("artifact\t", artifact.path, "\t", artifact.sha256, "\t", tostring(artifact.size), "\n")
    end
    for _, listener in ipairs(manifest.listeners) do
        io.write("listener\t", tostring(listener.port), "\t", listener.protocol, "\t", listener.host, "\n")
    end
elseif command == "status-match" then
    local status = read_json(file_path)
    local request = read_json(arg[3] or "")
    local ok, err = contract.validate_status(status)
    if not ok then fail(err) end
    ok, err = contract.validate_request(request)
    if not ok then fail(err) end
    if not contract.status_matches_request(status, request) then
        os.exit(2)
    end
    io.write(status.status, "\n")
else
    fail("unknown activation contract command: " .. tostring(command))
end
