#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script creates a comma-delimited list of volumes on the
#          filesystem and their directory location. The user can input any
#          specific volumes, and the script will limit the output to the name
#          and directories of just those volumes. Alternatively, if the user
#          enters the 'list' parameter, the script outputs a mapping of each
#          volume to its respective directory on 'df -h' if found.
#
################################################################################

usage="Usage: iostat_db_volumes.sh [input volume (optional, one or more)] | [list]"
example="Example: iostat_db_volumes.sh sda sdc"

# Process input options
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

# Set the field separator to newline
IFS=$'\n'

# Check arguments
# Check if user entered 'list' option
if [ "${1^^}" == "LIST" ]; then

    # Grab the output from iostat
    iostat_output=$(iostat -dxNy 1 1 | awk '{print $1}' | grep -v Linux | grep -v Device)

    # Loop through each volume
    for volume in $iostat_output; do
        # Grab the volume's directory
        dir=$(df -h | grep "$volume" | xargs | cut -d ' ' -f6)

        # Print mapping of volume to directory if grep succeeded
        if [ -n "$dir" ]; then
            echo "$volume -> $dir"
        fi
    done
    exit
fi

# Grab the output from iostat starting at the fourth line to exclude unnecessary lines
iostat_output=$(iostat -dxNy 1 1 | tail -n +4)

# No inputs: list all volumes
if [ $# -eq 0 ]; then

    for line in $iostat_output; do
        # Grab the volume name
        volume=$(echo "$line" | xargs | cut -d ' ' -f1)
        # Check to see if the volume is associated with the /dba filesystem
        dir=$(df -h | grep "$volume" | xargs | cut -d ' ' -f6)
        # Append vg- to the /dba volume so it passes the ^vg filter below
        if [ "$dir" == "/dba" ] && [[ ! "$volume" =~ ^vg ]]; then
            volume="vg-${volume}"
        # If the volume does not contain "vg" skip
        elif [[ ! "$volume" =~ "vg" ]]; then
            continue
        fi
        # Grab the decimal output of the % busy data in the last column
        busy=$(echo "$line" | awk '{print $(NF)}')
        # Convert to int
        busy=${busy%.*}

        # Append the current volume output to the result string
        if [ -z "$result" ]; then
            result="${volume}=${busy}"
        else
            result="${result},${volume}=${busy}"
        fi
    done
# User provided list of volumes to print
else

    # Loop through each volume name that was inputted
    for volume in "$@"; do

        # Check if the volume is found in iostats, continue if not
        check_volume=$(echo "$iostat_output" | grep -w "$volume")
        if [ -z "$check_volume" ]; then
            echo "Volume ${volume} not found."
            continue
        fi

        # Grab the busy percentage using the current volume name
        busy=$(echo "$iostat_output" | grep -w "${volume}" | awk '{print $(NF)}')
        # Convert to int
        busy=${busy%.*}

        # Append 'vg-' to the volume if it does not already start with 'vg'
        if [[ ! "$volume" =~ ^vg ]]; then
            volume="vg-${volume}"
        fi

        # Append the current volume output to the result string
        if [ -z "$result" ]; then
            result="${volume}=${busy}"
        else
            result="${result},${volume}=${busy}"
        fi
    done
fi

# Print the result and exit
# sed statement limits the number of extraneous chars outputted
# First sed statement eliminates everything between vg and the first -
# Second, and third sed statements eliminate unnecessary, known patterns that occur after the first hyphen and before the =
# Fourth sed statement removes -_ if it exists (potentially a holdover if -cluster or lv_ was eliminated)
# Fifth sed statement removes duplicate name of service (e.g. vg-mydb-mydb=0)
# tr, grep, tr, sed sequence eliminates anything not starting with vg
# echoing the result of the echo is necessary to end the program on a new line (since the tr '\n' ',' will end the program on a ',' otherwise)
# Output is compatible with node_exporter textfile collector format.

result=$(echo "$(echo "$result" | sed 's/vg[a-zA-Z1-9_]*-/vg-/g;s/lv_//g;s/-cluster_//g;s/-_/-/g;s/-[a-zA-Z1-9_]*-/-/g;' | tr ',' '\n' | grep '^vg' | tr '\n' ',' | sed 's/,$//g')" | awk -F'[=,]' '{for(i=1;i<=NF;i+=2){printf("node_iostat_busy{diskgroup=\"%s\"} %s\n", $i, $(i+1))}}')

echo "$result"

exit 0
