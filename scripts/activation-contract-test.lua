local cjson = require "cjson.safe"
local contract = require "litewaf_activation_contract"

local function fail(message)
    io.stderr:write(message .. "\n")
    os.exit(1)
end

local function read_json(name)
    local file, err = io.open(name, "rb")
    if not file then
        fail("open fixture failed: " .. tostring(err))
    end
    local payload = file:read("*a")
    file:close()
    local value, decode_err = cjson.decode(payload)
    if not value then
        fail("decode fixture failed: " .. tostring(decode_err))
    end
    return value
end

local fixture_dir = arg[1] or "/workspace/conf/contracts"
local manifest = read_json(fixture_dir .. "/manifest.valid.json")
local request = read_json(fixture_dir .. "/activate.valid.json")
local status = read_json(fixture_dir .. "/activation-status.valid.json")

local ok, err = contract.validate_manifest(manifest)
if not ok then fail(err) end
ok, err = contract.validate_request(request)
if not ok then fail(err) end
ok, err = contract.validate_status(status)
if not ok then fail(err) end
if not contract.status_matches_request(status, request) then
    fail("valid status did not match request")
end

status.status = "completed"
if contract.validate_status(status) then
    fail("unknown activation state was accepted")
end
status = read_json(fixture_dir .. "/activation-status.valid.json")
status.checksum = "sha256:" .. string.rep("f", 64)
if contract.status_matches_request(status, request) then
    fail("mismatched checksum was correlated")
end

manifest.artifacts = { manifest.artifacts[1] }
if contract.validate_manifest(manifest) then
    fail("malformed manifest was accepted")
end

status = read_json(fixture_dir .. "/activation-status.valid.json")
status.message = string.rep("x", contract.max_status_message_len + 1)
if contract.validate_status(status) then
    fail("unbounded activation message was accepted")
end

print("activation-contract-test passed")
