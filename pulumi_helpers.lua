---@meta

local file = require("file")
local strings = require("strings")
local cmd = require("cmd")
local json = require("json")

local pulumi_helpers = {}

local function assert_not_empty(value, message)
    if not value or value == "" then
        error(message)
    end
end

---Parse a tool reference like owner/repo and infer Pulumi plugin metadata.
---@param tool string
---@return table
function pulumi_helpers.parse_tool(tool)
    assert_not_empty(tool, "Tool name cannot be empty")

    local owner, repo = tool:match("^([^/%s]+)/([^/%s]+)$")
    if not owner or not repo then
        error("Tool " .. tool .. " must follow format owner/repo")
    end

    local kind
    local package_name

    if strings.has_prefix(repo, "pulumi-converter-") then
        kind = "converter"
        package_name = repo:gsub("^pulumi%-converter%-", "")
    elseif strings.has_prefix(repo, "pulumi-tool-") then
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

---Resolve the Pulumi home directory, defaulting to ~/.pulumi.
---@return string
function pulumi_helpers.pulumi_home()
    local pulumi_home = os.getenv("PULUMI_HOME")
    if pulumi_home and pulumi_home ~= "" then
        return pulumi_home
    end

    local home = os.getenv("HOME")
    assert_not_empty(home, "HOME environment variable is not set")
    return file.join_path(home, ".pulumi")
end

---Build the filesystem directory name Pulumi uses for a plugin.
---@param kind string
---@param package_name string
---@param version string
---@return string
function pulumi_helpers.plugin_directory_name(kind, package_name, version)
    return strings.join({ kind, package_name, "v" .. version }, "-")
end

---Return the full path to the plugin directory under Pulumi home.
---@param pulumi_home string
---@param kind string
---@param package_name string
---@param version string
---@return string
function pulumi_helpers.pulumi_plugin_dir(pulumi_home, kind, package_name, version)
    return file.join_path(pulumi_home, "plugins", pulumi_helpers.plugin_directory_name(kind, package_name, version))
end

---Ensure a directory exists via mkdir -p.
---@param path string
function pulumi_helpers.ensure_directory(path)
    cmd.exec(string.format("mkdir -p %q", path))
end

---Determine whether a directory exists.
---@param path string
---@return boolean
function pulumi_helpers.directory_exists(path)
    local output = cmd.exec(string.format("test -d %q && echo true || echo false", path))
    return output:match("true") ~= nil
end

---Determine whether a directory exists and has contents.
---@param path string
---@return boolean
function pulumi_helpers.directory_has_files(path)
    local output = cmd.exec(
        string.format(
            'if [ -d %q ] && [ "$(ls -A %q 2>/dev/null)" ]; then echo true; else echo false; fi',
            path,
            path
        )
    )
    return output:match("true") ~= nil
end

---Run pulumi plugin install for the given metadata.
---@param kind string
---@param package_name string
---@param version string
function pulumi_helpers.install_plugin(kind, package_name, version)
    local install_cmd = string.format("pulumi plugin install %s %s %s", kind, package_name, version)
    local result = cmd.exec(install_cmd)
    if result:match("error") or result:match("failed") then
        error(
            "Failed to install "
                .. kind
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
end

---Return decoded payload from `pulumi plugin ls --json`.
---@return table
function pulumi_helpers.list_installed_plugins()
    local ls_cmd = "pulumi plugin ls --json"
    local ls_result = cmd.exec(ls_cmd)
    if ls_result:match("error") or ls_result:match("failed") then
        error("Failed to list pulumi plugins: " .. ls_result)
    end
    return json.decode(ls_result)
end

---Locate the plugin directory reported by Pulumi's CLI.
---@param decoded_plugins table
---@param package_name string
---@param version string
---@return string kind
---@return string plugin_dir_name
function pulumi_helpers.find_plugin_from_ls(decoded_plugins, package_name, version)
    for _, plugin in ipairs(decoded_plugins) do
        if plugin.name == package_name and plugin.version == version then
            local kind = plugin.kind
            local plugin_dir_name = pulumi_helpers.plugin_directory_name(kind, plugin.name, version)
            return kind, plugin_dir_name
        end
    end
    return nil, nil
end

---Copy directory contents from source to destination.
---@param source string
---@param destination string
function pulumi_helpers.copy_directory(source, destination)
    pulumi_helpers.ensure_directory(destination)
    cmd.exec(string.format("cp -R %q/. %q", source, destination))
end

return pulumi_helpers
