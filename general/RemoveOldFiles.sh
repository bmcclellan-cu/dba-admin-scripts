#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose:  This deletes all files and directories matching a given pattern that are older than a given
#           number of days. A matching directory is deleted with everything in it, unless it contains
#           anything newer than file_age days (checked at any depth): then it is kept, and the files and
#           directories inside it are checked against the pattern and age instead.
#           If file_age=0 is passed to the script, no file age checks are run.
#
# Notes:    The name/pattern is matched against each file or directory name only (find -name), so it
#           cannot contain the "/" character; the script rejects such a pattern. It is matched in the
#           C locale: ? and [...] match single bytes, so a non-ASCII character counts as several.
#
#           If the given directory is a symbolic link, it is followed. Symbolic links inside it are not
#           followed and are never matched themselves (a matched directory is deleted with any links in
#           it, but not what they point to), so nothing outside the given directory is removed, as long
#           as nothing inside it is replaced by a symbolic link while the script runs.
#
#           This script avoids recursing into directories below the given directory which it does not have
#           read or execute permissions on (the given directory itself should have both: if find cannot
#           read it, the script exits 1).
#           As a result, files in those directories will not be attempted to be deleted. Those directories
#           are listed in a WARNING and do not make the script fail. A matched directory that contains one
#           is kept, since not all of its contents can be checked, and searched instead. With file_age=0
#           no check is made, so the matched directory is passed to rm -rf: that usually fails and the
#           script exits 1, though rm may still succeed if the inaccessible directory is empty (whether it
#           does depends on the rm version and the directory's permissions).
#
################################################################################
usage="Usage: RemoveOldFiles.sh [ directory ] [ name/pattern ] [ file_age ]"
example="Example: RemoveOldFiles.sh /BACKUPS/ \"ALLDATA*.gz\" 2"

exit_status=0
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check arguments
if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

dir=$1
pattern=$2
age=$3

# Check to see if the directory exists
if [ ! -d "$dir" ]; then
    echo "Error: Directory $dir does not exist. Exiting..."
    exit 1
fi

