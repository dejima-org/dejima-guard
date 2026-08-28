#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Every ```sh block in the documentation parses as shell.
#
# The runbooks are the product, and a command in one is not an illustration -
# it is something an operator pastes into a root shell on a hypervisor while
# following the page. A block that does not parse is a defect in the
# deliverable, exactly as a dangling link is.
#
# It exists because of a near-miss: restructuring prose around a fenced block
# turned a `\` line continuation into `\\`, which renders identically, reads
# as prose in a diff, and breaks for whoever pastes it. Nothing else here looks
# inside a fence, and nobody counts backslashes at end of line.
#
# IT PARSES AND DOES NOT EXECUTE, which is the only safe thing to do with a
# file full of `sudo iptables`. So it checks syntax, not whether a command is
# correct or does what the prose around it claims.
#
# PLACEHOLDERS ARE SUBSTITUTED FIRST. `<name>` is this repository's idiom, not
# shell, and shell reads it as redirection - so whether a block parsed would
# otherwise depend on how many angle brackets landed on a line.
# `try <forge-ip> 443` parses by accident as two redirects; `ssh <you>@<vm-ip>`
# does not, because the trailing `>` has nothing after it. The pattern requires
# a letter after the `<`, which leaves `3<>/dev/tcp/...` and `<<EOF` intact -
# both real shell, and both things a naive substitution would corrupt into a
# passing test.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "every fenced sh block parses as shell" {
    work="$BATS_TEST_TMPDIR/snippets"
    mkdir -p "$work"

    # Extracted to files rather than piped, so bash -n reports a line number
    # inside the block and the .loc file turns it back into a place in the docs.
    while IFS= read -r f; do
        safe="$(printf '%s' "$f" | tr '/.' '__')"
        awk -v dir="$work" -v pfx="$safe" -v file="$f" '
            /^```sh$/ {
                inblock = 1; n++
                out = dir "/" pfx "_" n ".sh"
                print file ":" NR > (out ".loc"); close(out ".loc")
                next
            }
            /^```$/ { if (inblock) { close(out); inblock = 0 } ; next }
            inblock { print >> out }
        ' "$REPO/$f"
    done < <(cd "$REPO" && git ls-files '*.md')

    checked=0
    fails=""
    for snippet in "$work"/*.sh; do
        [ -e "$snippet" ] || continue
        checked=$((checked + 1))
        sed -i -E 's/<[a-zA-Z][^<>]*>/PLACEHOLDER/g' "$snippet"
        if ! err="$(bash -n "$snippet" 2>&1)"; then
            fails="$fails\n  $(cat "$snippet.loc")\n$(printf '%s' "$err" | sed 's/^/      /')"
        fi
    done

    # A pass that checked nothing is the failure this suite exists to avoid, and
    # an extractor that silently stops matching is exactly how it would happen.
    [ "$checked" -gt 0 ] || { echo "no sh blocks found - the extractor is broken, not the docs" >&2; false; }

    if [ -n "$fails" ]; then
        printf 'fenced sh blocks that do not parse:%b\n' "$fails" >&2
        false
    fi
}

@test "the guard fails when a block is broken, rather than passing quietly" {
    # The same shape as links.bats's own self-check. A guard that cannot fail is
    # indistinguishable from one that always passes, and this one runs over
    # files nobody expects to break.
    printf 'x() { echo a \\\\\n  && echo b; }\n' > "$BATS_TEST_TMPDIR/broken.sh"
    run bash -n "$BATS_TEST_TMPDIR/broken.sh"
    [ "$status" -ne 0 ]
}
