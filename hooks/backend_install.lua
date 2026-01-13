-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall

-- Helper Functions

-- Load shared PULUMI_HOME management module
local pulumi_home_lib = require("pulumi_home")

-- Convenience alias for is_windows check
local function is_windows()
    return pulumi_home_lib.is_windows()
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

-- Create a temporary directory with a unique name
function create_temp_dir()
    local cmd = require("cmd")

    if is_windows() then
        -- Use RUNNER_TEMP (GitHub Actions) or TEMP/TMP as fallback
        local base_temp = os.getenv("RUNNER_TEMP") or os.getenv("TEMP") or os.getenv("TMP")
        if not base_temp or base_temp == "" then
            error("No temp directory environment variable set (tried RUNNER_TEMP, TEMP, TMP)")
        end

        -- Normalize to forward slashes internally
        base_temp = base_temp:gsub("\\", "/")

        -- Generate a unique name using os.tmpname()
        local tmp_name_full = os.tmpname()

        -- os.tmpname() creates a file, so remove it
        os.remove(tmp_name_full)

        -- Extract just the basename (e.g., "s2mk.0") and replace dots with underscores
        local tmp_name = tmp_name_full:match("[^/\\]+$")

        -- Replace dots with underscores to make it a valid directory name (e.g., "s2mk.0" -> "s2mk_0")
        tmp_name = tmp_name:gsub("%.", "_")

        -- Build the directory path with forward slashes internally
        local tmp_dir_name = base_temp .. "/lua_temp_" .. tmp_name

        -- Normalize to backslashes for Windows mkdir (same pattern as rest of file)
        local normalized_temp = tmp_dir_name:gsub("/", "\\")

        local mkdir_cmd = 'mkdir "' .. normalized_temp .. '"'

        windows_exec(mkdir_cmd)

        return tmp_dir_name -- Return with forward slashes for consistency
    else
        -- On Unix, use cmd.exec with mkdir -p
        local temp_path = os.tmpname()
        os.remove(temp_path)
        cmd.exec("mkdir -p " .. temp_path)
        return temp_path
    end
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

    -- http.download_file returns nil on success, error string on failure
    local err = http.download_file({ url = url }, download_path)

    if err ~= nil then
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

-- Extract plugin tarball to destination
function extract_plugin(tarball_path, destination)
    local archiver = require("archiver")
    local cmd = require("cmd")

    if is_windows() then
        -- Normalize to backslashes only
        local normalized_dest = destination:gsub("/", "\\")
        windows_exec('mkdir "' .. normalized_dest .. '"')
    else
        cmd.exec("mkdir -p " .. destination)
    end
    archiver.decompress(tarball_path, destination)
end

