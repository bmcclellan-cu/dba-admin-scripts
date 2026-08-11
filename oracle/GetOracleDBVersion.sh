#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script will attempt to determine what version of oracle a database is running,
#           as well as the ORACLE_HOME directory where the binaries are running from.
#
#####################################################################################
usage="Usage: GetOracleDBVersion.sh [ \$ORACLE_SID ]"
example="Example: GetOracleDBVersion.sh mydbprod"

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
    echo " "
    exit 1
fi

export ORACLE_SID=${1,,}

# Get the PID for the Oracle PMON process
pmon_pid=$(pgrep -f "ora_pmon_${ORACLE_SID}$")
exit_status=$?
if [ -z "$pmon_pid" ]; then
    echo "ERROR: Database $ORACLE_SID does not appear to be running, no pmon process active. Exiting..."
    exit 1
elif [ $exit_status -ne 0 ]; then
    echo "$pmon_pid"
    echo "An error occurred while getting pmon PID for database $ORACLE_SID. Exiting..."
    exit 1
fi

# Get the environment of the PMON process and extract ORACLE_HOME from it.
# Note: /proc/<PID>/environ is a null-delimited array of the environment variables of the process when
#       it was started, and bash string variables are unable to store nulls, so we must substitute them
#       out for newlines.
pmon_environ=$(tr '\0' '\n' < "/proc/$pmon_pid/environ")
if [ $? -ne 0 ]; then
    echo "$pmon_environ"
    echo "An error occurred while reading environment variables of the pmon process for database $ORACLE_SID. Exiting..."
    exit 1
fi

ORACLE_HOME=$(echo "$pmon_environ" | grep "^ORACLE_HOME=" | cut -d= -f2)
if [ -z "$ORACLE_HOME" ]; then
    echo "ERROR: No ORACLE_HOME found in environment of pmon process of $ORACLE_SID. Unable to determine ORACLE_HOME. Exiting..."
    exit 1
fi

echo "Successfully determined ORACLE_HOME for database $ORACLE_SID:"
echo "ORACLE_HOME=$ORACLE_HOME"

oracle_version=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    set heading off

    SELECT banner_full FROM v\$version;
EOD
)
if [ $? -ne 0 ]; then
    echo "$oracle_version"
    echo "An error occurred while querying for Oracle Database version. Exiting..."
    exit 1
fi

# Trim excess whitespace.
oracle_version=$(echo "$oracle_version" | xargs)

echo
echo "Oracle Version:"
echo "$oracle_version"

exit 0