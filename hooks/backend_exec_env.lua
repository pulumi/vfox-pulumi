-- hooks/backend_exec_env.lua
-- Sets up environment variables for a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv
local file = require("file")

function PLUGIN:BackendExecEnv(ctx)
    local install_path = ctx.install_path
    local tool = ctx.tool
    local version = ctx.version

    -- Basic PATH setup
    local bin_path = file.join_path(install_path, "bin")

    local env_vars = {
        -- Add tool's bin directory to PATH
        { key = "PATH", value = bin_path },
    }

    return {
        env_vars = env_vars,
    }
end
