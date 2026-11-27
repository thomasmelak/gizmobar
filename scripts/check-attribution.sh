#!/usr/bin/env bash
# Fails when commits or a PR description carry assistant attribution:
# co-author or session trailers, an assistant author/committer, or a
# "generated with" footer. Used by CI and by the commit-msg hook.
#
#   scripts/check-attribution.sh commits <base>..<head>
#   scripts/check-attribution.sh message <file>
#   PR_BODY="..." scripts/check-attribution.sh body
set -euo pipefail

# Patterns are bracketed so this file doesn't trip its own check.
TRAILERS='^(co-authored-by|cl[a]ude-session|generated-by):'
AUTHOR='cl[a]ude|anthr[o]pic'
BODY='cl[a]ude|anthr[o]pic|generated (with|by) \[?[a-z ]*code'

fail=0
check_text() { # name, text, pattern
    local hits
    hits=$(printf '%s\n' "$2" | grep -inE "$3" || true)
    if [ -n "$hits" ]; then
        echo "::error::$1 has attribution that isn't allowed:"
        printf '%s\n' "$hits" | sed 's/^/    /'
        fail=1
    fi
}

case "${1:-}" in
commits)
    range=${2:?usage: check-attribution.sh commits <base>..<head>}
    for sha in $(git rev-list "$range"); do
        short=$(git rev-parse --short "$sha")
        check_text "commit $short author" "$(git log -1 --format='%an <%ae>%n%cn <%ce>' "$sha")" "$AUTHOR"
        check_text "commit $short message" "$(git log -1 --format='%B' "$sha")" "$TRAILERS|generated (with|by) \\[?[a-z ]*code"
    done
    ;;
message)
    check_text "commit message" "$(grep -v '^#' "${2:?message file}")" "$TRAILERS|generated (with|by) \\[?[a-z ]*code"
    check_text "commit author" "$(git var GIT_AUTHOR_IDENT)" "$AUTHOR"
    ;;
body)
    check_text "PR description" "${PR_BODY:-}" "$BODY"
    ;;
*)
    echo "usage: check-attribution.sh commits <range> | message <file> | body" >&2
    exit 2
    ;;
esac

exit $fail
