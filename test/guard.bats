#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# The ways a guard can be wrong are worse than the ways a check can be, because
# nobody is looking at a guard. It runs from a timer and its output is an alert
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
    # argv and stdin recorded separately, because which one a secret travels in
    # is the difference between a token every local user can read out of
    # /proc/<pid>/cmdline and one nobody else sees.
    cat > "$STUB/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/curl.log"
[ -t 0 ] || cat >> "$DEJIMA_GUARD_STATE/curl.stdin.log"
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
curl_log()  { cat "$DEJIMA_GUARD_STATE/curl.log" "$DEJIMA_GUARD_STATE/curl.stdin.log" 2>/dev/null || true; }
curl_argv() { cat "$DEJIMA_GUARD_STATE/curl.log" 2>/dev/null || true; }
# Both halves, or a test that clears the record between cycles still counts
# the calls made before it cleared.
curl_reset() { : > "$DEJIMA_GUARD_STATE/curl.log"; : > "$DEJIMA_GUARD_STATE/curl.stdin.log"; }
alerts()    { curl_log | grep -c 'Title:' || true; }
heartbeats() { curl_log | grep -c 'kuma.example.invalid' || true; }

# --- the first run ----------------------------------------------------------

@test "a first run refuses rather than baselining whatever it finds" {
    # It used to take one and print a warning. Under the timer that is five
    # minutes after boot, unattended, quite possibly before anyone has looked at
    # the machine, with the warning going to a journal nobody is reading yet -
    # and everything this program says afterwards rests on that file being an
    # honest picture of a clean box.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$status" -ne 0 ]
    [ ! -f "$DEJIMA_GUARD_STATE/baseline" ]
    [[ "$output" == *"accept"* ]]
}

@test "a guard with no baseline reports as down, rather than as healthy" {
    # It is not watching. The dead-man's switch is the one channel that can say
    # so, and a heartbeat here would tell it all is well.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$(heartbeats)" = 0 ]
    [ "$(alerts)" = 0 ]
}

@test "accept takes the baseline, and a check against it alerts nothing" {
    # Everything is new the first time. Alerting on it would train the operator
    # to dismiss the first alert they ever get from this.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    [ "$status" -eq 0 ]
    [ -f "$DEJIMA_GUARD_STATE/baseline" ]
    run_watch check
    [ "$status" -eq 0 ]
    [ "$(alerts)" = 0 ]
}

@test "an unchanged box alerts nothing and sends the heartbeat" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
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
    # same is how a guard reports all-clear on a box whose audit was removed.
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
    curl_reset
    stub_ssh "" 0 255
    run_watch check
    [ "$(heartbeats)" = 0 ]
}

# --- drift ------------------------------------------------------------------

@test "a change against the baseline alerts once, not once per finding" {
    # An apt upgrade otherwise arrives as forty pushes, and the next real alert
    # lands in a topic already muted.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    curl_reset
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
    run_watch accept          # the baseline is a decision now
    run_watch check
    curl_reset
    stub_ssh "FILE aaa /etc/one
FILE bbb /etc/evil-http-backdoor" 0
    run_watch check
    [[ "$(curl_log)" != *evil-http-backdoor* ]]
    [[ "$(curl_log)" == *"file(s)"* ]]
}

@test "the detail is kept locally, where the alert deliberately does not put it" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    stub_ssh "FILE aaa /etc/one
FILE bbb /etc/evil-http-backdoor" 0
    run_watch check
    grep -q 'evil-http-backdoor' "$DEJIMA_GUARD_STATE/last-report"
}

@test "containment failing alerts even when nothing changed" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    curl_reset
    stub_ssh "FILE aaa /etc/one" 1
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$(curl_log)" == *containment* ]]
}

@test "both wrong at once is one alert, at max" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    curl_reset
    stub_ssh "FILE bbb /etc/two" 1
    run_watch check
    [ "$(alerts)" = 1 ]
    [[ "$(curl_log)" == *"Priority: max"* ]]
}

# --- an alert that does not arrive ------------------------------------------

@test "a failed send is reported, not swallowed" {
    # Every call site used to end in `|| true`, so a wrong token produced
    # exactly nothing: drift found, ALERTED printed, no alert in existence.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    printf '#!/bin/sh\nexit 22\n' > "$STUB/curl"; chmod +x "$STUB/curl"
    stub_ssh "FILE bbb /etc/two" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *"ALERT NOT SENT"* ]]
}

@test "a failed send suppresses the heartbeat" {
    # THE POINT OF THE ABOVE. A guard that has found something and cannot say
    # so is, practically, a guard that is not running - and the only channel
    # left that can report it is the one that reports silence. Heartbeating
    # here tells the dead-man's switch all is well on the single cycle where
    # that is least true.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    cat > "$STUB/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/curl.log"
case "$*" in *kuma*) exit 0 ;; *) exit 22 ;; esac
EOF
    chmod +x "$STUB/curl"
    curl_reset
    stub_ssh "FILE bbb /etc/two" 0
    run_watch check
    [ "$(heartbeats)" = 0 ]
}

@test "the detail is still written when the alert could not be sent" {
    # It is the only surviving record of a finding nobody was told about.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    printf '#!/bin/sh\nexit 22\n' > "$STUB/curl"; chmod +x "$STUB/curl"
    stub_ssh "FILE bbb /etc/evil" 0
    run_watch check
    grep -q 'evil' "$DEJIMA_GUARD_STATE/last-report"
}

@test "no alerting configured at all is a failure, not a quiet success" {
    stub_ssh "FILE aaa /etc/one" 0
    printf 'devbox_host = devbox.example.invalid\ndevbox_user = tester\n' > "$DEJIMA_GUARD_CONF"
    run_watch accept          # the baseline is a decision now
    run_watch check
    stub_ssh "FILE bbb /etc/two" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *"ALERT NOT SENT"* ]]
}

