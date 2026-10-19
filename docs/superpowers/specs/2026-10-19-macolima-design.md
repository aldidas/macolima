# Macolima — design

Name: **Macolima** (owner confirmed for now; cheap to change before release). It must not contain "Docker" or use the Docker whale/logo, and it must not use Colima's logo (credited to a specific artist); the app gets its own icon. The README and About screen state: "An unofficial, independent GUI for Colima. Not affiliated with or endorsed by the Colima project." Colima is MIT licensed and has no published trademark policy; this was checked, but it is not legal advice.

## Intent and why

The owner replaced Docker Desktop with Colima and now uses `docker` and `docker compose` from the CLI against the `colima` Docker context. What they miss is a GUI to *see* and *clean up* what is on their machine. They want a minimalist, native "Docker Desktop" for Colima: SwiftUI only (no Electron, no Tauri), light and dark themes, Liquid Glass.

Personal tool, published publicly on GitHub, MIT licensed (author's-assistant's call; Apache-2.0 was the considered alternative).

### Usage pattern (drives priorities)

1. **Most frequent:** glance at containers: which are running or stopped, which belong to a compose project. Start/stop them.
2. **Periodic:** clean up disk space on the Mac by finding unused images and volumes and deleting them.

## Goals

- **Containers view (landing view).** All containers (running and stopped), grouped by compose project, with a "Standalone" group for the rest. Per container: name, image, status, ports. Actions: start, stop, restart, delete, view logs. Per project group: start all / stop all (see Behavior).
- **Images view.** All local images with size, tag(s), created date, and an in-use / unused indicator. Sort by size (default: largest first). Delete with confirmation.
- **Volumes view.** All volumes with size, name, and in-use / unused indicator (plus which containers use it). Sort by size. Delete with confirmation.
- **Colima status, always visible.** Whether the VM is running; CPU/memory/disk allocation; disk used inside the VM vs. disk actually used on the Mac by the VM's disk image. Show *both* Docker's numbers and Colima's/host's numbers side by side. Reason: deleting images/volumes frees space inside the VM but the host disk image may not shrink; a cleanup tool that hides this feels broken.
- Start/stop Colima itself from the app.
- Layout: classic Mac three-pane (chosen by owner): sidebar (Containers / Images / Volumes, Colima status pinned at the bottom), list, detail pane. Wireframe: `.superpowers/brainstorm/10644-1792369873/content/layout.html`.
- Appearance: follows system light/dark; adopts Liquid Glass (standard SwiftUI/AppKit glass materials and toolbar/sidebar styling).
- Live updates: lists refresh on their own (Docker events stream) with no manual refresh needed.

## Non-goals (v1)

- Menu bar item. Owner likes it ("like Docker Desktop") but explicitly deferred it. Design the data layer so it can be added later.
- Compose `up` / `down` / `pull` / build (creating or removing containers from a compose file). v1 only groups containers by their compose labels and starts/stops them.
- Building images, running new containers, Kubernetes, Docker extensions, registries/login, networks view, multi-host or remote Docker.
- Release binaries, notarization, Developer ID signing, auto-update, App Store.
- Non-English localization.

## Anti-goals (a failure even if it technically works)

- An accidental click destroys data. Every delete is confirmed and states exactly what will be removed; volumes especially (data loss).
- "Unused" labels that lie. A *stopped* container still references its image and volumes; those must not be shown as safe to delete merely because nothing is running. "Unused" means no container (running or stopped) references it, and the UI should say so.
- Showing sizes that disagree with reality without explaining why (VM vs. host disk).
- Feature creep toward full Docker Desktop.

## Constraints and decisions

Decided by the owner:

- Native SwiftUI, light + dark, Liquid Glass.
- Classic sidebar / list / detail layout.
- Build-from-source only, installed via Makefile like the owner's other project (`/Users/aldidas/Documents/Works/herdrm/Makefile`): XcodeGen (`project.yml`, generated `.xcodeproj` gitignored), `xcodebuild`, ad-hoc signed.
  - `make build`: Debug build.
  - `make install`: Release build, quit the running app, back up the old copy once as `Macolima.previous.app`, `ditto` to `/Applications`, relaunch.
  - Also `make run`, `make test`, `make clean`, `make gen`, mirroring the reference.
