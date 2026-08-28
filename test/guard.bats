#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# The ways a watcher can be wrong are worse than the ways a check can be, because
# nobody is looking at a watcher. It runs from a timer and its output is an alert
# that either arrives or does not.
#
# Three of them are tested here and all three are silent failures:
#
#   - alerting on nothing, until the topic is muted and the real one is missed;
#   - staying quiet when the watched host stops answering, which is the case a
#     push reporter cannot report and the reason this pulls;
#   - sending the heartbeat on a cycle that failed, which tells the dead-man's
#     switch all is well at the exact moment it is not.
#
# `ssh` and `curl` are stubbed on PATH rather than the functions being replaced,
# because what is under test includes whether this program calls them at all.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TOOL="$REPO/bin/dejima-guard"
    STUB="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB"
    export DEJIMA_GUARD_STATE="$BATS_TEST_TMPDIR/lib"
    export DEJIMA_GUARD_CONF="$BATS_TEST_TMPDIR/config"
    cat > "$DEJIMA_GUARD_CONF" <<EOF
devbox_host = devbox.example.invalid
devbox_user = tester
ntfy_url = https://ntfy.example.invalid/alerts
heartbeat_url = https://kuma.example.invalid/api/push/abc
EOF
    # Records every call so a test can assert what was and was not sent.
    cat > "$STUB/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/curl.log"
exit 0
EOF
    chmod +x "$STUB/curl"
    mkdir -p "$DEJIMA_GUARD_STATE"
}

# An ssh that returns the given state for `drift --state`, and the given exit
# code for `reach`.
stub_ssh() {  # stub_ssh STATE REACH_RC [SSH_RC]
    printf '%s' "$1" > "$BATS_TEST_TMPDIR/state.txt"
    cat > "$STUB/ssh" <<EOF
#!/bin/sh
[ "${3:-0}" -eq 0 ] || exit ${3:-0}
case "\$*" in
  *"drift --state"*) cat "$BATS_TEST_TMPDIR/state.txt" ;;
  *reach*) echo "PASS: the gateway is unreachable"; exit $2 ;;
esac
EOF
    chmod +x "$STUB/ssh"
}

run_watch() { PATH="$STUB:$PATH" run "$TOOL" "$@"; }
curl_log()  { cat "$DEJIMA_GUARD_STATE/curl.log" 2>/dev/null || true; }
alerts()    { curl_log | grep -c 'Title:' || true; }
heartbeats() { curl_log | grep -c 'kuma.example.invalid' || true; }

# --- the first run ----------------------------------------------------------

@test "the first run records a baseline and does not alert" {
    # Everything is new on a first run. Alerting on it would train the operator
    # to dismiss the first alert they ever get from this.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$status" -eq 0 ]
    [ -f "$DEJIMA_GUARD_STATE/baseline" ]
    [ "$(alerts)" = 0 ]
}

@test "an unchanged box alerts nothing and sends the heartbeat" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    run_watch check
    [ "$status" -eq 0 ]
    [ "$(alerts)" = 0 ]
    [ "$(heartbeats)" -gt 0 ]
}

# --- the cases a push reporter cannot report --------------------------------

@test "a devbox that does not answer is alerted on, at max priority" {
    # THE CASE THIS DESIGN EXISTS FOR. A reporter running on the box itself
    # reports nothing here, forever, and nothing is wrong as far as anyone can
    # see.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check          # baseline
    stub_ssh "" 0 255        # ssh itself fails
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$(curl_log)" == *"Priority: max"* ]]
    [[ "$(curl_log)" == *unreachable* ]]
}

@test "an empty state is a failure, not a clean box" {
    # A check that produced nothing has not found nothing. Treating the two the
    # same is how a watcher reports all-clear on a box whose audit was removed.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    stub_ssh "" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$(curl_log)" == *"returned nothing"* ]]
}

