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

# --- an alert that does not arrive ------------------------------------------

@test "a failed send is reported, not swallowed" {
    # Every call site used to end in `|| true`, so a wrong token produced
    # exactly nothing: drift found, ALERTED printed, no alert in existence.
    stub_ssh "FILE aaa /etc/one" 0
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
    : > "$DEJIMA_GUARD_STATE/curl.log"
    stub_ssh "FILE bbb /etc/two" 0
    run_watch check
    [ "$(heartbeats)" = 0 ]
}

@test "the detail is still written when the alert could not be sent" {
    # It is the only surviving record of a finding nobody was told about.
    stub_ssh "FILE aaa /etc/one" 0
    run_watch check
    printf '#!/bin/sh\nexit 22\n' > "$STUB/curl"; chmod +x "$STUB/curl"
    stub_ssh "FILE bbb /etc/evil" 0
    run_watch check
    grep -q 'evil' "$DEJIMA_GUARD_STATE/last-report"
}

@test "no alerting configured at all is a failure, not a quiet success" {
    stub_ssh "FILE aaa /etc/one" 0
    printf 'devbox_host = devbox.example.invalid\ndevbox_user = tester\n' > "$DEJIMA_GUARD_CONF"
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
