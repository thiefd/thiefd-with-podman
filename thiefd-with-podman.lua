local socket = require "socket"
local ssl = require "ssl"
local https = require "ssl.https"
local ltn12 = require "ltn12"
local lanes = require "lanes".configure()
local os = require "os"

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
local SERVER_CERT = "certs/server.crt"
local SERVER_KEY = "certs/server.key"
local CA_CERT = "certs/ca.crt"

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
        options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"}
    }))
    return server, ctx
end

local function handle_https_request(client, ctx)
    local ssl_client = assert(ssl.wrap(client, ctx))
    local success, err = ssl_client:dohandshake()
    if not success then
        error_print("TLS handshake failed: " .. tostring(err))
        ssl_client:close()
        return
    end

    -- Verify client certificate
    local cert = ssl_client:getpeercertificate()
    if not cert then
        error_print("No client certificate provided")
        ssl_client:close()
        return
    end

    debug_print("Client certificate verified")

    ssl_client:settimeout(15)
    
    local request = ""
    while true do
        local line, err = ssl_client:receive()
        if err then
            error_print("Failed to receive request: " .. err)
            ssl_client:close()
            return
        end
        request = request .. line .. "\r\n"
        if line == "" then break end
    end
    
    debug_print("Received request headers:\n" .. request)
    
    local method, path = request:match("(%u+) (/%S*) HTTP/[%d.]+")
    
    if not method or not path then
        error_print("Invalid request received")
        ssl_client:send("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nInvalid Request")
        ssl_client:close()
        return
    end
    
    local content_length = tonumber(request:match("Content%-Length: (%d+)"))
    local body = ""
    if content_length then
        body, err = ssl_client:receive(content_length)
        if err then
            error_print("Failed to receive request body: " .. err)
            ssl_client:close()
            return
        end
    end
    
    debug_print("Received request body: '" .. body .. "'")
    
    if method == "POST" and path == "/thiefd" then
        debug_print("Processing POST /thiefd request")
        
        if not body or body == "" then
            debug_print("Bad request: missing command")
            ssl_client:send("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nCommand is required")
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
                ssl_client:send("HTTP/1.1 202 Accepted\r\nContent-Type: text/plain\r\n\r\nRequest accepted for processing")
                ssl_client:close()
                lanes.gen("*", handle_async_request)(PODMAN_IMAGE, command)
                
                local _, result = linda:receive("async_results")
                
                local webhook_to_use = FORWARD_MODE and FORWARD_WEBHOOK_URL or webhook_url
                send_webhook(webhook_to_use, "thiefd command results:\n" .. result)
            else
                local result = execute_podman_command(PODMAN_IMAGE, command)
                ssl_client:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n" .. result)
            end
        end
    else
        debug_print("Not found: " .. method .. " " .. path)
        ssl_client:send("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot Found")
    end
    
    debug_print("Closing client connection")
    ssl_client:close()
end

local function generate_certificates()
    print("Generating TLS certificates...")
    
    -- Prompt for certificate details
    print("Enter the Common Name for the CA (e.g., Your Company Name):")
    local ca_cn = io.read()
    print("Enter the Common Name for the server certificate (e.g., localhost or your domain):")
    local server_cn = io.read()
    print("Enter the Common Name for the client certificate (e.g., ClientName):")
    local client_cn = io.read()
    
    -- Create a directory for certificates
    os.execute("mkdir -p certs")
    
    -- Generate CA key and certificate
    os.execute("openssl genpkey -algorithm RSA -out certs/ca.key")
    os.execute(string.format("openssl req -x509 -new -nodes -key certs/ca.key -sha256 -days 1024 -out certs/ca.crt -subj '/CN=%s'", ca_cn))
    
    -- Generate server key and CSR
    os.execute("openssl genpkey -algorithm RSA -out certs/server.key")
    os.execute(string.format("openssl req -new -key certs/server.key -out certs/server.csr -subj '/CN=%s'", server_cn))
    
    -- Sign server certificate with CA
    os.execute("openssl x509 -req -in certs/server.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial -out certs/server.crt -days 365 -sha256")
    
    -- Generate client key and CSR
    os.execute("openssl genpkey -algorithm RSA -out certs/client.key")
    os.execute(string.format("openssl req -new -key certs/client.key -out certs/client.csr -subj '/CN=%s'", client_cn))
    
    -- Sign client certificate with CA
    os.execute("openssl x509 -req -in certs/client.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial -out certs/client.crt -days 365 -sha256")
    
    print("Certificates generated successfully in the 'certs' directory.")
end

-- Main function
local function main()
    print_logo()
    
    if #arg < 1 then
        print("Usage: lua script.lua <port> [--forward <webhook_url>]")
        os.exit(1)
    end
    
    local port = tonumber(arg[1])
    if not port then
        print("Invalid port number")
        os.exit(1)
    end
    
    if arg[2] == "--forward" and arg[3] then
        FORWARD_MODE = true
        FORWARD_WEBHOOK_URL = arg[3]
        print("Running in forward mode. All requests will be sent to: " .. FORWARD_WEBHOOK_URL)
    else
        print("Running in normal mode.")
    end

    print("Do you want to generate new TLS certificates? (y/n)")
    local generate_certs = io.read():lower()
    if generate_certs == "y" then
        generate_certificates()
    else
        print("Using existing certificates. Make sure they are properly configured.")
    end

    print("Enter the Podman image name to use:")
    PODMAN_IMAGE = io.read()
    
    local server, ctx = create_https_server(port)
    debug_print("Server listening on port " .. port .. " (HTTPS with mutual TLS)...")

    while true do
        debug_print("Waiting for new connection...")
        local client, err = server:accept()
        if client then
            debug_print("New connection accepted")
            local ok, err = pcall(handle_https_request, client, ctx)
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
