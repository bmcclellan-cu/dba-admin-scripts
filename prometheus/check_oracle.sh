#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script attempts to connect to an Oracle instance,
#          thereby verifying that it is running and accepting connections.
#          This is done by using a fake user and observing the ORA- error 
#          generated. If it is ORA-01017, then the database is accepting connections. 
#
#####################################################################################

usage="Usage: check_oracle.sh [ ORACLE_SID (optional) ]"
example="Example 1: check_oracle.sh
Example 2: check_oracle.sh sid1"

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

# Check the user before sourcing $HOME/.bashrc, which is only oracle's .bashrc for the oracle user.
vm_user=$(whoami)
if [[ "$vm_user" != "oracle" ]]; then
    echo "Script must be run as the oracle user. Exiting..."
    exit 1
fi

source "$HOME/.bashrc"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing $HOME/.bashrc. Exiting..."
    exit 1
fi

# If no argument supplied, run against all SIDS in env
if [ $# -lt 1 ]; then
    SIDS="$SIDSLIST"
else
    SIDS="$1"
fi

# Invalid credentials are needed to generate ORA-01017, which indicates SID is open
USER="user"
PASS="password"

# set your Oracle environment here
source "$HOME/19c.env"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing $HOME/19c.env. Exiting..."
    exit 1
fi

for sid in $SIDS; do
    export ORACLE_SID=$sid

    loginchk=$("$ORACLE_HOME/bin/sqlplus" "${USER}/${PASS}" < /dev/null)

    if grep -q "ORA-01017" <<< "$loginchk" ; then
        oracle_connect_status="1"
    else
        oracle_connect_status="0"
    fi

    echo "oracle_connect_status{sid=\"$sid\"} $oracle_connect_status"

done
exit 0
