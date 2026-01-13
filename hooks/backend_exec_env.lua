-- hooks/backend_exec_env.lua
-- Sets up environment variables for a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv

-- Load shared PULUMI_HOME management module
local pulumi_home_lib = require("pulumi_home")

function PLUGIN:BackendExecEnv(ctx)
    local file = require("file")
    local install_path = ctx.install_path
    local tool = ctx.tool
    local version = ctx.version

    -- Basic PATH setup
    local bin_path = file.join_path(install_path, "bin")

    -- Ensure PULUMI_HOME symlink/copy exists
    -- This runs during mise install even when cache is restored,
    -- ensuring plugins are always visible to pulumi plugin ls
    print(
        "[DEBUG BackendExecEnv] Called with tool="
            .. tostring(tool)
            .. ", version="
            .. tostring(version)
            .. ", bin_path="
            .. tostring(bin_path)
    )
    local success, err = pcall(function()
        pulumi_home_lib.ensure_pulumi_home_link(bin_path, tool, version)
    end)
    if not success then
        print("[DEBUG BackendExecEnv] ERROR: " .. tostring(err))
    else
        print("[DEBUG BackendExecEnv] Successfully ensured PULUMI_HOME link")
    end

    -- Ensure the mise-managed plugin path wins over binaries from the ambient PATH.
    -- See docs/adr/0001-path-management.md for the design rationale.
    local env_vars = {
        { key = "PATH", value = bin_path },
    }

    return {
        env_vars = env_vars,
    }
end
