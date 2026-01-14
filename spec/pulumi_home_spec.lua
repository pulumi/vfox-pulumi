local original_modules = {}
local original_getenv = os.getenv
local original_popen = io.popen
local getenv_stub
local popen_stub
local env_values
local popen_responses
local cmd_exec_calls

describe("pulumi_home", function()
    local pulumi_home

    local function load_subject()
        _G.RUNTIME = {
            osType = "Darwin",
            archType = "arm64",
        }
        -- Clear any cached module
        package.loaded.pulumi_home = nil
        pulumi_home = require("pulumi_home")
    end

    before_each(function()
        env_values = {}
        popen_responses = {}
        cmd_exec_calls = {}

        -- Save original modules
        original_modules.file = package.loaded.file
        original_modules.strings = package.loaded.strings
        original_modules.cmd = package.loaded.cmd

        -- Mock file module
        package.loaded.file = {
            join_path = function(...)
                return table.concat({ ... }, "/")
            end,
        }

        -- Mock strings module
        package.loaded.strings = {
            has_prefix = function(str, prefix)
                return str:sub(1, #prefix) == prefix
            end,
            join = function(parts, sep)
                return table.concat(parts, sep)
            end,
        }

        -- Mock cmd module
        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                -- Default: command succeeds
                return ""
            end,
        }

        -- Stub os.getenv
        getenv_stub = stub(os, "getenv", function(name)
            if env_values[name] ~= nil then
                return env_values[name]
            end
            return original_getenv(name)
        end)

        -- Stub io.popen
        popen_stub = stub(io, "popen", function(command)
            -- Find matching response
            for pattern, response in pairs(popen_responses) do
                if command:match(pattern) then
                    return {
                        read = function(self, format)
                            return response
                        end,
                        close = function(self)
                            return true
                        end,
                    }
                end
            end
            -- Default: empty output
            return {
                read = function(self, format)
                    return ""
                end,
                close = function(self)
                    return true
                end,
            }
        end)

        load_subject()
    end)

    after_each(function()
        _G.RUNTIME = nil
        package.loaded.file = original_modules.file
        package.loaded.strings = original_modules.strings
        package.loaded.cmd = original_modules.cmd
        package.loaded.pulumi_home = nil

        if getenv_stub then
            getenv_stub:revert()
        end
        if popen_stub then
            popen_stub:revert()
        end
    end)

    describe("is_windows", function()
        it("returns true for Windows osType", function()
            -- Clear module cache to force reload
            package.loaded.pulumi_home = nil
            _G.RUNTIME = { osType = "Windows", archType = "amd64" }
            pulumi_home = require("pulumi_home")
            assert.is_true(pulumi_home.is_windows())
        end)

        it("returns true for windows osType", function()
            package.loaded.pulumi_home = nil
            _G.RUNTIME = { osType = "windows", archType = "amd64" }
            pulumi_home = require("pulumi_home")
            assert.is_true(pulumi_home.is_windows())
        end)

        it("returns false for Darwin osType", function()
            package.loaded.pulumi_home = nil
            _G.RUNTIME = { osType = "Darwin", archType = "arm64" }
            pulumi_home = require("pulumi_home")
            assert.is_false(pulumi_home.is_windows())
        end)

        it("returns false for Linux osType", function()
            package.loaded.pulumi_home = nil
            _G.RUNTIME = { osType = "Linux", archType = "amd64" }
            pulumi_home = require("pulumi_home")
            assert.is_false(pulumi_home.is_windows())
        end)
    end)

    describe("check_pulumi_home_exists", function()
        describe("on Unix", function()
            before_each(function()
                _G.RUNTIME = { osType = "Darwin", archType = "arm64" }
                env_values.HOME = "/home/test"
                load_subject()
            end)

            it("returns true when plugin binary exists", function()
                -- Mock cmd.exec to succeed for test -f
                package.loaded.cmd = {
                    exec = function(command)
                        if command:match("^test %-f") then
                            return ""
                        end
                        error("command failed")
                    end,
                }
                load_subject()

                local exists = pulumi_home.check_pulumi_home_exists(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_true(exists)
            end)

            it("returns false when plugin binary does not exist", function()
                -- Mock cmd.exec to fail for test -f
                package.loaded.cmd = {
                    exec = function(command)
                        if command:match("^test %-f") then
                            error("file not found")
                        end
                        return ""
                    end,
                }
                load_subject()

                local exists = pulumi_home.check_pulumi_home_exists(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_false(exists)
            end)

            it("checks the correct path", function()
                package.loaded.cmd = {
                    exec = function(command)
                        table.insert(cmd_exec_calls, command)
                        return ""
                    end,
                }
                load_subject()

                pulumi_home.check_pulumi_home_exists(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )

                assert.equals(1, #cmd_exec_calls)
                assert.equals(
                    "test -f /home/test/.pulumi/plugins/resource-aws-v6.0.0/pulumi-resource-aws",
                    cmd_exec_calls[1]
                )
            end)
        end)

        describe("on Windows", function()
            before_each(function()
                package.loaded.pulumi_home = nil
                _G.RUNTIME = { osType = "Windows", archType = "amd64" }
                env_values.USERPROFILE = "C:\\Users\\test"
                pulumi_home = require("pulumi_home")
            end)

            it("returns true when dir output contains file information", function()
                popen_responses["dir.*2>NUL"] = [[
 Volume in drive C is Windows
 Volume Serial Number is E8D0-397F
 Directory of C:\Users\test\.pulumi\plugins\resource-aws-v6.0.0
12/13/2024  05:58 PM        45,819,728 pulumi-resource-aws.exe
               1 File(s)     45,819,728 bytes
               0 Dir(s)  35,668,926,464 bytes free
]]

                local exists = pulumi_home.check_pulumi_home_exists(
                    "C:/Users/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_true(exists)
            end)

            it("returns false when dir output is empty (BUG FIX TEST)", function()
                -- This is the bug case - empty output should mean file doesn't exist
                popen_responses["dir.*2>NUL"] = ""

                local exists = pulumi_home.check_pulumi_home_exists(
                    "C:/Users/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_false(exists)
            end)

            it("returns false when dir output contains 'File Not Found'", function()
                popen_responses["dir.*2>NUL"] = "File Not Found"

                local exists = pulumi_home.check_pulumi_home_exists(
                    "C:/Users/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_false(exists)
            end)

            it("returns false when dir output contains 'cannot find'", function()
                popen_responses["dir.*2>NUL"] = "cannot find the file specified"

                local exists = pulumi_home.check_pulumi_home_exists(
                    "C:/Users/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_false(exists)
            end)
        end)

        it("returns false when tool name cannot be parsed", function()
            env_values.HOME = "/home/test"

            local exists = pulumi_home.check_pulumi_home_exists(
                "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                "invalid-tool-name",
                "1.0.0"
            )
            assert.is_false(exists)
        end)
    end)

    describe("check_mise_cache_exists", function()
        describe("on Unix", function()
            before_each(function()
                _G.RUNTIME = { osType = "Darwin", archType = "arm64" }
                load_subject()
            end)

            it("returns true when binary exists in mise bin path", function()
                package.loaded.cmd = {
                    exec = function(command)
                        if command:match("^test %-f") then
                            return ""
                        end
                        error("command failed")
                    end,
                }
                load_subject()

                local exists = pulumi_home.check_mise_cache_exists(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_true(exists)
            end)

            it("returns false when binary does not exist", function()
                package.loaded.cmd = {
                    exec = function(command)
                        if command:match("^test %-f") then
                            error("file not found")
                        end
                        return ""
                    end,
                }
                load_subject()

                local exists = pulumi_home.check_mise_cache_exists(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_false(exists)
            end)

            it("checks the correct path", function()
                package.loaded.cmd = {
                    exec = function(command)
                        table.insert(cmd_exec_calls, command)
                        return ""
                    end,
                }
                load_subject()

                pulumi_home.check_mise_cache_exists(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )

                assert.equals(1, #cmd_exec_calls)
                assert.equals(
                    "test -f /home/test/.local/share/mise/installs/plugin/1.0.0/bin/pulumi-resource-aws",
                    cmd_exec_calls[1]
                )
            end)
        end)

        describe("on Windows", function()
            before_each(function()
                package.loaded.pulumi_home = nil
                _G.RUNTIME = { osType = "Windows", archType = "amd64" }
                pulumi_home = require("pulumi_home")
            end)

            it("returns true when dir output contains file information", function()
                popen_responses["dir.*2>NUL"] = [[
 Volume in drive C is Windows
 Directory of C:\Users\test\mise\bin
12/13/2024  05:58 PM        45,819,728 pulumi-resource-aws.exe
               1 File(s)     45,819,728 bytes
]]

                local exists = pulumi_home.check_mise_cache_exists(
                    "C:/Users/test/mise/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_true(exists)
            end)

            it("returns false when dir output is empty", function()
                popen_responses["dir.*2>NUL"] = ""

                local exists = pulumi_home.check_mise_cache_exists(
                    "C:/Users/test/mise/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )
                assert.is_false(exists)
            end)
        end)
    end)

    describe("ensure_pulumi_home_link", function()
        before_each(function()
            env_values.HOME = "/home/test"
        end)

        it("calls install_to_pulumi_home when link does not exist", function()
            package.loaded.cmd = {
                exec = function(command)
                    table.insert(cmd_exec_calls, command)
                    if command:match("^test %-f") then
                        error("file not found")
                    end
                    return ""
                end,
            }
            load_subject()

            pulumi_home.ensure_pulumi_home_link(
                "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                "pulumi/pulumi-aws",
                "6.0.0"
            )

            -- Should have created directory and symlink
            local found_mkdir = false
            local found_symlink = false
            for _, cmd in ipairs(cmd_exec_calls) do
                if cmd:match("mkdir %-p") then
                    found_mkdir = true
                end
                if cmd:match("ln %-s") then
                    found_symlink = true
                end
            end

            assert.is_true(found_mkdir, "Should create PULUMI_HOME directory")
            assert.is_true(found_symlink, "Should create symlink")
        end)

        it("does not call install_to_pulumi_home when link already exists", function()
            package.loaded.cmd = {
                exec = function(command)
                    table.insert(cmd_exec_calls, command)
                    -- All test -f commands succeed
                    return ""
                end,
            }
            load_subject()

            pulumi_home.ensure_pulumi_home_link(
                "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                "pulumi/pulumi-aws",
                "6.0.0"
            )

            -- Should only have checked existence, not created anything
            for _, cmd in ipairs(cmd_exec_calls) do
                assert.is_false(cmd:match("mkdir") ~= nil, "Should not create directory")
                assert.is_false(cmd:match("ln %-s") ~= nil, "Should not create symlink")
            end
        end)
    end)

    describe("install_to_pulumi_home", function()
        describe("on Unix", function()
            before_each(function()
                _G.RUNTIME = { osType = "Darwin", archType = "arm64" }
                env_values.HOME = "/home/test"
                load_subject()
            end)

            it("creates symlink with correct paths", function()
                package.loaded.cmd = {
                    exec = function(command)
                        table.insert(cmd_exec_calls, command)
                        return ""
                    end,
                }
                load_subject()

                pulumi_home.install_to_pulumi_home(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )

                -- Check commands
                assert.equals(3, #cmd_exec_calls)
                assert.is_true(cmd_exec_calls[1]:match("rm %-rf .*/resource%-aws%-v6%.0%.0") ~= nil)
                assert.is_true(cmd_exec_calls[2]:match("mkdir %-p .*/resource%-aws%-v6%.0%.0") ~= nil)
                assert.is_true(
                    cmd_exec_calls[3]:match(
                        "ln %-s /home/test/.*/bin/pulumi%-resource%-aws .*/resource%-aws%-v6%.0%.0/pulumi%-resource%-aws"
                    ) ~= nil
                )
            end)

            it("handles converter plugins", function()
                package.loaded.cmd = {
                    exec = function(command)
                        table.insert(cmd_exec_calls, command)
                        return ""
                    end,
                }
                load_subject()

                pulumi_home.install_to_pulumi_home(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-converter-terraform",
                    "1.0.0"
                )

                -- Check that converter type and name are correct
                local found_converter_mkdir = false
                for _, cmd in ipairs(cmd_exec_calls) do
                    if cmd:match("converter%-terraform%-v1%.0%.0") then
                        found_converter_mkdir = true
                    end
                end
                assert.is_true(found_converter_mkdir, "Should use converter type in path")
            end)

            it("uses custom PULUMI_HOME when set", function()
                env_values.PULUMI_HOME = "/custom/pulumi"
                load_subject()

                package.loaded.cmd = {
                    exec = function(command)
                        table.insert(cmd_exec_calls, command)
                        return ""
                    end,
                }

                pulumi_home.install_to_pulumi_home(
                    "/home/test/.local/share/mise/installs/plugin/1.0.0/bin",
                    "pulumi/pulumi-aws",
                    "6.0.0"
                )

                -- Check that custom PULUMI_HOME is used
                local found_custom_home = false
                for _, cmd in ipairs(cmd_exec_calls) do
                    if cmd:match("/custom/pulumi/") then
                        found_custom_home = true
                    end
                end
                assert.is_true(found_custom_home, "Should use custom PULUMI_HOME")
            end)
        end)
    end)
end)
