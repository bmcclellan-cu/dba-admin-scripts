#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  The purpose of this script is to validate that the listener.ora is valid
#           and that the Oracle Listener has successfully parsed and registered
#           all of the entries.
#
# Note: By default all non-database specific tests are run. You can run only specific
#       tests by using the script's flags.
#
#####################################################################################

usage="Usage: ValidateOracleListener.sh [ -p (optional, run the parenthesis check) ] [ -d database (optional, check if database is statically registered) ] [ -s (optional, check that the static service count matches what is registered with lsnrctl) ]"
example="Example: ValidateOracleListener.sh"

# Process input options
popt=false
sopt=false
database=""
while getopts ":hspd:" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0;;
        s)
            sopt=true
            ;;
        p)
            popt=true
            ;;
        d)
            # A blank value (empty or only whitespace) names no database. An empty one would also leave $database
            # empty, so the default tests would run instead of the database test.
            if [[ "$OPTARG" =~ ^[[:space:]]*$ ]]; then
                echo "Error: -d requires a database"
                exit 1
            fi
            database="${OPTARG,,}"
            ;;
        :)
            echo "Error: -$OPTARG requires a database"
            exit 1
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done
shift $((OPTIND-1))

if [ $# -ne 0 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

all_tests=false
if [[ "$popt" != true ]] && [[ "$sopt" != true ]] && [ -z "$database" ]; then 
    all_tests=true
fi

lsnr_file=$ORACLE_HOME/network/admin/listener.ora
if ! [ -f "$lsnr_file" ]; then
    echo "The Oracle listener file does not exist at $lsnr_file. Exiting..."
    exit 1
fi

# Ensure that comments are excluded from any searches through the entries
valid_lsnr_entries=$(sed 's/#.*//' "$lsnr_file")
if [[ "$popt" == true ]] || [[ "$all_tests" == true ]]; then
    # Verify that the number of opening parenthesis are the same as the number of closing parenthesis in
    # listener.ora
    count_open=$(tr -cd '(' <<< "$valid_lsnr_entries" | wc -c)
    count_closed=$(tr -cd ')' <<< "$valid_lsnr_entries" | wc -c)
    if [ "$count_open" != "$count_closed" ]; then
        echo "ERROR: Number of opening parenthesis is not equal to number of closing parenthesis in $lsnr_file (open=$count_open, closed=$count_closed)."
        echo "       listener.ora is invalid! Exiting..."
        exit 1
    fi

    # Equal counts can still be out of order, as in ")(". Walk the parentheses keeping the nesting depth; it goes
    # below 0 at the first closing parenthesis that has no opening one before it.
    parens=$(tr -cd '()' <<< "$valid_lsnr_entries")
    depth=0
    for (( i = 0; i < ${#parens}; i++ )); do
        if [ "${parens:i:1}" == "(" ]; then
            depth=$((depth + 1))
        else
            depth=$((depth - 1))
        fi
        if [ "$depth" -lt 0 ]; then
            echo "ERROR: A closing parenthesis comes before its opening parenthesis in $lsnr_file."
            echo "       listener.ora is invalid! Exiting..."
            exit 1
        fi
    done
fi

if [[ "$sopt" == true ]] || [ -n "$database" ] || [[ "$all_tests" == true ]]; then
    lsnr_services=$("$ORACLE_HOME/bin/lsnrctl" services)
    if [ $? -ne 0 ]; then
        echo "$lsnr_services"
        echo "An error occurred while getting list of services registered to the Oracle Listener. Exiting..."
        exit 1
    fi

    # Static entries in listener.ora will register as status UNKNOWN. For databases that are both dynamically
    # and statically registered, there will be 2 lines, one with the actual status and one reading 'UNKNOWN'.
    static_lsnr_services=$(echo "$lsnr_services" | grep "status UNKNOWN")

    if [[ "$sopt" == true ]] || [[ "$all_tests" == true ]]; then
        static_lsnr_service_count=$(grep -c "status UNKNOWN" <<< "$static_lsnr_services")

        # Get expected number of registered services from listener.ora within the SID_LIST_LISTENER block.
        # A listener.ora with no SID_LIST_LISTENER parameter has no static entries, so it counts as 0.
        # A SID_LIST_LISTENER whose parenthesized value cannot be read is an error, not 0.
        # 2>&1 is necessary as the output from perl "die" goes to stderr. LC_ALL=C stops perl from adding a
        # "Setting locale failed" warning to that output when the login's locale is not installed.
        static_entries_count=$(LC_ALL=C perl -0777 -ne '
    if (/^[ \t]*SID_LIST_LISTENER[ \t]*=\s*(?<block>\((?:[^()]++|(?&block))*\))/mx) {
        my $block = $+{block};
        my $count = () = $block =~ /\(\s*SID_DESC\s*=/g;
        print "$count\n";
    } elsif (/^[ \t]*SID_LIST_LISTENER[ \t]*=/m) {
        die "MALFORMED";
    } else {
        print "0\n";
    }
' <<< "$valid_lsnr_entries" 2>&1)
        exit_status=$?
        if [ "$exit_status" -ne 0 ] && [[ "$static_entries_count" =~ "MALFORMED" ]]; then
            echo "$static_entries_count"
            echo "SID_LIST_LISTENER is in $lsnr_file, but its value is not a complete set of parentheses. Exiting..."
            exit 1
        # perl's stderr is captured with its count, so a warning from perl that still exits 0 would leave text
        # here that the numeric comparison below cannot read.
        elif [ "$exit_status" -ne 0 ] || ! [[ "$static_entries_count" =~ ^[0-9]+$ ]]; then
            echo "$static_entries_count"
            echo "An unknown error occurred while searching for static entries. Exiting..."
            exit 1
        fi

        if [ "$static_lsnr_service_count" -ne "$static_entries_count" ]; then
            echo "ERROR: Number of entries in listener.ora does not match the number of statically registered"
            echo "       services 'lsnrctl services' is reporting (static_entries=$static_entries_count, services_reported=$static_lsnr_service_count)."
            echo "       Please check $lsnr_file is not malformed and reload the Oracle Listener. Exiting..."
            exit 1
        fi
    fi

    if [ -n "$database" ]; then
        # Check that the provided database is both present in listener.ora and is reported by lsnrctl
        # as a statically registered service. The listener can report a database that this file does not
        # hold, for example from an entry that was removed but not reloaded. A SID_NAME value may be in double
        # quotes or end its line.
        if ! grep -qE "SID_NAME[[:space:]]*=[[:space:]]*\"?${database}\"?([[:space:])]|$)" <<< "$valid_lsnr_entries"; then
            echo "ERROR: Provided database $database has no SID_NAME entry in $lsnr_file. Exiting..."
            exit 1
        fi
        if ! echo "$static_lsnr_services" | grep -q "\"$database\""; then
            echo "ERROR: 'lsnrctl services' is not reporting provided database $database as a statically registered service. Exiting..."
            exit 1
        fi
    fi
fi

echo "Script completed successfully!"
exit 0
