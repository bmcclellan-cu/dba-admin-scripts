#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to create a new entry in the listener.ora
#	   file with a given database name. This script is meant to help automate the
#	   steps of cloning a live database.
#
# Note: This script can only update the listener named LISTENER because we do our insert
#       based off the location of SID_LIST_LISTENER
#
#####################################################################################

usage="Usage: UpdateListenerFile.sh [database]"
example="Example: UpdateListenerFile.sh mydb"

# Process input options
while getopts ":h" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done

# Check arguments. A blank name (empty or only whitespace) would be written to listener.ora as an entry with no
# SID_NAME value, or, when empty, match an existing entry and be reported as already present.
if [ $# -ne 1 ] || [[ "$1" =~ ^[[:space:]]*$ ]]; then
    echo "$usage"
    echo "$example"
    exit 1
fi
database="${1,,}"

lsnr_file=$ORACLE_HOME/network/admin/listener.ora

# Get the status of the oracle listener. This command returns a non-zero exit status when the listener is down.
lsnr_status=$("$ORACLE_HOME/bin/lsnrctl" status)
exit_code=$?
if ! [[ "$lsnr_status" =~ "TNS-12541" ]] && [ $exit_code -ne 0 ]; then
    echo "An unknown error occurred while getting the status of the listener. Exiting..."
    echo "$lsnr_status"
    exit 1
elif  [[ "$lsnr_status" =~ "TNS-12541" ]]; then
    lsnr_running=false
else
    lsnr_running=true
fi

# Validate parts of the listener file before making updates. Validation includes checking parenthesis are balanced 
# and that the number of static entries in SID_LIST_LISTENER matches what is shown by 'lsnrctl services'.
# When the listener is stopped only the parenthesis check (-p) runs, because the static entry check asks the running
# listener.
if [ -f "$lsnr_file" ]; then
    validate_options=()
    if [[ "$lsnr_running" != true ]]; then
        validate_options=(-p)
    fi
    validate_listener=$("$HOME/common/oracle/ValidateOracleListener.sh" "${validate_options[@]}")
    if [ $? -ne 0 ]; then
        echo "$validate_listener"
        echo "One or more errors exist in $lsnr_file prior to any updates."
        echo "Please check the syntax of $lsnr_file and, if the listener is running, that it is the configuration lsnrctl is currently using."
        echo "Once you have verified the syntax of $lsnr_file and, if the listener is running, that the configuration is active in lsnrctl, run this script again."
        echo "Exiting..."
        exit 1
    fi
fi

# Check if listener.ora is present on the server
if [ -f "$lsnr_file" ]; then
    # Strip out any comments from the lsnr entries so the database existence check isn't misled
    valid_lsnr_entries=$(sed 's/#.*//' "$lsnr_file")
    # Check if database already exists in the listener file. A SID_NAME value may be in double quotes or end its line.
    db_check=$(grep -E "SID_NAME[[:space:]]*=[[:space:]]*\"?${database}\"?([[:space:])]|$)" <<< "$valid_lsnr_entries")
    if [ ! -z "$db_check" ]; then
        echo "$1 already has an entry in listener.ora file. Continuing without making changes..."
        exit 0
    fi

    # Backup the current listener.ora with date appended
    curr_date=$(date +%Y-%m-%d_%H-%M-%S)
    lsnr_backup="$ORACLE_HOME/network/admin/listener_$curr_date.ora"
    cp "$lsnr_file" "$lsnr_backup"
    if [ $? -ne 0 ]; then
        echo "Failed to copy $lsnr_file to $lsnr_backup which means this script failed to create a backup. Exiting..."
        exit 1
    fi

    # Add SID_LIST_LISTENER if it doesn't exist
    if ! grep -qE '^[[:space:]]*SID_LIST_LISTENER[[:space:]]*=' "$lsnr_file"; then
        echo "SID_LIST_LISTENER not found in $lsnr_file. Creating new entry..."

        # The blank line keeps the new parameter off the file's last line when that line has no newline.
        # Every line after the parameter name is indented, because Oracle reads a line starting in the
        # first column as a new parameter.
        cat >> "$lsnr_file" <<EOF

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $database)
      (ORACLE_HOME = $ORACLE_HOME)
      (SID_NAME = $database)
    )
  )
