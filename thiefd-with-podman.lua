local socket = require "socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local lanes = require "lanes".configure()
local ssl = require "ssl"
local lfs = require "lfs"

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

-- Global variables
local PODMAN_IMAGE
local FORWARD_MODE = false
local FORWARD_WEBHOOK_URL
local API_USERNAME
local API_PASSWORD
local SERVER_PORT

local function check_certbot_installed()
    local handle = io.popen("which certbot")
    local result = handle:read("*a")
    handle:close()
    return result ~= ""
end

local function install_certbot()
    print("Installing Certbot...")
    os.execute("sudo apt-get update")
    os.execute("sudo apt-get install -y certbot")
end

local function issue_letsencrypt_cert(domain, email)
    print("Issuing/renewing Let's Encrypt certificate for " .. domain)
    local cmd = string.format(
        "sudo certbot certonly --standalone --non-interactive --agree-tos --email %s -d %s",
        email, domain
    )
    local success = os.execute(cmd)
    
    if not success then
        error_print("Failed to issue/renew Let's Encrypt certificate")
        return nil, nil
    end
    
    local cert_file = "/etc/letsencrypt/live/" .. domain .. "/fullchain.pem"
    local key_file = "/etc/letsencrypt/live/" .. domain .. "/privkey.pem"
    
    if not lfs.attributes(cert_file) or not lfs.attributes(key_file) then
        error_print("Certificate files not found after issuing/renewal")
        return nil, nil
    end
    
    debug_print("Certificate issued/renewed successfully")
    return cert_file, key_file
