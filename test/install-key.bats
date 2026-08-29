#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Installing the guard's key is the step where the restriction is either
# applied or not, and the restriction is what stands between a key taken off
# the guard and a shell on the devbox.
#
# ssh-copy-id cannot do it: it copies the bare key with no options. Doing it by
# hand means copy, then edit - with a window in between where an unrestricted
# key is live. So this program exists, and what it has to get right is that the
# line it writes carries the forced command, every time.
#
# `ssh` is stubbed with a devbox: it runs the install script locally, and answers
# the four verification commands the way a box with the forced command in place
# answers them - two that work, two refused on stderr with exit 64.
#
# THE EXIT STATUS IS THE POINT. The stub this replaced did `shift; exec bash -c
# "$1"`, which for the verification calls handed bash the key's path rather than
# the command, so all four checks ran garbage and the phase was never tested at
# all. Two bugs shipped through it, both of which a stub that relayed a status
# would have caught: the missing IdentitiesOnly, and a `| grep -q refused`
# pipeline that under pipefail returned the refusal's own exit 64 and so read a
# working restriction as an absent one.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TOOL="$REPO/bin/dejima-guard-install-key"
    export HOME="$BATS_TEST_TMPDIR/home"
    STUB="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$HOME" "$STUB"
    cat > "$STUB/ssh" <<'STUBEOF'
#!/bin/bash
cmd="${!#}"                       # last argument, whatever options preceded it
case "$cmd" in
    *authorized_keys*)            # the install script, which this runs for real
        exec bash -c "$cmd" ;;
    "dejima-devbox-audit reach")
        echo "PASS"; exit 0 ;;
    "dejima-devbox-audit drift --state")
        echo "FILE /etc/ssh/sshd_config a1b2"; exit 0 ;;
    *)                            # dejima-guard-shell, verbatim
        echo "dejima-guard-shell: refused: $cmd" >&2; exit 64 ;;
esac
STUBEOF
    chmod +x "$STUB/ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/k" -C guard
    PUB="$BATS_TEST_TMPDIR/k.pub"
}

run_install() { PATH="$STUB:$PATH" DEJIMA_GUARD_CONF=/dev/null run "$TOOL" --pub "$PUB" me@box; }
authk() { cat "$HOME/.ssh/authorized_keys" 2>/dev/null || true; }

@test "the installed line carries the forced command" {
    # The whole reason this exists rather than ssh-copy-id.
    run_install
    [[ "$(authk)" == command=\"/usr/local/sbin/dejima-guard-shell\"* ]]
}

@test "the installed line strips everything else a key can be used for" {
    run_install
    for opt in no-port-forwarding no-agent-forwarding no-pty no-X11-forwarding; do
        [[ "$(authk)" == *"$opt"* ]] || { echo "missing $opt"; false; }
    done
}

@test "the key is never written without its restriction" {
    # One append, not copy-then-edit. There is no moment where the file holds a
    # bare key, which is what a two-step setup cannot promise.
    run_install
    [ "$(wc -l < "$HOME/.ssh/authorized_keys")" -eq 1 ]
    [[ "$(authk)" != ssh-ed25519* ]]
}

@test "running it twice does not add a second entry" {
    run_install
    run_install
    [ "$(wc -l < "$HOME/.ssh/authorized_keys")" -eq 1 ]
    [[ "$output" == *"already present"* ]]
}

@test "a key already there unrestricted is refused, not duplicated" {
    # Two entries for one key is worse than either: whichever ssh matches first
    # wins, and it will not be the one the operator expects.
    mkdir -p "$HOME/.ssh"; cat "$PUB" > "$HOME/.ssh/authorized_keys"
    run_install
    [ "$status" -ne 0 ]
    [[ "$output" == *"different options"* ]]
    [ "$(wc -l < "$HOME/.ssh/authorized_keys")" -eq 1 ]
}

@test "authorized_keys is created with a private umask" {
    run_install
    perm=$(stat -c %a "$HOME/.ssh")
    [ "$perm" = 700 ]
}

@test "a file that is not a public key is refused before anything connects" {
    echo "hello" > "$BATS_TEST_TMPDIR/bad.pub"
    PATH="$STUB:$PATH" DEJIMA_GUARD_CONF=/dev/null run "$TOOL" --pub "$BATS_TEST_TMPDIR/bad.pub" me@box
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not look like a public key"* ]]
    [ ! -e "$HOME/.ssh/authorized_keys" ]
}

@test "a devbox with the restriction in force passes all four checks" {
    # The end-to-end shape, against a stub that answers exactly as the real
    # forced command does. This failed on a correctly restricted devbox: the
    # refusal's exit 64 came back through the pipeline and outvoted grep's
    # match, so both refusals were reported as the restriction being absent.
    run_install
    [ "$status" -eq 0 ]
    [[ "$output" == *"permitted   dejima-devbox-audit reach"* ]]
    [[ "$output" == *"permitted   dejima-devbox-audit drift --state"* ]]
    [[ "$output" == *"refused     cat /etc/shadow"* ]]
    [[ "$output" == *"refused     dejima-devbox-audit drift --accept"* ]]
    [[ "$output" != *"NOT REFUSED"* ]]
}

@test "a devbox that runs what it should refuse fails the check" {
    # The direction that matters. A stub with no forced command answers
    # everything successfully, and this must not call that restricted.
    printf '#!/bin/bash\ncmd="${!#}"\ncase "$cmd" in *authorized_keys*) exec bash -c "$cmd";; esac\nexit 0\n' > "$STUB/ssh"
    chmod +x "$STUB/ssh"
    run_install
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT REFUSED"* ]]
}

@test "a check that fails shows what came back, not only its conclusion" {
    # This reported a working restriction as missing for one release, and the
    # evidence it was wrong was in output it had captured and thrown away.
    printf '#!/bin/bash\ncmd="${!#}"\ncase "$cmd" in *authorized_keys*) exec bash -c "$cmd";; esac\necho "root:x:0:0"\nexit 0\n' > "$STUB/ssh"
    chmod +x "$STUB/ssh"
    run_install
    [[ "$output" == *"root:x:0:0"* ]]
}

@test "the verification offers only the guard's key" {
    # Without IdentitiesOnly it checks whichever key ssh happens to use, which
    # on the operator's own machine is usually their own - so all four checks
    # report the restriction missing when it is fine. That is what happened the
    # first time this ran for real, and a check that is wrong in the alarming
    # direction gets ignored as fast as one wrong the other way.
    grep -q 'IdentitiesOnly=yes' "$TOOL"
}

@test "the restriction matches what the devbox project documents" {
    # Two repositories, one line. If dejima-devbox-hardener's section 7 and
    # this disagree, the key installed here is not the key that project's
    # forced command expects - and the failure is a guard that cannot collect.
    grep -q 'dejima-guard-shell' "$TOOL"
    grep -q 'no-port-forwarding,no-agent-forwarding,no-pty' "$TOOL"
}
