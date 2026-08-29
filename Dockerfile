# SPDX-License-Identifier: GPL-3.0-or-later
#
# The guard, for a host that runs containers rather than systemd timers.
#
# DEBIAN RATHER THAN ALPINE, and it is a correctness choice rather than habit.
# The diff that produces the change list uses --unchanged-line-format, which is
# GNU diffutils and not busybox. Alpine works with diffutils and coreutils
# added, but then the image is being patched back towards this one package at a
# time, and every tool here behaves as the devbox's does - which is the machine
# whose output this parses.
FROM debian:stable-slim

# ssh to reach the devbox, curl to alert and to send the heartbeat. Nothing
# else: this connects out twice and writes a file.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash openssh-client curl ca-certificates diffutils \
 && rm -rf /var/lib/apt/lists/*

# A uid of its own. It needs no privilege: it opens outbound connections and
# writes one directory. Running as root would be granting root to a program
# holding an SSH key to another machine, for no reason at all.
RUN useradd --system --create-home --home-dir /var/lib/dejima-guard \
            --shell /usr/sbin/nologin --uid 10001 guard

COPY bin/dejima-guard bin/dejima-guard-loop bin/dejima-guard-install-key /usr/local/bin/
RUN chmod 0755 /usr/local/bin/dejima-guard \
                /usr/local/bin/dejima-guard-loop \
                /usr/local/bin/dejima-guard-install-key

# The baseline and the report live here, and so does known_hosts. All three
# have to outlive the container: a baseline that resets on every deploy
# compares clean against everything forever, and a known_hosts that resets
# turns every first connection into a failed one.
VOLUME /var/lib/dejima-guard
ENV DEJIMA_GUARD_STATE=/var/lib/dejima-guard \
    DEJIMA_GUARD_SSH_KNOWN_HOSTS=/var/lib/dejima-guard/known_hosts \
    DEJIMA_GUARD_INTERVAL=900

USER guard
WORKDIR /var/lib/dejima-guard

# No EXPOSE, and there never should be one. What made a container acceptable
# for this is that nothing can connect to it.
ENTRYPOINT ["/usr/local/bin/dejima-guard-loop"]
