# Security policy

## What dejima-guard claims

It notices when a devbox changes, from a machine that is not the devbox, and it
tells you. It is a second opinion, not a boundary.

**It prevents nothing.** Everything it reports has already happened. The
controls that bound a compromise are
[dejima](https://gitbox.branderson.io/dejima/dejima)'s and
[dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener)'s;
this only reports on the machine those two are protecting.

What it does claim is that its answer is hard to suppress from the devbox: the
baseline lives here rather than there, the alert leaves from here, and it pulls
rather than being pushed to, so a collection that stops arriving is itself the
alarm. Root on the devbox can lie about the current state. It cannot alter what
this machine recorded last week, and it cannot make this machine stay quiet
without that silence being the signal.

## What it holds, which is the new risk it introduces

Watching a machine means holding credentials to it, so this is a concentration
of privilege that did not exist before you ran it.

| It holds | Taking it gets | It does not get |
| --- | --- | --- |
| An SSH key to the devbox | Two read-only audit commands, through a forced command | A shell, a file, a tunnel, or `drift --accept` |
| An ntfy token | Publishing to the alert topic: a forged all-clear, or noise to bury a real one | Reading past alerts, if it is `write-only` as documented |
| The baseline | Knowing exactly what an intruder would have to preserve to stay unnoticed | Anything on the devbox |

The key is restricted at the devbox end rather than trusted here, which is the
half that matters: see
["Let the guard in"](https://gitbox.branderson.io/dejima/dejima-devbox-hardener/src/branch/main/docs/building-a-devbox.md#guard-access).
`dejima-guard-install-key` proves the restriction rather than assuming it.

## Where this is weaker than dejima, and why

dejima runs untrusted code and is built accordingly. This runs one shell script
against one host. Two of its controls are still missing here, and both are worth
knowing about rather than discovering.

**No egress bound.** dejima's central claim is a deny-by-default allowlist
covering DNS as well as IP, which bounds where a compromised dependency can send
things. This has none: the container reaches anything the host can. Its actual
needs are three destinations: the devbox on 22, ntfy, and the heartbeat, so an
allowlist is cheap, but it belongs to your host or your container network and
this project neither ships nor requires one. Adding it inside the container is
possible and is the wrong trade: it would mean granting `NET_ADMIN` to a
container that currently drops every capability.

**The credential is in the container.** dejima keeps the model credential out
entirely, behind a proxy, so the container can use it without holding it. Here
the private key is mounted. An `SSH_AUTH_SOCK` from the host would give the same
use-without-possession and is not currently documented.

**No request logging.** dejima logs egress verdicts. This logs its findings and
its failures, not its connections.

Where it is stronger: it drops every capability, mounts the root filesystem
read-only, sets `no-new-privileges`, runs as a non-root uid, publishes no port,
and accepts no inbound connection at all.

## What it deliberately does not do

- **It does not catch an intruder who anticipated it.** The devbox-side audit
  can be lied to by root on the devbox. This catches a payload that did not
  think to look, which is most of them.
- **It sends no detail off this machine.** Alert bodies carry counts and
  categories, never a filename or a unit name, because the devbox chooses those
  strings. The detail stays in `dejima-guard report`.
- **It treats what the devbox says as untrusted input**, including in that
  report: control characters are replaced as the text is collected, since a
  filename can carry an escape sequence and the report is read on the machine
  holding the key to the box that named the file.
- **It cannot tell you its alerts are arriving.** Sent is not received.
  `test-alert` exists so that is a thing you settle deliberately.

## This is not proven software

Early development. Nothing here has been through outside review, an external
audit, or adversarial testing by anyone other than the person who wrote it.
Every security property described above is a claim awaiting scrutiny rather than
one that has survived it. Do not put it anywhere that being wrong about it would
matter.

## Reporting a vulnerability

Report it privately rather than in a public issue, to the address on the
maintainer's forge profile. There is one maintainer and no promised response
time; you will get an acknowledgement when it is seen, and credit if you want
it.

The organisation-wide policy, including what the sister projects claim, is
[dejima's SECURITY.md](https://gitbox.branderson.io/dejima/dejima/src/branch/main/SECURITY.md).

## No warranty

GPL-3.0-or-later, sections 15 and 16. This is provided as-is.
