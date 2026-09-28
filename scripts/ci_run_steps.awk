# Emit the shell of every GitHub Actions `run:` step, one bash script on
# stdout, for scripts/check.sh to shellcheck. A `run:` value is either a
# command on the step's own line or a block scalar whose body runs until the
# first line indented no further than the key. Each step opens with a
# marker comment so the gate can assert it found one block per `run:` key
# instead of silently linting nothing.
#
# A `${{ ... }}` placeholder is YAML substitution, not a shell parameter
# expansion, so it is replaced with GHA_EXPR before linting: shellcheck
# cannot parse the braces and would report every step that passes a matrix
# value as a syntax error.

function gha(line) {
    gsub(/\$\{\{[^}]*\}\}/, "GHA_EXPR", line)
    return line
}

FNR == 1 { inblock = 0 }

{
    line = $0
    if (line ~ /^[[:space:]]*run:[[:space:]]*[^[:space:]]/) {
        sub(/^[[:space:]]*run:[[:space:]]*/, "", line)
        gsub(/^["\047]|["\047]$/, "", line)
        print "# modelfs-ci-run-step"
        if (line ~ /^[|>][-+]?[0-9]*$/) {
            ind = match($0, /[^ ]/) - 1
            inblock = 1
        } else if (line != "") {
            print gha(line)
        }
        next
    }
    if (inblock) {
        if (line ~ /^[[:space:]]*$/) {
            print ""
            next
        }
        if (match(line, /[^ ]/) - 1 > ind) {
            print gha(substr(line, ind + 1))
            next
        }
        inblock = 0
    }
}
