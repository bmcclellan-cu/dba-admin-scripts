
#!/bin/bash
#
# Purpose: The purpose of this script is to output a list of all TMIDs in the TelemetryItemDefinition
# table to the specified text file as comma separated values.
#
# Author: Robert Schmidt
#
# Date Created: March 27, 2025
# Last Modified: March 27, 2025
################################################################################

usage="Usage: ./PrintTMIDs.sh [filename for output]"
example="Example: ./PrintTMIDs.sh file.txt"

# Check for help flag or invalid options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done


# Check if 1 input was given.
if [ $# -ne 1 ]; then
    echo "$usage"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$($HOME/common/oracle/VerifyAllParam.sh -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

outputFile="$1"

# Check if given file already exists.
if [ -f $outputFile ]; then
    echo "Output file already exists, please enter a filename for the script to create. Exiting..."
    exit 1
fi

# Check if given file is a directory.
if [ -d $outputFile ]; then
    echo "Output file is a directory, please enter a file for the script to create! Exiting..."
    exit 1
fi

# Query the TelemetryItemDefinition table for a list of all TMIDs
TMIDs=$(
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    set pagesize 0
    SELECT UNIQUE TLMID from TelemetryItemDefinition WHERE dataType='U' OR dataType='I' OR dataType='F';
EOD
)
if [ $? -ne 0 ]; then
    echo "$TMIDs"
    echo "Error occurred when fetching TMIDs. Exiting..."
    exit 1
fi


# Replace newlines with commas and remove trailing comma
TMIDs=$(echo "$TMIDs" | tr '\n' ',' | sed 's/,$//' | tr -d '[:space:]')

echo "$TMIDs" > $outputFile

