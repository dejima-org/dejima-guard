# dejima-guard

Notices when a devbox changes, and tells you — from a machine that is not the
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
detail — see [Why it pulls](#why-it-pulls).

| | |
| --- | --- |
| [Setting it up](#setting-it-up) | **Start here.** One config file, one key, and either a timer or a container |
| [Why it pulls](#why-it-pulls) | The three things the inversion buys |
| [What it does not do](#what-it-does-not-do) | Read this before relying on it |

---

## Before you use it

**Early development. Not ready to be depended on.** Nothing here has been
through outside review, an external audit, or adversarial testing by anyone but
the person who wrote it. Every security property this describes is a claim
awaiting scrutiny, not one that has survived it.

**One maintainer, no support.** Nothing about this is promised: not a reply, not
a fix, not a release.

**It is a second opinion, not a boundary.** Nothing here prevents anything. It
watches, and everything it can tell you is something that has already happened.

## Setting it up

It needs a machine that is always on and is not the devbox. A NAS, a home
server, a Pi, an existing VM — anything already running. **Not a new VM**: this
is not a service, and a machine of its own would be a poor trade for something
whose whole job is to notice.

```sh
sudo install -m 0755 bin/dejima-guard bin/dejima-guard-install-key /usr/local/sbin/
sudo install -d -m 0750 /etc/dejima-guard /var/lib/dejima-guard
sudo install -m 0640 etc/config.example /etc/dejima-guard/config
sudoedit /etc/dejima-guard/config
```

A key of its own, put on the devbox restricted so it can run the two read-only
subcommands and nothing else:

```sh
sudo ssh-keygen -t ed25519 -N '' -f /var/lib/dejima-guard/id_ed25519
sudo dejima-guard-install-key
```

It authenticates to the devbox the ordinary way, so expect a password prompt —
the guard's key is what it installs, not what it uses. It then tries four
commands with the new key and reports whether the restriction holds. It needs
`dejima-guard-shell` and a sudoers rule on the devbox, both from
["Let the guard in"](https://gitbox.branderson.io/dejima/dejima-devbox-hardener/src/branch/main/docs/building-a-devbox.md#guard-access);
if either is missing it says which.

Then the devbox's host key, which nothing else records and every other command
needs:

```sh
sudo dejima-guard trust-host
sudo dejima-guard check     # first run records the baseline, alerts nothing
sudo install -m 0644 systemd/dejima-guard.{service,timer} /etc/systemd/system/
sudo sed -i 's|@@BIN_DIR@@|/usr/local/sbin|' /etc/systemd/system/dejima-guard.service
sudo systemctl daemon-reload && sudo systemctl enable --now dejima-guard.timer
```

**Take the first baseline on a box you believe is clean.** One taken on a
compromised machine records the compromise as normal and reports clean forever.

`trust-host` prints the fingerprint before writing it — compare it against
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the devbox, or pass
`--fingerprint SHA256:...` and have it refuse anything else. Skipping it is not
a quiet failure: host key checking is left on, batch mode turns its prompt into
an error, and every cycle then reports the devbox unreachable at max priority.

### Or as a container

**1. Copy the example and edit it.** Every variable is commented with what goes
in it. Your copy is gitignored, and the example will not start as shipped — its
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
here is a shell on the devbox for whoever eventually takes *this* machine —
the one holding the evidence about that one. The line needs a forced command,
which `ssh-copy-id` cannot attach, and doing it by hand means copy-then-edit
with an unrestricted key live in between.

**3. Write the secret config.** The one file that is not a copy of anything:
whatever must not sit in the environment, which on a self-hosted ntfy is the
token.

```
ntfy_token = <the token, from your ntfy server>
```

An ntfy needing no token can have this empty, but it must exist — compose will
not start with a secret it cannot find.

```sh
chmod 600 secrets/guard_key secrets/config
sudo chown 10001:10001 secrets/guard_key secrets/config
```

**The `chown` is not optional.** The image runs as uid 10001, and compose mounts
a secret with the host's ownership — so a key that is `0600` and yours is one
the container cannot open. 10001 is fixed in the `Dockerfile` and is part of the
interface. Bind-mounting a host directory in place of the named volume needs the
same treatment.

**4. Record the host key and start it.**

```sh
docker compose run --rm dejima-guard dejima-guard trust-host
docker compose up -d
docker compose exec dejima-guard dejima-guard test-alert
```

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
what makes a compose file workable — but a token belongs in the file, since
`docker inspect` shows the environment and so does anything reading `/proc`.

**The machine being watched.** Everything here describes the *devbox*, at the
other end of the connection, not the machine the guard runs on.

| Setting | What goes in it |
| --- | --- |
| `devbox_host` | The devbox's hostname or address, as this machine reaches it |
| `devbox_user` | The account **on the devbox** to log in as. Not root, and no default — the devbox runbook builds a machine with no root password, so the guard connects as an ordinary account and elevates for two commands |
| `ssh_key` | The private key **on this machine**. Its own, not a general-purpose administrative one |
| `ssh_known_hosts` | Where the devbox's host key is remembered. Must persist — in a container, on the state volume. Populated by `dejima-guard trust-host`, never automatically |
| `ssh_timeout` | Seconds to wait. The line between a slow devbox and a gone one |

**Where alerts go.**

| Setting | What goes in it |
| --- | --- |
| `ntfy_url` | The topic to publish to. **Its own**, not the one dejima pushes to — that URL lives on the devbox, so root there could drown it or forge an all-clear |
| `ntfy_token` | Write access to that topic and nothing else. The reason the config file is `0640` |
| `heartbeat_url` | GET after a cycle that completed clean. An Uptime Kuma push monitor |
| `alert_command` | An alternative to ntfy: gets the title and body on stdin |

`etc/config.example` carries the same reference with the reasoning attached.

### The happy path is ntfy and Uptime Kuma

Both self-hosted, and if you run dejima's remote access you already have the
first.

**ntfy** carries the alerts. Give this its **own topic**, separate from the one
dejima pushes to, and give the devbox no credential for it — `ntfy_url` lives in
`~/.config/dejima/config` *on the devbox*, so root there can publish to that
topic, drown it, or forge an all-clear. Deny the devbox read on the alert topic
too: an intruder who can read the alerts about themselves learns what the
monitoring noticed and what it missed.

**Uptime Kuma** is the dead-man's switch. A push monitor expects a ping on a
cadence and alerts when one does not arrive; this pings only on a cycle that
completed and found nothing wrong. Without it, a dejima-guard that has died
looks exactly like one with nothing to report.

Anything else works through `alert_command` and a `heartbeat_url` of the same
shape. Only the one path is documented, because a list of alternatives is a list
that goes stale.

## Why it pulls

dejima-guard reaches in; the devbox never reaches out. That falls out of the
firewall the devbox already has — inbound SSH from the admin subnet is
permitted, so **no new firewall rule is needed** — and it buys three things:

**The baseline lives here.** Root on the devbox can lie about the current state.
It cannot alter what this machine recorded last week.

**The alert leaves from here.** A compromised devbox cannot suppress it by going
quiet, or drown it by shouting.

**Silence becomes a signal.** This is the one that matters. A reporter running
*on* the devbox, switched off by whoever took the box, causes nothing to happen —
forever, with nothing to see. A collection that stops arriving is itself the
alarm, and it is the only mechanism here that a compromised machine cannot
defeat by doing nothing.

It also bounds tampering: at a fifteen-minute cadence, an intruder has fifteen
minutes to notice the monitoring and scrub, and the resulting gap is evidence.

## What it does not do

- **It does not prevent anything.** Everything it reports has already happened.
- **It does not detect an intruder who anticipated it.** The devbox-side audit
  can be lied to by root on the devbox. What this catches is a payload that did
  not think to look — most of them, since the adversary in this threat model did
  not choose your devbox.
- **It does not watch CI runners.** Their scheduled rollback bounds dwell time,
  so the need is weaker. The design is not tier-specific and extending it would
  not be a rewrite.
- **It does not watch itself.** That is what the heartbeat is for, and the thing
  receiving it is outside this program.
- **It cannot tell you its alerts are arriving.** Sent is not received. A
  clean cycle never publishes, so a broken token or topic waits until the
  first real finding. What it does do is suppress the heartbeat when a send
  fails, so a broken channel surfaces as a dead guard rather than as silence —
  and `test-alert` exists so you can settle it deliberately rather than find
  out.
- **It sends no detail.** Alert bodies carry counts and categories, never a
  filename or a unit name. A compromised devbox controls those strings, and
  interpolating one into a push hands it a channel to your phone. The detail is
  in `dejima-guard report`, on this machine.

## Use

```sh
dejima-guard check       # what the timer runs
dejima-guard report      # the last cycle's detail
dejima-guard accept      # record the devbox's current state as the baseline
dejima-guard test-alert  # publish a test alert, then go and look
dejima-guard trust-host  # record the devbox's host key; run once, before check

dejima-guard-install-key # put the guard's key on a devbox, restricted
```

`accept` is a decision, which is why a check never makes it. After an `apt
upgrade` on the devbox, read the report, and if the changes are yours, accept.

## Tests

```sh
bats test/
```

They stub `ssh` and `curl` on `PATH` rather than replacing functions, because
what is under test includes whether this program calls them at all — and the
worst failures here are silent: alerting on nothing until the topic is muted,
staying quiet when the box stops answering, and sending the heartbeat on a cycle
that failed.

## License

GPL-3.0-or-later.
