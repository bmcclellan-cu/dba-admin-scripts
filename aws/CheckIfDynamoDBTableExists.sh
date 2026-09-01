#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: Check if the DynamoDB table exists. Prints 'Yes' if the table is
#          found and 'No' if it is not.
#
#          This script can be used as a helper script, called by other
#          AWS CLI scripts.
#
#####################################################################################

usage="Usage: CheckIfDynamoDBTableExists.sh [ dynamodb table ]"
example="Example: CheckIfDynamoDBTableExists.sh my-table"

# Process -h input option.
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
shift "$((OPTIND - 1))"

# Call helper script to verify AWS credentials
VerifyAWSLoginCredentials.sh
if [ $? -ne 0 ]; then
    #Error message will be displayed by calling script.
    exit 1
fi

# Verify/set input parameters
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

dynamodb_table=$1

table_check=$(aws dynamodb describe-table --table-name="$dynamodb_table" 2>&1)
exit_code=$?

if [[ $table_check =~ "ResourceNotFoundException" ]]; then
    echo "No"
    exit 0
elif [[ $exit_code -ne 0 ]]; then
    echo "Error while trying to check if table exists. Exiting..."
    echo "$table_check"
    exit 1
else
    echo "Yes"
    exit 0
fi