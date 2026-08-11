#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script will convert bytes into more readable formats. 
#          By default the script converts to KB, MB, GB, TB, PB,
#          but can convert to KiB, MiB, GiB, TiB, PiB with the -i option
#
#####################################################################################
usage="Usage: ConvertBytes.sh [ -i for KiB, MiB, GiB, TiB, PiB ] [ bytes ]"
example="Example: ConvertBytes.sh 120000"

iopt=false
while getopts ":hi" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    i)
        iopt=true
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
    echo "Usage: $usage"
    echo "Example: $example"
    exit 1
fi
# Verify input is a positive integer
if ! [[ $1 =~ ^[0-9]+$ ]]; then
    echo "Error: Input must be a positive integer. Exiting..."
    exit 1
fi

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
exit 0