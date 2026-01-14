-- Extracts PULUMI_VERSION_MISE and GO_VERSION_MISE from go.mod

local function read_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function extract_pulumi_version(content, module_path)
    -- Look for lines containing the module path
    for line in content:gmatch("[^\r\n]+") do
        if line:find(module_path, 1, true) then
            -- Extract version starting with 'v' followed by digits
            -- Match the version after the module path
            local version = line:match(module_path .. "%s+v([0-9]+%.[0-9]+%.[0-9]+)")
            if version then
                return version
            end
        end
    end
    return nil
end

local function extract_go_version(content)
    -- Prefer toolchain directive if present
    local toolchain_version = content:match("toolchain%s+go([0-9][^\r\n]*)")
    if toolchain_version then
        return toolchain_version:match("^[^%s]+")
    end

    -- Fall back to go version line
    local go_version = content:match("go%s+([0-9][^\r\n]*)")
    if go_version then
        return go_version:match("^[^%s]+")
    end

    return nil
end

local function find_git_root()
    -- Try to find .git directory by walking up the tree
    local current_dir = "."
    for _ = 1, 10 do -- Limit depth to avoid infinite loops
        local git_dir = current_dir .. "/.git"
        local f = io.open(git_dir .. "/config", "r")
        if f then
            f:close()
            return current_dir
        end
        current_dir = current_dir .. "/.."
    end
    return nil
end

function PLUGIN:MiseEnv(ctx)
    print("[MiseEnv] START: MiseEnv hook called")

    -- NOTE: We used to try to ensure PULUMI_HOME symlinks here by calling "mise list"
    -- and "mise where", but that creates a deadlock because we're calling mise from
    -- inside a mise hook. The PULUMI_HOME symlinks are now created in the PostInstall
    -- hook instead, which is the proper place for them.

    -- Parse go.mod to extract version information
    print("[MiseEnv] Starting go.mod parsing logic")
    local module_path = "github.com/pulumi/pulumi/pkg/v3"
    local go_mod_path = ctx.options.module_path or ""
    print("[MiseEnv] go_mod_path: " .. tostring(go_mod_path))
    local gomod = "go.mod"

    if go_mod_path ~= "" and go_mod_path ~= "." then
        gomod = go_mod_path .. "/" .. gomod
    end
    print("[MiseEnv] gomod path to read: " .. gomod)

    -- First, try to read go.mod from the specified location (or current dir)
    print("[MiseEnv] Attempting to read go.mod from: " .. gomod)
    local content = read_file(gomod)
    print("[MiseEnv] go.mod read result: " .. tostring(content ~= nil))

    -- If not found and no custom path was specified, try the repo root
    if not content and (go_mod_path == "" or go_mod_path == ".") then
        print("[MiseEnv] go.mod not found, searching for git root")
        local git_root = find_git_root()
        print("[MiseEnv] git root: " .. tostring(git_root))
        if git_root then
            local git_gomod_path = git_root .. "/go.mod"
            print("[MiseEnv] Attempting to read go.mod from git root: " .. git_gomod_path)
            content = read_file(git_gomod_path)
            print("[MiseEnv] go.mod read from git root result: " .. tostring(content ~= nil))
        end
    end

    if not content then
        -- No go.mod found, return empty (don't set variables, don't error)
        print("[MiseEnv] No go.mod found, returning empty result")
        print("[MiseEnv] END: MiseEnv hook completed (no go.mod)")
        return {}
    end

    -- Extract both versions independently
    print("[MiseEnv] Extracting pulumi version from go.mod")
    local pulumi_version = extract_pulumi_version(content, module_path)
    print("[MiseEnv] Pulumi version: " .. tostring(pulumi_version))

    print("[MiseEnv] Extracting go version from go.mod")
    local go_version = extract_go_version(content)
    print("[MiseEnv] Go version: " .. tostring(go_version))

    -- Build result array with whatever we found
    print("[MiseEnv] Building result array")
    local result = {}

    if pulumi_version then
        table.insert(result, { key = "PULUMI_VERSION_MISE", value = pulumi_version })
        print("[MiseEnv] Added PULUMI_VERSION_MISE=" .. pulumi_version)
    end

    if go_version then
        table.insert(result, { key = "GO_VERSION_MISE", value = go_version })
        print("[MiseEnv] Added GO_VERSION_MISE=" .. go_version)
    end

    print("[MiseEnv] END: MiseEnv hook completed successfully, returning " .. #result .. " environment variables")
    return result
end
