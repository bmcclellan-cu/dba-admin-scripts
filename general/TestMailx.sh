#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to test the functionality of mailx commands
#          from the current system by sending a test email to $ALL_DBA_EMAIL_LIST
#
#####################################################################################

usage="Usage: TestMailx.sh"
example="Example: TestMailx.sh"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0;;
    \?)
        echo "Error: Invalid option"
        exit 1
    esac
done

# Check arguments
if [ $# -ne 0 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

source "$HOME/.bashrc"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing $HOME/.bashrc"
    exit 1
fi

# Define test file path
TEST_FILE="/tmp/test_mailx.txt"

# Define email recipients
RECIPIENTS="${ALL_DBA_EMAIL_LIST}"

# Create test file with content
echo "This is a test email from TestMailx.sh on $HOSTNAME" > "$TEST_FILE"
echo "Timestamp: $(date)" >> "$TEST_FILE"

# Send email with mailx with subject of '$HOSTNAME TestMailx.sh Output'
if [ -n "$RECIPIENTS" ]; then
    mailx -s "$HOSTNAME TestMailx.sh Output" "$RECIPIENTS" < "$TEST_FILE"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to send email"
        exit 1
    fi
    echo "Email sent successfully to $RECIPIENTS"
else
    echo "Error: ALL_DBA_EMAIL_LIST is not set"
    exit 1
fi

rm "$TEST_FILE"