@test "test-alert publishes, and says that sent is not received" {
    # Whether a push arrived is a question only the operator's phone answers,
    # so this must not imply it verified anything.
    run_watch test-alert
    [ "$status" -eq 0 ]
    [ "$(alerts)" = 1 ]
    [[ "$output" == *"Sent is not received"* ]]
}

@test "test-alert fails loudly when the channel is broken" {
    printf '#!/bin/sh\nexit 22\n' > "$STUB/curl"; chmod +x "$STUB/curl"
    run_watch test-alert
    [ "$status" -ne 0 ]
    [[ "$output" == *"goes nowhere"* ]]
}

@test "the README does not hand anyone a placeholder token to paste" {
    # It said: printf 'ntfy_token = tk_...' > secrets/config, inside a block
    # meant to be pasted whole. Pasted verbatim that writes a literal tk_...,
    # and a wrong token is a channel that silently drops findings.
    ! grep -q "printf 'ntfy_token" "$REPO/README.md" \
        || { echo "README still pastes a placeholder token into a file"; false; }
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
    chmod 0640 "$DEJIMA_GUARD_CONF"
    DEJIMA_GUARD_DEVBOX_HOST=devbox.example.invalid run_watch accept
    [ "$status" -eq 0 ]
    [ -f "$DEJIMA_GUARD_STATE/baseline" ]
}

@test "a config file alone still works, with no environment set" {
    # The container path must not become the only path. A systemd host mounts
    # nothing and sets nothing.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
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

@test "only the configured key is offered" {
    # `-i` ADDS a key rather than restricting to it. Without IdentitiesOnly,
    # ssh can authenticate with the operator's own key - or one in an agent -
    # and the forced command attached to the guard's key never applies. The
    # guard works, the alerts arrive, and the restriction protects nothing.
    #
    # Found on a real devbox, by the installer's check, which had the same bug.
    cat > "$STUB/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/ssh.log"
case "$*" in *"drift --state"*) echo "FILE aaa /etc/one" ;; esac
EOF
    chmod +x "$STUB/ssh"
    # A real file, because the key is checked for existence and readability
    # before anything connects - an unreadable one is the expected first
    # failure of a container deployment and is reported here rather than left
    # to look like the devbox rejecting it.
    : > "$BATS_TEST_TMPDIR/key"; chmod 600 "$BATS_TEST_TMPDIR/key"
    DEJIMA_GUARD_SSH_KEY="$BATS_TEST_TMPDIR/key" run_watch check
    grep -q 'IdentitiesOnly=yes' "$DEJIMA_GUARD_STATE/ssh.log"
}

@test "no key configured does not force IdentitiesOnly" {
    # With no -i there is nothing to restrict to, and setting it would refuse
    # every identity the operator has arranged by other means.
    cat > "$STUB/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/ssh.log"
case "$*" in *"drift --state"*) echo "FILE aaa /etc/one" ;; esac
EOF
    chmod +x "$STUB/ssh"
    run_watch check
    ! grep -q 'IdentitiesOnly' "$DEJIMA_GUARD_STATE/ssh.log"
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

# --- naming ------------------------------------------------------------------
#
# "The watcher could not collect from the devbox" names neither machine. An
# operator watching two boxes cannot tell the pushes apart, and on a phone at
# 3am "the devbox" is not a hostname.

@test "an alert names the watched host rather than saying devbox" {
    stub_ssh "" 0 255
    run_watch check
    [[ "$(curl_log)" == *"Title: devbox: unreachable"* ]]
    [[ "$(curl_log)" != *"Title: devbox unreachable"* ]]
}

@test "the alert body names the guard and the full host" {
    stub_ssh "" 0 255
    run_watch check
    [[ "$(curl_log)" == *"dejima-guard could not collect from devbox.example.invalid"* ]]
    [[ "$(curl_log)" != *"The watcher"* ]]
}

@test "the title uses the short name, which is what a lock screen shows" {
    # A fully qualified name in a title pushes the finding off the end of the
    # line, leaving a push that says only which machine, never what.
    stub_ssh "FILE /etc/passwd aaaa" 0
    run_watch accept          # the baseline is a decision now
    run_watch check                    # first run takes the baseline
    stub_ssh "FILE /etc/passwd bbbb" 0
    run_watch check
    [[ "$(curl_log)" == *"Title: devbox: unexplained changes"* ]]
    [[ "$(curl_log)" != *"Title: devbox.example.invalid:"* ]]
}

# --- the reason a collection failed -------------------------------------------

@test "a failed collection reports what ssh said, locally" {
    # The reason used to go to /dev/null and the alert offered three guesses
    # instead - on the one failure that stops this program working at all.
    cat > "$STUB/ssh" <<'SSHEOF'
#!/bin/sh
echo "Host key verification failed." >&2
exit 255
SSHEOF
    chmod +x "$STUB/ssh"
    run_watch check
    [[ "$output" == *"Host key verification failed"* ]]
}

@test "a host key failure names the command that fixes it" {
    # It is not "the box is down", it never recovers on its own, and it is the
    # expected state of a fresh container. Every cycle would alert at max
    # priority until the topic is muted.
    cat > "$STUB/ssh" <<'SSHEOF'
#!/bin/sh
echo "Host key verification failed." >&2
exit 255
SSHEOF
    chmod +x "$STUB/ssh"
    run_watch check
    [[ "$output" == *"trust-host"* ]]
}

@test "ssh's words stay off the phone" {
    # The one string near an alert that the far end has any say in.
    cat > "$STUB/ssh" <<'SSHEOF'
#!/bin/sh
echo "Host key verification failed." >&2
exit 255
SSHEOF
    chmod +x "$STUB/ssh"
    run_watch check
    [[ "$(curl_log)" != *"Host key verification"* ]]
}

# --- trust-host ---------------------------------------------------------------
#
# Without it the guard cannot connect at all: StrictHostKeyChecking is on by
# design and BatchMode turns its prompt into a failure, so an empty known_hosts
# reports the host unreachable at max priority on every cycle, forever. Nothing
# in this repository wrote that file - the comment explaining where it should
# live was the whole of the provision for it.

