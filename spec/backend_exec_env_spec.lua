local copy_calls
local install_calls
local directory_state
local ensured_paths
local env_values
local getenv_stub
local original_getenv = os.getenv
local original_modules = {}

describe("backend_exec_env", function()
    local function load_subject()
        _G.PLUGIN = {}
        dofile("hooks/backend_exec_env.lua")
    end

    before_each(function()
        copy_calls = {}
        install_calls = 0
        directory_state = {}
        ensured_paths = {}
        env_values = {}

        original_modules.file = package.loaded.file
        original_modules.pulumi_helpers = package.loaded.pulumi_helpers

        package.loaded.file = {
            join_path = function(...)
                return table.concat({ ... }, "/")
            end,
        }

        package.loaded.pulumi_helpers = {
            parse_tool = function(tool)
                assert.is_equal("pulumi/pulumi-snowflake", tool)
                return { kind = "resource", package_name = "snowflake" }
            end,
            pulumi_home = function()
                return "/pulumi"
            end,
            plugin_directory_name = function(kind, package_name, version)
                return table.concat({ kind, package_name, "v" .. version }, "-")
            end,
            ensure_directory = function(path)
                ensured_paths[path] = true
                if directory_state[path] == nil then
                    directory_state[path] = false
                end
            end,
            directory_has_files = function(path)
                return directory_state[path] == true
            end,
            copy_directory = function(source, destination)
                table.insert(copy_calls, { source = source, destination = destination })
                directory_state[destination] = true
            end,
            install_plugin = function()
                install_calls = install_calls + 1
                directory_state["/pulumi/plugins/resource-snowflake-v1.0.0"] = true
            end,
        }

        getenv_stub = stub(os, "getenv", function(name)
            if env_values[name] ~= nil then
                return env_values[name]
            end
            return original_getenv(name)
        end)

        load_subject()
    end)

    after_each(function()
        _G.PLUGIN = nil

        package.loaded.file = original_modules.file
        package.loaded.pulumi_helpers = original_modules.pulumi_helpers

        if getenv_stub then
            getenv_stub:revert()
        end
    end)

    local function run(ctx)
        return PLUGIN:BackendExecEnv(ctx)
    end

    it("copies from mise install when pulumi cache is empty", function()
        local install_path = "/mise/install"
        local bin_path = install_path .. "/bin"
        local plugin_path = "/pulumi/plugins/resource-snowflake-v1.0.0"

        directory_state[bin_path] = true
        directory_state[plugin_path] = false

        local result = run({ tool = "pulumi/pulumi-snowflake", version = "1.0.0", install_path = install_path })

        assert.same({ { source = bin_path, destination = plugin_path } }, copy_calls)
        assert.is_equal(0, install_calls)
        assert.is_true(directory_state[plugin_path])
        assert.same(bin_path, result.env_vars[1].value)
    end)

    it("reinstalls when both locations are empty", function()
        local install_path = "/mise/install"
        local bin_path = install_path .. "/bin"
        local plugin_path = "/pulumi/plugins/resource-snowflake-v1.0.0"

        directory_state[bin_path] = false
        directory_state[plugin_path] = false

        run({ tool = "pulumi/pulumi-snowflake", version = "1.0.0", install_path = install_path })

        assert.is_equal(1, install_calls)
        assert.same({ { source = plugin_path, destination = bin_path } }, copy_calls)
        assert.is_true(directory_state[bin_path])
    end)

    it("populates mise install from pulumi cache when bin is empty", function()
        local install_path = "/mise/install"
        local bin_path = install_path .. "/bin"
        local plugin_path = "/pulumi/plugins/resource-snowflake-v1.0.0"

        directory_state[bin_path] = false
        directory_state[plugin_path] = true

        run({ tool = "pulumi/pulumi-snowflake", version = "1.0.0", install_path = install_path })

        assert.is_equal(0, install_calls)
        assert.same({ { source = plugin_path, destination = bin_path } }, copy_calls)
        assert.is_true(directory_state[bin_path])
    end)

    it("raises when the pulumi plugin cannot be ensured", function()
        local install_path = "/mise/install"
        local bin_path = install_path .. "/bin"

        directory_state[bin_path] = false

        package.loaded.pulumi_helpers.install_plugin = function()
            install_calls = install_calls + 1
            -- Intentionally do not populate the Pulumi directory
        end

        assert.has_error(
            function()
                run({ tool = "pulumi/pulumi-snowflake", version = "1.0.0", install_path = install_path })
            end,
            "Unable to ensure Pulumi plugin snowflake@1.0.0 is available in PULUMI_HOME"
        )

        assert.is_equal(1, install_calls)
    end)
end)
