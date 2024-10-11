local socket = require "socket"
local ssl = require "ssl"
local https = require "ssl.https"
local ltn12 = require "ltn12"
local lanes = require "lanes".configure()

-- Print ASCII Logo
local function print_logo()
    local logo = [[
████████╗██╗  ██╗██╗███████╗███████╗██████╗ 
╚══██╔══╝██║  ██║██║██╔════╝██╔════╝██╔══██╗
   ██║   ███████║██║█████╗  █████╗  ██║  ██║
   ██║   ██╔══██║██║██╔══╝  ██╔══╝  ██║  ██║
   ██║   ██║  ██║██║███████╗██║     ██████╔╝
   ╚═╝   ╚═╝  ╚═╝╚═╝╚══════╝╚═╝     ╚═════╝ 
   ==============================WITH PODMAN
    ]]
    print(logo)
end

local function simple_json_encode(data)
    if type(data) == "string" then
        return '"' .. data:gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
    elseif type(data) == "table" then
        local json = "{"
        for k, v in pairs(data) do
            if type(k) == "string" then
                json = json .. '"' .. k .. '":'
            else
                json = json .. "[" .. tostring(k) .. "]:"
            end
            json = json .. simple_json_encode(v) .. ","
        end
        return json:sub(1, -2) .. "}"
    else
        return tostring(data)
    end
end

local function debug_print(msg)
    print(os.date("%Y-%m-%d %H:%M:%S") .. " [DEBUG] " .. msg)
end

local function error_print(msg)
    print(os.date("%Y-%m-%d %H:%M:%S") .. " [ERROR] " .. msg)
end

local PODMAN_IMAGE
local FORWARD_MODE = false
local FORWARD_WEBHOOK_URL
local SERVER_CERT = "/path/to/server.crt"
local SERVER_KEY = "/path/to/server.key"
local CA_CERT = "/path/to/ca.crt"

local function execute_podman_command(podman_image, command)
    if not podman_image or podman_image == "" then
        error_print("Podman image name is empty")
        return "Error: Empty Podman image name"
    end
    if not command or command == "" then
        error_print("Attempt to execute empty command")
        return "Error: Empty command"
    end
    debug_print("Executing Podman command: " .. command)
    local cmd = string.format("podman run --rm %s %s", podman_image, command)
    local handle = io.popen(cmd)
    local result = handle:read("*a")
    handle:close()
    debug_print("Podman execution completed")
    return result
end

local function send_webhook(url, data)
    debug_print("Sending webhook to: " .. url)
    local payload = simple_json_encode({text = data})
    local response = {}
    
    local request, code = https.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = #payload
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response)
    }
    
    debug_print("Webhook sent, response code: " .. tostring(code))
    if code ~= 200 then
        error_print("Webhook request failed. Response: " .. table.concat(response))
    end
    return code, table.concat(response)
end

local linda = lanes.linda()

local function handle_async_request(podman_image, command)
    local result = execute_podman_command(podman_image, command)
    linda:send("async_results", result)
end

local function create_https_server(port)
    local server = assert(socket.bind("0.0.0.0", port))
    local ctx = assert(ssl.newcontext({
        mode = "server",
        protocol = "any",
        key = SERVER_KEY,
        certificate = SERVER_CERT,
        cafile = CA_CERT,
        verify = {"peer", "fail_if_no_peer_cert"},
        options = {"all", "no_sslv2", "
