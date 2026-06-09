# Shareframe-Board login banner: show the fastfetch-style `sysinfo` on entry.
# Only for interactive login shells on a tty (skip scp/non-interactive shells).
if case "$-" in *i*) [ -t 1 ] ;; *) false ;; esac; then
	command -v sysinfo >/dev/null 2>&1 && sysinfo
fi