# Real keys, not plausible-looking strings. A blob ssh-keygen cannot read
# exercises a different path than a host key does, and the difference was a
# genuine bug: fingerprinting failed at the head of a pipeline and took the
# whole command down with it under pipefail.
stub_keyscan() {  # stub_keyscan NAME
    local f="$BATS_TEST_TMPDIR/hk_$1"
    [ -f "$f.pub" ] || ssh-keygen -q -t ed25519 -N '' -f "$f" -C "$1"
    printf '#!/bin/sh\nprintf "%%s %%s\\n" devbox.example.invalid "%s"\n' \
        "$(awk '{print $1, $2}' "$f.pub")" > "$STUB/ssh-keyscan"
    chmod +x "$STUB/ssh-keyscan"
}
keyline() { awk '{print $1, $2}' "$BATS_TEST_TMPDIR/hk_$1.pub"; }

@test "trust-host records the host key, so a first check can connect" {
    export DEJIMA_GUARD_SSH_KNOWN_HOSTS="$BATS_TEST_TMPDIR/lib/known_hosts"
    stub_keyscan real
    run_watch trust-host
    [ "$status" -eq 0 ]
    grep -q 'devbox.example.invalid ssh-ed25519' "$DEJIMA_GUARD_SSH_KNOWN_HOSTS"
}

@test "trust-host says plainly that nothing verified the key" {
    # It is trust on first use. An operator who thinks it was checked has been
    # misled by the tool rather than by their own assumption.
    export DEJIMA_GUARD_SSH_KNOWN_HOSTS="$BATS_TEST_TMPDIR/lib/known_hosts"
    stub_keyscan real
    run_watch trust-host
    [[ "$output" == *"NOT VERIFIED"* ]]
}

@test "trust-host refuses to overwrite a key that has changed" {
    # A changed host key is either a rebuild or the thing this program exists to
    # notice. Quietly replacing it would erase the distinction.
    export DEJIMA_GUARD_SSH_KNOWN_HOSTS="$BATS_TEST_TMPDIR/lib/known_hosts"
    stub_keyscan old
    printf 'devbox.example.invalid %s\n' "$(keyline old)" \
        > "$DEJIMA_GUARD_SSH_KNOWN_HOSTS"
    old_blob=$(awk '{print $3}' "$DEJIMA_GUARD_SSH_KNOWN_HOSTS")
    stub_keyscan new
    run_watch trust-host
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIFFERENT KEY"* ]]
    grep -qF "$old_blob" "$DEJIMA_GUARD_SSH_KNOWN_HOSTS"
    [ "$(grep -c . "$DEJIMA_GUARD_SSH_KNOWN_HOSTS")" -eq 1 ]
}

@test "trust-host run twice does not append a second copy" {
    export DEJIMA_GUARD_SSH_KNOWN_HOSTS="$BATS_TEST_TMPDIR/lib/known_hosts"
    stub_keyscan real
    run_watch trust-host
    run_watch trust-host
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$DEJIMA_GUARD_SSH_KNOWN_HOSTS")" -eq 1 ]
}

@test "a wrong --fingerprint writes nothing at all" {
    export DEJIMA_GUARD_SSH_KNOWN_HOSTS="$BATS_TEST_TMPDIR/lib/known_hosts"
    stub_keyscan real
    run_watch trust-host --fingerprint SHA256:definitelynotthisone
    [ "$status" -ne 0 ]
    [ ! -s "$DEJIMA_GUARD_SSH_KNOWN_HOSTS" ]
}

# --- the key this machine holds ----------------------------------------------
#
# Containers make an unreadable key the expected first failure rather than an
# unlikely one: the image runs as its own uid, compose mounts a file secret with
# the host's ownership, and a private key is 0600 to somebody else. So a
# correctly built deployment cannot read its own key until the ownership is
# made to match, and the whole setup looks like the devbox refusing it.

@test "an unreadable key is reported here, not left to look like a rejection" {
    # ssh calls it "Permission denied (publickey,password)", which is what a
    # devbox that rejected the key says too - so the operator debugs the far
    # end over a file on this one.
    key="$BATS_TEST_TMPDIR/unreadable_key"
    : > "$key"; chmod 000 "$key"
    export DEJIMA_GUARD_SSH_KEY="$key"
    stub_ssh "FILE /etc/passwd aaaa" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read ssh_key"* ]]
}

@test "an unreadable key names the chown that fixes it" {
    key="$BATS_TEST_TMPDIR/unreadable_key"
    : > "$key"; chmod 000 "$key"
    export DEJIMA_GUARD_SSH_KEY="$key"
    stub_ssh "" 0
    run_watch check
    [[ "$output" == *"chown"* ]]
}

