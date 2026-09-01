#!/bin/bash
# AvailabilityFlag: Public
#
#  Purpose: The purpose of this script is to startup a closed database in nomount mode.
#	    The user can optionally startup a specific database with a pfile by
#	    providing the database's SID, the desired pfile's absolute path, or both.
#	    If neither are provided, the script will startup the current ORACLE_SID
#	    database in nomount mode normally.
#
#####################################################################################

usage="Usage: StartupOracleNoMount.sh [ORACLE_SID (optional)] [absolute pfile path (optional)]"
example="Example: StartupOracleNoMount.sh mysid"

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

# Set variables based on user parameters
if [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
# User entered 2 parameters
elif [ $# -eq 2 ]; then
    sid=$1
    if [ -f "$2" ]; then
        pfile=$2
    else 
        echo "Pfile $2 does not exist. Exiting..."
        exit 1
    fi
# User entered 1 parameter
elif [ $# -eq 1 ]; then
    base_input=$(basename "$1")
    # User entered pfile
    if [[ "$base_input" == init*.ora ]]; then
        if [ -f "$1" ]; then
            pfile=$1
            sid=${base_input#init}
            sid=${sid%.ora}
        else 
            echo "Pfile $1 does not exist. Exiting..."
            exit 1
    fi
    # User entered ORACLE_SID
    else
        sid=$1
    fi
# User entered no parameters
else
    if [ -z "$ORACLE_SID" ]; then
        echo "ERROR: ORACLE_SID is not set."
        exit 1
    else
        sid=$ORACLE_SID
    fi
fi

# Lowercase input SID
sid=${sid,,}

# Run CheckDatabaseOpenStatus.sh to check that database is closed
db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")

# Check for Error
if [ $? -ne 0 ]; then
    echo "$db_status"
    echo "Error occurred while checking open status of sid $sid. Exiting..."
    exit 1
fi

# Check if database is closed
if [ "$db_status" != "CLOSED" ]; then
    echo "Database must be closed (is currently '$db_status'). User must shutdown database before proceeding."
    exit 1
fi

# Set ORACLE_SID from sid
export ORACLE_SID=$sid

# If user didn't enter pfile, startup in nomount normally
if [ -z "$pfile" ]; then
    #Startup database in nomount mode
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    startup nomount;
    exit;
EOD
    sqlerror=$?
# If user entered pfile, startup database on SID using given pfile
else
    #Startup database in nomount mode
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    startup nomount pfile=${pfile};
    exit;
EOD
    sqlerror=$?
fi

# Error check for query
if [ $sqlerror -ne 0 ]; then
    echo "Error occurred while starting up $sid"
    exit 1
fi

# Check if database is in nomount mode
db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")

# Error check for database status
if [ $? -ne 0 ]; then
    echo "$db_status"
    echo "Error occurred while checking open status of sid $sid. Exiting..."
    exit 1
elif [ "$db_status" == "NOMOUNT" ]; then
    echo "$sid successfully started in nomount mode."
    exit 0
else
    echo "Error occurred during $sid startup nomount, database currently in $db_status mode"
    exit 1
fi
