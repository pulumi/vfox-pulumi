-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall

-- Helper Functions

-- Check if running on Windows (case-insensitive)
local function is_windows()
    local os_type = RUNTIME.osType
    return os_type == "Windows" or os_type == "windows" or os_type == "WINDOWS"
end

-- Execute command on Windows using io.popen (cmd.exec doesn't work in mise on Windows)
function windows_exec(command)
    local handle = io.popen(command .. " 2>&1")
    local output = handle:read("*a")
    local success, exit_type, exit_code = handle:close()

    if not success then
        error(string.format("Command failed: %s\nOutput: %s", command, output))
    end

    return output
end

-- Get platform information (OS and architecture) in Pulumi's expected format
function get_platform_info()
    local os_map = {
        Darwin = "darwin",
        darwin = "darwin",
        Linux = "linux",
        linux = "linux",
        Windows = "windows",
        windows = "windows",
    }
    local arch_map = {
        arm64 = "arm64",
        aarch64 = "arm64",
        amd64 = "amd64",
        x86_64 = "amd64",
        x64 = "amd64",
    }

    local os = os_map[RUNTIME.osType]
    local arch = arch_map[RUNTIME.archType]

    if not os or not arch then
        error(
            string.format(
                "Unsupported platform: %s/%s. Supported: Darwin/Linux/Windows with arm64/amd64",
                RUNTIME.osType,
                RUNTIME.archType
            )
        )
    end

    return { os = os, arch = arch }
end

-- Build the standard asset name for a plugin
function build_asset_name(kind, name, version, os, arch)
    return string.format("pulumi-%s-%s-v%s-%s-%s.tar.gz", kind, name, version, os, arch)
end

-- Build the get.pulumi.com CDN URL
function build_pulumi_cdn_url(kind, name, version, os, arch)
    local asset = build_asset_name(kind, name, version, os, arch)
    return "https://get.pulumi.com/releases/plugins/" .. asset
end

-- Build the GitHub browser download URL (avoids API rate limits)
function build_github_download_url(owner, repo, version, asset_name)
    return string.format("https://github.com/%s/%s/releases/download/v%s/%s", owner, repo, version, asset_name)
end

-- Try downloading from get.pulumi.com CDN
function try_pulumi_cdn_download(url, download_path)
    local http = require("http")

    -- http.download_file may throw exceptions on HTTP errors (like 403)
    -- Use pcall to catch these and allow fallback to GitHub
    local success, err = pcall(function()
        return http.download_file({ url = url }, download_path)
    end)

    if not success then
        -- Exception was thrown (e.g., HTTP 403)
        return false, tostring(err)
    end

    if err ~= nil then
        -- Error string was returned
        return false, err
    end

    return true, nil
end

-- Try downloading from GitHub releases (browser URL, no API)
function try_github_download(owner, repo, version, asset_name, download_path)
    local http = require("http")

    local download_url = build_github_download_url(owner, repo, version, asset_name)

    -- http.download_file returns nil on success, error string on failure
    local err = http.download_file({ url = download_url }, download_path)

    if err ~= nil then
        return false, "GitHub download failed: " .. tostring(err)
    end

    return true, nil
end

-- Main download orchestrator: tries CDN first, then GitHub
function download_plugin(owner, repo, kind, name, version, download_path)
    local platform = get_platform_info()
    local asset_name = build_asset_name(kind, name, version, platform.os, platform.arch)

    -- For third-party providers, skip CDN (they don't host there)
    if owner == "pulumi" then
        -- Try get.pulumi.com CDN first
        local cdn_url = build_pulumi_cdn_url(kind, name, version, platform.os, platform.arch)
        local success, err = try_pulumi_cdn_download(cdn_url, download_path)

        if success then
            return true, "Downloaded from get.pulumi.com"
        end
    end

    -- Fallback to GitHub (or primary for third-party)
    local success, err = try_github_download(owner, repo, version, asset_name, download_path)

    if success then
        return true, "Downloaded from GitHub"
    end

    -- Both failed
    return false, "Failed to download plugin: " .. (err or "unknown error")
end

-- Extract plugin tarball and clean up
function extract_and_cleanup(tarball_path, install_path)
    local archiver = require("archiver")
    local cmd = require("cmd")

    -- Extract tarball directly to install path
    archiver.decompress(tarball_path, install_path)

    -- Remove tarball
    if is_windows() then
        local normalized_tarball = tarball_path:gsub("/", "\\")
        windows_exec('del /F /Q "' .. normalized_tarball .. '"')
    else
        cmd.exec("rm -f " .. tarball_path)
    end
end

-- Main installation function
function PLUGIN:BackendInstall(ctx)
    local file = require("file")
    local strings = require("strings")
    local cmd = require("cmd")

    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path

    -- Validate inputs
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end
    if not version or version == "" then
        error("Version cannot be empty")
    end
    if not install_path or install_path == "" then
        error("Install path cannot be empty")
    end

    local owner, repo = tool:match("^([^/%s]+)/([^/%s]+)$")
    if not owner or not repo then
        error("Tool " .. tool .. " must follow format owner/repo")
    end

    -- Determine plugin type from repo name
    local type
    local package_name
    if strings.has_prefix(repo, "pulumi-converter") then
        type = "converter"
        package_name = repo:gsub("^pulumi%-converter%-", "")
    elseif strings.has_prefix(repo, "pulumi-tool") then
        type = "tool"
        package_name = repo:gsub("^pulumi%-tool%-", "")
    else
        type = "resource"
        package_name = repo:gsub("^pulumi%-", "")
    end

    -- Download tarball directly to install path
    local tarball_path = file.join_path(install_path, "plugin.tar.gz")

    -- Download plugin
    local success, message = download_plugin(owner, repo, type, package_name, version, tarball_path)
    if not success then
        error("Failed to download " .. type .. " " .. package_name .. "@" .. version .. ": " .. message)
    end

    -- Extract and cleanup
    local extract_success, extract_err = pcall(function()
        extract_and_cleanup(tarball_path, install_path)
    end)
    if not extract_success then
        -- Clean up tarball if extraction failed
        pcall(function()
            if is_windows() then
                local normalized_tarball = tarball_path:gsub("/", "\\")
                windows_exec('del /F /Q "' .. normalized_tarball .. '"')
            else
                cmd.exec("rm -f " .. tarball_path)
            end
        end)
        error("Failed to extract plugin: " .. tostring(extract_err))
    end

    return {}
end
