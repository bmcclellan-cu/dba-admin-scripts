#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script will check if the Linux server has enough memory to host
#          a server or database. It will check if the number of megabytes
#          is available for use. If no number is given, the script will
#          simply echo the available memory on the server in megabytes.
#
################################################################################

usage="Usage: CheckServerMemory.sh [ number of megabytes (optional) ]"
example="Example: CheckServerMemory.sh 1024"

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

# Check input arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set memory if input is given
if [ $# -eq 1 ]; then
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "Memory input must be a number. Exiting..."
        exit 1
    else
        memory=$1

        if [ $? -ne 0 ]; then
            echo "Error processing input. Exiting..."
            exit 1
        fi
    fi
fi

# Get the amount of free memory in megabytes by extracting available space from free command output
# and dividing by 1024
# 'NR==2' get the second row (the Memory row)
# '{print $7/1024}' get the 7th item (available column) and divide by 1 Mb
free_mem_mb=$(printf "%.0f" "$(free | awk 'NR==2{print $7/1024}')")

if [ $? -ne 0 ]; then
    echo "Error: Failed to get free memory on server."
    exit 1
fi

# Compare the free memory with the requested memory amount
if [ -z "$memory" ]; then 
    echo "$free_mem_mb"
    exit 0
elif [ "$free_mem_mb" -ge "$memory" ]; then
    echo "Yes, there is enough free memory ($free_mem_mb megabytes available)"
    exit 0
else 
    echo "No, there is not enough free memory ($free_mem_mb megabytes available)"
    exit 0
fi