- Project start/stop works like Docker Desktop: start/stop the project as a whole, or any container individually.
- Environment: macOS 27 with Xcode, Colima 0.10.3, active Docker context `colima` whose socket is `~/.colima/default/docker.sock`. Colima was *not running* when checked, so a "VM stopped" empty state is a first-class screen, not an edge case.

Builder's calls (made by the design author; change if wrong):

- Minimum macOS 26 (Liquid Glass requires it). Swift + SwiftUI; AppKit only where SwiftUI falls short.
- Talk to the **Docker Engine API over the unix socket** (containers, images, volumes, events, disk usage `/system/df`, logs) rather than parsing CLI output. Use the `colima` CLI (`colima status --json`, `start`, `stop`) only for VM status/control and host disk image size.
- Resolve the socket from the active Docker context (`docker context inspect`) with `~/.colima/default/docker.sock` as the fallback; support the Colima profile name if it isn't `default` (details left to builder).
- App Sandbox off (needs the socket and the `colima` binary); hardened runtime off for the locally built copy, as in the reference Makefile.
- Project grouping uses the `com.docker.compose.project` label. Project start/stop is implemented by starting/stopping each container of the project via the API, not by shelling out to `docker compose`.
- MIT license; `LICENSE` file in the repo root; README states "build from source".
- No third-party Swift dependencies unless clearly needed.

Further builder's calls (from the builder check):

- **API version:** negotiate rather than pin (query `/version`, use the versioned path it supports). `/system/df` is slow on large hosts, so fetch it on view open and on Docker events, cache it in memory, and never poll it on a timer.
- **Host-disk number:** the *allocated* size of Colima's VM disk image (file blocks actually used on the Mac, `st_blocks`), not its apparent/sparse size. Also show the configured maximum disk size next to it. The image path is discovered from the Colima profile directory (under `~/.colima/_lima/<profile>/`), not hardcoded.
- **Profiles:** single profile, auto-detected from the active Docker context (default `default`). No profile switcher in v1.
- **Deletes are conservative:** never pass `force`, and never remove a container's anonymous volumes when deleting the container (volumes are deleted only from the Volumes view). An image referenced by any container, running or stopped, cannot be deleted, and the UI says which container holds it. Multi-select delete confirms once, lists everything that will go, and reports partial failures per item.
- **Logs:** bounded live tail (follow, last N lines kept in memory, with copy). No search in v1. Handle the multiplexed stdout/stderr framing and the TTY (non-multiplexed) case.
- **macOS:** minimum macOS 26 is deliberate (Liquid Glass); the owner's machine runs 27.

## Behavior notes

- **Project stop/start:** stop all running containers of the project / start all stopped ones. Container order and `depends_on` are not reproduced in v1 (builder may start in a sensible order using the compose `depends_on` label if cheap).
- **Delete image:** blocked or clearly warned if a container references it; dangling and unused images are the easy wins and should be easy to select (multi-select delete is welcome).
- **Delete volume:** confirmation names the volume and lists containers that reference it (if any).
- **Prune (in v1, owner decision):** a "Remove all unused" action in both the Images and Volumes views. It first shows a preview sheet listing exactly what will be removed and the total space freed; nothing is removed until the owner confirms. "Unused" uses the same definition as the UI badges (no container, running or stopped, references it). Removal goes item by item so partial failures are reported per item. Volume prune warns explicitly about data loss.
- **Colima stopped (owner decision):** the app keeps a last-known snapshot of containers, images and volumes (with sizes) on disk and, while Docker is unreachable, shows it read-only and clearly marked as stale ("as of <time>"). Every action that needs the live Docker engine, including deletes and prune, is disabled while stale, with a prominent "Start Colima" button. Once Colima is running the live data replaces the snapshot. The snapshot is refreshed whenever live data loads. Stored in the app's Application Support directory.
- **Errors:** Docker unreachable vs. Colima stopped vs. permission problems are distinct, human-readable states with an obvious next action (e.g. "Start Colima").

## Left to the builder

Module/package structure, data-layer design (actor, async event stream), view models, how the Docker API client is implemented (hand-rolled HTTP over unix socket is expected; no mandated library), polling intervals for host disk size, icon and final app name, test strategy (the reference project unit-tests its kit package with `swift test`; a similar split is welcome), exact column sets and visual polish within the layout above.

## Open items

- Final app name and bundle identifier (default `Macolima`, `dev.<owner>.macolima`).
- This directory is not yet a git repository; initialize it when building starts, and add `.superpowers/` and `build/` to `.gitignore`.
