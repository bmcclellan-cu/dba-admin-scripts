#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script creates a new temp tablespace for the active database.
#
#	   NOTE: A reboot is required to assign the new tablespace as the active
#		 default temp tablespace. Processes use the default temp space
#		 frequently, and it's impossible to drop it when it's being used,
#		 so rebooting the db will allow those processes to exit, and allow
#		 the original temp tablespace to be dropped.
#
#		 To see the processes currently using the temp tablespace, enter the following query:
#
#		 select * from v$tempseg_usage tu, v$session s where tu.session_addr=s.saddr;
#
#	   The temp_tablespace and local_temp_tablespace for XS$NULL cannot be modified (Doc ID 1325766.1),
#	   so the user is ignored.
#
usage="Usage: CreateTempTablespace.sh [ [ -d (optional, drop current tablespace) ][absolute path to datafile] [tablespace name (optional)]] | [list]"
example="Example: CreateTempTablespace.sh /path/to/data/temp01.dbf TEMP"
#####################################################################################

# Process input options
dopt=0
while getopts ":hd" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    d)
        dopt=1
        shift 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Check arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
# Check if user entered list parameter, wait until lists are printed to exit
elif [ "${1^^}" == "LIST" ]; then
    is_list=1
# Check if file already exists so that SQL doesn't produce 'file already exists' error
elif [ -f "$1" ]; then
    echo "File \"$1\" already exists."
    exit 1
fi

