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

## What actually bounds this

Two things characterise the exposure, and both matter more than any comparison
with the projects around it.

**It runs on whatever you run it on.** The guard holds a key to the watched box
and parses that box's output, and its exposure is bounded by the hardening of a
machine this project does not describe and asks nothing of. A NAS, a home
server, an existing VM: whatever it is, it is not hardened by anything here. The
container path answers this for itself, running unprivileged with every
capability dropped and the root filesystem read-only. The host path is a systemd
unit, and what that unit asks for is the whole of the answer: its own account,
an empty capability bounding set, and memory and task limits.

What the guard does to protect that host: it never runs as root, it caps how
much the watched machine may send it, it names the ssh settings a local
`ssh_config` could otherwise widen, and it refuses a config file that is
writable by group or others, because `alert_command` makes that file
executable-equivalent.

**The collector runs on the watched host.** `dejima-devbox-audit` executes on
the devbox, so root there can return whatever it likes, including last week's
state verbatim. This is the detection ceiling and no amount of care on this side
raises it. The heartbeat proves the guard ran, not that it saw the truth. What
the design does buy is that lying has to be deliberate and continuous: the
baseline is here, out of reach, so a payload that did not think to look is
caught, and one that stops the collection entirely is caught by its silence.

## Where it sits next to the other projects

Not a fourth enforcement layer. It enforces nothing, and it is the only one of
the four that adds a machine holding credentials rather than taking some away.

Three of dejima's controls have no equivalent here, and are worth knowing rather
than discovering:

- **No egress bound.** dejima's deny-by-default allowlist covers DNS as well as
  IP. This has none: the container reaches whatever the host can. Its needs are
  three destinations, so an allowlist is cheap, but it belongs to your host or
  your container network. Doing it inside the container would mean granting
  `NET_ADMIN` to something that currently drops every capability, which is a
  worse trade than the gap.
- **The credential is in the container.** dejima keeps the model credential out
  entirely, behind a proxy. Here the private key is mounted. An `SSH_AUTH_SOCK`
  from the host would give the same use-without-possession and is not documented
  yet.
- **No request logging.** dejima logs egress verdicts. This logs findings and
  failures, not connections.

## What it deliberately does not do

- **It does not catch an intruder who anticipated it.** The devbox-side audit
  can be lied to by root on the devbox. This catches a payload that did not
  think to look, which is most of them.
- **It sends no paths off this machine.** Alert bodies carry counts and the
  watched area a change falls under, printed from a fixed list in the guard,
  never a filename or a unit name, because the devbox chooses those strings.
  The detail stays in `dejima-guard report`.
- **An expected-changes window is opened on the guard, never by the devbox.**
  One the devbox could open would let it silence its own guard. A window never
  holds or accepts a change to a critical path, or a containment failure.
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
