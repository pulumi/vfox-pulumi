-- pulumi_home.lua
-- Shared module for managing PULUMI_HOME plugin installations
-- This ensures consistent symlink/copy behavior across hooks

local M = {}

-- Check if running on Windows (case-insensitive)
function M.is_windows()
    local os_type = RUNTIME.osType
    return os_type == "Windows" or os_type == "windows" or os_type == "WINDOWS"
end

-- Execute command on Windows using io.popen (cmd.exec doesn't work in mise on Windows)
local function windows_exec(command)
    local handle = io.popen(command .. " 2>&1")
    local output = handle:read("*a")
    local success, exit_type, exit_code = handle:close()

    if not success then
        error(string.format("Command failed: %s\nOutput: %s", command, output))
    end

    return output
end

-- Parse tool name into owner, repo, plugin kind, and package name
local function parse_tool_info(tool)
    local strings = require("strings")

    local owner, repo = tool:match("^([^/%s]+)/([^/%s]+)$")
    if not owner or not repo then
        return nil, "Tool " .. tool .. " must follow format owner/repo"
    end

    -- Determine plugin type from repo name
    local kind
    local package_name
    if strings.has_prefix(repo, "pulumi-converter") then
        kind = "converter"
        package_name = repo:gsub("^pulumi%-converter%-", "")
    elseif strings.has_prefix(repo, "pulumi-tool") then
        kind = "tool"
        package_name = repo:gsub("^pulumi%-tool%-", "")
    else
        kind = "resource"
        package_name = repo:gsub("^pulumi%-", "")
    end

    return {
        owner = owner,
        repo = repo,
        kind = kind,
        package_name = package_name,
    }
end

-- Install to PULUMI_HOME using platform-specific approach
-- Unix: Symlink (saves disk space)
-- Windows: Copy (symlinks need admin/Developer Mode)
function M.install_to_pulumi_home(mise_bin_path, tool, version)
    print("[pulumi_home] install_to_pulumi_home called for tool: " .. tool .. ", version: " .. version)
    local file = require("file")
    local cmd = require("cmd")
    local strings = require("strings")

    -- Parse tool info
    print("[pulumi_home] Parsing tool info")
    local tool_info, err = parse_tool_info(tool)
    if not tool_info then
        -- Silently return if we can't parse the tool name
        print("[pulumi_home] Failed to parse tool info, returning silently: " .. tostring(err))
        return
    end
    print("[pulumi_home] Tool info - kind: " .. tool_info.kind .. ", package_name: " .. tool_info.package_name)

    local kind = tool_info.kind
    local package_name = tool_info.package_name

    -- Determine PULUMI_HOME location
    print("[pulumi_home] Determining PULUMI_HOME location")
    local pulumi_home = os.getenv("PULUMI_HOME")
    if not pulumi_home or pulumi_home == "" then
        if M.is_windows() then
            pulumi_home = file.join_path(os.getenv("USERPROFILE"), ".pulumi")
        else
            pulumi_home = file.join_path(os.getenv("HOME"), ".pulumi")
        end
    end
    print("[pulumi_home] PULUMI_HOME: " .. pulumi_home)

    -- Build paths: PULUMI_HOME/plugins/<type>-<name>-v<version>/pulumi-<type>-<name>
    local plugin_dir_name = strings.join({ kind, package_name, "v" .. version }, "-")
    local binary_name = strings.join({ "pulumi", kind, package_name }, "-")
    -- On Windows, add .exe extension
    if M.is_windows() then
        binary_name = binary_name .. ".exe"
    end
    local plugin_dir = file.join_path(pulumi_home, "plugins", plugin_dir_name)
    local plugins_dir = file.join_path(pulumi_home, "plugins")
    local source_binary = file.join_path(mise_bin_path, binary_name)
    local target_binary = file.join_path(plugin_dir, binary_name)
    print("[pulumi_home] Source binary: " .. source_binary)
    print("[pulumi_home] Target binary: " .. target_binary)
    print("[pulumi_home] Plugin dir: " .. plugin_dir)

    -- Platform-specific installation
    print("[pulumi_home] Platform: " .. (M.is_windows() and "Windows" or "Unix"))
    if M.is_windows() then
        -- Windows: Copy binary
        -- Normalize paths to backslashes only
        print("[pulumi_home] Normalizing Windows paths")
        local normalized_plugin_dir = plugin_dir:gsub("/", "\\")
        local normalized_plugins_dir = plugins_dir:gsub("/", "\\")
        local normalized_source = source_binary:gsub("/", "\\")
        local normalized_target = target_binary:gsub("/", "\\")

        -- Remove old plugin dir if exists (ignore errors)
        print("[pulumi_home] Removing old plugin dir (if exists): " .. normalized_plugin_dir)
        pcall(function()
            windows_exec('rmdir /S /Q "' .. normalized_plugin_dir .. '"')
        end)
        print("[pulumi_home] Old plugin dir removed")

        -- Create parent directory (might already exist from other plugins)
        print("[pulumi_home] Creating parent plugins dir: " .. normalized_plugins_dir)
        pcall(function()
            windows_exec('mkdir "' .. normalized_plugins_dir .. '"')
        end)
        print("[pulumi_home] Parent plugins dir created")

        -- Create plugin directory
        print("[pulumi_home] Creating plugin dir: " .. normalized_plugin_dir)
        windows_exec('mkdir "' .. normalized_plugin_dir .. '"')
        print("[pulumi_home] Plugin dir created")

        -- Verify source exists before copying
        print("[pulumi_home] Verifying source binary exists: " .. normalized_source)
        local source_check, source_err = pcall(function()
            windows_exec('dir "' .. normalized_source .. '" >NUL')
        end)
        if not source_check then
            print("[pulumi_home] ERROR: Source binary not found")
            error(string.format("Source binary not found: %s", normalized_source))
        end
        print("[pulumi_home] Source binary verified")

        print("[pulumi_home] Copying binary from source to target")
        windows_exec(string.format('copy /Y "%s" "%s"', normalized_source, normalized_target))
        print("[pulumi_home] Binary copied successfully")
    else
        -- Unix: Symlink binary (saves disk space)
        print("[pulumi_home] Removing old plugin dir: " .. plugin_dir)
        cmd.exec("rm -rf " .. plugin_dir)
        print("[pulumi_home] Old plugin dir removed")

        print("[pulumi_home] Creating plugin dir: " .. plugin_dir)
        cmd.exec("mkdir -p " .. plugin_dir)
        print("[pulumi_home] Plugin dir created")

        print("[pulumi_home] Creating symlink from " .. source_binary .. " to " .. target_binary)
        cmd.exec(string.format("ln -s %s %s", source_binary, target_binary))
        print("[pulumi_home] Symlink created successfully")
    end
    print("[pulumi_home] install_to_pulumi_home completed")
end

-- Check if symlink/copy exists in PULUMI_HOME
-- Returns true if the plugin is already installed, false otherwise
function M.check_pulumi_home_exists(mise_bin_path, tool, version)
    print("[pulumi_home] check_pulumi_home_exists called for tool: " .. tool)
    local file = require("file")
    local cmd = require("cmd")
    local strings = require("strings")

    -- Parse tool info
    print("[pulumi_home] Parsing tool info")
    local tool_info, err = parse_tool_info(tool)
    if not tool_info then
        print("[pulumi_home] Failed to parse tool info: " .. tostring(err))
        return false
    end
    print("[pulumi_home] Tool info - kind: " .. tool_info.kind .. ", package_name: " .. tool_info.package_name)

    local kind = tool_info.kind
    local package_name = tool_info.package_name

    -- Determine PULUMI_HOME location
    print("[pulumi_home] Determining PULUMI_HOME location")
    local pulumi_home = os.getenv("PULUMI_HOME")
    if not pulumi_home or pulumi_home == "" then
        if M.is_windows() then
            pulumi_home = file.join_path(os.getenv("USERPROFILE"), ".pulumi")
        else
            pulumi_home = file.join_path(os.getenv("HOME"), ".pulumi")
        end
    end
    print("[pulumi_home] PULUMI_HOME: " .. pulumi_home)

    -- Build target binary path
    local plugin_dir_name = strings.join({ kind, package_name, "v" .. version }, "-")
    local binary_name = strings.join({ "pulumi", kind, package_name }, "-")
    if M.is_windows() then
        binary_name = binary_name .. ".exe"
    end
    local plugin_dir = file.join_path(pulumi_home, "plugins", plugin_dir_name)
    local target_binary = file.join_path(plugin_dir, binary_name)
    print("[pulumi_home] Target binary path: " .. target_binary)

    -- Check if target exists
    print("[pulumi_home] Checking if target binary exists")
    if M.is_windows() then
        local normalized_target = target_binary:gsub("/", "\\")
        print("[pulumi_home] Normalized Windows path: " .. normalized_target)
        local result = pcall(function()
            local handle = io.popen('dir "' .. normalized_target .. '" 2>NUL')
            local output = handle:read("*a")
            handle:close()
            -- Check that output is non-empty and contains the file (not just "File Not Found")
            if output and output ~= "" and not output:match("File Not Found") and not output:match("cannot find") then
                return true
            end
            error("not found")
        end)
        print("[pulumi_home] Windows check result: " .. tostring(result))
        return result
    else
        print("[pulumi_home] Running Unix test command: test -f " .. target_binary)
        local result = pcall(function()
            cmd.exec("test -f " .. target_binary)
        end)
        print("[pulumi_home] Unix check result: " .. tostring(result))
        return result
    end
end

-- Check if binary exists in mise cache
-- Returns true if the plugin binary is already installed in mise's location
function M.check_mise_cache_exists(mise_bin_path, tool, version)
    local file = require("file")
    local cmd = require("cmd")
    local strings = require("strings")

    -- Parse tool info
    local tool_info, err = parse_tool_info(tool)
    if not tool_info then
        return false
    end

    local kind = tool_info.kind
    local package_name = tool_info.package_name

    -- Build binary name
    local binary_name = strings.join({ "pulumi", kind, package_name }, "-")
    if M.is_windows() then
        binary_name = binary_name .. ".exe"
    end

    local binary_path = file.join_path(mise_bin_path, binary_name)

    -- Check if binary exists
    if M.is_windows() then
        local normalized_path = binary_path:gsub("/", "\\")
        return pcall(function()
            local handle = io.popen('dir "' .. normalized_path .. '" 2>NUL')
            local output = handle:read("*a")
            handle:close()
            -- Check that output is non-empty and contains the file
            if output and output ~= "" and not output:match("File Not Found") and not output:match("cannot find") then
                return true
            end
            error("not found")
        end)
    else
        return pcall(function()
            cmd.exec("test -f " .. binary_path)
        end)
    end
end

-- Ensure symlink/copy exists in PULUMI_HOME (idempotent)
-- Only creates the link if it doesn't already exist
function M.ensure_pulumi_home_link(mise_bin_path, tool, version)
    print("[pulumi_home] ensure_pulumi_home_link called for tool: " .. tool .. ", version: " .. version .. ", path: " .. mise_bin_path)
    print("[pulumi_home] Checking if PULUMI_HOME link already exists")
    local exists = M.check_pulumi_home_exists(mise_bin_path, tool, version)
    print("[pulumi_home] PULUMI_HOME link exists: " .. tostring(exists))
    if not exists then
        print("[pulumi_home] Creating PULUMI_HOME link")
        M.install_to_pulumi_home(mise_bin_path, tool, version)
        print("[pulumi_home] PULUMI_HOME link created successfully")
    else
        print("[pulumi_home] Skipping creation (link already exists)")
    end
end

return M
