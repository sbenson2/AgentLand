#!/bin/zsh
# Pairs the simulator's AgentLand with this Mac's running host, without a camera (QR-only pairing, 2026-10-16).
#
#   scripts/sim-pair.sh [SIMULATOR-UDID]
#
# It mints a fresh single-use pairing code from the running `agentland-host serve` the way the Mac app does
# (`agentland-host pair --state <state> --expires 600s --pin`), builds the same invitation the Mac's QR code
# carries (name, address, certificate fingerprint, routes, remote access, expiry), and relaunches AgentLand on
# the simulator with `-AgentLandPairingURL <invitation>`, which only a DEBUG simulator build reads. The app then
# pairs as a scan of that code would. The code and invitation are never printed or written anywhere but the
# launch's arguments.
#
# SIMULATOR-UDID defaults to $AGENTLAND_SIM (required when no argument is given). The host is the one serving the Mac app's state
# (~/Library/Application Support/agentland/host.json); AGENTLAND_SIM_PAIR_STATE=<state path> picks the host
# serving another state file (a disposable test host), and fails when none does.
set -eu
SIM=${1:-${AGENTLAND_SIM:-}}
exec /usr/bin/python3 -I - "$SIM" <<'PY'
import base64, ctypes, hashlib, ipaddress, json, os, re, subprocess, sys, time

sim = sys.argv[1]
if not re.fullmatch(r"[0-9A-Fa-f-]{36}", sim):
    sys.exit("sim-pair: give a simulator UDID")
default_state = os.path.expanduser("~/Library/Application Support/agentland/host.json")
wanted_state = os.environ.get("AGENTLAND_SIM_PAIR_STATE") or default_state

libc = ctypes.CDLL(None, use_errno=True)
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")

def argv_of(pid):
    """The process's exact arguments (KERN_PROCARGS2), so paths with spaces stay whole."""
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return None
    raw = buffer.raw[:size.value]
    argc = int.from_bytes(raw[:4], "little")
    rest = raw[4:]
    rest = rest[rest.index(b"\0"):].lstrip(b"\0")  # skip the executable path and its padding
    return [part.decode("utf-8", "replace") for part in rest.split(b"\0")[:argc]]

def executable_of(pid):
    buffer = ctypes.create_string_buffer(4096)
    length = libproc.proc_pidpath(pid, buffer, 4096)
    return buffer.value.decode() if length > 0 else None

def flag(arguments, name):
    for index, value in enumerate(arguments):
        if value == name and index + 1 < len(arguments):
            return arguments[index + 1]
        if value.startswith(name + "="):
            return value[len(name) + 1:]
    return None

pids = subprocess.run(["/usr/bin/pgrep", "-U", str(os.getuid()), "agentland-host"],
                      capture_output=True, text=True).stdout.split()
hosts = []
for pid in map(int, pids):
    arguments = argv_of(pid)
    if not arguments or len(arguments) < 2 or arguments[1] != "serve":
        continue
    if os.path.realpath(flag(arguments, "--state") or "") == os.path.realpath(wanted_state):
        hosts.append((pid, arguments))
if len(hosts) != 1:
    sys.exit(f"sim-pair: {'no' if not hosts else 'more than one'} running AgentLand host serves {wanted_state}. "
             "Connect AgentLand on this Mac first.")
pid, arguments = hosts[0]
binary = executable_of(pid)
state = flag(arguments, "--state")
listen = flag(arguments, "--listen") or ""
certificate = flag(arguments, "--cert")
advertised = flag(arguments, "--advertised-host")
if not binary or not certificate or not advertised or "--dev-http" in arguments:
    sys.exit("sim-pair: the host isn't serving trusted HTTPS with an advertised name, so the Mac shows no QR code either.")
listen_host, _, port = listen.rpartition(":")
port = int(port)
listen_host = listen_host.strip("[]")