@test "a key that does not exist is named, rather than reported as a devbox fault" {
    export DEJIMA_GUARD_SSH_KEY="$BATS_TEST_TMPDIR/no-such-key"
    stub_ssh "" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "a bad key stops the cycle before it can alert about the devbox" {
    # A file on this machine is not a finding about that one. Reporting it as
    # one sends the operator to the wrong host, and the silence that follows is
    # what the dead-man's switch is for.
    key="$BATS_TEST_TMPDIR/unreadable_key"
    : > "$key"; chmod 000 "$key"
    export DEJIMA_GUARD_SSH_KEY="$key"
    stub_ssh "" 0
    run_watch check
    [ "$(alerts)" -eq 0 ]
    [ "$(heartbeats)" -eq 0 ]
}

@test "the uid the README tells you to chown to is the one the image runs as" {
    # Two files, one number. A uid that moved between them would produce
    # exactly the failure this documents, with the documentation insisting it
    # had been dealt with.
    uid=$(grep -oE '\-\-uid [0-9]+' "$REPO/Dockerfile" | awk '{print $2}')
    [ -n "$uid" ]
    grep -q "chown $uid:$uid" "$REPO/README.md"
}
# --- what a URL may contain ---------------------------------------------------
#
# The rule refused "&", so it refused the push URL Uptime Kuma hands out - the
# one value heartbeat_url is documented to hold. This project rejected the
# setting this project recommends.
#
# Refusing a legitimate URL is not the safe direction. It costs the heartbeat,
# which is the one signal a compromised devbox cannot suppress, so an
# over-strict rule quietly removes the control that does not depend on the
# watched machine cooperating.

@test "an Uptime Kuma push URL is accepted, ampersands and all" {
    export DEJIMA_GUARD_HEARTBEAT_URL='https://kuma.example.invalid/api/push/abc?status=up&msg=OK&ping='
    stub_ssh "FILE /etc/passwd aaaa" 0
    run_watch check
    [[ "$output" != *"heartbeat_url contains"* ]]
}

@test "every character RFC 3986 permits is accepted" {
    # Written out rather than sampled: the previous list looked complete too.
    export DEJIMA_GUARD_NTFY_URL="https://h.example.invalid/p?a=1&b=2#f/x_y~z.w+q%20r,s;t=u!v\$w'x(y)z*"
    stub_ssh "FILE /etc/passwd aaaa" 0
    run_watch check
    # Asserted as "not rejected at all" rather than as the absence of one
    # message. Matching on the new wording passed against the old check, which
    # rejected this URL saying something else.
    [[ "$output" != *"ntfy_url"* ]]
}

@test "a URL with whitespace is still refused" {
    export DEJIMA_GUARD_HEARTBEAT_URL='https://kuma.example.invalid/api/push/a b'
    stub_ssh "" 0
    run_watch check
    [[ "$output" == *"whitespace"* ]]
}

@test "a URL with an embedded newline is refused" {
    # The check that deletes permitted characters cannot see this one:
    # command substitution strips a trailing newline, so what is left reads as
    # empty and the value passes. It is also the character worth being surest
    # about, being the one that turns one argument into two lines of something.
    export DEJIMA_GUARD_HEARTBEAT_URL="$(printf 'https://kuma.example.invalid/a\nb')"
    stub_ssh "" 0
    run_watch check
    [[ "$output" == *"whitespace"* ]] || [[ "$output" == *"control character"* ]]
}

@test "a refused URL names the character, not just the setting" {
    # "contains a character that is not allowed here" was the whole report.
    # Finding which one meant guessing, on a value that is usually long.
    export DEJIMA_GUARD_HEARTBEAT_URL='https://kuma.example.invalid/a|b'
    stub_ssh "" 0
    run_watch check
    [[ "$output" == *"|"* ]]
}

@test "the config example's own heartbeat_url would be accepted" {
    # A shipped example the shipped check refuses is the failure this had.
    url=$(sed -n 's/^[[:space:]]*heartbeat_url[[:space:]]*=[[:space:]]*//p' "$REPO/etc/config.example" | tail -1)
    [ -n "$url" ]
    export DEJIMA_GUARD_HEARTBEAT_URL="$url"
    stub_ssh "FILE /etc/passwd aaaa" 0
    run_watch check
    [[ "$output" != *"heartbeat_url"* ]]
}

@test "nothing user-facing calls this program the watcher" {
    # It has a name. "The watcher" names no machine, reads as a role rather
    # than a thing to run, and left alerts that identified neither end of the
    # connection they were about.
    #
    # This file is excluded: the assertion above deliberately quotes the old
    # wording, which is the only place it should still appear.
    found=$(grep -rn -i 'the watcher' "$REPO/README.md" "$REPO/bin" "$REPO/etc" \
                "$REPO/systemd" "$REPO/Dockerfile" "$REPO/docker-compose.example.yml" \
            2>/dev/null || true)
    [ -z "$found" ] || { echo "$found"; false; }
}

# --- the report is an untrusted document -------------------------------------
#
# Alert bodies are composed here from counts, and that rule holds. But the alert
# exists to say go and read the report, and the report is the devbox's own
# words: file paths, unit names, whatever ssh said. A path is a filename, and a
# filename may contain an escape sequence.

@test "escape sequences from the devbox do not reach the report" {
    # ESC[2K ESC[A erases the line above and writes over it. `dejima-guard
    # report` cats this to a terminal on the machine holding the SSH key to the
    # box the report is about, so a compromised devbox could name a file such
    # that the evidence of it scrolls past as an all-clear.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check                     # first cycle takes the baseline
    stub_ssh "$(printf 'FILE aaa /etc/\033[2K\033[Aall-clear')" 0
    run_watch check                     # second produces the diff, and a report
    run_watch report
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *"?[2K"* ]]
}

@test "a control character is replaced rather than dropped" {
    # A filename with an escape sequence in it is itself a finding. One that
    # vanished silently would be the second thing this got wrong.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    stub_ssh "$(printf 'FILE aaa /etc/we\001ird')" 0
    run_watch check
    run_watch report
    [[ "$output" == *"we?ird"* ]]
}

@test "a legitimate non-ASCII path is left as it is" {
    # Stripping to ASCII would mangle every accented filename on the box into a
    # difference that never goes away.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    stub_ssh 'FILE aaa /etc/café-und-größe' 0
    run_watch check
    run_watch report
    [[ "$output" == *"café-und-größe"* ]]
}

@test "the baseline is stored sanitised, so a diff cannot resurrect one" {
    # Sanitising only on display would leave the bytes in the baseline and in
    # every diff computed against it.
    stub_ssh "$(printf 'FILE aaa /etc/x\033[2Ky')" 0
    run_watch check
    ! grep -q $'\033' "$DEJIMA_GUARD_STATE/baseline"
}

@test "ssh's own words are sanitised too" {
    # It is the far end talking, on the path that reports the far end failing.
    cat > "$STUB/ssh" <<'SSHEOF'
#!/bin/sh
printf 'Host key \033[2Kverification failed.\n' >&2
exit 255
SSHEOF
    chmod +x "$STUB/ssh"
    run_watch check
    [[ "$output" != *$'\033'* ]]
}

