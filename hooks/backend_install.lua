-- hooks/backend_install.lua
-- Installs a specific version of a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendinstall
function PLUGIN:BackendInstall(ctx)
    local file = require("file")
    local pulumi = require("pulumi_helpers")

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

    local metadata = pulumi.parse_tool(tool)

    -- Ensure the mise install location exists
    pulumi.ensure_directory(install_path)
    local final_install_path = file.join_path(install_path, "bin")
    pulumi.ensure_directory(final_install_path)

    -- Always install into PULUMI_HOME
    pulumi.install_plugin(metadata.kind, metadata.package_name, version)

    -- Resolve Pulumi's plugin directory based on CLI output
    local pulumi_home = pulumi.pulumi_home()
    local decoded = pulumi.list_installed_plugins()
    local kind, plugin_dir_name = pulumi.find_plugin_from_ls(decoded, metadata.package_name, version)

    if not kind or not plugin_dir_name or plugin_dir_name == "" then
        error("Could not find installed tool: " .. tool .. " in PULUMI_HOME: " .. pulumi_home)
    end

    -- Copy plugin contents into the mise install directory
    local plugin_path = file.join_path(pulumi_home, "plugins", plugin_dir_name)
    pulumi.copy_directory(plugin_path, final_install_path)

    return {}
end