# The Mac's name, as the Mac app advertises it (Host.current().localizedName, at most 63 bytes).
name = subprocess.run(["/usr/sbin/scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip()
while len(name.encode()) > 63:
    name = name[:-1]
name = name or "AgentLand Mac"

# The certificate's SHA-256 fingerprint, of its DER bytes (HostAdvertisingConfiguration).
pem = open(certificate, encoding="utf-8").read()
match = re.search(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)
if not match:
    sys.exit("sim-pair: the host's certificate couldn't be read.")
fingerprint = hashlib.sha256(base64.b64decode("".join(match.group(1).split()))).hexdigest()

def route_host(value):
    value = value.strip().rstrip(".").lower()
    try:
        return str(ipaddress.ip_address(value.strip("[]")))
    except ValueError:
        return value

# The routes the host lists (desktop/network_routes.go): its local name, then Tailscale's while it runs and
# the listener takes its addresses. Read as the host reads it: this computer's status alone.
routes = [{"host": route_host(advertised), "kind": "local", "port": port}]
for cli in ("/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            os.path.expanduser("~/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"):
    if os.path.isfile(cli) and os.access(cli, os.X_OK):
        environment = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "TMPDIR") if key in os.environ}
        environment.update(LC_ALL="C", TAILSCALE_BE_CLI="1")
        try:
            output = subprocess.run([cli, "status", "--json", "--peers=false"], capture_output=True,
                                    timeout=4, env=environment).stdout[:1 << 20]
            status = json.loads(output)
        except (subprocess.TimeoutExpired, ValueError):
            break
        if status.get("BackendState") != "Running":
            break
        own = status.get("Self") or {}
        raw = own.get("TailscaleIPs") or status.get("TailscaleIPs") or []
        addresses = []
        for value in raw:
            try:
                address = ipaddress.ip_address(value)
            except ValueError:
                continue
            if getattr(address, "ipv4_mapped", None):
                address = address.ipv4_mapped
            if not address.is_unspecified:
                addresses.append(address)
            if len(addresses) == 4:
                break
        if listen_host:
            try:
                listener = ipaddress.ip_address(listen_host)
                if not listener.is_unspecified:
                    addresses = [a for a in addresses if a == listener]
            except ValueError:
                addresses = []
        if addresses:
            texts = [str(a) for a in addresses]
            routes.append({"addresses": texts, "host": route_host(own.get("DNSName") or "") or texts[0],
                           "kind": "tailscale", "port": port})
        break

# The Mac adds remote access when its host takes node IDs: a host started with a tunnel socket and the local session.
remote_access = "--tunnel-socket" in arguments and "--local-session-env" in arguments

requested_at = int(time.time())
minted = subprocess.run([binary, "pair", "--state", state, "--expires", "600s", "--pin"],
                        capture_output=True, text=True, timeout=30)
code = minted.stdout.strip()
if minted.returncode != 0 or not code:
    sys.exit("sim-pair: the host didn't make a pairing code.")

invitation = {"address": f"https://{advertised}:{port}", "certificateSHA256": fingerprint, "code": code,
              "expiresAt": requested_at + 600, "name": name, "version": 1}
if routes:
    invitation["routes"] = {"items": routes[:4], "version": 1}
if remote_access:
    invitation["remoteAccess"] = {"version": 1}
payload = json.dumps(invitation, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
url = "agentland://pair?data=" + base64.urlsafe_b64encode(payload).decode().rstrip("=")

lock = ["/usr/bin/lockf", "-k", "/private/tmp/agentland-sim.lock"]
subprocess.run([*lock, "xcrun", "simctl", "terminate", sim, "dev.agentland.client"], capture_output=True)
launched = subprocess.run([*lock, "xcrun", "simctl", "launch", sim, "dev.agentland.client", "-AgentLandPairingURL", url],
                          capture_output=True)
if launched.returncode != 0:
    sys.exit("sim-pair: the simulator didn't launch AgentLand (is it booted, with a Debug build installed?).")
print(f"Launched AgentLand on {sim} with a fresh pairing code for {name}; it pairs at once (Debug simulator builds only).")
PY
