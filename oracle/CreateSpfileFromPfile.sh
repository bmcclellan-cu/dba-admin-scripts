#!/bin/bash
# AvailabilityFlag: Public
#
#  Purpose: The purpose of this script is to create an spfile from an existing pfile
#	    given by the user as input for the script. The script creates the spfile
#	    from the pfile in a sqlplus block after checking that an spfile isn't already
#	    in use by the database. If an spfile does already exist, the script copies
#	    the existing spfile to a backup and creates a new spfile from the pfile.
#
#  NOTE: If absolute pfile path is not defined, sqlplus uses the existing pfile.
#	 The spfile is created at $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora
#
#####################################################################################

usage="Usage: CreateSpfileFromPfile.sh [absolute pfile path (optional)]"
example="Example: CreateSpfileFromPfile.sh \$ORACLE_HOME/dbs/init\$ORACLE_SID.ora"

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

if [ $# -gt 1 ]; then
    echo $usage
    echo $example
    exit 1
fi

# Check if $ORACLE_SID is set
if [ -z "$ORACLE_SID" ]; then
    echo "\$ORACLE_SID not set. Exiting..."
    exit 1
fi

# Check the current status of the database
database_status=$(source $HOME/common/oracle/CheckDatabaseOpenStatus.sh $ORACLE_SID)

if [ $? -ne 0 ]; then
    echo "Error occurred when checking the open status of the database $ORACLE_SID.  Exiting..."
    echo "$database_status"
    exit 1
fi

# Set pfile path if user provided one as input
if [ ! -z "$1" ]; then
    pfile_location="='$1'"
    directory=$(dirname "$1")
    if [ ! -d $directory ]; then
        echo "Directory $directory does not exist. Exiting..."
        exit 1
    fi
    
    if [[ "$directory" != /* ]]; then
        echo "Error. Path to datafile must be an absolute path. Exiting..."
        exit 1
    fi

    if [ $(realpath "$directory") != "$directory" ]; then
        echo "Path to parent directory using symlink. Continuing..."
    fi

    # The next two checks ensure proper file naming convention in pfile
    if [[ ! $(basename $1) =~ ^init ]]; then
        echo "Error, Pfile should start with 'init'."
        echo "$example"
        echo "Exiting..."
        exit 1
    fi

    if [[ ! "$1" =~ \.ora$ ]]; then
        echo "Error. Pfile must have a .ora extension."
        echo "$example"
        echo "Exiting..."
        exit 1
    fi

    # Check for pfile existence
    if [ ! -f "$1" ]; then 
        echo "Error.  Pfile given does not exist. Exiting..."
        exit 1
    fi

    # Check that pfile type is ASCII text
    ASCII_file=$(file "$1" | grep "ASCII text")
    if [ -z "$ASCII_file" ]; then
        echo "Error, pfile must be an ASCII text file. Exiting..."
        exit 1
    fi

    # Check that pfile follows typical 'init{$ORACLE_SID}.ora naming structure'
    if [[ ! $(basename "$1") =~ "$ORACLE_SID" ]]; then
        echo "SID $ORACLE_SID must correspond to inputted pfile $(basename "$1"). Exiting..."
        exit 1
    fi
else
    # Check that SID has a corresponding pfile
    if [ ! -f "$ORACLE_HOME/dbs/init$ORACLE_SID.ora" ]; then
        echo "SID $ORACLE_SID has no corresponding pfile. Exiting..."
        exit 1
    fi
fi

if [ "$database_status" == "CLOSED" ]; then
    # If an spfile for the database already exists, rename it with the current date appended so that a new spfile can replace it
    if [ -f "$ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora" ]; then
        curr_date=$(date +%Y-%m-%d_%H-%M-%S)
        mv "$ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora" "$ORACLE_HOME/dbs/spfile${ORACLE_SID}_${curr_date}.ora"
    fi
# If database isn't closed, check that an spfile isn't already in use
else

    # Check that spfile is not in use
    spfile_in_use=$($HOME/common/oracle/CheckIfSpfileInUse.sh)

    # Check return status of CheckIfSpfileInUse.sh
    if [ $? -ne 0 ]; then
        echo "Error occured when checking if Spfile is in use. Exiting..."
        echo "$spfile_in_use"
        exit 1
    elif [ "$spfile_in_use" != "NO" ]; then
        echo "Spfile already in use for the current database ${ORACLE_SID}. Shutdown the database and try again."
        exit 1
    fi
fi

# Create spfile from pfile using sqlplus
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
set feedback off
create spfile from pfile${pfile_location};
exit;
EOD

# Check for errors returned by sqlplus
if [ $? -ne 0 ]; then
    echo "Error encountered when attempting to create spfile"
    exit 1
else
    echo "Spfile created successfully at $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora"
    exit 0
fi
