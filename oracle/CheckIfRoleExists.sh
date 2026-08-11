#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check whether
#	   a role does or does not exist in the current database. It checks the
#	   dba_roles table for the role and returns 'Yes' if found or 'No' if not.
#
#####################################################################################

usage="Usage: CheckIfRoleExists.sh [role_name]"
example="Example: CheckIfRoleExists.sh MYAPP_TDP_ROLE"

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

# Check arguments
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# ORACLE_SID check
if [ -z "$ORACLE_SID" ]; then
    echo "Error: \$ORACLE_SID not set, must be assigned before running script. Exiting... "
    exit 1
fi

# Verify single ORACLE_SID
sid_check=$($HOME/common/oracle/VerifyAllParam.sh -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Set user input to uppercase
role=${1^^}

# SYSDBA role is not found in the dba_roles table but is a valid role
if [ "$role" == "SYSDBA" ]; then
    echo "Yes"
    exit 0
fi

# Store the schema in $role_check if found in dba_roles
role_check=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1
    SELECT role FROM dba_roles WHERE role = '$role';
EOD
)

# Check if schema was found
if [ -z "$role_check" ]; then
    echo "No"
    exit 0
else
    echo "Yes"
    exit 0
fi
