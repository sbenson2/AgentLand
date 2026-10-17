# Sandbox plan — web projects (2026-09-26)

The owner's direction: a Sandbox area where people see what they build with AI. It covers web projects only. Nothing here is built yet; this records the design the owner approved to save.

## Two ways to open a project

Each Sandbox project offers both.

| | Run on the Mac, show on the phone | Run on the phone |
|---|---|---|
| What can run | Anything: static sites, React/Vite, Next.js with server code, APIs, databases | Apps that build to plain files (most React, Vite, Svelte and plain HTML apps) |
| Updates live as the AI edits | Yes | No, each new version is a fresh download |
| Away from home | Only after previews go through the iroh tunnel | Yes: the download is an API call, which the tunnel already carries |
| Needs the Mac while in use | Yes | No, it works offline |
| Where the code runs | In its own container on the Mac | Inside the phone's web engine, in AgentLand |

### Run on the Mac, show on the phone
- The project's server runs on the Mac with no window, inside its own container, published only on `127.0.0.1`.
- The phone's Browser tab shows it through the existing preview proxy (`desktop/preview.go`), which only ever dials loopback. Live reload works because the proxy passes WebSockets through.
- Previews are not carried through the iroh tunnel today (`docs/HOST-API.md`: capabilities through the tunnel leave out `preview`). Carrying them is a contained change on both sides.
- A headless browser on the Mac streaming video to the phone was considered and rejected: it lags and loses real touch and scrolling.

### Run on the phone
- The Mac builds the project into plain files, inside the container.
- The phone downloads the build and checks each file against the build's hash list. AgentLand then serves the files to its own web view from `http://localhost:<port>`, on a port of its own in the app.
- Not a custom URL scheme: WebKit does not treat custom schemes as secure contexts, which turns off `crypto.subtle`, the clipboard and other secure-context APIs. WebKit does treat `localhost` as secure.
- Server code and databases cannot run on the phone; those projects use the Mac mode.

## What testing in AgentLand cannot cover
- AgentLand's browser is the same WebKit engine as Safari, so layout and JavaScript match.
- Service workers (offline and PWA features) do not run in an app's web view unless the app limits it to a short list of App-Bound Domains. Add to Home Screen is not available either. Testing those needs Safari.

## Security

**Mac mode.** The project's code runs on the Mac, so each project gets its own container (Apple's `container` 1.0: one lightweight Linux VM per container, macOS 26 on Apple silicon):
- the project folder mounted read-only (`--mount …,readonly`), so nothing inside can change files the Mac later runs, such as git hooks or scripts;
- a clean environment with none of the host's variables or secrets;
- `--memory` and `--cpus` limits, and a stop after it sits idle;
- published only on `127.0.0.1` (`-p 127.0.0.1:<port>:<port>`), so the preview proxy is the one way in;
- internet access only while packages install. After that, the project runs with no network (`--network none`; confirm it on the installed version before relying on it). Don't use an `--internal` (host-only) network: it doesn't stop outbound TCP (apple/container#2062, noted 2026-09-27 while planning plain chats' code runs).

Remaining gaps and choices for this mode:
- A host-only network still reaches services on the Mac that listen on all interfaces: AdGuard, Filebrowser, RomM, Plex, the suite. Closing that takes a one-time firewall rule, which needs the owner's admin password.
- A lighter macOS sandbox that lets the server read the owner's files is not enough. A page could carry those files to the phone, and the phone has internet. A container never sees them.
- Colima is not used for this: its single VM also runs RomM and the suite.

**Phone mode.**
- Only the build runs on the Mac, and it runs in the container.
- On the phone, the code stays inside WebKit's sandbox. Like any website, it can reach the internet and the home network, but it has no way into AgentLand or the Mac: AgentLand registers no URL scheme and adds no script bridge.

**Both modes.**
- One web data store per project. Today one Browser tab shares storage across everything it opens, because all previews share the preview listener's origin (a cookie picks the port).
- The Sandbox lists only projects it started, not every port a program on the Mac listens on.
- Pages can ask for the camera or microphone. AgentLand already holds both permissions (pairing, dictation), so WebKit's own prompt is the only gate. AgentLand should ask with the project's name, or refuse by default. Location is not available, because AgentLand never asks for it.

## Mac apps (later)
These need screen streaming rather than a proxy:
- **Stream one window.** AgentLand streams that app's window to the phone and sends taps and typing back. This needs Screen Recording and Accessibility permission for AgentLand on the Mac. Accessibility can control any app, so it is a large grant.
- **Sandbox the app.** The Mac can sign the AI's app with the App Sandbox on, which keeps it out of the owner's files and off the network unless allowed.
- **Stopgap, no new code.** macOS Screen Sharing plus a VNC app on the phone. This shows and controls the whole Mac.

## First build
1. Install Apple's `container` (an admin install; ask the owner first).
2. Host:
   - Sandbox projects: a folder plus its detected kind.
   - Run a project in a container, published on loopback.
   - Build and package for phone mode (the file list with hashes).
3. App:
   - A Sandbox section in the sidebar, with **Open** (Mac) and **Run on this iPhone**.
   - One web data store per project.
   - The in-app `localhost` server for phone mode.
   - A camera and microphone prompt that names the project.
4. Previews through the tunnel, so Mac mode works away from home.

## Sources
- Apple container: https://github.com/apple/container, networking https://github.com/apple/container/blob/main/docs/networking.md, command reference https://github.com/apple/container/blob/main/docs/command-reference.md
- App-Bound Domains and service workers: https://useyourloaf.com/blog/app-bound-domains/, https://github.com/ionic-team/capacitor/issues/4122
- Custom schemes are not secure contexts in WKWebView: https://alastair.is/getting-wkwebview-to-treat-a-wkurlschemehandler-as-secure/
- Secure contexts and localhost: https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts
