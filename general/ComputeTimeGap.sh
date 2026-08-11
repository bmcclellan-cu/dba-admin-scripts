#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: Given two linux date command outputs, calculate the time difference between them, and 
#          output the difference in a human readable format: X years, X months, X days, X hours, X
#          minutes, X seconds
#
# NOTE: -x option must be used if gap between timestamps exceeds 1 month
#
#####################################################################################

usage="Usage: ComputeTimeGap.sh [ -x (optional, adds year and month values to output) ] [ timestamp 1 ] [ timestamp 2 ]"
example="Example: ComputeTimeGap.sh -x '2023-05-10 21:57:39' '2023-05-10 22:44:00'"

# Process input options
xopt=0
while getopts ":hx" option; do
    case $option in
    h)
        echo $usage
        echo $example
        exit 0
        ;;
    x)
        xopt=1
        shift 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check arguments
if [ $# -ne 2 ]; then
    echo $usage
    echo $example
    exit 1
fi

# Declare variables for timestamp inputs
timestamp1="$1"
timestamp2="$2"

# Calculate difference between two dates in seconds
s1=$(date -d "$timestamp1" "+%s")
if [ $? -ne 0 ]; then
    exit 1
fi

s2=$(date -d "$timestamp2" "+%s")
if [ $? -ne 0 ]; then
    exit 1
fi

diff=$(($s2 - $s1))
if [ $diff -lt 0 ]; then
    echo "Error: timestamp 2 must represent a time after timestamp 1"
    exit 1
fi

diff_date=$(date -d "@$diff" "+%Y %m %d %H %M %S")

# Generate and echo output
year=$(echo "$diff_date" | awk '{print $1}')
month=$(echo "$diff_date" | awk '{print $2}')
day=$(echo "$diff_date" | awk '{print $3}')
hour=$(echo "$diff_date" | awk '{print $4}')
minute=$(echo "$diff_date" | awk '{print $5}')
second=$(echo "$diff_date" | awk '{print $6}')
new_year=$((10#$year - 1970))
new_month=$((10#$month - 1))
new_day=$((10#$day - 1))

# Echo output
if [ $xopt -eq 0 ]; then
    echo "$new_day days, $hour hours, $minute minutes, $second seconds"
else
    echo "$new_year years, $new_month months, $new_day days, $hour hours, $minute minutes, $second seconds"
fi
