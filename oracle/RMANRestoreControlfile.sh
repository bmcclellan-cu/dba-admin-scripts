#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script restores a controlfile from an RMAN backup on a database in
#	   nomount mode. The user can input a number of days where the script will
#	   look at backups made in the last number of days that the user inputs. If
#	   the user doesn't provide an input, the script will default to 100 days.
#
#####################################################################################

usage="Usage: RMANRestoreControlfile.sh [number of days (optional)] [ORACLE_SID (optional)]"
example="Example: RMANRestoreControlfile.sh 20 mysid"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo $usage
        echo $example
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check user input
if [ $# -gt 2 ]; then
    echo $usage
    echo $example
    exit 1
# Expected input: [days] [SID]
elif [ $# -eq 2 ]; then
    # Check that "number of days" input is a number
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "Error. Number of days input must be an integer. Exiting..."
        exit 1
    fi

    days=$1
    export ORACLE_SID=$2
# Expected input: [days|SID]
elif [ $# -eq 1 ]; then
    # If the the input var is not a number, set it as the ORACLE_SID
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "First input is not a number, and therefore is being taken as ORACLE_SID..."
        export ORACLE_SID=$1
        days=100
    else
        days=$1
    fi
fi

# If the 'days' var is not empty, make sure it is a number between 1 and 366
if [ -n "$days" ]; then
    if [ "$days" -lt 1 ] || [ "$days" -gt 366 ]; then
        echo "Error. Days input must be a number between 1 and 366. Exiting..."
        exit 1
    fi
# If the days var is empty, use 100 days as default
else 
    days=100
fi

# Check if current database is in NOMOUNT mode using CheckDatabaseOpenStatus.sh
database_status=$($HOME/common/oracle/CheckDatabaseOpenStatus.sh $ORACLE_SID)

if [ $? -ne 0 ]; then
    echo "An error occurred while running CheckDatabaseOpenStatus.sh on database ${ORACLE_SID}. Exiting..."
    exit 1
elif [ "$database_status" != "NOMOUNT" ]; then
    echo "$ORACLE_SID database is not in nomount mode. Exiting..."
    exit 1
fi

#Restore controlfile
rman target / <<EOD
restore controlfile from autobackup maxdays $days;
exit;
EOD

if [ $? -ne 0 ]; then
    echo "RMAN controlfile restore failed ..exiting!"
    exit 1
else
    echo "RMAN controlfile restore success...continuing!"
fi
