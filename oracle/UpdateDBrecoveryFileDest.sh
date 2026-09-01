#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: Update Oracle param recovery file area
#
# Explanation: The Oracle recovery file destination is
#              a directory where control files backups,
#              archive logs, and RMAN backups are stored.
#
# Arguments: Entering "list" for the directory argument will display
#	         current db_recovery_file_dest param and then exit.
#            The scope argument can be both, memory, or spfile,
#            default is both.
#
usage="Usage: UpdateDBrecoveryFileDest.sh [ [ -o (optional override directory read-write access check) ] [directory] [ORACLE_SID (csv) | ALL] [both | memory | spfile (optional scope param)]] | [list] [ORACLE_SID (csv) | ALL]"
example="Example1: UpdateDBrecoveryFileDest.sh /path/to/recovery ALL both
Example2: UpdateDBrecoveryFileDest.sh /path/to/recovery mysid1,mysid2 memory"
##########################################################################################

# Process input options
override_read_write_check=false
while getopts ":ho" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    o)
        override_read_write_check=true
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

# Check arguments
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

if [[ "${1^^}" == "LIST" ]] && [[ "$override_read_write_check" == true ]]; then
    echo "$usage"
    echo "$example"
    echo "List option cannot be used with the override directory read-write access check. Exiting..."
    exit 1
fi

# If there are 3 parameters, check that scope input is valid
if [ $# -eq 3 ] && [[ ! ${3^^} =~ MEMORY|SPFILE|BOTH ]]; then
    echo "Scope must be memory, spfile, or 'both'. Exiting..."
    exit 1
# Set the third parameter to the input value
elif [ $# -eq 3 ]; then
    scope=$3
# If the optional third parameter is not provided set to a default
elif [ $# -eq 2 ] && [ "${1^^}" != "LIST" ]; then
# Set scope to the input param
    scope="both"
fi

sid=${2}
exit_status=0

# Show current db_recovery_file_dest param if "list" parameter was given
if [ "${1^^}" == "LIST" ]; then
    IFS=,
    for SID in $sid; do
        if [ "${SID^^}" != "ALL" ]; then
            # Checking ORACLE_SID
            invalid_sids=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$SID")
            if [ -n "$invalid_sids" ]; then
                if [ "$invalid_sids" == "-1" ]; then
                    echo "Error, \$ORACLE_SID not set. Continuing..."
                    exit_status=1
                    continue
                fi
                echo "Error, provided \$ORACLE_SID $SID is not open. Continuing..."
                exit_status=1
                continue
            fi
        fi    
        dest=$("$HOME/common/oracle/PrintParamDBrecoveryFileDest.sh" "$SID")
        if [ $? -ne 0 ]; then
            echo "$dest"
            echo "Error occurred while running PrintParamDBrecoveryFileDest.sh. Continuing..."
            exit_status=1
            continue
        fi

        if [ "${SID^^}" != "ALL" ]; then
            echo "Current db_recovery_file_dest for $SID: $dest"
        else 
            echo "$dest"
        fi
    done
    if [ $exit_status -ne 0 ]; then
        echo
        echo "One or more errors occurred while listing DB recovery file destinations. Exiting..."
        exit 1
    else
        exit 0
    fi
else
    if [ "${sid^^}" != "ALL" ]; then
        SIDS="$sid"
    else
        SIDS="$SIDSLIST"
        SIDS=$(echo "$SIDS" | tr ' ' ',')
    fi
fi

# Check directory exists
if [ ! -d "$1" ]; then
    echo "The directory $1 does not exist. Exiting..."
    exit 1
fi
# Check read and write access for current user
if [ "$override_read_write_check" != true ] && ! { sudo -u oracle test -r "$1" && sudo -u oracle test -w "$1"; } ; then
    echo "The directory $1 does not have read-write access for user oracle. Exiting..."
    exit 1
fi
directory=$(realpath "$1")

IFS=,
for SID in $SIDS; do
    echo
    echo "Updating $SID database..."

    # Set and check database
    export ORACLE_SID=$SID
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$SID")

    if [ $? -ne 0 ]; then
        echo "Error occurred while checking open status of database $SID. Continuing..."
        exit_status=1
        continue
    elif [[ "$db_status" == *"CLOSED"* ]] || [[ "$db_status" == *"ERROR"* ]]; then
        echo "Error: Cannot update db_recovery_file_dest on $SID database as it is either in a CLOSED state or CheckDatabaseOpenStatus.sh reported an error during it's execution. Continuing..."
        exit_status=1
        continue
    elif [ "$db_status" == "OPEN" ]; then
        # If this variable is not set then it will be omitted from the query below.
        alter_system_cmd="alter system switch logfile;"
    else
        # Clear this variable to work with for loop in case of closed or nomount database
        alter_system_cmd=""
    fi

    original_value=$("$HOME/common/oracle/PrintParamDBrecoveryFileDest.sh" "$SID")
    # Check for errors
    if [ $? -ne 0 ]; then
        echo "Error occurred while determining original recovery file destination for $SID database. Continuing..."
        echo "$original_value"
        exit_status=1
        continue
    fi

    # Change recovery file directory
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    alter system set db_recovery_file_dest = '${directory}' scope = ${scope};
    --Below syntax says "use alter_system_cmd if set, if not set use nothing"
    ${alter_system_cmd:-}
    commit;
    exit;
EOD

    # Check for errors
    if [ $? -ne 0 ]; then
        echo "Error occurred while changing recovery file destination for $SID database. Continuing..."
        exit_status=1
        continue
    else
        echo "SID $ORACLE_SID db_recovery_file_dest parameter updated from ${original_value} to $directory within scope ${scope}"
    fi
done

if [ $exit_status -eq 1 ]; then
    echo
    echo "One or more errors occurred while updating the recovery destination. Check output for more information. Exiting..."
    exit 1
fi

exit 0
