#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script prints every helper script that a given script calls,
#           then everything those helpers call, recursively. Use it before
#           changing a script's AvailabilityFlag to Public: a Public script
#           that calls a Private or unflagged helper is broken for anyone
#           outside LASP, because the private helper never reaches the public repo.
#
# Notes:    Two calling conventions are detected on non-comment lines:
#               <any_prefix>/common/<dir>/<Script>.sh   (or .py)
#               <Script>.sh                      resolved via PATH, as the
#                                                aws/ scripts are written
#           Only command positions count for the second form. Quoted strings
#           are stripped first, so a script named inside an echo message or a
#           usage line is not mistaken for a dependency.
#
#           A PATH-resolved name is mapped back to a repo path by preferring
#           the caller's own directory. 
#           A basename living in several directories is reported as AMBIGUOUS:<path>,<path> if several have it and none are the caller's.
#
#           A helper invoked through a variable path will still not be
#           detected. Spot-check anything before you flag it as public.
#
#           Note: this script will not catch the dependencies of run_oracle_prometheus.sh because of its unique way of calling scripts.
#
###########################################################################

usage="Usage: PrintScriptDependencies.sh [ -f (optional, flat alphabetized list) ] [ -a (optional, show AvailabilityFlag) ] [ -r <ref> (optional, git ref to read from) ] [script]"
example="Example 1: PrintScriptDependencies.sh oracle/26aiUpgrade/PatchDB19c.sh
Example 2: PrintScriptDependencies.sh -f -a oracle/OracleWeeklyRestore.sh
Example 3: PrintScriptDependencies.sh -a -r origin/main general/ConvertBytes.sh"

flat_opt=0
avail_opt=0
git_ref=""

while getopts ":hfar:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    f)
        flat_opt=1
        ;;
    a)
        avail_opt=1
        ;;
    :)
        echo "ERROR: Option -$OPTARG requires an argument."
        exit 1
        ;;
    r)
        git_ref="$OPTARG"
        if [[ "$git_ref" == *.sh ]] || [[ "$git_ref" == *.py ]]; then
            echo "ERROR: No git reference specified."
            echo "$usage"
            exit 1
        fi
        ;;
    \?)
        echo "ERROR: Invalid option"
        echo "$usage"
        exit 1
        ;;
    esac
done
shift "$((OPTIND - 1))"

target="$1"
if [ -z "$target" ]; then
    echo "ERROR: No script specified."
    echo "$usage"
    exit 1
fi

# Get the root of the repo
repo_root=$(git rev-parse --show-toplevel)
if [ "$?" -ne 0 ]; then
    echo "$repo_root"
    echo "ERROR: Not inside a git repository. Run this script from within the repo."
    exit 1
fi
# Show the path from the repo root
# Ex: cd /Users/lasp-dba-admin/oracle
# Result: oracle/
rel_dir=$(git rev-parse --show-prefix)
if [ "$?" -ne 0 ]; then
    echo "$rel_dir"
    echo "ERROR: Not inside a git repository. Run this script from within the repo."
    exit 1
fi
# Remove a leading ./
# From the repo root, where is the target script
cd_target="$rel_dir${target#./}"

if [ -f "$target" ]; then
    # Get the absolute path by cd'ing into the file's directory, using pwd to expand it, then adding the file name back on
    # -P resolves symlinks so the path matches the repo root git reports, and any .. in the argument is flattened out
    target=$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")
fi

# Remove the $repo_root so the path is repo-relative
target="${target#"$repo_root"/}"
# Remove a leading ./
target="${target#./}"

# cd into the repo root
cd "$repo_root" || exit 1

work_dir=$(mktemp -d)
if [ -z "$work_dir" ] || [ ! -d "$work_dir" ]; then
    echo "ERROR: Could not create temp directory."
    exit 1
fi
trap 'rm -rf "$work_dir"' EXIT

# read_file <path> - emit a file's contents from the working tree, or from a
# git ref when -r was supplied. Reading from a ref lets you inspect main
# without switching branches.
read_file() {
    if [ -n "$git_ref" ]; then
        # Print the file's contents as they were at the given git ref
        git show "$git_ref:$1"
        if [ $? -ne 0 ]; then
            echo "ERROR: git ref command failed with $git_ref"
            return 1
        fi
    else
        cat "$1"
        if [ $? -ne 0 ]; then
            echo "ERROR: cat command failed with file $1"
            return 1
        fi
    fi
}