@test "the setup installs every program the README later tells you to run" {
    # A rewrite of the setup replaced a manual step with a call to
    # dejima-guard-install-key, which the install block did not install. The
    # instructions were then correct about what to run and wrong about whether
    # it was there.
    for prog in $(grep -oE '\bdejima-guard(-[a-z-]+)?\b' "$REPO/README.md" \
                  | sort -u | grep -v '^dejima-guard$'); do
        [ -f "$REPO/bin/$prog" ] || continue        # not one of ours
        grep -q "bin/$prog" "$REPO/README.md" \
            || { echo "README runs $prog but never installs it"; false; }
    done
}

@test "every compose command that starts the guard rebuilds it" {
    # There is no registry: the image is built from the Dockerfile in the
    # checkout. `docker compose up -d` reuses whatever image exists, so after a
    # git pull it starts the old code and reports success - an update that
    # silently did not happen, on the program whose job is to notice things.
    #
    # Scoped to the setup, which is the part that follows a pull. A one-shot
    # `run` afterwards is working against an image that is already current, and
    # rebuilding on every `accept` would be a slow answer to a question nobody
    # asked.
    setup_block=$(sed -n '/^### Or as a container/,/^### What goes in each setting/p' "$REPO/README.md")
    while IFS= read -r line; do
        case "$line" in
            *" up "*|*" run "*) ;;
            *) continue ;;
        esac
        [[ "$line" == *--build* ]] \
            || { echo "setup compose command without --build: $line"; false; }
    done < <(printf '%s\n' "$setup_block" | grep -oE 'docker compose [a-z]+ [^`]*')

    # Anywhere at all, an `up` starts the long-running thing and must be current.
    while IFS= read -r line; do
        [[ "$line" == *--build* ]] \
            || { echo "compose up without --build: $line"; false; }
    done < <(grep -oE 'docker compose up [^`]*' "$REPO/README.md")
}

# --- branding -----------------------------------------------------------------

@test "every image the README references is a file this repository ships" {
    # Both syntaxes and both formats. The wordmark is an <img> tag and a png;
    # the badge is markdown image syntax and an svg. A test written for only the
    # first pair would not have seen the second at all.
    found=0
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        case "$src" in http*) continue ;; esac
        found=$((found + 1))
        [ -f "$REPO/$src" ] || { echo "README references missing image: $src"; false; }
    done < <(grep -ohE 'src="[^"]+\.(png|svg)"|\]\([^)]+\.(png|svg)\)' "$REPO/README.md" \
             | sed 's/^src="//; s/"$//; s/^](//; s/)$//')
    [ "$found" -ge 2 ] || { echo "expected at least the wordmark and the badge"; false; }

    # Both wordmark modes ship, because the GitHub mirror picks between them
    # by the reader's theme.
    [ -f "$REPO/assets/dejima-wordmark-darkmode.png" ]
    [ -f "$REPO/assets/dejima-wordmark-lightmode.png" ]
}

@test "the marks are attributed, since the licence here does not cover them" {
    # They are trademarks, and GPL-3.0 says nothing about them. The link is
    # absolute so a fork resolves it to the canonical terms rather than to its
    # own copy of them.
    grep -q 'dejima/src/branch/main/ATTRIBUTION.md' "$REPO/README.md"
    grep -q 'dejima/src/branch/main/ATTRIBUTION.md' "$REPO/assets/README.md"
}

# --- what the alerting setup documents ---------------------------------------

@test "the intervals the README quotes are the ones that ship" {
    # The Uptime Kuma advice is "longer than dejima-guard's", which is only
    # actionable if the number beside it is this program's actual cadence. Two
    # places hold it and neither knows about the README.
    grep -q 'DEJIMA_GUARD_INTERVAL=900' "$REPO/Dockerfile"
    grep -q 'OnUnitActiveSec=15min' "$REPO/systemd/dejima-guard.timer"
    grep -q '900s' "$REPO/README.md"
    grep -q '15min' "$REPO/README.md"
}

@test "the heartbeat interval documented is longer than the push interval" {
    # Equal intervals put every ping on the deadline, and the timer adds up to
    # 60s of jitter on top - so a monitor set to match goes down on a healthy
    # guard, which is the false alarm that gets a monitor deleted.
    kuma=$(grep -oE '\b1200s\b' "$REPO/README.md" | head -1)
    [ "$kuma" = 1200s ]
    [ "${kuma%s}" -gt 900 ]
}

@test "ntfy is documented as write-only for the guard, and closed by default" {
    # read-write would let whoever takes the guard read every alert ever sent
    # about the devbox, and the absence of alerts is as informative as their
    # content. deny-all is what denies the devbox without anyone remembering to.
    grep -q 'auth-default-access: deny-all' "$REPO/README.md"
    grep -q 'ntfy access guard .* write-only' "$REPO/README.md"
    grep -q 'ntfy access phone .* read-only' "$REPO/README.md"

    # deny-all is server-wide, so it takes dejima's anonymous publishing with
    # it unless that topic is granted back by name. Recommending the setting
    # without the grant would break notifications on the box being watched.
    grep -q 'ntfy access everyone .* read-write' "$REPO/README.md"

    # And it is not always available: a shared server is somebody else's to
    # configure. Advice that assumes otherwise has no answer for the reader who
    # cannot take it.
    grep -q 'server you cannot reconfigure' "$REPO/README.md"

    # An admin bypasses the ACL entirely, so every entry above is decoration on
    # an admin account. Documenting the grants without that would describe a
    # closed topic that is open.
    grep -q 'admin bypasses the ACL' "$REPO/README.md"
}

