#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: To traverse through a directory tree and list all files modified
#          before or after a single point in time, along with the date that
#          they were last modified.
#
# Arguments: The first argument is a parent directory that the search will
#            begin at. Any files in this directory or any children directories
#            will be searched. The second argument contains a date where any
#            files modified anytime after the set date will be outputted to
#            the user. This argument is optional, so any file under the
#            selected directory, regardless of its last modified date, will be
#            printed if the argument is left blank. The date input format is
#            MM/DD/YY or MM/DD/YYYY.
# 
#            Additionally the -b option can be used with a date input to list 
#            the files modified before the given date. If no date is given the
#            option will list all files modified before today's date
# 
#            The -d option can be used to output filenames only
#
################################################################################

usage="Usage: list_files.sh [-d (filenames only)] [-b (list files modified before the given date)] [directory] [last day modified, MM/DD/YY or MM/DD/YYYY (optional)] "
example="Example: list_files.sh /path/to/directory 09/01/2020"

# GNU (Linux database hosts) and BSD (macOS workstations) disagree on how dates are
# parsed and how file times are formatted, so detect once and define helpers for both.
# 'find -newermt' needs no special handling; it is supported on GNU and BSD alike.
# A successful `date -d` identifies GNU date; the else branch is BSD/macOS.
if date -d "1970-01-01" >/dev/null 2>&1; then
    # Convert a user-supplied MM/DD/YY or MM/DD/YYYY date to YYYY-MM-DD for find -newermt.
    # stderr is suppressed so an invalid date produces this script's message, not the tool's.
    to_iso_date() { date -d "$1" +%Y-%m-%d 2>/dev/null; }
    # Print a file's last-modified time as MM/DD/YY HH:MM
    file_mtime() { date -d "$(stat -c %y "$1")" '+%D %R'; }
else
    to_iso_date() { date -j -f "%m/%d/%Y" "$1" +%Y-%m-%d 2>/dev/null || date -j -f "%m/%d/%y" "$1" +%Y-%m-%d 2>/dev/null; }
    file_mtime() { stat -f '%Sm' -t '%D %R' "$1"; }
fi

# Process input options
while getopts ":hbd" option; do
    case $option in
    h)
        echo $usage
        echo $example
        exit 0
        ;;
    b) 
        before=1
        ;;
    d)
        data_only=1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Shift arguments over by the number of options entered
shift $((OPTIND-1))

# Check arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Validate the passed in date and convert it to the YYYY-MM-DD form find expects
if [ $# -eq 2 ]; then
    start_date=$(to_iso_date "$2")
    if [ $? -ne 0 ] || [ -z "$start_date" ]; then
        echo "Invalid date entered. Exiting..."
        exit 1
    fi
fi

if [ -d "$1" ]; then
    parent_dir=$1
else
    echo "Directory $1 could not be found. Exiting..."
    exit 1
fi


# Sets date to the Unix time 0 if no date is provided
# This means that all files in the directory selected
# and all sub-directories will be printed
if [ $# -eq 1 ]; then
    if [ -z $before ]; then
        start_date="1970-01-01"
    else
        start_date=$(date +"%Y-%m-%d")
    fi
fi

# Gather a sorted list of files inside the $parent_dir argument
# that were modified $days ago
if [ -z $before ]; then
    new_dirs=$(find -L "${parent_dir}" -type f -newermt "$start_date" | sort)
else
    new_dirs=$(find -L "${parent_dir}" -type f ! -newermt "$start_date" | sort)
fi

# Check if any files were found
if [ -z "${new_dirs}" ]; then
    if [ -z $before ]; then
        echo "No files modified after $start_date."
    else
        echo "No files were last modified before $start_date."
    fi
    exit 0
fi

# Iterate over directories and list files that were modified after start_date
# If data_only option given then output just the file without any date information
if [ ! -z $data_only ]; then
    for file in $new_dirs; do
        echo "$file"
    done
    exit 0
else
    for file in $new_dirs; do
        echo "$file - Last Modified $(file_mtime "$file")"
    done
fi

echo ""
if [ -z "$before" ]; then
    echo "Finished processing files inside $parent_dir that were modified since $start_date"
else
    echo "Finished processing files inside $parent_dir that were last modified before $start_date"
fi
exit 0
