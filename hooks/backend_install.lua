-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall
function PLUGIN:BackendInstall(ctx)
    local file = require("file")
    local strings = require("strings")
    local json = require("json")
    local http = require("http")
    local archiver = require("archiver")

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

    local plugin_kind
    local plugin_name
    if strings.has_prefix(repo, "pulumi-converter") then
        plugin_kind = "converter"
        plugin_name = repo:gsub("^pulumi%-converter%-", "")
    elseif strings.has_prefix(repo, "pulumi-tool") then
        plugin_kind = "tool"
        plugin_name = repo:gsub("^pulumi%-tool%-", "")
    else
        plugin_kind = "resource"
        plugin_name = repo:gsub("^pulumi%-", "")
    end

    -- Determine OS and architecture
    -- RUNTIME.osType returns "Darwin", "Linux", or "Windows" (capitalized)
    -- Pulumi expects lowercase: "darwin", "linux", "windows"
    local os_type = RUNTIME.osType:lower()
    local arch_type = RUNTIME.archType:lower()

    -- Construct the expected asset name
    -- Format: pulumi-{kind}-{name}-v{version}-{os}-{arch}.tar.gz
    local asset_name = strings.join({ "pulumi", plugin_kind, plugin_name, "v" .. version, os_type, arch_type }, "-")
        .. ".tar.gz"

    -- Download the plugin tarball
    local temp_file = file.join_path(install_path, "plugin.tar.gz")
    local download_response
    local download_succeeded = false

    -- For official pulumi plugins, check get.pulumi.com first with a HEAD request
    if owner == "pulumi" then
        local get_pulumi_url = "https://get.pulumi.com/releases/plugins/" .. asset_name
        local head_response = http.head({ url = get_pulumi_url })

        if head_response.status_code == 200 then
            -- Available on get.pulumi.com, download it
            http.download_file({ url = get_pulumi_url }, temp_file)
            download_succeeded = true
        end
    end

    -- Fall back to GitHub if get.pulumi.com wasn't available or if this is a third-party plugin
    if not download_succeeded then
        -- Construct GitHub API URL to get release info
        local release_url = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/releases/tags/v" .. version

        -- Add GitHub token if available for authentication
        -- MISE_GITHUB_TOKEN takes precedence if both are set
        local headers = {}
        local token = os.getenv("MISE_GITHUB_TOKEN") or os.getenv("GITHUB_TOKEN")
        if token and token ~= "" then
            headers["Authorization"] = "token " .. token
        end

        -- Fetch release information from GitHub
        local release_response = http.get({
            url = release_url,
            headers = headers,
        })

        if release_response.status_code ~= 200 then
            error(
                "Failed to fetch release info for "
                    .. tool
                    .. "@"
                    .. version
                    .. ": HTTP "
                    .. release_response.status_code
                    .. "\nURL: "
                    .. release_url
            )
        end

        local release_data = json.decode(release_response.body)

        -- Find the matching asset
        local download_url
        if release_data.assets then
            for _, asset in ipairs(release_data.assets) do
                if asset.name == asset_name then
                    download_url = asset.url
                    break
                end
            end
        end

        if not download_url or download_url == "" then
            error(
                "Could not find asset "
                    .. asset_name
                    .. " in release "
                    .. tool
                    .. "@"
                    .. version
                    .. "\nAvailable assets: "
                    .. (function()
                        if not release_data.assets then
                            return "none"
                        end
                        local names = {}
                        for _, asset in ipairs(release_data.assets) do
                            table.insert(names, asset.name)
                        end
                        return strings.join(names, ", ")
                    end)()
            )
        end

        -- Download from GitHub using asset API URL (supports private repos with auth)
        local download_headers = {
            ["Accept"] = "application/octet-stream",
        }
        if token and token ~= "" then
            download_headers["Authorization"] = "token " .. token
        end

        http.download_file({
            url = download_url,
            headers = download_headers,
        }, temp_file)
    end

    -- Extract the tarball to the install path
    local final_install_path = file.join_path(install_path, "bin")
    archiver.decompress(temp_file, final_install_path)

    -- Clean up the temporary tarball
    os.remove(temp_file)

    return {}
end