datafile=$1
directory=$(dirname "$datafile")
new_tablespace=$2
if [[ $is_list -ne 1 ]]; then
    if [ ! -d "$directory" ]; then
        echo "Directory $directory does not exist. Exiting..."
        exit 1
    fi
    
    if [[ "$directory" != /* ]]; then
        echo "Error. Path to datafile must be an absolute path. Exiting..."
        exit 1
    fi

    if [ "$(realpath "$directory")" != "$directory" ]; then
        echo "Path to parent directory using symlink. Continuing..."
    fi

    if [ "$directory" == "/" ]; then  
        echo "Error. Cannot modify root directory. Exiting..."
        exit 1
    fi

    if [[ ! $datafile =~ \.dbf$ ]]; then
        echo "Error. Datafile must have a .dbf extension. Exiting..."
        exit 1
    fi

    if [[ ! $(basename "$datafile") =~ ^[a-zA-Z0-9] ]]; then
        echo "File cannot start with a special character. Exiting..."
        exit 1
    fi

    # Create datafile directory if it doesn't exist
    if [ ! -d "$directory" ]; then
        mkdir -p "$directory"
        if [ $? -ne 0 ]; then
            echo "Failed to make new directory $directory. Exiting..."
            exit 1
        else
            echo ""
            echo "Created new directory $directory."
            echo ""
        fi
    fi
fi

echo "Current temp space datafiles:"
# List current temp data files to user
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    column FILE_NAME format a62
    column TABLESPACE_NAME format a15
    set pagesize 20000;
    select df.name as file_name ,ts.name as tablespace_name
    from v\$tablespace ts inner join v\$tempfile df on (ts.ts# = df.ts#)
    order by ts.name;
    exit;
EOD

if [ $? -ne 0 ]; then
    echo "Error occurred when querying the database for tablespace and temp file name. Exiting..."
    exit 1
fi

if [ $dopt -eq 1 ]; then 
    echo ""
    echo "NOTE: If there are multiple temp spaces, the script will drop them after creating a new default temp space."
    echo ""
fi

# List current default temp table space
default_space=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1
    SELECT PROPERTY_VALUE FROM DATABASE_PROPERTIES WHERE PROPERTY_NAME = 'DEFAULT_TEMP_TABLESPACE';
    exit;
EOD
)

if [ $? -ne 0 ]; then
    echo "Error occurred when attempting to print out default temp tablespace. Exiting..."
    exit 1
fi

# Exit if list parameter was given
if [[ $is_list -eq 1 ]]; then
    exit 0
fi

# Removes the newline character at the beginning of $default_space that the sqlplus block adds
default_space=${default_space:1}

# Check if user entered a tablespace name
if [ -z "$new_tablespace" ]; then

    # Check if TEMP tablespace exists, if not use it instead of incremented tbsp name
    new_space_exists=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "TEMP")

    if [ $? -ne 0 ]; then
        echo "Error occurred when running CheckIfTablespaceExists.sh.  Exiting"
        exit 1
    elif [ "$new_space_exists" == "No" ]; then
        new_space="TEMP"
    else
        # Create tablespace name from default space
        last_2_chars=${default_space: -2:2}

        # Check if last 2 characters of default_space are numbers
        # RegEx pattern matching from jimmij, FaSean Lin: https://unix.stackexchange.com/questions/151654/checking-if-an-input-number-is-an-integer
        if [[ ${last_2_chars:1} =~ ^[0-9]+$ ]]; then
            # Get the sum of last_2_chars and 1
            new_file_num=$((10#$last_2_chars + 1))

            # Check if we need to prepend a 0
            if [ $new_file_num -le 9 ]; then
                new_file_num="0${new_file_num}"
            fi

            # Strip the trailing two-digit number off the tablespace name
            without_suffix=${default_space::-2}
            # Reattach it, incremented and zero-padded
            new_space="${without_suffix}${new_file_num}"
        else
            # No numbers, append a number starting at 01
            new_space="${default_space}_01"
        fi
    fi
# Tablespace name set to user input
else
    new_space=${2^^}
fi

# Try to find new_space in the current temp tablespaces
new_space_exists=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$new_space")
if [ $? -ne 0 ]; then
    echo "Error occurred when running CheckIfTablespaceExists.sh.  Exiting"
    exit 1
fi
new_space_exists=$(echo "$new_space_exists" | grep "Yes")

# If new_space already exists, keep adding 1 to the end of the name and check again if it exists
while [ -n "$new_space_exists" ]; do
    last_2_chars=${new_space: -2:2}
    if [[ "$last_2_chars" =~ ^[0-9]+$ ]]; then
        new_file_num=$((10#$last_2_chars + 1))
        # Strip the trailing two-digit number off the tablespace name
        new_space=${new_space::-2}
    else
        new_file_num=1
        new_space="${new_space}_"
    fi

    # Check if we need to prepend a 0
    if [ $new_file_num -le 9 ]; then
        new_file_num="0${new_file_num}"
    fi

    # Reattach the number, incremented and zero-padded
    new_space="${new_space}${new_file_num}"

    new_space_exists=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$new_space")
    if [ $? -ne 0 ]; then
        echo "Error occurred when running CheckIfTablespaceExists.sh.  Exiting"
        exit 1
    fi 
    new_space_exists=$(echo "$new_space_exists" | grep "Yes")
done

# Create the new temp table space
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    CREATE TEMPORARY TABLESPACE ${new_space}
    TEMPFILE '${datafile}' SIZE 256M
    AUTOEXTEND ON;
    exit;
EOD

if [ $? -ne 0 ]; then
    echo "Error encountered when creating new temp space ${new_space}"
    exit 1
fi

# Tell database to use new tablespace as default temp
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    ALTER DATABASE DEFAULT TEMPORARY TABLESPACE ${new_space};
    BEGIN
        FOR user IN
        (SELECT username FROM dba_users WHERE temporary_tablespace NOT IN '${new_space}'
        and username != 'XS\$NULL')
        LOOP
            EXECUTE IMMEDIATE 'ALTER USER '|| user.username ||' TEMPORARY TABLESPACE ${new_space}';
        END LOOP;
        FOR user IN
        (SELECT username FROM dba_users WHERE local_temp_tablespace NOT IN '${new_space}'
        and username != 'XS\$NULL')
        LOOP
            EXECUTE IMMEDIATE 'ALTER USER '|| user.username ||' LOCAL TEMPORARY TABLESPACE ${new_space}';
        END LOOP;
    END;
    /
    exit;
EOD

if [ $? -ne 0 ]; then
    echo "Error encountered when assigning DEFAULT TEMPORARY TABLESPACE to ${new_space}"
    exit 1
fi

# List current temp databases to user
prev_tbsps=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD | xargs
    whenever oserror exit 1
    whenever sqlerror exit 1
    column TABLESPACE_NAME format a15
    set pagesize 20000;
    set heading off
    set feedback off
    select distinct ts.name as "Tablespace Name"
    from v\$tablespace ts inner join v\$tempfile df on (ts.ts# = df.ts#)
    where ts.name != '${new_space}'
    order by 1;
    exit;
EOD
)

if [ $? -ne 0 ]; then
    echo "Error occurred when querying the database for current temp tablespaces. Exiting..."
    exit 1
fi

if [ $dopt -ne 1 ]; then
    echo "Added the new temp tablespace $new_space with datafile $datafile."
else

    echo "Dropping the following temp tablespaces: $prev_tbsps"
    echo "Adding the following new temp tablespace $new_space with datafile $datafile."
    echo

    # Reboot the database to gain ability to drop original tablespaces
    # after pausing to allow the user to back out of the script
    echo "********************DATABASE WILL BE SHUTDOWN AND REBOOTED IN 10 SECONDS********************"
    echo "*********PRESS CONTROL + C TO EXIT SCRIPT AND TO PRESERVE PREVIOUS TEMP TABLESPACES*********"
    sleep 10

    echo
    echo "Shutting down $ORACLE_SID..."

    shutdown_status=$("$HOME/common/oracle/shutdown_oracle.sh" "$ORACLE_SID")

    if [ $? -ne 0 ]; then
        echo "Error occurred while shutting down $ORACLE_SID database"
        echo "$shutdown_status"
    fi

    echo "Starting $ORACLE_SID back up..."

    startup_status=$("$HOME/common/oracle/startup_oracle.sh" "$ORACLE_SID")

    if [ $? -ne 0 ]; then
        echo "Error occurred while starting up $ORACLE_SID database"
        echo "$startup_status"
    fi

    # Drop original temp tablespaces
    echo
    echo "$ORACLE_SID successfully rebooted. Dropping original temp tablespaces..."
    echo

    drop_original=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1

        BEGIN
            FOR tbsp IN
            (select distinct ts.name as tablespace_name from v\$tablespace ts
            inner join v\$tempfile df on (ts.ts# = df.ts#)
            where ts.name != '${new_space}')
            LOOP
                EXECUTE IMMEDIATE 'DROP TABLESPACE ' || tbsp.tablespace_name || ' including contents and datafiles';
            END LOOP;
        END;
        /
EOD
    )

    bash_error=$?
    ora_error=$(echo "$drop_original" | grep "ORA-")

    if [ $bash_error -ne 0 ] || [ ! -z "$ora_error" ]; then
        echo "Error occurred while attempting to drop original tablespaces. Exiting..."
        echo "$drop_original"
        exit 1
    fi

    echo "The following tablespaces have been dropped: $prev_tbsps"
    echo

    # Verify that no other temp tablespaces exist on the database
    old_tbsps=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1

        set heading off
        set feedback off

        select count(*) from dba_users where
        (temporary_tablespace not in '${new_space}' OR local_temp_tablespace not in '${new_space}')
        AND username != 'XS\$NULL';
        exit;
EOD
    )

    if [ $? -ne 0 ]; then
        echo "Error occurred while checking for existence of original tablespaces"
        echo "$old_tbsps"
        exit 1
    elif [ "$old_tbsps" -ne 0 ]; then
        echo "One or more original temp tablespace still exists in the database"
        echo "User will have to drop the tablespaces manually"
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1

        select username from dba_users where
        (temporary_tablespace not in '${new_space}' OR local_temp_tablespace not in '${new_space}')
        AND username != 'XS\$NULL';
        exit;
EOD

        if [ $? -ne 0 ]; then
            echo "Error occurred when querying the database for remaining temp tablespaces datafiles. Exiting..."
            exit 1
        fi

        exit 1

    else
        echo "Original temp tablespaces dropped successfully"
    fi
fi

echo "Current temp space datafiles:"
# List current temp data files to user
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
column FILE_NAME format a62
column TABLESPACE_NAME format a15
set pagesize 20000;
select df.name as file_name ,ts.name as tablespace_name
from v\$tablespace ts inner join v\$tempfile df on (ts.ts# = df.ts#);
exit;
EOD

if [ $? -ne 0 ]; then
    echo "Error occurred when querying the database for current temp tablespaces datafiles. Exiting..."
    exit 1
fi

exit 0
