# ADR 0001: Manage Pulumi Plugin PATH via mise backend

## Status
Accepted 2025-10-20

## Context
- Plugin installation is moving from the `ci-mgmt.yaml` driven `make install_plugins` flow to a mise backend plugin (PR #1).
- The backend invokes `pulumi plugin install` so that installs respect `PULUMI_HOME` and remain visible to `pulumi plugin ls`.
- Historically, build scripts pinned plugin versions by setting `PULUMI_HOME=.pulumi` and installing into `.pulumi/plugins`, ensuring deterministic builds even with multiple contributors.
- Some contributors may have plugins installed globally (e.g., via `go install`). Pulumi prefers plugin binaries on `PATH` over those in `PULUMI_HOME`, which can silently derail builds.

## Decision
- Continue installing through `pulumi plugin install`, then expose the mise-managed install directory on `PATH` via `BackendExecEnv`.
- Symlink the Pulumi-managed plugin directory into the mise install's `bin` directory so the correct binary is the first one resolved on `PATH`.

## Consequences
- Build and test commands consistently run against the version pinned by mise, even if other copies exist elsewhere on the machine.
- The approach preserves compatibility with workflows that rely on locally built plugin binaries being reachable through `PATH`.
- `PULUMI_IGNORE_AMBIENT_PLUGINS` was considered but rejected because it would block legitimate cases where we need Pulumi to find locally built plugins.
- Capturing this rationale makes it clear why the backend modifies `PATH`, guards the behavior against accidental removal, and provides context for future maintainers evaluating alternatives.
