#!/usr/bin/env bash
# s6-rc Service-Dependency-Uebersicht.
#   ./s6/deps.sh         -> Tabelle (Name, Typ, deps)
#   ./s6/deps.sh tree    -> ASCII-Baum (Roots oben, Kinder eingerueckt)
#   ./s6/deps.sh dot     -> Graphviz (z.B. ./s6/deps.sh dot | dot -Tpng > deps.png)
SRC="$(dirname "$0")/source"
mode="${1:-table}"

# Service-Tree liegt in oneshots/ longruns/ bundles/ — flach hierherholen.
declare -A SDIR
services=()
for kind in oneshots longruns; do
    for d in "$SRC/$kind"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        SDIR[$name]="$SRC/$kind/$name"
        services+=("$name")
    done
done

get() { tr '\n' ' ' < "${SDIR[$1]}/$2" 2>/dev/null | sed 's/ *$//'; }

case "$mode" in
table)
    printf "%-18s %-8s %s\n" NAME TYPE DEPS
    printf "%-18s %-8s %s\n" ------ ---- ----
    for s in "${services[@]}"; do
        printf "%-18s %-8s %s\n" "$s" "$(get "$s" type)" "$(get "$s" dependencies)"
    done
    ;;
tree)
    declare -A KIDS
    for s in "${services[@]}"; do
        for p in $(get "$s" dependencies); do
            KIDS[$p]="${KIDS[$p]} $s"
        done
    done
    walk() {
        local n="$1" depth="$2"
        local pad
        pad=$(printf '%*s' $((depth*4)) '')
        printf '%s%s [%s]\n' "$pad" "$n" "$(get "$n" type)"
        for k in ${KIDS[$n]}; do
            walk "$k" $((depth+1))
        done
    }
    echo "rc.init: mount /proc /sys /dev/pts /tmp + hostname"
    echo "s6-rc -u change default"
    for s in "${services[@]}"; do
        if [ -z "$(get "$s" dependencies)" ]; then
            walk "$s" 1
        fi
    done
    ;;
dot)
    echo "digraph s6 {"
    echo "  rankdir=LR; node [fontname=monospace];"
    for s in "${services[@]}"; do
        t="$(get "$s" type)"
        shape=ellipse
        [ "$t" = oneshot ] && shape=box
        echo "  \"$s\" [shape=$shape,label=\"$s\\n($t)\"];"
        for p in $(get "$s" dependencies); do
            echo "  \"$p\" -> \"$s\";"
        done
    done
    echo "}"
    ;;
*)
    echo "usage: $0 [table|tree|dot]" >&2
    exit 1
    ;;
esac
