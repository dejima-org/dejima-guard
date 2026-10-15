<!-- Fixed, not preference-aware, and that is the decision rather than an
     oversight. `prefers-color-scheme` reports the browser's setting, never the
     site's, and this is read on a forge that renders dark whichever way the
     browser is set - so anything conditional shows dark ink on a dark page to
     a reader whose browser prefers light, and does it silently.
     The suffix names the mode a file is FOR, not the colour of its ink:
     -darkmode is the pale wordmark that belongs on a dark page. GitHub does
     follow its own theme setting through <picture>, so the GitHub mirror
     replaces the tag below with one that falls back to
     dejima-wordmark-lightmode.png; see dejima's mirror/github-mirror.sh.
     Every &nbsp; here is spacing, and it has to be a character rather than CSS
     or a presentation attribute. Gitea's sanitizer strips `style` from the tag
     and from any wrapper, `hspace`/`vspace` survive sanitizing only to be
     ignored by browsers that dropped HTML4 presentation attributes, and a bare
     <br> ends a line nothing follows, which browsers collapse to no height.
     &nbsp; survives as a real U+00A0: on its own line it fills a paragraph
     that would otherwise be empty, and immediately before the tag it sits
     inline and indents the image by one space. -->
&nbsp;

&nbsp;<img src="assets/dejima-wordmark-darkmode.png" alt="dejima" height="72">

---

&nbsp;

# dejima-guard

Notices when a devbox changes, and tells you, from a machine that is not the
devbox.

