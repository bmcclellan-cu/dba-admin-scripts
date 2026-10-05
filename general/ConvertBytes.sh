#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: This script will convert bytes into more readable formats. 
#          The -d option converts to KB, MB, GB, TB, PB,
#          but the script can convert to KiB, MiB, GiB, TiB, PiB with the -i option.
#          Additionally, this script can convert parameters like "25.25 GB" back into bytes.
#
# Note: -i or -d flag is required because the user must specify what unit they want.
#
#####################################################################################
usage="Usage: ConvertBytes.sh ([ -i for KiB, MiB, GiB, TiB, PiB ] || [ -d for KB, MB, GB, TB, PB ]) [ bytes ]"
example="Example 1: ConvertBytes.sh -d 120000
Example 2: ConvertBytes.sh -i \"25.25 GiB\""
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

# Verify input
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi
if [ $dopt == false ] && [ $iopt == false ]; then
    echo "User must specify -i flag for (B, KiB, MiB, GiB, TiB, PiB) or -d flag for (B, KB, MB, GB, TB, PB)"
    echo "$usage"
    echo "$example"
    exit 1
elif [ $dopt == true ] && [ $iopt == true ]; then
    echo "Invalid input: -i flag and -d flag are mutually exclusive."
    echo "$usage"
    echo "$example"
    exit 1
fi

# If input is positive integer in format of 27111981056.00 or 27111981056 go to 
# the else block where this quantity of bytes is transformed into human readable units.
if ! [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    IFS=" " read -r number format <<< "$1"
    if ! [[ $number =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Invalid input: input must be a number."
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

    # The number to raise the power to, for instance if the unit is KiB, then that means number * 1024 ^ 2
    power=-1
    
    # Find the index of the requested unit and the base its prefixes are powers of
    if [ "$iopt" = true ]; then
        base=1024
    else
        base=1000
    fi

    # Loop over the indices
    for unit in "${!decimal[@]}"; do
        if [ "$format" == "${decimal[$unit]}" ] || [ "$format" == "${binary[$unit]}" ]; then
            power=$unit
            break
        fi
    done

    if [ $power -eq -1 ]; then
        echo "Error: Unknown format '$format'. Valid units: B, KB, MB, GB, TB, PB, KiB, MiB, GiB, TiB, PiB. Exiting..."
        exit 1
    fi
    # Calculate $number * $base^$power with (...)/1 truncating digits after decimal point
    bc <<< "($number * $base^$power)/1"
else
    bytes=$1
    unit=0
    if [ "$iopt" = true ]; then
        units=("B" "KiB" "MiB" "GiB" "TiB" "PiB")
        while [ "$(echo "$bytes >= 1024" | bc)" == 1 ] && [ $unit -lt 5 ]; do
            ((unit++))
            bytes=$(echo "scale=2; $bytes / 1024" | bc)
        done
    else
        units=("B" "KB" "MB" "GB" "TB" "PB")
        while [ "$(echo "$bytes >= 1000" | bc)" == 1 ] && [ $unit -lt 5 ]; do
            ((unit++))
            bytes=$(echo "scale=2; $bytes / 1000" | bc)
        done
    fi

    bytes=$(echo "$bytes" | bc)
    echo "$bytes ${units[$unit]}"
fi
exit 0