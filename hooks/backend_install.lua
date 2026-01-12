-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall

-- Helper Functions

-- Get platform information (OS and architecture) in Pulumi's expected format
function get_platform_info()
    local os_map = {Darwin = "darwin", Linux = "linux", Windows = "windows"}
    local arch_map = {
        arm64 = "arm64", aarch64 = "arm64",
        amd64 = "amd64", x86_64 = "amd64", x64 = "amd64"
    }

    local os = os_map[RUNTIME.osType]
    local arch = arch_map[RUNTIME.archType]

    if not os or not arch then
        error(string.format("Unsupported platform: %s/%s. Supported: Darwin/Linux/Windows with arm64/amd64",
                           RUNTIME.osType, RUNTIME.archType))
    end

    return {os = os, arch = arch}
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
    return string.format("https://github.com/%s/%s/releases/download/v%s/%s",
                        owner, repo, version, asset_name)
end

-- Try downloading from get.pulumi.com CDN
function try_pulumi_cdn_download(url, download_path)
    local http = require("http")

    local success, err = pcall(function()
        http.download_file({url = url}, download_path)
    end)

    return success, err
end

-- Try downloading from GitHub releases (browser URL, no API)
function try_github_download(owner, repo, version, asset_name, download_path)
    local http = require("http")

    local download_url = build_github_download_url(owner, repo, version, asset_name)

    local success, download_err = pcall(function()
        http.download_file({url = download_url}, download_path)
    end)

    if not success then
        return false, "GitHub download failed: " .. tostring(download_err)
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

-- Extract plugin tarball to destination
function extract_plugin(tarball_path, destination)
    local archiver = require("archiver")
    local cmd = require("cmd")

    cmd.exec("mkdir -p " .. destination)
    archiver.decompress(tarball_path, destination)
end

-- Install plugin to mise location
function install_to_mise(extracted_path, install_path)
    local file = require("file")
    local cmd = require("cmd")

    local bin_path = file.join_path(install_path, "bin")
    cmd.exec("mkdir -p " .. bin_path)
    cmd.exec("cp -r " .. extracted_path .. "/* " .. bin_path)
end

-- Install to PULUMI_HOME using platform-specific approach
-- Unix: Symlink (saves disk space)
-- Windows: Copy (symlinks need admin/Developer Mode)
function install_to_pulumi_home(mise_bin_path, kind, name, version)
    local file = require("file")
    local cmd = require("cmd")
    local strings = require("strings")

    local pulumi_home = os.getenv("PULUMI_HOME")
    if not pulumi_home or pulumi_home == "" then
        if RUNTIME.osType == "Windows" then
            pulumi_home = file.join_path(os.getenv("USERPROFILE"), ".pulumi")
        else
            pulumi_home = file.join_path(os.getenv("HOME"), ".pulumi")
        end
    end

    -- Build: PULUMI_HOME/plugins/<type>-<name>-v<version>
    local plugin_name = strings.join({kind, name, "v" .. version}, "-")
    local plugin_dir = file.join_path(pulumi_home, "plugins", plugin_name)
    local plugins_dir = file.join_path(pulumi_home, "plugins")

    -- Platform-specific installation
    if RUNTIME.osType == "Windows" then
        -- Windows: Copy files (symlinks unreliable)
        cmd.exec("rmdir /S /Q " .. plugin_dir .. " 2>NUL")  -- Remove if exists, ignore errors
        cmd.exec("mkdir " .. plugins_dir .. " 2>NUL")  -- Create parent, ignore if exists
        cmd.exec(string.format('xcopy /E /I /Y "%s" "%s"', mise_bin_path, plugin_dir))
    else
        -- Unix: Symlink (saves disk space)
        cmd.exec("rm -rf " .. plugin_dir)
        cmd.exec("mkdir -p " .. plugins_dir)
        cmd.exec(string.format("ln -s %s %s", mise_bin_path, plugin_dir))
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

    local mise_bin_path = file.join_path(install_path, "bin")

    -- Check if already installed (handles cache restoration)
    -- If mise location has the binary but PULUMI_HOME link/copy is missing, just recreate it
    local already_exists = pcall(function()
        -- Check if any files exist in mise bin path
        cmd.exec("test -f " .. mise_bin_path .. "/*")
    end)

    if already_exists then
        -- Binary exists (cache restored), just ensure PULUMI_HOME link/copy
        install_to_pulumi_home(mise_bin_path, type, package_name, version)
        return {}
    end

    -- Need to download: create temporary directory for download/extraction
    local temp_dir = os.tmpname() .. "-pulumi-plugin"
    cmd.exec("mkdir -p " .. temp_dir)

    local tarball_path = file.join_path(temp_dir, "plugin.tar.gz")
    local extract_path = file.join_path(temp_dir, "extracted")

    -- Download plugin
    local success, message = download_plugin(owner, repo, type, package_name, version, tarball_path)
    if not success then
        cmd.exec("rm -rf " .. temp_dir)
        error("Failed to download " .. type .. " " .. package_name .. "@" .. version .. ": " .. message)
    end

    -- Extract plugin
    local extract_success, extract_err = pcall(function()
        extract_plugin(tarball_path, extract_path)
    end)
    if not extract_success then
        cmd.exec("rm -rf " .. temp_dir)
        error("Failed to extract plugin: " .. tostring(extract_err))
    end

    -- Install to mise location (primary)
    local mise_success, mise_err = pcall(function()
        install_to_mise(extract_path, install_path)
    end)
    if not mise_success then
        cmd.exec("rm -rf " .. temp_dir)
        error("Failed to install to mise location: " .. tostring(mise_err))
    end

    -- Install to PULUMI_HOME (symlink on Unix, copy on Windows)
    local pulumi_success, pulumi_err = pcall(function()
        install_to_pulumi_home(mise_bin_path, type, package_name, version)
    end)
    if not pulumi_success then
        cmd.exec("rm -rf " .. temp_dir)
        error("Failed to install to PULUMI_HOME: " .. tostring(pulumi_err))
    end

    -- Clean up
    cmd.exec("rm -rf " .. temp_dir)

    return {}
end
