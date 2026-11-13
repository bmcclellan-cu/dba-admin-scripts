#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: This script will convert bytes into more readable formats. 
#          The -d option converts to KB, MB, GB, TB, PB.
#          The -i option converts to KiB, MiB, GiB, TiB, PiB.
#          Additionally, this script can convert parameters like "25.25 GB" back into bytes.
#
# Note: A byte count on its own needs -i or -d to choose the units it is converted to.
#       An argument with a unit, like "25.25 GB", is converted back into bytes, and its unit decides the base:
#       KB, MB, GB, TB and PB are powers of 1000, and KiB, MiB, GiB, TiB and PiB are powers of 1024.
#       -i and -d are refused with an argument that has a unit.
#
#####################################################################################
usage="Usage: ConvertBytes.sh -i|-d <bytes>   (-i for KiB, MiB, GiB, TiB, PiB; -d for KB, MB, GB, TB, PB)
       ConvertBytes.sh \"<number> <unit>\"   (unit: B, bytes, KB, MB, GB, TB, PB, KiB, MiB, GiB, TiB, PiB)"
example="Example 1: ConvertBytes.sh -d 120000         prints 120.00 KB
Example 2: ConvertBytes.sh \"25.25 GiB\"      prints 27111981056"
iopt=false
dopt=false

while getopts ":hid" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    i)
        iopt=true
        ;;
    d)
        dopt=true
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift $((OPTIND - 1))

# Verify input; an empty or all-whitespace argument is neither a byte count nor a number with a unit
if [ $# -ne 1 ] || [ -z "${1//[[:space:]]/}" ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

if [ $dopt == true ] && [ $iopt == true ]; then
    echo "Invalid input: -i flag and -d flag are mutually exclusive."
    echo "$usage"
    echo "$example"
    exit 1
fi

# A non-negative number such as 271, 271.00 or .5; at least one digit is required
number_regex='^([0-9]+(\.[0-9]+)?|\.[0-9]+)$'

# An argument with a unit, like ".00625 MB", "0.00625 MB" or "25.0045 GiB", is converted into bytes here.
# A number on its own, like 271 or 271.00, goes to the else block, which converts the bytes into readable units.
if ! [[ $1 =~ $number_regex ]]; then

    IFS=" " read -r number format <<< "$1"
    # Check the number and unit before the flags, so a malformed byte count given with -i or -d is reported as such
    if ! [[ $number =~ $number_regex ]]; then
        echo "Invalid input: '$1' is not a number of bytes or a number followed by a unit."
        echo "$usage"
        echo "$example"
        exit 1
    elif [ -z "$format" ]; then
        echo "Invalid input: '$1' has no unit. Give a byte count on its own with -i or -d, or a number and a unit."
        echo "$usage"
        echo "$example"
        exit 1
    fi

    # "bytes" is accepted as an alias for "B"
    if [ "$format" == "bytes" ]; then
        format="B"
    fi

    decimal=("B" "KB" "MB" "GB" "TB" "PB")
    binary=("B" "KiB" "MiB" "GiB" "TiB" "PiB")

    # The power the base is raised to, for instance 2 for MiB: number * 1024 ^ 2
    power=-1

    # Loop over the indices; the decimal and binary lists have the same length, so
    # they can be iterated through in the same loop easily.
    for unit in "${!decimal[@]}"; do
        if [ "$format" == "${decimal[$unit]}" ]; then
            base=1000
            power=$unit
            break
        elif [ "$format" == "${binary[$unit]}" ]; then
            base=1024
            power=$unit
            break
        fi
    done

    if [ "$power" -eq -1 ]; then
        echo "Error: Unknown format '$format'. Valid units: B, KB, MB, GB, TB, PB, KiB, MiB, GiB, TiB, PiB. Exiting..."
        exit 1
    fi

    if [ $dopt != false ] || [ $iopt != false ]; then
        echo "Invalid input: -i and -d are only for a number of bytes; the unit in '$1' already decides the base."
        echo "$usage"
        echo "$example"
        exit 1
    fi

    # Calculate $number * $base^$power with (...)/1 truncating digits after decimal point
    bc <<< "($number * $base^$power)/1"
else
    bytes=$1
    unit=0

    if [ "$iopt" == true ]; then
        units=("B" "KiB" "MiB" "GiB" "TiB" "PiB")
        while [ "$(echo "$bytes >= 1024" | bc)" == 1 ] && [ $unit -lt 5 ]; do
            ((unit++))
            bytes=$(echo "scale=2; $bytes / 1024" | bc)
        done
    elif [ "$dopt" == true ]; then
        units=("B" "KB" "MB" "GB" "TB" "PB")
        while [ "$(echo "$bytes >= 1000" | bc)" == 1 ] && [ $unit -lt 5 ]; do
            ((unit++))
            bytes=$(echo "scale=2; $bytes / 1000" | bc)
        done
    else
        echo "Invalid input: a number of bytes needs -i or -d to choose the units it is converted to."
        echo "$usage"
        echo "$example"
        exit 1
    fi

    bytes=$(echo "$bytes" | bc)
    echo "$bytes ${units[$unit]}"
fi
exit 0