A devbox has no upper bound on how long a compromise lasts. Its sister project,
[dejima-ci-hardener](https://gitbox.branderson.io/dejima/dejima-ci-hardener),
rebuilds a runner from a snapshot on a schedule, so anything that gets in has
until the next rebuild. A devbox holds uncommitted work and is never rebuilt.
Nothing reclaims it and nothing is looking.

[dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener)
made the box report what changed. This is the part that reads those reports and
wakes you up.

**It does not run on the devbox.** That is the entire design, not a deployment
detail: see [Why it pulls](#why-it-pulls).

| | |
| --- | --- |
| [Setting it up](#setting-it-up) | **Start here.** One config file, one key, and either a timer or a container |
| [Why it pulls](#why-it-pulls) | The three things the inversion buys |
| [What it does not do](#what-it-does-not-do) | Read this before relying on it |

[![Developed in dejima](assets/dejima-badge.svg)](https://gitbox.branderson.io/dejima/dejima)

---

## Before you use it

**Early development. Not ready to be depended on.** Nothing here has been
through outside review, an external audit, or adversarial testing by anyone but
the person who wrote it. Every security property this describes is a claim
awaiting scrutiny, not one that has survived it.

**One maintainer, no support.** Nothing about this is promised: not a reply, not
a fix, not a release. [SECURITY.md](SECURITY.md) has what this claims, what it
holds, and where it is weaker than dejima. It is also where to report a
vulnerability rather than in a public issue.

**It is a second opinion, not a boundary.** Nothing here prevents anything. It
watches, and everything it can tell you is something that has already happened.

## Setting it up

It needs a machine that is always on and is not the devbox. A NAS, a home
server, a Pi, an existing VM: anything already running. **Not a new VM**: this
is not a service, and a machine of its own would be a poor trade for something
whose whole job is to notice.

### On the host, with a systemd timer

```sh
sudo useradd --system --home-dir /var/lib/dejima-guard \
             --shell /usr/sbin/nologin dejima-guard
sudo install -m 0755 bin/dejima-guard bin/dejima-guard-install-key /usr/local/sbin/
sudo install -d -m 0750 -o dejima-guard -g dejima-guard \
             /etc/dejima-guard /var/lib/dejima-guard
sudo install -m 0640 -o root -g dejima-guard etc/config.example /etc/dejima-guard/config
sudoedit /etc/dejima-guard/config
```

**An account of its own, because the unit runs as it.** This holds an SSH key to
another machine, and a bug in it should yield that account rather than root on
whatever host you put it on. The config stays root-owned and group-readable: it
names a command the guard runs, so write access to it is code execution as the
guard, and `dejima-guard` refuses to start if it is writable by group or others.

A key of its own, put on the devbox restricted so it can run the two read-only
subcommands and nothing else:

```sh
sudo -u dejima-guard ssh-keygen -t ed25519 -N '' -f /var/lib/dejima-guard/id_ed25519
sudo -u dejima-guard dejima-guard-install-key
```

It authenticates to the devbox the ordinary way, so expect a password prompt:
the guard's key is what it installs, not what it uses. It then tries four
commands with the new key and reports whether the restriction holds. It needs
`dejima-guard-shell` and a sudoers rule on the devbox, both from
["Let the guard in"](https://gitbox.branderson.io/dejima/dejima-devbox-hardener/src/branch/main/docs/building-a-devbox.md#guard-access);
if either is missing it says which.

Then the devbox's host key, which nothing else records and every other command
needs:

```sh
sudo -u dejima-guard dejima-guard trust-host
sudo -u dejima-guard dejima-guard accept    # the baseline, taken deliberately
sudo install -m 0644 systemd/dejima-guard.{service,timer} /etc/systemd/system/
sudo sed -i 's|@@BIN_DIR@@|/usr/local/sbin|' /etc/systemd/system/dejima-guard.service
sudo systemctl daemon-reload && sudo systemctl enable --now dejima-guard.timer
```

**Take the baseline on a box you believe is clean.** One taken on a compromised
machine records the compromise as normal and reports clean forever. `check` will
not take one for you: under the timer that would happen five minutes after boot,
unattended, and everything the guard says afterwards rests on that file. Until
you run `accept` it reports as down, which is what a guard that has not been
told what normal looks like is.

`trust-host` prints the fingerprint before writing it: compare it against
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the devbox, or pass
`--fingerprint SHA256:...` and have it refuse anything else. Skipping it is not
a quiet failure: host key checking is left on, batch mode turns its prompt into
an error, and every cycle then reports the devbox unreachable at max priority.

### Or as a container

**1. Copy the example and edit it.** Every variable is commented with what goes
in it. Your copy is gitignored, and the example will not start as shipped: its
host is a placeholder the guard refuses, so it cannot become a live config by
being copied and forgotten.

```sh
cp docker-compose.example.yml docker-compose.yml
$EDITOR docker-compose.yml
```

**A copy, not an override.** `docker compose up` merges
`docker-compose.override.yml` with the file it overrides rather than replacing
it, so an override would leave the example's values in play.

**2. Make a key and put it on the devbox**, as described above.

```sh
mkdir -p secrets
ssh-keygen -t ed25519 -N '' -f secrets/guard_key -C dejima-guard
bin/dejima-guard-install-key --pub secrets/guard_key.pub you@devbox
```

**Not `ssh-copy-id`.** It copies the bare key with no options, and a bare key
here is a shell on the devbox for whoever eventually takes *this* machine:
the one holding the evidence about that one. The line needs a forced command,
which `ssh-copy-id` cannot attach, and doing it by hand means copy-then-edit
with an unrestricted key live in between.

**3. Write the secret config.** The one file that is not a copy of anything:
whatever must not sit in the environment, which on a self-hosted ntfy is the
token.

```
ntfy_token = <the token, from your ntfy server>
heartbeat_url = <the Push URL Uptime Kuma gave you>
```

**Both of these are credentials, which is why neither is in the compose file.**
The token is obvious. The push URL is less so: it carries its token in the path,
and anyone holding it can tell Kuma this guard is healthy, which suppresses the
one signal that reports a guard that has died. Everything in a compose
`environment:` block shows up in `docker inspect` and to anything that can read
`/proc`.

An ntfy needing no token can leave that line out, but the file must exist:
compose will not start with a secret it cannot find.

```sh
chmod 600 secrets/guard_key secrets/config
sudo chown 10001:10001 secrets/guard_key secrets/config
```

**The `chown` is not optional.** The image runs as uid 10001, and compose mounts
a secret with the host's ownership, so a key that is `0600` and yours is one
the container cannot open. 10001 is fixed in the `Dockerfile` and is part of the
interface. Bind-mounting a host directory in place of the named volume needs the
same treatment.

**4. Record the host key and start it.**

```sh
docker compose run --build --rm dejima-guard trust-host
docker compose run --build --rm dejima-guard accept       # the baseline
docker compose up --build -d
docker compose exec dejima-guard dejima-guard test-alert
```

**`--build`, every time.** This builds from the `Dockerfile` rather than pulling
from a registry, and `up -d` reuses whatever image already exists, so after a
`git pull` it would start the old code and report success. Rebuilding is how an
update takes effect here.

**Go and check that alert arrived on your phone.** Nothing else exercises that
path, and a broken one takes the first real finding with it.

**The volume is not a cache.** It holds the baseline, the last report and
`known_hosts`. Losing it is not a clean slate: a fresh baseline compares clean
against everything for the rest of its life, and a fresh `known_hosts` reports
the devbox unreachable forever.

**It never publishes a port, and never should.** What makes a container an
acceptable home for a program holding an SSH key to the devbox is that nothing
can connect to it. The compose file also drops every capability, mounts the root
filesystem read-only, and sets `no-new-privileges`.

### What goes in each setting

Every one can come from the config file or from the environment as
`DEJIMA_GUARD_` plus the key in upper case. The environment wins, which is
what makes a compose file workable, but a token belongs in the file, since
`docker inspect` shows the environment and so does anything reading `/proc`.

**The machine being watched.** Everything here describes the *devbox*, at the
other end of the connection, not the machine the guard runs on.

| Setting | What goes in it |
| --- | --- |
| `devbox_host` | The devbox's hostname or address, as this machine reaches it |
| `devbox_user` | The account **on the devbox** to log in as. Not root, and no default: the devbox runbook builds a machine with no root password, so the guard connects as an ordinary account and elevates for two commands |
| `ssh_key` | The private key **on this machine**. Its own, not a general-purpose administrative one |
| `ssh_known_hosts` | Where the devbox's host key is remembered. Must persist: in a container, on the state volume. Populated by `dejima-guard trust-host`, never automatically |
| `ssh_timeout` | Seconds to wait. The line between a slow devbox and a gone one |
| `critical_paths` | Paths whose change is its own max-priority alert, one per line. Defaults to the audit binary, the forced command, the sudoers rule, `sshd_config` and `authorized_keys` |
| `ignore_paths` | Paths whose change is reported but never alerted on, space-separated substrings. None by default. See [Changes not worth waking for](#changes-not-worth-waking-for) |

**Where alerts go.**

| Setting | What goes in it |
| --- | --- |
| `ntfy_url` | The topic to publish to. **Its own**, not the one dejima pushes to: that URL lives on the devbox, so root there could drown it or forge an all-clear |
| `ntfy_token` | Write access to that topic and nothing else. The reason the config file is `0640` |
| `heartbeat_url` | GET after a cycle that completed clean. An Uptime Kuma push monitor. **A credential**: the token is in the path, so it belongs in the config file rather than the environment |
| `alert_command` | An alternative to ntfy: gets the title and body on stdin |
| `guard_name` | This machine's name, for alerts to say where to run `dejima-guard report`. Optional; inside a container the hostname is a container ID, so it is never guessed |

`etc/config.example` carries the same reference with the reasoning attached.

### The happy path is ntfy and Uptime Kuma

Both self-hosted, and if you run dejima's remote access you already have the
first.

#### ntfy: its own topic, and a token that can only write to it

Give this its **own topic**, separate from the one dejima pushes to. `ntfy_url`
lives in `~/.config/dejima/config` *on the devbox*, so root there can publish to
dejima's topic, drown it, or forge an all-clear on it. A shared topic hands the
machine under suspicion a voice in the channel reporting on it.

On a public ntfy that is as far as you can go: anyone who learns the topic name
can post to it. Closing it properly needs a server you configure.

```yaml
# server.yml
auth-file: /var/lib/ntfy/user.db
auth-default-access: deny-all
```

> ⚠️ **This is a server-wide switch, and on its own it will break notifications
> that have nothing to do with dejima.** It closes *every* topic on that server.
> Worse, the apps subscribe to all of a server's topics over one connection, and
> ntfy authorises it by looping the list, returning 403 for the whole request
> on the first topic the account cannot read. Nothing says which one, so
> one missing grant reads as the server being broken. Grant everything back
> before you turn it on.

```sh
ntfy user add guard                              # role user, not admin
ntfy user add phone                              # you, subscribing
ntfy access guard    dejima-alerts  write-only
ntfy access phone    "*"            read-only    # EVERY topic you subscribe to
ntfy access everyone dejima-notify  read-write   # dejima's topic, as it was
ntfy access everyone "home-*"       read-write   # anything else that published
ntfy token add guard                             # prints tk_..., for secrets/config
ntfy access                                      # read it back
```

Four rules decide whether that is what you think it is:

- **`deny-all` is server-wide.** There is no per-topic default, so everything
  publishing anonymously needs granting back by name. `dejima-notify-watch` has
  no token to offer and does not need one: nothing about dejima changes, and the
  devbox still ends up with no access to `dejima-alerts` at all.
- **Neither account may be an `admin`.** An admin bypasses the ACL entirely, so
  an admin token is a key to the alert topic that no entry can take away.
- **`write-only` for the guard**, not `read-write`. It never reads the topic and
  this machine can be taken too; read access would hand whoever took it every
  alert about the devbox, and the gaps between them are as informative as the
  contents. The devbox gets no read either, since an intruder reading the alerts
  about themselves learns what the monitoring missed.
- **An `everyone` grant does cover a logged-in user**, on topics where that user
  has no entry of their own. Logging in to read the alert topic does not cost
  you the anonymous grant on dejima's.

The `"*"` for the reading account is doing real work. Name topics individually
if you prefer, but name *all* of them, everywhere that account subscribes: one
left out denies the rest with it.

**Then log the subscribers in** (web app: Settings → Users; Android: per
server). A denied subscribe fails the WebSocket upgrade, which the apps report
as `WebSocketNotSupportedException` or a 403 on the upgrade, so it reads as a
broken reverse proxy. Publishing keeps working throughout, because that path
carries a token, so a test alert arriving proves nothing about whether anyone
can read it. To tell the ACL from the proxy without WebSockets in the way, and
to find a topic that is denying the rest:

```sh
for t in dejima-alerts dejima-notify whatever-else; do
  printf '%s ' "$t"
  curl -s -o /dev/null -w '%{http_code}\n' -u phone:PASS \
    "https://ntfy.example.invalid/$t/json?poll=1"
done
```

Anonymous should give 403 and the credentialled call 200. Anything else is the
proxy. A hand-rolled browser client needs `?auth=` instead of a header, since a
browser cannot set one on a WebSocket: its value is base64 of the string
`Basic ` plus base64 of `user:pass`.

**On a server you cannot reconfigure**, one topic cannot be closed properly.
Access falls back to `auth-default-access` whenever no entry matches, so denying
the alert topic means an entry for `everyone` *and* one per account, and the
next account added inherits publish rights to the channel reporting on the
devbox. Existing admins keep access regardless. What is left is an unguessable
topic name, which is not access control and is worth calling that; a second
server for the one topic, which carries a few hundred bytes a day; or
`alert_command`, which leaves ntfy entirely.

Either way, a stolen guard token can still publish: a forged all-clear, or noise
to bury a real alert. Nothing in ntfy prevents that, which is part of why the
heartbeat is a separate channel on a separate server.

#### Uptime Kuma: a Push monitor, and the interval matters

This is the dead-man's switch. dejima-guard pings only on a cycle that completed
and found nothing wrong, so silence is the signal, and without it, a guard that
died looks exactly like one with nothing to report.

**Add New Monitor → Monitor Type: `Push`.** Kuma then shows a **Push URL** ending
in a token. That whole URL is `heartbeat_url`.

| Field | Set it to | Why |
| --- | --- | --- |
| Monitor Type | `Push` | Kuma waits to be called. Every other type calls out, and there is nothing here to call |
| Heartbeat Interval | **Longer than dejima-guard's**: 1200s against the default 900s | Kuma counts from the last ping, so equal intervals put every ping right on the deadline. The gap is never exactly 900s either: the systemd timer adds up to 60s of deliberate jitter, and the cycle itself takes as long as two SSH round trips |
| Retries | `0` | A missed ping *is* the finding. Retries make Kuma wait for more of them before saying so, which delays the one alert that reports a guard that has stopped |

dejima-guard's own interval is `DEJIMA_GUARD_INTERVAL` (900s) in a container, or
`OnUnitActiveSec` in `systemd/dejima-guard.timer` (15min) on a host. Change
either and Kuma has to follow, or it starts alerting on a schedule nobody
changed.

Anything else works through `alert_command` and a `heartbeat_url` of the same
shape. Only the one path is documented, because a list of alternatives is a list
that goes stale.

## Why it pulls

dejima-guard reaches in; the devbox never reaches out. That falls out of the
firewall the devbox already has: inbound SSH from the admin subnet is
permitted, so **no new firewall rule is needed**, and it buys three things:

**The baseline lives here.** Root on the devbox can lie about the current state.
It cannot alter what this machine recorded last week.

**The alert leaves from here.** A compromised devbox cannot suppress it by going
quiet, or drown it by shouting.

**Silence becomes a signal.** This is the one that matters. A reporter running
*on* the devbox, switched off by whoever took the box, causes nothing to happen:
forever, with nothing to see. A collection that stops arriving is itself the
alarm, and it is the only mechanism here that a compromised machine cannot
defeat by doing nothing.

It also bounds tampering: at a fifteen-minute cadence, an intruder has fifteen
minutes to notice the monitoring and scrub, and the resulting gap is evidence.

## What it does not do

- **It does not prevent anything.** Everything it reports has already happened.
- **It does not detect an intruder who anticipated it.** The devbox-side audit
  can be lied to by root on the devbox. What this catches is a payload that did
  not think to look: most of them, since the adversary in this threat model did
  not choose your devbox.
- **It does not watch CI runners.** Their scheduled rollback bounds dwell time,
  so the need is weaker. The design is not tier-specific and extending it would
  not be a rewrite.
- **It does not watch itself.** That is what the heartbeat is for, and the thing
  receiving it is outside this program.
- **It cannot tell you its alerts are arriving.** Sent is not received. A
  clean cycle never publishes, so a broken token or topic waits until the
  first real finding. What it does do is suppress the heartbeat when a send
  fails, so a broken channel surfaces as a dead guard rather than as silence:
  and `test-alert` exists so you can settle it deliberately rather than find
  out.
- **It sends no paths.** Alert bodies say what kind of change and under which
  watched area ("1 file(s) modified in ~/.ssh/known_hosts"), worded by the
  guard from a fixed list, never a filename or a unit name. A compromised devbox
  controls those strings, and interpolating one into a push hands it a channel
  to your phone. The paths are in `dejima-guard report`, on this machine.

## Use

```sh
dejima-guard check       # what the timer runs
dejima-guard status      # baseline, last check, any expected-changes window
dejima-guard report      # the last cycle's detail: each path added, modified or removed
dejima-guard accept      # record the devbox's current state as the baseline, then check
dejima-guard expect 30m  # updating the devbox: hold alerts, then accept at the end
dejima-guard test-alert  # publish a test alert, then go and look
dejima-guard trust-host  # record the devbox's host key; run once, before check

dejima-guard-install-key # put the guard's key on a devbox, restricted
```

`accept` is a decision, which is why a check never makes it. After an
unannounced change, read the report, and if the changes are yours, accept. The
check it runs afterwards gets the heartbeat going again.

### Updating the devbox without being paged

Say so first, on the guard:

```sh
dejima-guard expect 30m   # or 2h, 90s; 24h at most
```

Until then, changes and the devbox being unreachable (a reboot) are held
rather than sent. When the window ends the guard accepts the devbox's state and
sends a low-priority note saying what it accepted; `report --finding` has the
paths. Finished early? `dejima-guard accept`. Called it off? `dejima-guard
expect --cancel`.

**Critical paths and containment still alert**, and a window never accepts a
critical path: those need an `accept` by hand. **It is opened on the guard and
only there.** A devbox that could announce its own changes could silence its
own guard.

### Changes not worth waking for

`ignore_paths` in the config, space-separated, each matched as a substring of
the path like `critical_paths`:

```
ignore_paths = /.ssh/known_hosts
```

`~/.ssh/known_hosts` is the usual candidate. It changes whenever the devbox
first connects to an SSH host, such as cloning from a new git server. Ignored
changes still show in `report`, under their own heading, and a critical path
cannot be ignored.

### In a container, every one of those needs a prefix

There is no `dejima-guard` on the host: it lives in the image, with the config
and the state volume the commands need. Running the bare name on a container
host either finds nothing or, if you also installed the host path, finds a
second deployment with its own baseline.

**While it is running**, which is the usual case:

```sh
docker compose exec dejima-guard dejima-guard report
docker compose exec dejima-guard dejima-guard accept
```

**While it is not** (during setup, or after `docker compose down`):

```sh
docker compose run --rm dejima-guard accept
```

`exec` runs inside the container that is already there. `run` starts another one
from the same image, with the same volume and secrets, and removes it after.
Either works; `exec` is cheaper and is what to reach for once the thing is up.

**The command is not repeated after `run`.** The image's entrypoint is already
the guard, so `run --rm dejima-guard accept` is the whole of it. Naming the
binary again passes it as an argument to itself.

**Or skip the prefix.** `bin/dejima-guard-docker` runs the guard in its
container by name, from any directory. Install it on the container host as
`dejima-guard` and every command above works as written:

```sh
sudo install -m 0755 bin/dejima-guard-docker /usr/local/bin/dejima-guard
dejima-guard status
```

It assumes the `container_name` the example compose file sets; set
`DEJIMA_GUARD_CONTAINER` if yours differs. Do not install it beside a host
install of the guard, which would be a second deployment with its own baseline.

## Tests

```sh
bats test/
```

They stub `ssh` and `curl` on `PATH` rather than replacing functions, because
what is under test includes whether this program calls them at all, and the
worst failures here are silent: alerting on nothing until the topic is muted,
staying quiet when the box stops answering, and sending the heartbeat on a cycle
that failed.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

The dejima wordmark and logo are not code and are not covered by that licence.
They are trademarks; who holds them and what may be done with them is stated
once for the organisation, at
[dejima's ATTRIBUTION.md](https://gitbox.branderson.io/dejima/dejima/src/branch/main/ATTRIBUTION.md).