EOF

    else
        # Insert new SID_DESC at the beginning of the existing SID_LIST
        # $gap matches whitespace and "#" comments, so a comment after "SID_LIST_LISTENER =" and before the first "(" inside
        # SID_LIST does not hide the insertion point; its possessive quantifiers (*+) stop perl from backtracking to find
        # a "(" inside a comment.
        # 2>&1 is used because the "die" output goes to stderr
        perl_out=$(DATABASE="$database" perl -0ni -e '
    my $gap = qr/(?:\s|\#[^\n]*+)*+/;
    $matched = s{(^[ \t]*SID_LIST_LISTENER[ \t]*=${gap}\(${gap}SID_LIST${gap}=${gap})(?=\()}
                {$1(SID_DESC =\n        (GLOBAL_DBNAME = $ENV{DATABASE})\n        (ORACLE_HOME = $ENV{ORACLE_HOME})\n        (SID_NAME = $ENV{DATABASE})\n    )\n    }mx;

    print;
    die "NOT FOUND\n" unless $matched;
' "$lsnr_file" 2>&1)
        exit_status=$?
        # Mentioning the backup is unnecessary here because listener.ora keeps its content when perl dies with NOT FOUND:
        # perl before 5.28 has already printed the text unchanged, and later versions leave the original file in place.
        if [ $exit_status -ne 0 ] && [[ "$perl_out" =~ "NOT FOUND" ]]; then
            echo "$perl_out"
            echo "Error: Could not find SID_LIST_LISTENER insertion point for new entry. Exiting..."
            exit 1
        elif [ $exit_status -ne 0 ]; then
            echo "$perl_out"
            echo "An unknown error occurred while inserting the new record into the listeners SID_LIST."
            if [ -f "$lsnr_backup" ]; then
                echo "If the file has been modified, you can restore it using the backup file at $lsnr_backup and reloading lsnrctl."
            fi
            echo "Exiting..."
            exit 1
        fi
    fi

# If listener.ora is not present...
else
    # Copy the template listenerXXXX.ora to the listener directory
    cp "$HOME/common/oracle/listenerXXXX.ora" "$lsnr_file"

    # Populate the HOST field with the hostname command
    sed -i "s/HOST = X\+/HOST = $(hostname)/g" "$lsnr_file"

    # Populate the SID_LIST, GLOBAL_DBNAME, and SID_NAME fields with the input
    sed -i "s/GLOBAL_DBNAME = X\+/GLOBAL_DBNAME = $database/g" "$lsnr_file"
    sed -i "s/SID_NAME = X\+/SID_NAME = $database/g" "$lsnr_file"

    # Populate the ORACLE_HOME field with the current $ORACLE_HOME
    sed -i "s|ORACLE_HOME = X\+|ORACLE_HOME = $ORACLE_HOME|g" "$lsnr_file"
fi

validate_listener_paren=$("$HOME/common/oracle/ValidateOracleListener.sh" -p)
if [ $? -ne 0 ]; then
    echo "$validate_listener_paren"
    echo "Updates resulted in unbalanced parentheses in the listener file."
    if [ -f "$lsnr_backup" ]; then
        echo "A backup exists at $lsnr_backup and the configuration has not been registered with lsnrctl yet."
        echo "The backup can be restored by running 'cp $lsnr_backup $lsnr_file' and then reloading/starting the listener using lsnrctl."
    fi
    echo "Exiting..."
    exit 1
fi

if [[ "$lsnr_running" == true ]]; then
    # Reload the listener if it's running
    "$ORACLE_HOME/bin/lsnrctl"  reload
else
    # Start the listener if it's not already running
    "$ORACLE_HOME/bin/lsnrctl" start
fi
if [ $? -ne 0 ]; then
    echo "Listener start/reload did not complete successfully. Check above output for errors"
    exit 1
fi

validate_listener=$("$HOME/common/oracle/ValidateOracleListener.sh" -d "$database")
if [ $? -ne 0 ]; then
    echo "$validate_listener"
    echo "One or more errors exist in $lsnr_file after this script's updates."
    if [ -f "$lsnr_backup" ]; then
        echo "A backup exists at $lsnr_backup."
        echo "The backup can be restored by running 'cp $lsnr_backup $lsnr_file' and then reloading/starting the listener using lsnrctl."
    fi
    echo "Exiting..."
    exit 1
fi

exit 0