@test "the deny-all advice warns that it closes the rest of the server too" {
    # It is a server-wide setting recommended for one topic's sake. A reader who
    # applies it and loses every other subscription was told to do that, and the
    # symptom - a failed WebSocket upgrade - points at their reverse proxy
    # rather than at the setting they just changed.
    grep -q 'break notifications' "$REPO/README.md"
    grep -q '403' "$REPO/README.md"
    grep -qi 'log in' "$REPO/README.md"

    # The warning has to sit with the setting, not below the commands that
    # follow it. A reader who has already run the block has already broken the
    # other notifications on that server.
    yaml=$(grep -n 'auth-default-access: deny-all' "$REPO/README.md" | head -1 | cut -d: -f1)
    warn=$(grep -n 'server-wide switch' "$REPO/README.md" | head -1 | cut -d: -f1)
    cmds=$(grep -n 'ntfy user add guard' "$REPO/README.md" | head -1 | cut -d: -f1)
    [ "$warn" -gt "$yaml" ] && [ "$warn" -lt "$cmds" ]

    # And the block a reader pastes has to be one that works. Granting the
    # reading account only the alert topic is the configuration that took down
    # everything else on the server.
    grep -q 'ntfy access phone    "\*"' "$REPO/README.md"

    # The apps subscribe to every topic over one request, and ntfy denies the
    # whole request on the first topic the account cannot read. Without this,
    # a single stray subscription looks like the server being broken and both
    # correctly configured topics look like the thing that broke.
    grep -q 'returning 403 for the whole request' "$REPO/README.md"
}

# --- what the process list shows ---------------------------------------------
#
# /proc/<pid>/cmdline is world-readable. A secret passed as a command-line
# argument is readable by every local account for as long as the call runs, and
# on the systemd path this runs as root on a machine that may have other people
# on it.

@test "the ntfy token is never a command-line argument" {
    export DEJIMA_GUARD_NTFY_TOKEN=tk_secretvalue
    stub_ssh "" 0 255                      # any path that alerts
    run_watch check
    [[ "$(curl_log)" == *tk_secretvalue* ]]      # it was sent
    [[ "$(curl_argv)" != *tk_secretvalue* ]]     # and not through argv
}

@test "the heartbeat URL is never a command-line argument" {
    # An Uptime Kuma push URL carries its token in the path, so the URL is the
    # credential rather than merely the destination.
    stub_ssh "FILE /etc/passwd aaaa" 0
    run_watch accept          # the baseline is a decision now
    run_watch check
    [[ "$(curl_log)" == *kuma.example.invalid* ]]
    [[ "$(curl_argv)" != *kuma.example.invalid* ]]
}

@test "a token that would break out of the curl config is refused" {
    # curl config syntax is not shell, but it is still a parser being handed a
    # value from a file: a quote ends the value early and the rest is read as
    # further options.
    export DEJIMA_GUARD_NTFY_TOKEN='tk_x" 
url = "http://evil.example.invalid/'
    stub_ssh "" 0 255
    run_watch check
    [[ "$output" == *"ntfy_token"* ]]
    [[ "$(curl_log)" != *evil.example.invalid* ]]
}

@test "the security policy states what taking this machine would get" {
    # Watching a devbox means holding credentials to it, so running this is a
    # concentration of privilege that did not exist before. A page that claims
    # the benefit without stating that is selling something.
    [ -f "$REPO/SECURITY.md" ]
    grep -q 'ntfy token' "$REPO/SECURITY.md"
    grep -q 'baseline' "$REPO/SECURITY.md"
    grep -qi 'egress' "$REPO/SECURITY.md"
    grep -q 'SECURITY.md' "$REPO/README.md"
}

@test "no em-dashes, anywhere this project publishes" {
    # House style across the organisation. They are also the single most
    # reliable tell of machine-written prose, which is a poor look on a project
    # about noticing what changed.
    # Built from its bytes rather than written out, or this file is the one
    # hit the check reports and the only way to pass is to exempt the test.
    dash=$(printf '\xe2\x80\x94')
    found=$(cd "$REPO" && git ls-files | xargs grep -nF "$dash" 2>/dev/null || true)
    [ -z "$found" ] || { echo "$found"; false; }
}

# --- the guard's own host ------------------------------------------------------
#
# The container path has always run unprivileged in a capability-dropped
# sandbox. The host path runs on whatever the operator has, and this project
# describes no hardening for that machine, so what the unit asks for is the
# whole of what bounds a bug here.

@test "the systemd unit does not run as root" {
    # The Dockerfile argues that running as root grants root to a program
    # holding an SSH key to another machine, for no reason at all. That argument
    # does not stop being true on a host, and the unit used to disagree with it.
    grep -q '^User=' "$REPO/systemd/dejima-guard.service"
    grep -q '^StateDirectory=' "$REPO/systemd/dejima-guard.service"
}

@test "the unit empties the capability bounding set" {
    # NoNewPrivileges does not drop capabilities for root, so on the old unit it
    # was doing less than it looked like it was doing.
    grep -q '^CapabilityBoundingSet=$' "$REPO/systemd/dejima-guard.service"
}

@test "the unit bounds memory and tasks" {
    # The watched host chooses how much it sends. The collector caps that, and
    # these are the backstop for what the cap does not cover.
    grep -q '^MemoryMax=' "$REPO/systemd/dejima-guard.service"
    grep -q '^TasksMax=' "$REPO/systemd/dejima-guard.service"
}

@test "SECURITY.md does not claim a non-root uid the host path lacks" {
    # It listed "runs as a non-root uid" among the stronger properties, which
    # was true of the container and read as a property of the project.
    if grep -q 'non-root uid' "$REPO/SECURITY.md"; then
        grep -q '^User=' "$REPO/systemd/dejima-guard.service"
    fi
}

# --- how much the watched host may send ---------------------------------------

@test "an oversize response is a finding, not something to truncate and diff" {
    # Truncating would hand the devbox a way to manufacture a diff, or to cut
    # the state off just before whatever it added.
    export DEJIMA_GUARD_MAX_STATE_BYTES=2048
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    big=$(head -c 9000 /dev/zero | tr '\0' 'x')
    stub_ssh "$big" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$(curl_log)" == *"oversize"* ]]
}

