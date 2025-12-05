local cmd_exec_calls
local cmd_exec_results
local decoded_payload
local original_getenv = os.getenv
local getenv_stub
local env_values
local original_modules = {}

describe("backend_install", function()
    local function load_subject()
        _G.PLUGIN = {}
        dofile("hooks/backend_install.lua")
    end

    before_each(function()
        cmd_exec_calls = {}
        cmd_exec_results = {}
        decoded_payload = {}
        env_values = {}

        original_modules.file = package.loaded.file
        original_modules.strings = package.loaded.strings
        original_modules.json = package.loaded.json
        original_modules.cmd = package.loaded.cmd
        original_modules.pulumi_helpers = package.loaded.pulumi_helpers

        package.loaded.file = {
            join_path = function(...)
                return table.concat({ ... }, "/")
            end,
        }

        package.loaded.strings = {
            has_prefix = function(str, prefix)
                return str:sub(1, #prefix) == prefix
            end,
            join = function(parts, sep)
                return table.concat(parts, sep)
            end,
        }

        package.loaded.json = {
            decode = function()
                return decoded_payload
            end,
        }

        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                if #cmd_exec_results > 0 then
                    local result = table.remove(cmd_exec_results, 1)
                    return result
                end
                return ""
            end,
        }

        package.loaded.pulumi_helpers = nil

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
        package.loaded.strings = original_modules.strings
        package.loaded.json = original_modules.json
        package.loaded.cmd = original_modules.cmd
        package.loaded.pulumi_helpers = original_modules.pulumi_helpers

        if getenv_stub then
            getenv_stub:revert()
        end
    end)

    local function run(ctx)
        return PLUGIN:BackendInstall(ctx)
    end

    it("requires tool name", function()
        assert.has_error(function()
            run({ tool = "", version = "1.0.0", install_path = "/tmp/install" })
        end, "Tool name cannot be empty")
    end)

    it("requires version", function()
        assert.has_error(function()
            run({ tool = "owner/repo", version = "", install_path = "/tmp/install" })
        end, "Version cannot be empty")
    end)

    it("requires install path", function()
        assert.has_error(function()
            run({ tool = "owner/repo", version = "1.0.0", install_path = "" })
        end, "Install path cannot be empty")
    end)

    it("requires owner/repo tools", function()
        assert.has_error(function()
            run({ tool = "pulumi", version = "1.0.0", install_path = "/tmp/install" })
        end, "Tool pulumi must follow format owner/repo")
    end)

    it("installs resource plugins using HOME fallback", function()
        env_values.PULUMI_HOME = false
        env_values.HOME = "/home/test"

        decoded_payload = {
            { kind = "resource", name = "snowflake", version = "0.1.0" },
        }

        cmd_exec_results = { "", "", "", "[]" }

        local result = run({
            tool = "pulumi/pulumi-snowflake",
            version = "0.1.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.same({
            'mkdir -p "/tmp/install"',
            'mkdir -p "/tmp/install/bin"',
            "pulumi plugin install resource snowflake 0.1.0",
            "pulumi plugin ls --json",
            'mkdir -p "/tmp/install/bin"',
            'cp -R "/home/test/.pulumi/plugins/resource-snowflake-v0.1.0"/. "/tmp/install/bin"',
        }, cmd_exec_calls)
    end)

    it("installs tool plugins when repo uses pulumi-tool prefix", function()
        env_values.PULUMI_HOME = "/custom/pulumi"

        decoded_payload = {
            { kind = "tool", name = "npm", version = "1.2.3" },
        }

        cmd_exec_results = { "", "", "", "[]" }

        local result = run({
            tool = "pulumi/pulumi-tool-npm",
            version = "1.2.3",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.same("pulumi plugin install tool npm 1.2.3", cmd_exec_calls[3])
        assert.same('cp -R "/custom/pulumi/plugins/tool-npm-v1.2.3"/. "/tmp/install/bin"', cmd_exec_calls[6])
    end)

    it("installs converter plugins when repo uses pulumi-converter prefix", function()
        env_values.PULUMI_HOME = "/custom/pulumi"

        decoded_payload = {
            { kind = "converter", name = "python", version = "0.9.0" },
        }

        cmd_exec_results = { "", "", "", "[]" }

        local result = run({
            tool = "pulumi/pulumi-converter-python",
            version = "0.9.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.same("pulumi plugin install converter python 0.9.0", cmd_exec_calls[3])
        assert.same('cp -R "/custom/pulumi/plugins/converter-python-v0.9.0"/. "/tmp/install/bin"', cmd_exec_calls[6])
    end)

    it("raises when installation command reports an error", function()
        env_values.PULUMI_HOME = "/pulumi"
        decoded_payload = {
            { kind = "resource", name = "snowflake", version = "0.1.0" },
        }
        cmd_exec_results = { "", "", "error: install failed", "[]" }

        assert.has_error(
            function()
                run({
                    tool = "pulumi/pulumi-snowflake",
                    version = "0.1.0",
                    install_path = "/tmp/install",
                })
            end,
            "Failed to install resource snowflake@0.1.0: error: install failed\n"
                .. "pulumi plugin install resource snowflake 0.1.0"
        )
    end)

    it("raises when plugin list command fails", function()
        env_values.PULUMI_HOME = "/pulumi"
        decoded_payload = {}
        cmd_exec_results = { "", "", "", "failed to list" }

        assert.has_error(function()
            run({
                tool = "pulumi/pulumi-snowflake",
                version = "0.1.0",
                install_path = "/tmp/install",
            })
        end, "Failed to list pulumi plugins: failed to list")
    end)

    it("raises when plugin cannot be found after install", function()
        env_values.PULUMI_HOME = "/pulumi"
        decoded_payload = {}
        cmd_exec_results = { "", "", "", "[]" }

        assert.has_error(function()
            run({
                tool = "pulumi/pulumi-snowflake",
                version = "0.1.0",
                install_path = "/tmp/install",
            })
        end, "Could not find installed tool: pulumi/pulumi-snowflake in PULUMI_HOME: /pulumi")
    end)
end)