if [ -n "$git_ref" ]; then
    # List every file tracked at the given git ref into the all_files file
    git ls-tree -r --name-only "$git_ref" > "$work_dir/all_files"
    if [ "$?" -ne 0 ]; then
        echo "ERROR: '$git_ref' is not a valid git ref."
        exit 1
    fi
else
    git ls-files > "$work_dir/all_files"
    if [ "$?" -ne 0 ]; then
        echo "ERROR: Not inside a git repository. Run this script from within the repo."
        exit 1
    fi
fi
# If $work_dir/all_files file does not exist or does not have a size greater than 0, exit
if [ ! -s "$work_dir/all_files" ]; then
    echo "ERROR: Could not list repository files."
    exit 1
fi

# Just the scripts used to map a PATH-resolved bare name back to a repo path.
grep -E '\.(sh|py)$' "$work_dir/all_files" > "$work_dir/all_scripts"

# Validate the target against all_files rather than the filesystem. With -r the
# file may legitimately be absent from the working tree while existing in the
# ref, and a typo would otherwise report "0 dependencies" and exit 0 -
# indistinguishable from a genuinely self-contained script.
#
# An untracked file that exists on disk is still analysed: the common case is
# checking a script you are about to add, before committing it.
# Running grep with -q (suppresses stdout)
if grep -qxF "$cd_target" "$work_dir/all_files"; then
    target="$cd_target"
elif ! grep -qxF "$target" "$work_dir/all_files"; then
    if [ -n "$git_ref" ]; then
        echo "ERROR: $target is not tracked in $git_ref"
        exit 1
    fi

    # Neither option exists under the repo root
    if [ ! -f "$repo_root/$cd_target" ] && [ ! -f "$repo_root/$target" ]; then
        echo "ERROR: $target not found under $repo_root"
        exit 1
    fi

    echo "NOTE: $target is not tracked by git yet. Analyzing the file on disk."
    echo ""
fi


# get_availability <path> - the AvailabilityFlag value, or "unflagged".
# Reads only the header; the flag is a declaration, not body text.
# Echoes the flag value in lower case, or unflagged when no header line matches
get_availability() {
    local value
    # The awk statement takes the first 15 lines of the parameter script, and finds any line with '# AvailabilityFlag', '-- AvailabilityFlag', or other space permutations and converts the availability to lower case
    value=$(read_file "$1")

    if [ $? -ne 0 ]; then
        echo "$value" >> "$work_dir"/error
        echo "ERROR: read_file function failed when called in get_availability." >> "$work_dir"/error
        return 1
    fi

    value=$(echo "$value" | awk 'NR<=15 && sub(/^[[:space:]]*(#|--)?[[:space:]]*AvailabilityFlag:[[:space:]]*/,"") {print tolower($1); exit}')

    if [ -z "$value" ]; then
        echo "unflagged"
    else
        echo "$value"
    fi
}