-- Install plugin to mise location
function install_to_mise(extracted_path, install_path)
    local file = require("file")
    local cmd = require("cmd")

    local bin_path = file.join_path(install_path, "bin")
    if is_windows() then
        -- Normalize to backslashes only
        local normalized_bin = bin_path:gsub("/", "\\")
        local normalized_extracted = extracted_path:gsub("/", "\\")

        windows_exec('mkdir "' .. normalized_bin .. '"')
        -- Copy contents with \* (like Unix /*)
        windows_exec(string.format('xcopy /E /I /Y "%s\\*" "%s"', normalized_extracted, normalized_bin))
    else
        cmd.exec("mkdir -p " .. bin_path)
        cmd.exec("cp -r " .. extracted_path .. "/* " .. bin_path)
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
    local already_exists = false
    if is_windows() then
        local normalized_path = mise_bin_path:gsub("/", "\\")
        -- First check if directory exists
        local dir_exists = pcall(function()
            windows_exec('dir "' .. normalized_path .. '"')
        end)
        if dir_exists then
            -- Check if the specific binary exists
            -- Note: io.popen doesn't reliably return exit codes on Windows, so check output content
            local binary_name = strings.join({ "pulumi", type, package_name }, "-")
            local binary_path = normalized_path .. "\\" .. binary_name .. ".exe"
            local success, output = pcall(function()
                return windows_exec('dir "' .. binary_path .. '"')
            end)
            -- Check output content since exit codes aren't reliable
            already_exists = success
                and output
                and not output:match("File Not Found")
                and not output:match("cannot find")
        end
    else
        already_exists = pcall(function()
            cmd.exec("test -f " .. mise_bin_path .. "/*")
        end)
    end

    if already_exists then
        -- Binary exists (cache restored), just ensure PULUMI_HOME link/copy
        pulumi_home_lib.install_to_pulumi_home(mise_bin_path, tool, version)
        return {}
    end

    -- Need to download: create temporary directory for download/extraction
    local temp_dir = create_temp_dir()

    -- Verify temp directory was created
    local dir_check_success = pcall(function()
        if is_windows() then
            local normalized_temp = temp_dir:gsub("/", "\\")
            windows_exec('dir "' .. normalized_temp .. '" >NUL 2>&1')
        else
            cmd.exec("test -d " .. temp_dir)
        end
    end)
    if not dir_check_success then
        error("Failed to create temporary directory: " .. temp_dir)
    end

    -- Build paths using file.join_path (uses forward slashes, works on all platforms)
    local tarball_path = file.join_path(temp_dir, "plugin.tar.gz")
    local extract_path = file.join_path(temp_dir, "extracted")

    -- Download plugin
    local success, message = download_plugin(owner, repo, type, package_name, version, tarball_path)
    if not success then
        if is_windows() then
            local normalized_temp = temp_dir:gsub("/", "\\")
            pcall(function()
                windows_exec('rmdir /S /Q "' .. normalized_temp .. '"')
            end)
        else
            cmd.exec("rm -rf " .. temp_dir)
        end
        error("Failed to download " .. type .. " " .. package_name .. "@" .. version .. ": " .. message)
    end

    -- Verify file was downloaded
    local file_check_success = pcall(function()
        if is_windows() then
            local normalized_tarball = tarball_path:gsub("/", "\\")
            windows_exec('dir "' .. normalized_tarball .. '" >NUL 2>&1')
        else
            cmd.exec("test -f " .. tarball_path)
        end
    end)
    if not file_check_success then
        if is_windows() then
            local normalized_temp = temp_dir:gsub("/", "\\")
            pcall(function()
                windows_exec('rmdir /S /Q "' .. normalized_temp .. '"')
            end)
        else
            cmd.exec("rm -rf " .. temp_dir)
        end
        error("Downloaded file not found: " .. tarball_path)
    end

    -- Extract plugin
    local extract_success, extract_err = pcall(function()
        extract_plugin(tarball_path, extract_path)
    end)
    if not extract_success then
        if is_windows() then
            local normalized_temp = temp_dir:gsub("/", "\\")
            pcall(function()
                windows_exec('rmdir /S /Q "' .. normalized_temp .. '"')
            end)
        else
            cmd.exec("rm -rf " .. temp_dir)
        end
        error("Failed to extract plugin: " .. tostring(extract_err))
    end

    -- Install to mise location (primary)
    local mise_success, mise_err = pcall(function()
        install_to_mise(extract_path, install_path)
    end)
    if not mise_success then
        if is_windows() then
            local normalized_temp = temp_dir:gsub("/", "\\")
            pcall(function()
                windows_exec('rmdir /S /Q "' .. normalized_temp .. '"')
            end)
        else
            cmd.exec("rm -rf " .. temp_dir)
        end
        error("Failed to install to mise location: " .. tostring(mise_err))
    end

    -- Install to PULUMI_HOME (symlink on Unix, copy on Windows)
    local pulumi_success, pulumi_err = pcall(function()
        pulumi_home_lib.install_to_pulumi_home(mise_bin_path, tool, version)
    end)
    if not pulumi_success then
        if is_windows() then
            local normalized_temp = temp_dir:gsub("/", "\\")
            pcall(function()
                windows_exec('rmdir /S /Q "' .. normalized_temp .. '"')
            end)
        else
            cmd.exec("rm -rf " .. temp_dir)
        end
        error("Failed to install to PULUMI_HOME: " .. tostring(pulumi_err))
    end

    -- Clean up
    if is_windows() then
        local forward_temp = temp_dir:gsub("\\", "/")
        pcall(function()
            windows_exec('rmdir /S /Q "' .. forward_temp .. '"')
        end)
    else
        cmd.exec("rm -rf " .. temp_dir)
    end

    return {}
end
