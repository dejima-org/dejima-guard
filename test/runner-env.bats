#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Asserts on the RUNNER this repository's CI lands on, not on this repository.
#
# This repository configures no runner and cannot fix one. What it can do is
# check that the job got no more than it asked for.
#
# .gitea/workflows/tests.yml asks for the confined tier, on the grounds that
# bats over stubbed shell needs neither a Docker socket nor the host's network
# namespace. `runs-on:` is a request. Which runner answers it depends on which
# runners carry the label, and nothing in a job's log says whether the socket
# was mounted into it. So without this file, "we run confined" is a claim in a
# comment, and it would keep reading as true on a runner that grants
# everything.
#
# DEJIMA_CI_TIER is declared by the workflow rather than sniffed, so landing on
# the wrong runner fails rather than quietly selecting different assertions.
# Unset means this is not a CI runner and there is nothing to assert, which is
# what makes the file safe to leave in `bats test/` on a laptop.

setup() {
    [ -n "${DEJIMA_CI_TIER:-}" ] || skip "not on a CI runner (DEJIMA_CI_TIER unset)"
    case "$DEJIMA_CI_TIER" in
        confined) ;;
        privileged)
            # Not an assertion about the privileged tier being wrong in
            # general. It is wrong for THIS repository, and landing there means
            # the label routed somewhere unintended.
            echo "This repository's CI is meant to run on the confined tier." >&2
            echo "DEJIMA_CI_TIER=privileged means the job asked for confined and" >&2
            echo "got something else, or the workflow was changed." >&2
            return 1 ;;
        *) echo "unknown DEJIMA_CI_TIER: $DEJIMA_CI_TIER" >&2; return 1 ;;
    esac
}

# An off-list destination that answers when it is reachable. This matters more
# than it looks: an address that never answers - a documentation range, say -
# would satisfy every negative check below on a runner with no network at all,
# which is the exact failure this file exists to detect.
OFF_LIST_IP=1.1.1.1

# Overridable, because an allowlist is per-operator and hardcoding one name
# would fail on a runner correctly configured for a different set. The default
# is what .dejima/allowed-domains in this repository declares.
ALLOWED_HOST=${DEJIMA_GUARD_ALLOWED_HOST:-deb.debian.org}

connects() {  # connects HOST PORT -> 0 if a TCP connection completes
    python3 - "$1" "$2" <<'PY'
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=6).close()
except OSError:
    sys.exit(1)
PY
}

# --- the privilege this repository declined ---------------------------------

@test "this job was not handed the Docker daemon" {
    # act_runner mounts /var/run/docker.sock into every job container unless
    # container.docker_host is exactly "-". Unset is the default, and the
    # default mounts. So this asserts the runner was configured rather than
    # merely labelled.
    [ ! -e /var/run/docker.sock ] || {
        echo "this job has the Docker socket, which is root-equivalent on the" >&2
        echo "runner host. Nothing in this repository needs it, and the" >&2
        echo "workflow asks for the confined tier precisely so it does not" >&2
        echo "have it." >&2
        echo "" >&2
        echo "This repository cannot fix that. The runner is configured by" >&2
        echo "dejima-ci-hardener: container.docker_host must be \"-\" in its" >&2
        echo "config.yaml, which dejima-ci-runners --role confined writes." >&2
        false
    }
}

@test "this job is not in the host network namespace" {
    # The privileged tier's second grant. Read sysfs rather than shelling out
    # to ip(8): /sys/class/net is per-netns and always present, while iproute2
    # may not be installed - which would turn "the tool is missing" into "the
    # host netns is missing".
    [ ! -e /sys/class/net/docker0 ] || {
        echo "docker0 is visible, so this job is in the host's network" >&2
        echo "namespace and no bridge rules sit in front of it." >&2
        echo "The confined tier does not grant that." >&2
        false
    }
}

# --- the allowlist this repository depends on -------------------------------
#
# The confined tier resolves only what the served repositories declare. This
# repository declares deb.debian.org and nothing else, which is where bats
# comes from. If that stops being true, the `tests` job fails at apt with a
# message about a missing package and nothing about why - so these run first
# and say the real thing.

@test "an allowlisted destination is reachable" {
    # The positive control for everything below. Without it, a runner with no
    # network at all passes every negative assertion in this file.
    run getent hosts "$ALLOWED_HOST"
    [ "$status" -eq 0 ] || {
        echo "$ALLOWED_HOST did not resolve, so the negative checks below would" >&2
        echo "pass for the wrong reason." >&2
        echo "" >&2
        echo "The runner reads .dejima/allowed-domains from each served" >&2
        echo "repository's MAIN branch, not from the branch under test, so a" >&2
        echo "domain added on a branch is not in force yet. That is deliberate:" >&2
        echo "a branch cannot grant itself a destination." >&2
        false
    }
    run connects "$ALLOWED_HOST" 80
    [ "$status" -eq 0 ]
}

@test "a name that is on no allowlist does not resolve" {
    # .invalid is reserved by RFC 2606 so it never resolves anywhere. Here it
    # must be REFUSED by a resolver that answers for allowlisted names, which
    # the positive control above establishes.
    run getent hosts example.invalid
    [ "$status" -ne 0 ]
}

@test "this job cannot reach a resolver of its own choosing" {
    # The check most easily left out, and the one deciding whether the DNS
    # allowlist means anything: a job that can query any resolver it likes can
    # resolve anything it likes, whatever the runner's dnsmasq is configured
    # with.
    run connects "$OFF_LIST_IP" 53
    [ "$status" -ne 0 ] || {
        echo "reached $OFF_LIST_IP:53, so this job can use any resolver it" >&2
        echo "likes and the DNS allowlist is decorative." >&2
        false
    }
}

@test "a destination that is on no allowlist is unreachable" {
    # An IP literal rather than a name, so this tests the packet filter rather
    # than the resolver. By name it would fail at DNS first and prove nothing.
    run connects "$OFF_LIST_IP" 443
    [ "$status" -ne 0 ] || {
        echo "reached $OFF_LIST_IP:443, so this job has unrestricted egress." >&2
        echo "If the DNS checks above passed, the resolver is fine and the" >&2
        echo "packet filter is not - on the runner host, DOCKER-USER is the" >&2
        echo "chain to look at." >&2
        false
    }
}

@test "IPv6 is not an unfiltered way around all of the above" {
    # An address family with no allowlist is not a smaller hole than the one
    # the rules above close; on a runner with IPv6 egress it is the same hole.
    #
    # This one passes for two different reasons - v6 rejected, or v6 never
    # configured - and both are acceptable, so it gets no positive control.
    # What it rules out is the third case: working IPv6 egress with rules
    # written only for v4.
    run connects 2606:4700:4700::1111 443
    [ "$status" -ne 0 ]
}
