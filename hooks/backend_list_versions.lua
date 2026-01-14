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

    -- Check cache first
    local cache = require("github_cache")
    local ttl = tonumber(os.getenv("VFOX_PULUMI_CACHE_TTL")) or 43200
    local disable_cache = os.getenv("VFOX_PULUMI_DISABLE_CACHE") == "1"

    if not disable_cache then
        local cached = cache.get_cache(owner, repo)
        if cached and cache.is_cache_valid(cached, ttl) then
            return { versions = cached.versions }
        end
    end

    local http = require("http")
    local json = require("json")
    local headers = { ["User-Agent"] = "mise-backend-pulumi" }

    -- Add conditional request headers if we have stale cache
    local cached = nil
    if not disable_cache then
        cached = cache.get_cache(owner, repo)
        if cached and cached.etag then
            headers["If-None-Match"] = cached.etag
        end
    end

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

    -- Handle 304 Not Modified (doesn't count against rate limit!)
    if resp.status_code == 304 and cached then
        if not disable_cache then
            cache.touch_cache(owner, repo)
        end
        return { versions = cached.versions }
    end

    if resp.status_code ~= 200 then
        error(("GitHub API returned status %d for %s"):format(resp.status_code, full_repo))
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

    -- Store cache with ETag for future conditional requests
    if not disable_cache then
        local etag = resp.headers["etag"] or resp.headers["ETag"]
        local last_modified = resp.headers["last-modified"] or resp.headers["Last-Modified"]
        cache.set_cache(owner, repo, versions, etag, last_modified)
    end

    return { versions = versions }
end
