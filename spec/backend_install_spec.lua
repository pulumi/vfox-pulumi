local cmd_exec_calls
local http_download_calls
local archiver_decompress_calls
local original_getenv = os.getenv
local getenv_stub
local env_values
local original_modules = {}

describe("backend_install", function()
    local function load_subject()
        _G.PLUGIN = {}
        -- Only set RUNTIME if it's not already set (for tests that override it)
        if not _G.RUNTIME then
            _G.RUNTIME = {
                osType = "Darwin",
                archType = "arm64",
            }
        end
        dofile("hooks/backend_install.lua")
    end

    before_each(function()
        cmd_exec_calls = {}
        http_download_calls = {}
        archiver_decompress_calls = {}
        env_values = {}

        original_modules.file = package.loaded.file
        original_modules.strings = package.loaded.strings
        original_modules.cmd = package.loaded.cmd
        original_modules.http = package.loaded.http
        original_modules.archiver = package.loaded.archiver

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

        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                -- Make cache check fail (test -f mise_bin_path/*)
                if command:match("^test %-f .*/bin/%*") then
                    error("file not found")
                end
                -- Make other checks succeed (temp dir, downloaded file)
                -- This includes: test -d for temp dir, test -f for downloaded file
                return ""
            end,
        }

        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                -- Simulate successful download by returning nil
                return nil
            end,
        }

        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
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
        _G.RUNTIME = nil

        package.loaded.file = original_modules.file
        package.loaded.strings = original_modules.strings
        package.loaded.cmd = original_modules.cmd
        package.loaded.http = original_modules.http
        package.loaded.archiver = original_modules.archiver

        if getenv_stub then
            getenv_stub:revert()
        end
    end)

    local function run(ctx)
        return PLUGIN:BackendInstall(ctx)
    end

    -- Validation tests
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

    -- Installation tests
    it("installs resource plugins using direct download from CDN", function()
        env_values.PULUMI_HOME = false
        env_values.HOME = "/home/test"

        local result = run({
            tool = "pulumi/pulumi-snowflake",
            version = "0.1.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify download was attempted from CDN
        assert.same(1, #http_download_calls)
        assert.is_truthy(
            http_download_calls[1].url:match(
                "https://get%.pulumi%.com/releases/plugins/pulumi%-resource%-snowflake%-v0%.1%.0%-darwin%-arm64%.tar%.gz"
            )
        )

        -- Verify extraction
        assert.same(1, #archiver_decompress_calls)

        -- Verify installation commands
        local found_mkdir_temp = false
        local found_mkdir_mise = false
        local found_cp_mise = false
        local found_mkdir_pulumi = false
        local found_symlink = false
        local found_rm_temp = false

        for _, cmd in ipairs(cmd_exec_calls) do
            -- Match temp directory creation (os.tmpname() pattern, but not install paths)
            if (cmd:match("mkdir %-p /tmp/") or cmd:match("mkdir %-p.*lua_")) and not cmd:match("/install") then
                found_mkdir_temp = true
            end
            if cmd:match("mkdir %-p /tmp/install/bin") then
                found_mkdir_mise = true
            end
            if cmd:match("cp %-r.*extracted/%* /tmp/install/bin") then
                found_cp_mise = true
            end
            if cmd:match("mkdir %-p /home/test/%.pulumi/plugins/resource%-snowflake%-v0%.1%.0") then
                found_mkdir_pulumi = true
            end
            if
                cmd:match(
                    "ln %-s /tmp/install/bin/pulumi%-resource%-snowflake /home/test/%.pulumi/plugins/resource%-snowflake%-v0%.1%.0/pulumi%-resource%-snowflake"
                )
            then
                found_symlink = true
            end
            -- Match temp directory cleanup (os.tmpname() pattern, but not install paths)
            if (cmd:match("rm %-rf /tmp/") or cmd:match("rm %-rf.*lua_")) and not cmd:match("/install") then
                found_rm_temp = true
            end
        end

        assert.is_true(found_mkdir_temp, "Should create temp directory")
        assert.is_true(found_mkdir_mise, "Should create mise bin directory")
        assert.is_true(found_cp_mise, "Should copy to mise location")
        assert.is_true(found_mkdir_pulumi, "Should create PULUMI_HOME plugin directory")
        assert.is_true(found_symlink, "Should create symlink in PULUMI_HOME")
        assert.is_true(found_rm_temp, "Should cleanup temp directory")
    end)

    it("installs tool plugins when repo uses pulumi-tool prefix", function()
        env_values.PULUMI_HOME = "/custom/pulumi"
        env_values.HOME = "/home/test"

        local result = run({
            tool = "pulumi/pulumi-tool-npm",
            version = "1.2.3",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify correct plugin type in URL
        assert.same(1, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("pulumi%-tool%-npm%-v1%.2%.3"))

        -- Verify symlink uses correct type
        local found_symlink = false
        for _, cmd in ipairs(cmd_exec_calls) do
            if
                cmd:match(
                    "ln %-s /tmp/install/bin/pulumi%-tool%-npm /custom/pulumi/plugins/tool%-npm%-v1%.2%.3/pulumi%-tool%-npm"
                )
            then
                found_symlink = true
            end
        end
        assert.is_true(found_symlink, "Should create symlink with tool type")
    end)

    it("installs converter plugins when repo uses pulumi-converter prefix", function()
        env_values.PULUMI_HOME = "/custom/pulumi"
        env_values.HOME = "/home/test"

        local result = run({
            tool = "pulumi/pulumi-converter-python",
            version = "0.9.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify correct plugin type in URL
        assert.same(1, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("pulumi%-converter%-python%-v0%.9%.0"))

        -- Verify symlink uses correct type
        local found_symlink = false
        for _, cmd in ipairs(cmd_exec_calls) do
            if
                cmd:match(
                    "ln %-s /tmp/install/bin/pulumi%-converter%-python /custom/pulumi/plugins/converter%-python%-v0%.9%.0/pulumi%-converter%-python"
                )
            then
                found_symlink = true
            end
        end
        assert.is_true(found_symlink, "Should create symlink with converter type")
    end)

    it("falls back to GitHub when CDN fails", function()
        env_values.HOME = "/home/test"

        -- Make first download (CDN) fail, second (GitHub) succeed
        local download_count = 0
        package.loaded.http = {
            download_file = function(opts, path)
                download_count = download_count + 1
                table.insert(http_download_calls, { url = opts.url, path = path })
                if download_count == 1 then
                    return "CDN download failed"
                end
                -- Second call succeeds
                return nil
            end,
        }
        load_subject()

        local result = run({
            tool = "pulumi/pulumi-random",
            version = "4.16.8",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify both downloads were attempted
        assert.same(2, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("https://get%.pulumi%.com"))
        assert.is_truthy(
            http_download_calls[2].url:match("https://github%.com/pulumi/pulumi%-random/releases/download")
        )
    end)

    it("uses GitHub directly for third-party providers", function()
        env_values.HOME = "/home/test"

        local result = run({
            tool = "oxidecomputer/pulumi-oxide",
            version = "0.5.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify only GitHub download was attempted (no CDN)
        assert.same(1, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("https://github%.com/oxidecomputer/pulumi%-oxide"))
        assert.is_falsy(http_download_calls[1].url:match("get%.pulumi%.com"))
    end)

    it("handles cache restoration by recreating PULUMI_HOME symlink", function()
        env_values.HOME = "/home/test"

        -- Make test -f succeed (files exist)
        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                if command:match("^test %-f") then
                    -- Don't error, indicating files exist
                    return ""
                end
                return ""
            end,
        }
        load_subject()

        local result = run({
            tool = "pulumi/pulumi-aws",
            version = "6.0.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Should NOT download when cache exists
        assert.same(0, #http_download_calls)
        assert.same(0, #archiver_decompress_calls)

        -- Should only recreate PULUMI_HOME symlink
        local found_symlink = false
        local found_mkdir_pulumi = false
        for _, cmd in ipairs(cmd_exec_calls) do
            if cmd:match("mkdir %-p /home/test/%.pulumi/plugins/resource%-aws%-v6%.0%.0") then
                found_mkdir_pulumi = true
            end
            if
                cmd:match(
                    "ln %-s /tmp/install/bin/pulumi%-resource%-aws /home/test/%.pulumi/plugins/resource%-aws%-v6%.0%.0/pulumi%-resource%-aws"
                )
            then
                found_symlink = true
            end
        end

        assert.is_true(found_mkdir_pulumi, "Should create PULUMI_HOME plugin directory")
        assert.is_true(found_symlink, "Should recreate symlink")
    end)

    it("uses Windows commands when on Windows", function()
        -- Clear state and reset with Windows RUNTIME
        _G.RUNTIME = nil
        _G.PLUGIN = nil
        http_download_calls = {}
        cmd_exec_calls = {}
        archiver_decompress_calls = {}

        -- Mock io.popen for Windows command execution
        local original_io_popen = io.popen
        io.popen = function(command)
            -- Strip the 2>&1 redirect for cleaner command logging
            local clean_cmd = command:gsub(" 2>&1$", "")
            table.insert(cmd_exec_calls, clean_cmd)

            -- Simulate cache miss for specific binary file check
            -- Only match dir commands checking for the binary, not copy commands
            if command:match("^dir.*pulumi%-resource%-[%w%-]+%.exe") then
                return {
                    read = function() return "" end,
                    close = function() return nil, "exit", 1 end  -- file not found
                }
            end

            -- Return success for other commands (mkdir, xcopy, copy, etc.)
            return {
                read = function() return "" end,
                close = function() return true, "exit", 0 end
            }
        end

        -- Re-setup mocks
        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                return nil
            end,
        }
        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
            end,
        }
        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                if command:match("^test %-f") then
                    error("file not found")
                end
                -- Simulate cache miss for Windows dir/findstr check
                if command:match("^dir .* | findstr") or command:match("^dir.*|.*findstr") then
                    error("no files found")
                end
                return ""
            end,
        }

        _G.RUNTIME = {
            osType = "Windows",
            archType = "amd64",
        }
        env_values.TEMP = "C:/Users/test/AppData/Local/Temp"
        env_values.USERPROFILE = "C:/Users/test"
        env_values.HOME = nil -- Use nil instead of false

        load_subject()

        local result = run({
            tool = "pulumi/pulumi-azure",
            version = "5.0.0",
            install_path = "C:/tmp/install",
        })

        assert.same({}, result)

        -- Verify Windows asset name in download URL
        assert.same(1, #http_download_calls, "Expected 1 download call, got " .. #http_download_calls)
        if #http_download_calls > 0 and http_download_calls[1] then
            assert.is_truthy(
                http_download_calls[1].url:match("windows%-amd64"),
                "Expected URL to contain 'windows-amd64', got: " .. tostring(http_download_calls[1].url)
            )
        else
            error("No download calls recorded")
        end

        -- Verify Windows commands are used
        local found_rmdir = false
        local found_mkdir_windows = false
        local found_copy = false

        for _, cmd in ipairs(cmd_exec_calls) do
            if cmd:match("rmdir /S /Q") then
                found_rmdir = true
            end
            if cmd:match("mkdir.*2>NUL") then
                found_mkdir_windows = true
            end
            if cmd:match("copy /Y") then
                found_copy = true
            end
        end

        assert.is_true(found_rmdir or found_mkdir_windows, "Should use Windows mkdir command")
        assert.is_true(found_copy, "Should use copy instead of ln")

        -- Restore original io.popen
        io.popen = original_io_popen
    end)

    it("raises when download fails from both sources", function()
        env_values.HOME = "/home/test"

        -- Make all downloads fail
        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                return "Network error"
            end,
        }
        load_subject()

        assert.has_error(function()
            run({
                tool = "pulumi/pulumi-gcp",
                version = "7.0.0",
                install_path = "/tmp/install",
            })
        end)
    end)

    it("raises when extraction fails", function()
        env_values.HOME = "/home/test"

        -- Make extraction fail
        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
                error("Corrupted archive")
            end,
        }
        load_subject()

        assert.has_error(function()
            run({
                tool = "pulumi/pulumi-kubernetes",
                version = "4.0.0",
                install_path = "/tmp/install",
            })
        end)
    end)

    it("uses correct platform detection for Linux amd64", function()
        -- Clear state and reset with Linux RUNTIME
        _G.RUNTIME = nil
        _G.PLUGIN = nil
        http_download_calls = {}
        cmd_exec_calls = {}
        archiver_decompress_calls = {}

        -- Re-setup mocks
        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                return nil
            end,
        }
        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
            end,
        }
        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                -- Make cache check fail (test -f mise_bin_path/*)
                if command:match("^test %-f .*/bin/%*") then
                    error("file not found")
                end
                -- Make other checks succeed (temp dir, downloaded file)
                return ""
            end,
        }

        _G.RUNTIME = {
            osType = "Linux",
            archType = "x86_64", -- Should map to amd64
        }
        env_values.HOME = "/home/test"

        load_subject()

        local result = run({
            tool = "pulumi/pulumi-aws",
            version = "6.0.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify correct OS and arch in URL
        assert.same(1, #http_download_calls, "Expected 1 download call, got " .. #http_download_calls)
        if #http_download_calls > 0 and http_download_calls[1] then
            assert.is_truthy(
                http_download_calls[1].url:match("linux%-amd64"),
                "Expected URL to contain 'linux-amd64', got: " .. tostring(http_download_calls[1].url)
            )
        else
            error("No download calls recorded")
        end
    end)
end)