@test "an oversize response does not become the baseline" {
    export DEJIMA_GUARD_MAX_STATE_BYTES=2048
    big=$(head -c 9000 /dev/zero | tr '\0' 'x')
    stub_ssh "$big" 0
    run_watch accept
    [ "$status" -ne 0 ]
    [ ! -f "$DEJIMA_GUARD_STATE/baseline" ]
}

@test "a capped read is not reported as the devbox being unreachable" {
    # head closing the pipe sends SIGPIPE to ssh, so with pipefail on, a capped
    # read looks like a failed connection - the one reading that sends an
    # operator to the wrong end of the problem.
    export DEJIMA_GUARD_MAX_STATE_BYTES=2048
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    big=$(head -c 9000 /dev/zero | tr '\0' 'x')
    stub_ssh "$big" 0
    run_watch check
    [[ "$(curl_log)" != *unreachable* ]]
}

@test "a normal-sized state still collects" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    [ -f "$DEJIMA_GUARD_STATE/baseline" ]
    grep -q '/etc/one' "$DEJIMA_GUARD_STATE/baseline"
}

# --- what the ssh client is allowed to inherit --------------------------------

@test "the connection names the settings a local ssh_config could widen" {
    # ssh reads /etc/ssh/ssh_config and the account's ~/.ssh/config, neither of
    # which this project owns, on a connection to a host the design assumes may
    # be hostile.
    stub_ssh "FILE aaa /etc/one" 0
    cat > "$STUB/ssh" <<'SSHEOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DEJIMA_GUARD_STATE/ssh.log"
case "$*" in *"drift --state"*) echo "FILE aaa /etc/one" ;; esac
SSHEOF
    chmod +x "$STUB/ssh"
    run_watch accept
    for o in ForwardAgent=no ClearAllForwardings=yes PermitLocalCommand=no ControlMaster=no; do
        grep -q "$o" "$DEJIMA_GUARD_STATE/ssh.log" || { echo "missing $o"; false; }
    done
}

# --- the config file is executable-equivalent ---------------------------------

@test "a group-writable config is refused, since it names a command to run" {
    # alert_command means write access to this file is code execution as
    # whoever the guard runs as. ssh takes the same line about a private key.
    chmod 0660 "$DEJIMA_GUARD_CONF"
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [ "$status" -ne 0 ]
    [[ "$output" == *"writable by group"* ]]
}

@test "a correctly permissioned config is accepted" {
    chmod 0640 "$DEJIMA_GUARD_CONF"
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    [ "$status" -eq 0 ]
}

@test "no credential is set in the compose environment block" {
    # Everything in `environment:` is visible to `docker inspect` and to
    # anything that can read /proc, which is the reason the token was already
    # kept out. The heartbeat URL belongs with it: an Uptime Kuma push URL
    # carries its token in the path, so holding it is enough to tell Kuma this
    # guard is healthy and suppress the one signal that reports a dead one.
    for key in TOKEN HEARTBEAT_URL; do
        grep -q "DEJIMA_GUARD_$key:" "$REPO/docker-compose.example.yml" \
            && { echo "DEJIMA_GUARD_$key is in the compose environment"; false; }
    done
    # And it is still reachable, in the file that is mounted as a secret.
    grep -q '^heartbeat_url' "$REPO/etc/config.example"
    grep -q 'heartbeat_url' "$REPO/README.md"
}

# --- what kind of change it was ------------------------------------------------
#
# Every finding used to arrive as one "unexplained changes" at high. A checksum
# that moved because logrotate ran, a new listening port, and the audit binary
# itself being replaced were the same push.

@test "a change to the audit's own binary is its own alert, at max" {
    # The sharpest one. If the collector changed, everything this guard has been
    # told since is suspect, including the report saying so.
    stub_ssh "FILE aaa /usr/local/sbin/dejima-devbox-audit" 0
    run_watch accept
    stub_ssh "FILE bbb /usr/local/sbin/dejima-devbox-audit" 0
    run_watch check
    [[ "$(curl_log)" == *"Priority: max"* ]]
    [[ "$(curl_log)" == *"watched path changed"* ]]
    [[ "$(curl_log)" == *"unverified"* ]]
}

@test "the forced command and the sudoers rule are watched the same way" {
    # They are what makes the guard's access read-only, so a change to them is a
    # change in what a stolen key is worth.
    for path in /usr/local/sbin/dejima-guard-shell /etc/sudoers.d/dejima-guard; do
        rm -rf "$DEJIMA_GUARD_STATE"; mkdir -p "$DEJIMA_GUARD_STATE"
        stub_ssh "FILE aaa $path" 0
        run_watch accept
        stub_ssh "FILE bbb $path" 0
        run_watch check
        [[ "$(curl_log)" == *"watched path changed"* ]] || { echo "missed $path"; false; }
    done
}

@test "an authorized_keys change is watched whichever home it is in" {
    # Matched on the tail of the path, since the account name is the operator's
    # and root's copy is a different directory again.
    stub_ssh "FILE aaa /home/someone/.ssh/authorized_keys" 0
    run_watch accept
    stub_ssh "FILE bbb /home/someone/.ssh/authorized_keys" 0
    run_watch check
    [[ "$(curl_log)" == *"watched path changed"* ]]
}

@test "a new listening port alerts at max, not as an ordinary change" {
    # A listener is a thing arranging to be reached. It is not a config edit.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    stub_ssh "FILE aaa /etc/one
PORT tcp 0.0.0.0:4444" 0
    run_watch check
    [[ "$(curl_log)" == *"Priority: max"* ]]
    [[ "$(curl_log)" == *"newly arranged to run or to be reached"* ]]
}

@test "a newly enabled unit alerts at max too" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    stub_ssh "FILE aaa /etc/one
UNIT backdoor.service" 0
    run_watch check
    [[ "$(curl_log)" == *"Priority: max"* ]]
}

