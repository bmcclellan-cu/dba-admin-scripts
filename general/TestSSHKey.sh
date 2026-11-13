#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: Validate SSH key authentication to a specified remote host
#
##########################################################################
usage="Usage: TestSSHKey.sh [ user ] [ destination host ]"
example="Example: TestSSHKey.sh MY_USER MY_SERVER"

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

if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

user=$1
dest=$2

echo "Checking SSH key access to ${user}@${dest}..."
echo

res=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${dest}" "true" 2>&1)
status=$?

if [ $status -eq 0 ]; then
    echo "SSH access to ${user}@${dest} is successful."
    echo
elif echo "$res" | grep -q "Permission denied"; then
    echo "SSH access to ${user}@${dest} failed: Permission denied"
    echo
else
    echo "An error occurred while trying to test ssh keys for ${user}@${dest}:"
    echo "$res"
    exit 1
fi