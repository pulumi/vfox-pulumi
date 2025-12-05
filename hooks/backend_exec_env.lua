-- hooks/backend_exec_env.lua
-- Sets up environment variables for a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv

function PLUGIN:BackendExecEnv(ctx)
    local file = require("file")
    local pulumi = require("pulumi_helpers")

    local install_path = ctx.install_path
    local tool = ctx.tool
    local version = ctx.version

    if not install_path or install_path == "" then
        error("Install path cannot be empty")
    end
    if not version or version == "" then
        error("Version cannot be empty")
    end

    local metadata = pulumi.parse_tool(tool)
    local bin_path = file.join_path(install_path, "bin")
    pulumi.ensure_directory(bin_path)

    local pulumi_home = pulumi.pulumi_home()
    local plugin_dir_name = pulumi.plugin_directory_name(metadata.kind, metadata.package_name, version)
    local plugin_dir = file.join_path(pulumi_home, "plugins", plugin_dir_name)

    local plugin_has_files = pulumi.directory_has_files(plugin_dir)
    local bin_has_files = pulumi.directory_has_files(bin_path)

    if not plugin_has_files and bin_has_files then
        pulumi.copy_directory(bin_path, plugin_dir)
        plugin_has_files = pulumi.directory_has_files(plugin_dir)
    end

    if not plugin_has_files and not bin_has_files then
        pulumi.install_plugin(metadata.kind, metadata.package_name, version)
        plugin_has_files = pulumi.directory_has_files(plugin_dir)
    end

    if plugin_has_files and not bin_has_files then
        pulumi.copy_directory(plugin_dir, bin_path)
        bin_has_files = pulumi.directory_has_files(bin_path)
    end

    if not plugin_has_files then
        error(
            "Unable to ensure Pulumi plugin "
                .. metadata.package_name
                .. "@"
                .. version
                .. " is available in PULUMI_HOME"
        )
    end

    return {
        env_vars = {
            { key = "PATH", value = bin_path },
        },
    }
end
