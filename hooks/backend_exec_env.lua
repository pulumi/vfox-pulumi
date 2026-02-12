-- hooks/backend_exec_env.lua
-- Sets up environment variables for a tool
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html#backendexecenv

function PLUGIN:BackendExecEnv(ctx)
    local install_path = ctx.install_path

    -- Ensure the mise-managed plugin path wins over binaries from the ambient PATH.
    -- See docs/adr/0001-path-management.md for the design rationale.
    local env_vars = {
        { key = "PATH", value = install_path },
    }

    return {
        env_vars = env_vars,
    }
end
