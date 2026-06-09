# Shareframe-Board interactive prompt: user@host:cwd, colored.
# Overrides Buildroot's default PS1='# ' (skeleton /etc/profile sources
# profile.d/*.sh AFTER setting it). Only meaningful for interactive shells.
case "$-" in
	*i*) ;;
	*) return 0 2>/dev/null || exit 0 ;;
esac

PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
export PS1
