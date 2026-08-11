#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script will create a linux symlink, which is like a shortcut on windows.
# 
# Arguments: symlink_name is the file/directory that points to the file/directory
# specified in target_directory.
#
# Notes: If the destination of a symlink is renamed or moved, the link breaks and must be
# changed. Also, symlinks will not react to changes made to permissions of files they 
# are pointed at.
#
################################################################################

usage="Usage: ./CreateSymLink.sh [ target_directory ] [ symlink_name ]"
example="Example: ./CreateSymLink.sh /BACKUP ./mydir/bckup"

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
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

target_directory="$1"
symlink_name="$2"

symlink_name_check=$(echo "$symlink_name" | grep '/'$)

if [ $? -eq 0 ]; then
    echo "Error: there is a '/' at the end of symlink_name: ${symlink_name_check}"
    echo "Remove the '/' before running again, exiting..."
    exit 1
fi

# Target of the linux symlink has to exist
if [ ! -e "$target_directory" ]; then
    echo "$target_directory does not exist on disk, exiting..."
    exit 1

# Shortcut must not already be a symlink
elif [ -L "$symlink_name" ]; then
    # Read what the link points to for the end user
    cur_destination=$(readlink -f "$symlink_name")
    echo "$symlink_name is already a symlink pointing to $cur_destination, exiting..."
    exit 1

# File or directory pointing to the target_directory must not exist
elif [ -e "$symlink_name" ]; then

    if [ -d "$symlink_name" ]; then 
        echo "The symlink_name: ${symlink_name} should not be a directory, exiting..."
        exit 1
    else
        echo "$symlink_name already exists on disk, exiting..."
        exit 1
    fi
fi

# Running symlink command to create a soft link (-s) and redirecting stderr to stdout
link=$(ln -s "$target_directory" "$symlink_name" 2>&1)

if [ $? -ne 0 ]; then
    if [[ "$link" = *"Permission denied"* ]]; then
        # Get current linux user
        user=$(whoami)

        echo "Current linux user $user does not have permission to create this symlink. Copy/paste the command below as an alternate user:"
        echo "${HOME}/common/general/CreateSymLink.sh ${target_directory} ${symlink_name}"
    else
        echo "Symlink creation failed. Exiting..."
    fi

    exit 1
else
    echo "Symlink creation successful from ${symlink_name} to ${target_directory}"
    exit 0
fi