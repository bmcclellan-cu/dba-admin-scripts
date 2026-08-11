#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script will print out summary information including attributes, keys, item count, and table size. 
# 
#####################################################################################

usage="Usage: PrintDynamoDBTableSummary.sh [ table_name ]"
example="Example: PrintDynamoDBTableSummary.sh mytable"

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
shift "$((OPTIND - 1))"

# Call helper script to verify AWS credentials
VerifyAWSLoginCredentials.sh
if [ $? -ne 0 ]; then
    #Error message will be displayed by calling script.
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

table_exists=$(CheckIfDynamoDBTableExists.sh -- "$1")
if [ $? -ne 0 ]; then
    echo "An error occurred while checking if $1 exists. Exiting..."
    echo "$table_exists"
    exit 1
fi
if [ "$table_exists" != "Yes" ]; then
    echo "Table $1 does not exist. Exiting..."
    exit 1
fi
table_name=$1

table_info=$(aws dynamodb describe-table --table="$table_name" | jq -r ".Table")
if [ $? -ne 0 ]; then
    echo "An error occurred while getting information for $table_name. Exiting..."
    echo "$table_info"
    exit 1
fi

pkey=$(echo "$table_info" | jq -r ".KeySchema[] | select(.KeyType == \"HASH\") | .AttributeName")
skey=$(echo "$table_info" | jq -r ".KeySchema[] | select(.KeyType == \"RANGE\") | .AttributeName")

attributes=$(echo "$table_info" | jq -c ".AttributeDefinitions[]")

# Header incase multiple tables are being displayed
echo
echo "Summary information for $table_name:"
echo "-------------------------------------"

# Table header
echo "Attribute Info:"
printf "%30s | %16s | %11s | %10s\n" "Attribute" "Is Partition Key" "Is Sort Key" "Data Type"
n=100
for ((i=0; i<n; i++)); do
    printf "-"
done
echo
# Table content
for attribute in $attributes; do 
    attribute_name=$(echo "$attribute" | jq -r ".AttributeName")

    # Determine if attribute is a partition/sort key
    attribute_ispkey="No"
    attribute_isskey="No"
    if [ "$attribute_name" == "$pkey" ]; then
        attribute_ispkey="Yes"
    elif [ "$attribute_name" == "$skey" ]; then
        attribute_isskey="Yes"
    fi

    # Convert type into readable format
    attribute_type=$(echo "$attribute" | jq -r ".AttributeType")
    if [ "$attribute_type" == "S" ]; then
        attribute_type="String"
    elif [ "$attribute_type" == "N" ]; then
        attribute_type="Number"
    elif [ "$attribute_type" == "B" ]; then
        attribute_type="Binary"
    elif [ "$attribute_type" == "BOOL" ]; then
        attribute_type="Boolean"
    elif [ "$attribute_type" == "NULL" ]; then
        attribute_type="Null"
    elif [ "$attribute_type" == "L" ]; then
        attribute_type="List"
    elif [ "$attribute_type" == "M" ]; then
        attribute_type="Map"
    elif [ "$attribute_type" == "SS" ]; then
        attribute_type="String Set"
    elif [ "$attribute_type" == "NS" ]; then
        attribute_type="Number Set"
    elif [ "$attribute_type" == "BS" ]; then
        attribute_type="Binary Set"
    fi
    printf "%30s | %16s | %11s | %10s\n" "$attribute_name" "$attribute_ispkey" "$attribute_isskey" "$attribute_type" 
done 
echo

table_status=$(echo "$table_info" | jq -r ".TableStatus")
item_count=$(echo "$table_info" | jq -r ".ItemCount")
table_size=$(echo "$table_info" | jq -r ".TableSizeBytes") 
# Make the table size human readable
table_size=$(ConvertBytes.sh "$table_size")
if [ $? -ne 0 ]; then
    echo "An error occurred while converting table size to readable format. Exiting..."
    echo "$table_size"
    exit 1
fi

echo "Item count/size info:"
echo "WARNING: AWS only updates item count and table size every six hours so recent changes may not be reflected."
echo "Table $table_name is $table_status and contains $item_count items with a total size of $table_size"
echo