# For every line of the script being read:
#   - Skip comment lines, and skip the inside of quoted strings, including
#     ones that run across several lines
#   - Split what is left on command separators so each fragment starts where
#     a command would start
#   - Strip variable assignments
#   - Print the first token if it ends in .sh or .py and has no slash in it,
#     since path-style calls are caught by the /common/ grep instead
# Quote the EOF so the shell leaves $0, $(, and the backtick alone
IFS= read -r -d '' bare_name_awk << 'EOF'
{
    line = $0

    if (line ~ /^[[:space:]]*#/) { next }

    # Continuation lines of a multi-line string are text, not code.
    if (in_string) {
        idx = index(line, "\"")
        if (idx == 0) { next }
        line = substr(line, idx + 1)
        in_string = 0
    }

    if (in_quote) {
        idx = index(line, "'")
        if (idx == 0) { next }
        line = substr(line, idx + 1)
        in_quote = 0
    }

    # Remove balanced quoted literals.
    while (match(line, /"[^"]*"/)) {
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
    }
    # Remove single quotes
    while (match(line, /'[^']*'/)) {
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
    }

    sub(/[[:space:]]*#.*$/, "", line)

    # A leftover quote opens a string that runs past the end of this line.
    if (match(line, /"/)) {
        line = substr(line, 1, RSTART - 1)
        in_string = 1
    }
    if (match(line, /'/)) {
        line = substr(line, 1, RSTART - 1)
        in_quote = 1
    }

    # Split on command separators so each fragment starts at a command position.
    gsub(/\$\(|`|\|\||&&|[|;&{}()]/, "\n", line)

    n = split(line, fragments, "\n")
    for (i = 1; i <= n; i++) {
        fragment = fragments[i]
        sub(/^[[:space:]]+/, "", fragment)

        # Strip keywords, interpreters, and inline VAR= assignments so that
        # "if nohup python3 foo.py" -> foo.py.
        while (match(fragment, /^(if|elif|while|until|then|else|do|!|nohup|time|exec|command|sudo|eval|source|\.|python|python3|perl|bash|sh|ksh)[[:space:]]+/) || \
               match(fragment, /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/)) {
            fragment = substr(fragment, RLENGTH + 1)
            sub(/^[[:space:]]+/, "", fragment)
        }

        # A redirect target is a file, not a command.
        if (fragment ~ /^[<>]/) { continue }

        if (match(fragment, /^[A-Za-z0-9_.-]+\.(sh|py)([[:space:]]|$)/)) {
            token = substr(fragment, RSTART, RLENGTH)
            sub(/[[:space:]]+$/, "", token)
            print token
        }
    }
}
EOF
# resolve_bare_name <basename> <caller path> - map a PATH-resolved invocation
# back to a repo path, reading the list of every script in the repo.
# Pick a PATH-resolved invocation in this order:
#   - A file with that name in the caller's own directory
#   - The only file with that name anywhere in the repo
#   - Nothing at all, if no file has that name
#   - AMBIGUOUS:<path>,<path> if several have it and none are the caller's
resolve_bare_name() {
    awk -v name="$1" -v caller="$2" '
    BEGIN {
        caller_dir = caller
        # Dirname of the caller, "." when it has no directory part
        # /\/[^\/]*$/ -> match a slash, and then any run of non-slash characters to the end of the string
        if (caller_dir ~ /\//) { sub(/\/[^\/]*$/, "", caller_dir) } else { caller_dir = "." }
    }
    {
        base = $0
        sub(/^.*\//, "", base)
        if (base != name) { next }

        path_dir = $0
        if (path_dir ~ /\//) { sub(/\/[^\/]*$/, "", path_dir) } else { path_dir = "." }
        if (path_dir == caller_dir) { same_dir = $0 }

        count = count + 1
        found[count] = $0
    }
    END {
        if (same_dir != "") { print same_dir; exit }
        if (count == 1) { print found[1]; exit }
        if (count == 0) { exit }

        joined = found[1]
        for (i = 2; i <= count; i++) { joined = joined "," found[i] }
        print "AMBIGUOUS:" joined
    }' "$work_dir/all_scripts"
}

# get_direct_dependencies <path> - repo-relative paths this script invokes
# Returns 1 on failure so that walk() can abort the whole traversal.
get_direct_dependencies() {
    local file="$1"
    local name
    local contents
    contents=$(read_file "$file");

    if [ $? -ne 0 ]; then
        echo "$contents"  >> "$work_dir"/error
        echo "ERROR: Failed to read $file in get_direct_dependencies"  >> "$work_dir"/error
        return 1
    fi
    {
        # <any_prefix>/common/<dir>/<name>.sh or .py
        # cat the file (or git show with -r flag) into the grep and sed statements
        # The first grep excludes comments
        # The second and third grep excludes examples and usage strings like in TestScriptAsCrontab script
        # The fourth grep only finds substrings that end in .sh or .py
        # The sed then deletes everything before and including the /common/
        echo "$contents"  \
            | grep -vE '^[[:space:]]*#' \
            | grep -vEi '.*"Example.*' \
            | grep -vEi '.*"Usage:.*' \
            | grep -oE "[^[:space:]\"']*/common/[a-z]+/[A-Za-z0-9_]+\.(sh|py)" \
            | sed 's|.*/common/||'

        

        # Bare names resolved through PATH.
        while read -r name; do
            if [ -z "$name" ]; then
                continue
            fi
            resolve_bare_name "$name" "$file"
        done <<< "$(echo "$contents" | awk "$bare_name_awk")"
    } | sort -u
}

# walk <path> <depth> - print the dependency tree depth-first.
# This is a recursive function.
# Every file visited that is neither AMBIGUOUS nor NOT IN REPO is recorded in seen_all so the flat list and the totals
# can be produced without walking twice.
walk() {
    local current="$1"
    local depth="$2"
    local indent=""
    local i=0
    local direct_deps
    local dependency

    # indent output for readability
    while [ "$i" -lt "$depth" ]; do
        indent="$indent    "
        i=$((i + 1))
    done

    local label="$current"
    if [ "$avail_opt" -eq 1 ]; then
        label="$current  [$(get_availability "$current")]"
    fi

    # A file already expanded elsewhere in the tree is shown but not expanded
    # again. This also stops cycles from recursing forever.
    # Running grep with -q (suppresses stdout)
    # -x Select only those matches that exactly match the whole line.
    # -F treat the pattern as a literal string
    if grep -qxF "$current" "$work_dir/seen_all"; then
        echo "${indent}${label} (see above)"
        return 0
    fi
    # Append current to the seen_all record
    echo "$current" >> "$work_dir/seen_all"
    echo "${indent}${label}"

    direct_deps=$(get_direct_dependencies "$current")
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to get get_direct_dependencies of $current"  >> "$work_dir"/error
        return 1
    fi

    while read -r dependency; do
        if [ -z "$dependency" ]; then
            continue
        fi
        if [ "$dependency" = "$current" ]; then
            continue
        fi

        # A bare name that could be any of several files displayed for the user if (-f is not used)
        if [ "${dependency#AMBIGUOUS:}" != "$dependency" ]; then
            echo "${indent}    ${dependency#AMBIGUOUS:}  [AMBIGUOUS - PATH-resolved]"
            echo "$dependency" >> "$work_dir/ambiguous"
            continue
        fi
        # If the dependency script is not in all_files, then mark it as missing
        # Running grep with -q (suppresses stdout)
        if ! grep -qxF "$dependency" "$work_dir/all_files"; then
            echo "${indent}    $dependency  [NOT IN REPO]"
            echo "$dependency" >> "$work_dir/missing"
            continue
        fi

        walk "$dependency" "$((depth + 1))"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to walk $dependency at depth: $((depth + 1))"  >> "$work_dir"/error
            return 1
        fi

    done <<< "$direct_deps"
}
# Create empty files that will be used to track dependencies
: > "$work_dir/seen_all"
: > "$work_dir/ambiguous"
: > "$work_dir/missing"
: > "$work_dir/error"

walk "$target" 0 > "$work_dir/tree"
if [ $? -ne 0 ]; then
    cat "$work_dir/error"
    echo "Failed to walk $target. Exiting..."
    exit 1
fi


if [ "$flat_opt" -eq 1 ]; then
    # Flat mode: alphabetized unique list, excluding the script itself.
    # -x Select only those matches that exactly match the whole line.
    # -F treat the pattern as a literal string
    # -v exclude lines that have the $target pattern
    # only add unique and sorted entries into $work_dir/flat
    grep -vxF "$target" "$work_dir/seen_all" | sort -u > "$work_dir/flat"

    while read -r dependency; do
        if [ -z "$dependency" ]; then
            continue
        fi
        if [ "$avail_opt" -eq 1 ]; then
            # Left-align the flag in an 11-wide column so the paths line up.
            printf '%-11s %s\n' "$(get_availability "$dependency")" "$dependency"
        else
            echo "$dependency"
        fi
    done < "$work_dir/flat"
else
    cat "$work_dir/tree"
fi

# Count the number of occurrences that do not match the $target
total=$(grep -cvxF "$target" "$work_dir/seen_all")
echo ""
echo "$total dependency/dependencies found."

# When the flags were requested, say plainly how many block script publication
if [ "$avail_opt" -eq 1 ]; then
    not_public=0
    while read -r dependency; do
        if [ -z "$dependency" ] || [ "$dependency" = "$target" ]; then
            continue
        fi
        if [ "$(get_availability "$dependency")" != "public" ]; then
            not_public=$((not_public + 1))
        fi
    done < "$work_dir/seen_all"

    echo "$not_public of them are not Public."
fi

# A missing name could point at either a Public or a Private file, so it
# must not be included in the counts above.
sort -u "$work_dir/ambiguous" > "$work_dir/ambiguous_uniq"
# Count non-empty lines ('.' matches any character).
ambiguous_count=$(grep -c . "$work_dir/ambiguous_uniq")
if [ "${ambiguous_count:-0}" -gt 0 ]; then
    echo "WARNING: $ambiguous_count PATH-resolved name(s) matched more than one file and are not included in the counts above. Resolve them by hand before flagging anything Public."
    sort -u "$work_dir/ambiguous" | sed 's/^/       /'
fi

# A missing name could point at either a Public or a Private file, so it
# must not be included in the counts above.
sort -u "$work_dir/missing" > "$work_dir/missing_uniq"
# Count non-empty lines ('.' matches any character).
missing_count=$(grep -c . "$work_dir/missing_uniq")
if [ "${missing_count:-0}" -gt 0 ]; then
    echo "WARNING: $missing_count dependency/dependencies were not found in the repo and are not included in the counts above. Resolve them by hand before flagging anything Public."
    sort -u "$work_dir/missing" | sed 's/^/     /'
fi

exit 0