@test "a port that went away is not a new listener" {
    # Removal is drift worth reporting and is not the shape this escalates for.
    stub_ssh "FILE aaa /etc/one
PORT tcp 0.0.0.0:4444" 0
    run_watch accept
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    [[ "$(curl_log)" == *"unexplained changes"* ]]
    [[ "$(curl_log)" != *"newly arranged"* ]]
}

@test "an ordinary file change still reports as ordinary drift" {
    # The escalations are worth nothing if everything escalates.
    stub_ssh "FILE aaa /etc/logrotate.conf" 0
    run_watch accept
    stub_ssh "FILE bbb /etc/logrotate.conf" 0
    run_watch check
    [[ "$(curl_log)" == *"unexplained changes"* ]]
    [[ "$(curl_log)" != *"Priority: max"* ]]
}

@test "symlink changes are counted and named" {
    # The devbox collects them now because hashing cannot see one. A count that
    # ignored them would report a substitution as nothing at all.
    stub_ssh "LINK /usr/local/bin/x -> /bin/sh" 0
    run_watch accept
    stub_ssh "LINK /usr/local/bin/x -> /tmp/evil" 0
    run_watch check
    [[ "$(curl_log)" == *"symlink"* ]]
}

@test "the watched paths are configurable, and the default is not empty" {
    export DEJIMA_GUARD_CRITICAL_PATHS='/etc/mine'
    stub_ssh "FILE aaa /etc/mine" 0
    run_watch accept
    stub_ssh "FILE bbb /etc/mine" 0
    run_watch check
    [[ "$(curl_log)" == *"watched path changed"* ]]
}

# --- running one command in a container ---------------------------------------

@test "the entrypoint runs a single command when given arguments" {
    # `docker compose run SERVICE CMD` replaces the command and keeps the
    # entrypoint. So `run --rm dejima-guard trust-host` arrives at the loop as
    # an argument, and a loop that ignored its arguments started checking every
    # fifteen minutes instead - in a container the operator had to interrupt,
    # while waiting for a fingerprint that was never going to print.
    # Timed out, because the bug being guarded against is an infinite loop:
    # without the timeout a regression hangs the suite rather than failing it.
    run timeout 5 env DEJIMA_GUARD_BIN=/bin/echo "$REPO/bin/dejima-guard-loop" trust-host
    [ "$status" -eq 0 ]
    [ "$output" = "trust-host" ]
    [[ "$output" != *"every"* ]]
}

@test "the entrypoint still loops when given nothing" {
    # The timer is the default, and this is the half a container deployment
    # depends on.
    run timeout 2 env DEJIMA_GUARD_INTERVAL=60 DEJIMA_GUARD_BIN=/bin/true \
        "$REPO/bin/dejima-guard-loop"
    [[ "$output" == *"every 60s"* ]]
}

@test "the setup does not name the binary twice after run" {
    # The entrypoint is already the guard, so repeating the name passes it to
    # itself as an argument.
    ! grep -q 'compose run .*dejima-guard dejima-guard' "$REPO/README.md"
}

@test "the container form of every command is documented" {
    # There is no dejima-guard on a container host. The bare names in Use are
    # the host path, and running them on a compose deployment finds nothing, or
    # finds a second deployment with its own baseline.
    grep -q 'docker compose exec dejima-guard dejima-guard' "$REPO/README.md"
    grep -q 'docker compose run --rm dejima-guard' "$REPO/README.md"
    grep -qi 'no .dejima-guard. on the host' "$REPO/README.md"
}

# --- the evidence outliving the cycle after it --------------------------------
#
# last-report is overwritten every cycle, so a clean one erases the alert before
# it. On anything that alternates - and a flapping line alternates by definition
# - an operator running `report` after an alert lands is most likely to catch a
# clean cycle and read "no changes against the baseline", which says the alert
# was imaginary.

@test "a clean cycle does not erase the last finding" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    stub_ssh "FILE bbb /etc/one" 0          # a change: this cycle alerts
    run_watch check
    stub_ssh "FILE bbb /etc/one" 0          # accepted as the new normal? no:
    run_watch accept                        # re-accept so the next is clean
    run_watch check
    run_watch report --finding
    [[ "$output" == *"/etc/one"* ]]
}

@test "report says a finding is still there when the last cycle was clean" {
    # This is exactly when an operator is looking and finding nothing.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    stub_ssh "FILE bbb /etc/one" 0
    run_watch check
    run_watch accept
    run_watch check
    run_watch report
    [[ "$output" == *"no changes against the baseline"* ]]
    [[ "$output" == *"report --finding"* ]]
}

@test "report does not point at a finding that is the report" {
    # After an alerting cycle the two are the same file, and telling somebody to
    # go and read what they are already reading is noise.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    stub_ssh "FILE bbb /etc/one" 0
    run_watch check
    run_watch report
    [[ "$output" != *"report --finding"* ]]
}

@test "--finding with nothing found says so rather than printing the last cycle" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    run_watch check
    run_watch report --finding
    [[ "$output" == *"no cycle has found anything yet"* ]]
}

@test "an argument report does not know is an error, not a no-op" {
    # The version before --finding dropped every argument at the dispatch, so
    # `report --finding` printed the last report and looked like the flag had
    # worked. Identical output from two different commands reads as the feature
    # doing nothing, when what it did was not exist in the copy being run.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    run_watch check
    run_watch report --findings          # a plausible typo
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown argument"* ]]
}

@test "the unknown-argument message says how to get a newer copy" {
    # A container makes this easy to be in: git pull changes the checkout and
    # not the image.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    run_watch check
    run_watch report --whatever
    [[ "$output" == *"--build"* ]]
    [[ "$output" == *"install.sh"* ]]
}

@test "report with no argument is still fine" {
    stub_ssh "FILE aaa /etc/one" 0
    run_watch accept
    run_watch check
    run_watch report
    [ "$status" -eq 0 ]
}