@test "no heartbeat is sent on a cycle that failed" {
    # Pinging the dead-man's switch in a failure path tells it all is well at
    # the exact moment it is not, which is worse than not having one.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    : > "$DEJIMA_GUARD_STATE/curl.log"
    stub_ssh "" 0 255
    run_watch check
    [ "$(heartbeats)" = 0 ]
}

# --- drift ------------------------------------------------------------------

@test "a change against the baseline alerts once, not once per finding" {
    # An apt upgrade otherwise arrives as forty pushes, and the next real alert
    # lands in a topic already muted.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    : > "$DEJIMA_GUARD_STATE/curl.log"
    stub_ssh "FILE aaa /etc/one
FILE bbb /etc/two
FILE ccc /etc/three
UNIT backdoor.service" 0
    run_watch check
    [ "$status" -ne 0 ]
    [ "$(alerts)" = 1 ]
}

@test "the alert body carries counts, never anything the devbox chose" {
    # A compromised devbox controls every filename. Interpolating one into a
    # push hands it a channel to the operator's phone - the thing dejima's own
    # notification guarantee exists to prevent, defeated one layer out.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    : > "$DEJIMA_GUARD_STATE/curl.log"
    stub_ssh "FILE aaa /etc/one
FILE bbb /etc/evil-http-backdoor" 0
    run_watch check
    [[ "$(curl_log)" != *evil-http-backdoor* ]]
    [[ "$(curl_log)" == *"file(s)"* ]]
}

@test "the detail is kept locally, where the alert deliberately does not put it" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    stub_ssh "FILE aaa /etc/one
FILE bbb /etc/evil-http-backdoor" 0
    run_watch check
    grep -q 'evil-http-backdoor' "$DEJIMA_GUARD_STATE/last-report"
}

@test "containment failing alerts even when nothing changed" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    : > "$DEJIMA_GUARD_STATE/curl.log"
    stub_ssh "FILE aaa /etc/one" 1
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$(curl_log)" == *containment* ]]
}

@test "both wrong at once is one alert, at max" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    : > "$DEJIMA_GUARD_STATE/curl.log"
    stub_ssh "FILE bbb /etc/two" 1
    run_watch check
    [ "$(alerts)" = 1 ]
    [[ "$(curl_log)" == *"Priority: max"* ]]
}

# --- accepting --------------------------------------------------------------

@test "accept replaces the baseline" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    stub_ssh "FILE bbb /etc/two" 0
    run_watch accept
    [ "$status" -eq 0 ]
    grep -q 'FILE bbb' "$DEJIMA_GUARD_STATE/baseline"
    run_watch check
    [ "$status" -eq 0 ]
}

@test "accept refuses an empty state rather than baselining nothing" {
    # A baseline of nothing compares clean against everything, forever.
    stub_ssh "" 0
    run_watch accept
    [ "$status" -ne 0 ]
    [ ! -f "$DEJIMA_GUARD_STATE/baseline" ]
}

# --- configuration by environment, which is how a container gets it ---------

@test "the environment overrides the config file" {
    stub_ssh "FILE aaa /etc/one" 0
    printf 'devbox_host = wrong.example.invalid\ndevbox_user = tester\n' > "$DEJIMA_GUARD_CONF"
    DEJIMA_GUARD_DEVBOX_HOST=devbox.example.invalid run_watch check
    [ "$status" -eq 0 ]
    [ -f "$DEJIMA_GUARD_STATE/baseline" ]
}

@test "a config file alone still works, with no environment set" {
    # The container path must not become the only path. A systemd host mounts
    # nothing and sets nothing.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$status" -eq 0 ]
}

@test "known_hosts is passed to ssh when configured" {
    # Without it a container fails host-key verification on every run, and
    # BatchMode turns that into "could not reach the devbox" at max priority -
    # a false alarm that never stops, which is the kind that gets muted.
    cat > "$STUB/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/ssh.log"
case "$*" in *"drift --state"*) echo "FILE aaa /etc/one" ;; esac
EOF
    chmod +x "$STUB/ssh"
    DEJIMA_GUARD_SSH_KNOWN_HOSTS=/var/lib/dejima-guard/known_hosts run_watch check
    grep -q 'UserKnownHostsFile=/var/lib/dejima-guard/known_hosts' "$DEJIMA_GUARD_STATE/ssh.log"
}