# find -name only matches a single name, so a pattern with "/" would match nothing
if [[ "$pattern" == */* ]]; then
    echo "Error: name/pattern must not contain \"/\". Exiting..."
    exit 1
fi

# Verify file_age input
if ! [[ "$age" =~ ^[0-9]+$ ]]; then
    echo "Error: file_age must be a non-negative integer"
    exit 1
fi

# Strip leading zeros, so 00 counts as 0 (without arithmetic, which could overflow on a long input)
age="${age#"${age%%[!0]*}"}"
age="${age:-0}"

if [ "$age" == "0" ]; then
    mtime=()
else
    mtime=(-mtime "+$age")
fi

# Work in the C locale, where every byte is one character. In a UTF-8 locale, bash's read and pattern
# removal can mangle file names that are not valid UTF-8, so the paths read back from find would not
# be the paths on disk. (Patterns are matched byte by byte too, which is what file names are.)
export LC_ALL=C

# Arguments for `find` to prevent it from recursing into directories it cannot access. Note that the executable permission
# for directories gates whether or not one can change directories into it or read the metadata of the files within it, so
# it must be checked as well. The pattern essentially states: If an item is a directory which is either not readable or
# executable, then prune it.
# find -exec: Execute the command specified after the flag, replacing {} with the current file/directory being
#             iterated over.
# find -o: Short circuiting logical OR. If the condition before it is not met, find will run the checks/actions following
#          the OR; if it is met, find continues to the next file/directory.
# find -prune: Remove the current directory from find's search space and do not recurse into it. Against files it is a
#              no-op.
# Note: While the -readable and -executable flags are a faster way of checking permissions, they are only available in
#       the GNU version of `find`, and as such do not work on macOS.
exclude_unreachable_dirs=(
    -type d \(
        ! -exec test -x {} \;
        -o ! -exec test -r {} \;
    \) -prune
)
objects_to_delete=()
skipped_unreachable=false

# Succeeds if $2 holds only find messages saying that an entry under the searched directory $1
# disappeared while find ran ("No such file or directory"), and at least one of them. GNU find quotes
# the path and BSD find does not; both start it with the directory as given. Any other message,
# including find failing to run a command, does not count.
only_vanished_entries() {
    local root="${1%/}"
    local message
    local seen=false
    while IFS= read -r message; do
        [ -z "$message" ] && continue
        case "$message" in
            # find failing to run the record writer is not a vanished entry, even under "/" or "/usr"
            "find: $BASH: "* | "find: '$BASH': "*) return 1 ;;
            "find: $root/"*": No such file or directory" | "find: '$root/"*": No such file or directory") seen=true ;;
            *) return 1 ;;
        esac
    done < <(printf '%s\n' "$2")
    $seen
}

# Splits the output of a find run ($1) whose records were written with $encode_records (below). Each
# record's path is decoded exactly and put in record_paths, with its tag (M, U or N) at the same index
# in record_tags. Every other line is a message from find: it is printed, and kept in find_messages.
split_find_output() {
    local line path
    record_tags=()
    record_paths=()
    find_messages=""
    while IFS= read -r line; do
        if [[ "$line" == $'\002'?" "* ]]; then
            printf -v path '%b' "${line:3}"
            record_tags+=("${line:1:1}")
            record_paths+=("$path")
        elif [ -n "$line" ]; then
            echo "$line"
            find_messages+="$line"$'\n'
        fi
    done < <(printf '%s\n' "$1")
}

# Finds the files and directories under $1 that match the pattern and age, and appends them to
# objects_to_delete. Inaccessible directories under $1 are listed in a WARNING. Called for the given
# directory, and again for each matched directory that is kept because it holds newer files or an
# inaccessible directory.
# The find command reads as such:
#   Traverse the directory, following it if it is a symlink but no symlink inside it (-H), so a
#   link cannot lead the deletion outside the directory. Record inaccessible directories and do not
#   recurse into them. Otherwise, check that the object is a file or directory whose name matches
#   the given pattern and optional mtime flag. If all checks pass, record it, and do not recurse
#   into it (-prune): deleting a matched directory deletes its contents, so they are not listed or
#   counted separately.
# find -mindepth 1: Tells find not to match the directory we pass to it. Prevents us from deleting
#                   the directory passed to the script.
# find -exec "$BASH" -c "$encode_records" M {} +: each path is written on its own line by a bash child,
#     which doubles every backslash and writes a newline as \n; the parent turns the line back into
#     the exact path with printf %b. So names with spaces, newlines, quotes, ~ or glob characters such
#     as * are read back exactly (in the C locale set above), and no eval is needed. Each record line
#     starts with a \002 byte and "M " (a match) or "U " (an inaccessible directory); find's own
#     messages cannot start with \002.
#     The list is kept in memory and read back through a pipe (not a temp file or a here-string, which
#     bash may back with a temp file), so a full disk cannot stop the cleanup.
# Return Value:
#   0: success; the matches have been added to objects_to_delete. find may have reported entries that
#      disappeared while it searched (common in busy directories such as /tmp); it still checked the rest.
#   1: find failed (its messages have been printed); nothing has been added to objects_to_delete
encode_records='for p; do p=${p//\\/\\\\}; p=${p//$'\''\n'\''/\\n}; printf "\002%s %s\n" "$0" "$p"; done'
collect_matches() {
    local find_output find_status k
    local matches=()
    local unreachable_dirs=()
    find_output=$(find -H "$1" -mindepth 1 \
        \( "${exclude_unreachable_dirs[@]}" -exec "$BASH" -c "$encode_records" U {} + \) \
        -o \( \( -type f -o -type d \) -name "$pattern" "${mtime[@]}" -prune -exec "$BASH" -c "$encode_records" M {} + \) \
        2>&1)
    find_status=$?

    # Messages from find are printed whether or not it failed
    split_find_output "$find_output"

    # Use nothing from a failed search, so no partial list is ever deleted. The one exception is find
    # reporting only entries under $1 that disappeared while it searched: it went on to search the rest.
    if [ "$find_status" -ne 0 ] && ! only_vanished_entries "$1" "$find_messages"; then
        return 1
    fi

    for k in "${!record_paths[@]}"; do
        if [ "${record_tags[k]}" == "M" ]; then
            matches+=("${record_paths[k]}")
        else
            unreachable_dirs+=("${record_paths[k]}")
        fi
    done

    if [ "${#matches[@]}" -ne 0 ]; then
        objects_to_delete+=("${matches[@]}")
    fi
    if [ "${#unreachable_dirs[@]}" -ne 0 ]; then
        skipped_unreachable=true
        echo "WARNING: these directories were skipped because they are not both readable and executable, so nothing in them was checked or deleted:"
        printf '%s\n' "${unreachable_dirs[@]}"
    fi
    return 0
}

if ! collect_matches "$dir"; then
    echo "Error occurred while finding old files/directories. Exiting..."
    exit 1
fi

# Check for errors
if [ "${#objects_to_delete[@]}" -eq 0 ]; then
    if $skipped_unreachable; then
        # Not "No files/directories of pattern": PullExternalBackups.sh prints only its own summary when
        # it sees that, which would hide the WARNING above
        echo "Nothing of pattern $pattern older than $age days found outside the skipped directories above."
    else
        echo "No files/directories of pattern $pattern older than $age days found."
    fi
    echo "No files or directories deleted. Exiting..."
    exit 0
fi

echo ""
echo "Old files and directories found:"
printf '%s\n' "${objects_to_delete[@]}"
echo ""

successful_deletions=0

# Delete any files found that match the pattern and age input. An index loop is used because a kept
# directory appends its own matches to objects_to_delete while the loop runs.
echo "Removing all specified files and directories..."
i=0
while [ "$i" -lt "${#objects_to_delete[@]}" ]; do
    object="${objects_to_delete[$i]}"
    i=$((i + 1))

    # A directory's own mtime normally changes only when its own entries change (added, removed or
    # renamed), so an old directory can still hold newer files deeper down. Keep it if it holds anything
    # newer than file_age, or a directory that is not both readable and executable (so it cannot be
    # checked), and check what is inside it instead.
    if [ -d "$object" ] && [ ! -L "$object" ] && [ "$age" != "0" ]; then
        # find -quit: stop at the first inaccessible directory or newer entry found. Inaccessible directories
        # are pruned first, so whether the directory is kept does not depend on the order find reads
        # entries in (which entry the message names can).
        # The entry found is written as a record, so it can be told apart from find's messages. It uses
        # -exec ... {} + (run before -quit exits, or find exits non-zero), so a failed write makes find
        # fail rather than the entry being silently missed and the directory deleted.
        newer_output=$(find "$object" -mindepth 1 \
            \( "${exclude_unreachable_dirs[@]}" -exec "$BASH" -c "$encode_records" N {} + -quit \) \
            -o \( ! -mtime "+$age" -exec "$BASH" -c "$encode_records" N {} + -quit \) 2>&1)
        newer_status=$?
        split_find_output "$newer_output"
        newer_entry="${record_paths[0]:-}"

        # Any message other than an entry disappearing is an error, even if find exited 0. Entries that
        # disappeared mean the directory is changing, and find may have missed a newer one, so the
        # directory is kept rather than deleted.
        if { [ "$newer_status" -ne 0 ] || [ -n "$find_messages" ]; } && ! only_vanished_entries "$object" "$find_messages"; then
            echo "An error occurred while checking directory $object for newer files. It was not removed."
            exit_status=1
            continue
        elif [ -n "$newer_entry" ] || [ -n "$find_messages" ]; then
            if [ -n "$newer_entry" ]; then
                echo "Keeping directory $object: it contains $newer_entry, which is not older than $age days or is not both readable and executable. Checking inside it instead."
            else
                echo "Keeping directory $object: entries in it disappeared while it was checked, so it is still changing. Checking inside it instead."
            fi
            if ! collect_matches "$object"; then
                echo "An error occurred while finding old files/directories inside $object."
                exit_status=1
            fi
            continue
        fi
    fi

    rm -rf "$object"
    if [ $? -ne 0 ]; then
        echo "An error occurred while removing file/directory $object."
        exit_status=1
        continue
    fi
    echo "Removed $object"

    successful_deletions=$((successful_deletions + 1))
done

# If an error occurred, alert the user and exit
if [ "$exit_status" -ne 0 ]; then
    echo "An error occurred while checking or deleting one or more files/directories. Check above output for more details."
fi

echo "$successful_deletions files/directories deleted."

exit $exit_status
