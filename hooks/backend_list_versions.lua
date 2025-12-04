local function classify(version)
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if major then
        return 1, tonumber(major), tonumber(minor), tonumber(patch), version
    end
    return 0, nil, nil, nil, version
end

local function stable_first_sort(a, b)
    local a_rank, a_major, a_minor, a_patch, a_version = classify(a)
    local b_rank, b_major, b_minor, b_patch, b_version = classify(b)

    if a_rank ~= b_rank then
        return a_rank < b_rank
    end

    if a_rank == 1 then
        if a_major ~= b_major then
            return a_major < b_major
        end
        if a_minor ~= b_minor then
            return a_minor < b_minor
        end
        if a_patch ~= b_patch then
            return a_patch < b_patch
        end
        return a_version < b_version
    end

    return a_version < b_version
end

function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool and ctx.tool:gsub("^%s+", ""):gsub("%s+$", "")

    -- Validate tool name
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    local owner, repo = tool:match("^([^/%s]+)/([^/%s]+)$")
    if not owner or not repo then
        error("Tool " .. tool .. " must follow format owner/repo")
    end

    local full_repo = owner .. "/" .. repo

    local http = require("http")
    local json = require("json")
    local headers = { ["User-Agent"] = "mise-backend-pulumi" }

    -- Check for GitHub token in MISE_GITHUB_TOKEN or GITHUB_TOKEN
    -- MISE_GITHUB_TOKEN takes precedence if both are set
    local token = os.getenv("MISE_GITHUB_TOKEN") or os.getenv("GITHUB_TOKEN")
    if token and token ~= "" then
        headers["Authorization"] = "Bearer " .. token
    end

    local include_prerelease = true

    local per_page = 100
    local versions = {}
    local seen = {}

    local api_url = string.format("https://api.github.com/repos/%s/releases?per_page=%d", full_repo, per_page)

    local resp, err = http.get({
        url = api_url,
        headers = headers,
    })

    if err then
        error("Failed to fetch versions for " .. tool .. ": " .. err)
    end

    if resp.status_code ~= 200 then
        local error_msg = ("GitHub API returned status %d for %s"):format(resp.status_code, full_repo)

        -- If rate limited (403), check for reset time
        if resp.status_code == 403 and resp.headers then
            local reset_time = resp.headers["x-ratelimit-reset"]
            local remaining = resp.headers["x-ratelimit-remaining"]

            if reset_time then
                local current_time = os.time()
                local wait_seconds = tonumber(reset_time) - current_time
                if wait_seconds > 0 then
                    local minutes = math.floor(wait_seconds / 60)
                    error_msg = error_msg
                        .. ("\nRate limit exceeded. Retry after %d minutes (%d seconds)"):format(minutes, wait_seconds)
                else
                    error_msg = error_msg .. "\nRate limit exceeded. You can retry now."
                end
            end

            if remaining then
                error_msg = error_msg .. ("\nRemaining requests: %s"):format(remaining)
            end
        end

        error(error_msg)
    end

    local releases = json.decode(resp.body)
    if type(releases) ~= "table" or #releases == 0 then
        error("No versions found for " .. tool .. " in GitHub releases")
    end

    for _, release in ipairs(releases) do
        if not release.draft and (include_prerelease or not release.prerelease) then
            local tag = release.tag_name or ""
            if tag ~= "" then
                local version = tag:gsub("^v", "")
                if not seen[version] then
                    table.insert(versions, version)
                    seen[version] = true
                end
            end
        end
    end

    table.sort(versions, stable_first_sort)

    return { versions = versions }
end