@test "no known_hosts configured leaves ssh to its own default" {
    # On a systemd host ~/.ssh/known_hosts is the right answer and naming one
    # would override something already correct.
    cat > "$STUB/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/ssh.log"
case "$*" in *"drift --state"*) echo "FILE aaa /etc/one" ;; esac
EOF
    chmod +x "$STUB/ssh"
    run_watch check
    ! grep -q 'UserKnownHostsFile' "$DEJIMA_GUARD_STATE/ssh.log"
}

# --- config -----------------------------------------------------------------

@test "a URL without a scheme is refused rather than guessed at" {
    # curl reads a leading -K/path as an option taking the request from a file.
    # dejima refuses these for the same reason and this follows it.
    stub_ssh "FILE aaa /etc/one" 0
    printf 'devbox_host = devbox.example.invalid
devbox_user = tester\nntfy_url = ntfy.example.invalid/x\n' > "$DEJIMA_GUARD_CONF"
    run_watch check
    [ -f "$DEJIMA_GUARD_STATE/baseline" ] || true
    stub_ssh "FILE zzz /etc/one" 0
    run_watch check
    [[ "$output" == *"must start with http"* ]]
}

@test "the example placeholder is refused rather than run" {
    # So the shipped compose example cannot become a live config by being
    # copied and forgotten. It would otherwise start, fail to resolve, and
    # report a devbox unreachable that was never configured.
    printf 'devbox_host = CHANGE-ME.example.invalid\ndevbox_user = tester\n' > "$DEJIMA_GUARD_CONF"
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *placeholder* ]]
}

@test "the shipped compose example carries that placeholder" {
    # If it ever carries a plausible-looking host instead, the refusal above
    # stops protecting anything and this is the test that says so.
    grep -q 'DEJIMA_GUARD_DEVBOX_HOST: CHANGE-ME' "$REPO/docker-compose.example.yml"
}

@test "there is no committed docker-compose.yml to start by accident" {
    # `docker compose up` in a fresh clone must have nothing to run.
    [ ! -e "$REPO/docker-compose.yml" ]
}

@test "no devbox_user is refused rather than defaulted to root" {
    # It used to default to root, on a machine whose own runbook builds it
    # with no root password and expects sudo from an ordinary account - so the
    # default was wrong for every devbox built the documented way. Defaulting
    # to nothing is not better: ssh would use the local username, which in a
    # container is an account that does not exist over there.
    printf 'devbox_host = devbox.example.invalid\n' > "$DEJIMA_GUARD_CONF"
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *devbox_user* ]]
}

@test "nothing in the config is named so that it could mean this machine" {
    # DEJIMA_GUARD_HOST read as the host the guard runs on rather than the one
    # it watches, which is the wrong end of the only connection this makes. A
    # name that needs a comment to be read correctly is the wrong name.
    ! grep -qE '^\s*(host|user)\s*=' "$REPO/etc/config.example" \
        || { echo "config.example still has a bare host/user key"; false; }
    ! grep -qE 'DEJIMA_GUARD_(HOST|USER):' "$REPO/docker-compose.example.yml" \
        || { echo "the compose example still has an ambiguous variable"; false; }
}

@test "the two commands sent match what the devbox forced command permits" {
    # dejima-devbox-hardener's dejima-guard-shell whitelists these two strings
    # exactly. Change one here and the other side refuses it, which arrives
    # back as a failed collection reported as the devbox being unreachable.
    grep -q 'ssh_devbox dejima-devbox-audit drift --state' "$REPO/bin/dejima-guard"
    grep -q 'ssh_devbox dejima-devbox-audit reach' "$REPO/bin/dejima-guard"
}

@test "no host configured is refused, not silently skipped" {
    printf 'ntfy_url = https://ntfy.example.invalid/x\n' > "$DEJIMA_GUARD_CONF"
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *"no devbox_host"* ]]
}