end

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
    
    local request, code = http.request{
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

local function handle_request(client, custom_endpoint)
    debug_print("Handling new request")
    client:settimeout(15)
    
    local request = ""
    while true do
        local line, err = client:receive()
        if err then
            error_print("Failed to receive request: " .. err)
            client:close()
            return
        end
        request = request .. line .. "\r\n"
        if line == "" then break end
    end
    
    debug_print("Received request headers:\n" .. request)
    
    local method, path = request:match("(%u+) (/%S*) HTTP/[%d.]+")
    
    if not method or not path then
        error_print("Invalid request received")
        client:send("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nInvalid Request")
        client:close()
        return
    end
    
    -- Check authentication
    local auth_header = request:match("Authorization: Basic ([%w+/=]+)")
    if not auth_header then
        client:send("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Podman API\"\r\nContent-Type: text/plain\r\n\r\nAuthentication required")
        client:close()
        return
    end
    
    local decoded_auth = (require"mime").unb64(auth_header)
    local username, password = decoded_auth:match("(.+):(.+)")
    
    if username ~= API_USERNAME or password ~= API_PASSWORD then
        client:send("HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain\r\n\r\nInvalid credentials")
        client:close()
        return
    end
    
    local content_length = tonumber(request:match("Content%-Length: (%d+)"))
    local body = ""
    if content_length then
        body, err = client:receive(content_length)
        if err then
            error_print("Failed to receive request body: " .. err)
            client:close()
            return
        end
    end
    
    debug_print("Received request body: '" .. body .. "'")
    
    if method == "POST" and path == custom_endpoint then
        debug_print("Processing POST " .. custom_endpoint .. " request")
        
        if not body or body == "" then
            debug_print("Bad request: missing command")
            client:send("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nCommand is required")
        else
            local command, webhook_url = body:match("^(.-)\n(.+)$")
            if not command then
                command = body
            end
            command = command:gsub("^%s*(.-)%s*$", "%1")
            local is_async = command:match("^async") ~= nil
            if is_async then
                command = command:gsub("^async%s*", "")
            end
            
            debug_print("Processed command: '" .. command .. "', Async: " .. tostring(is_async) .. ", Webhook: " .. (webhook_url or "None"))
            
            if FORWARD_MODE or is_async then
                client:send("HTTP/1.1 202 Accepted\r\nContent-Type: text/plain\r\n\r\nRequest accepted for processing")
                client:close()
                lanes.gen("*", handle_async_request)(PODMAN_IMAGE, command)
                
                local _, result = linda:receive("async_results")
                
                local webhook_to_use = FORWARD_MODE and FORWARD_WEBHOOK_URL or webhook_url
                send_webhook(webhook_to_use, "thiefd command results:\n" .. result)
            else
                local result = execute_podman_command(PODMAN_IMAGE, command)
                client:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n" .. result)
            end
        end
    else
        debug_print("Not found: " .. method .. " " .. path)
        client:send("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot Found")
    end
    
    debug_print("Closing client connection")
    client:close()
end

-- Main function
local function main()
    print_logo()

    -- Read configuration from environment variables
    FORWARD_MODE = os.getenv("THIEFD_FORWARD_MODE") == "true"
    FORWARD_WEBHOOK_URL = os.getenv("THIEFD_FORWARD_WEBHOOK_URL")
    PODMAN_IMAGE = os.getenv("THIEFD_PODMAN_IMAGE")
    API_USERNAME = os.getenv("THIEFD_API_USERNAME")
    API_PASSWORD = os.getenv("THIEFD_API_PASSWORD")
    SERVER_PORT = tonumber(os.getenv("THIEFD_SERVER_PORT")) or 443
    local domain = os.getenv("THIEFD_DOMAIN")
    local email = os.getenv("THIEFD_EMAIL")
    local CUSTOM_ENDPOINT = os.getenv("THIEFD_CUSTOM_ENDPOINT") or "/thiefd"  -- New environment variable

    -- Validate required environment variables
    local required_vars = {
        "THIEFD_PODMAN_IMAGE",
        "THIEFD_API_USERNAME",
        "THIEFD_API_PASSWORD",
        "THIEFD_DOMAIN",
        "THIEFD_EMAIL"
    }

    for _, var in ipairs(required_vars) do
        if not os.getenv(var) then
            error_print("Missing required environment variable: " .. var)
            os.exit(1)
        end
    end

    if FORWARD_MODE then
        if not FORWARD_WEBHOOK_URL then
            error_print("THIEFD_FORWARD_WEBHOOK_URL is required when THIEFD_FORWARD_MODE is true")
            os.exit(1)
        end
        print("Running in forward mode. All requests will be sent to: " .. FORWARD_WEBHOOK_URL)
    else
        print("Running in normal mode.")
    end

    print("Using Podman image: " .. PODMAN_IMAGE)
    print("Server will listen on port: " .. SERVER_PORT)
    print("Custom endpoint: " .. CUSTOM_ENDPOINT)

    if not check_certbot_installed() then
        error_print("Certbot is required for Let's Encrypt certificates. Please install it and try again.")
        os.exit(1)
    end

    local cert_file, key_file = issue_letsencrypt_cert(domain, email)
    if not cert_file or not key_file then
        error_print("Failed to issue/renew Let's Encrypt certificate. Exiting.")
        os.exit(1)
    end

    local params = {
        mode = "server",
        protocol = "any",
        key = key_file,
        certificate = cert_file,
        cafile = cert_file,
        verify = {"none"},
        options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
    }

    local server = assert(socket.bind("0.0.0.0", SERVER_PORT))
    debug_print("Server listening on port " .. SERVER_PORT .. " (HTTPS)...")

    while true do
        debug_print("Waiting for new connection...")
        local client, err = server:accept()
        if client then
            debug_print("New connection accepted")
            local ssl_client = assert(ssl.wrap(client, params))
            ssl_client:dohandshake()
            local ok, err = pcall(function()
                handle_request(ssl_client, CUSTOM_ENDPOINT)  -- Pass CUSTOM_ENDPOINT to handle_request
            end)
            if not ok then
                error_print("Error handling request: " .. tostring(err))
            end
        else
            error_print("Failed to accept connection: " .. tostring(err))
        end
    end
end

-- Run the main function
main()
