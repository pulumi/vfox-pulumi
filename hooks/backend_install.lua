-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall
function PLUGIN:BackendInstall(ctx)
    local file = require("file")
    local strings = require("strings")
    local json = require("json")
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

    -- Create installation directory
    cmd.exec("mkdir -p " .. install_path)

    local install_cmd = strings.join({ "pulumi", "plugin", "install", type, package_name, version }, " ")
    local result = cmd.exec(install_cmd)
    if result:match("error") or result:match("failed") then
        error(
            "Failed to install "
                .. type
                .. " "
                .. package_name
                .. "@"
                .. version
                .. ": "
                .. result
                .. "\n"
                .. install_cmd
        )
    end

    local pulumi_home = os.getenv("PULUMI_HOME")
    local home = os.getenv("HOME")
    if not pulumi_home or pulumi_home == "" then
        pulumi_home = file.join_path(home, ".pulumi")
    end

    local ls_cmd = strings.join({ "pulumi", "plugin", "ls", "--json" }, " ")
    local ls_result = cmd.exec(ls_cmd)
    if ls_result:match("error") or ls_result:match("failed") then
        error("Failed to list pulumi plugins: " .. ls_result)
    end
    local decoded = json.decode(ls_result)

    -- generate the plugin name as it exists on the filesystem, e.g. resource-local-v0.0.1
    local plugin_name
    for _, plugin in ipairs(decoded) do
        if plugin.name == package_name and plugin.version == version then
            plugin_name = strings.join({ plugin.kind, plugin.name, "v" .. version }, "-")
        end
    end

    if not plugin_name or plugin_name == "" then
        error("Could not find installed tool: " .. tool .. " in PULUMI_HOME: " .. pulumi_home)
    end

    local plugin_path = file.join_path(pulumi_home, "plugins", plugin_name)
    local final_install_path = file.join_path(install_path, "bin")

    -- symlink the plugin installed by pulumi to the mise install path
    -- e.g. ~/.local/share/mise/installs/pulumi-plugins-pulumi-pulumi-local/0.1.6/bin
    file.symlink(plugin_path, final_install_path)

    return {}
end
