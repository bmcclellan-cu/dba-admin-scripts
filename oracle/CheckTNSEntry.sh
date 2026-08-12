#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to run a TNS check on either a single
#	   ORACLE_SID or all entries in the tnsnames.ora file. The script will run
#	   the tnsping command on the appropriate entries. It will then print a 
#	   success message for each entry. If the script is unsuccessful, it will
#	   print the error message for the user to see. 
#
#####################################################################################

usage="Usage: CheckTNSEntry.sh [\$ORACLE_SID | ALL] [ hostname (optional, required with service_name) ] [ service_name (optional, required with hostname) ]"
example="Example: CheckTNSEntry.sh MYDBD19 my-db.example.com MYDBD19"
error=0

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


if [ $# -ne 1 ] && [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
elif [ $# -eq 3 ]; then
    if [ "${1^^}" == "ALL" ]; then
        echo "Hostname/service_name cannot be given with 'ALL' parameter. Exiting..."
        exit 1
    fi
    hostname="$2"
    # Separate host name from domain, if applicable 
    if [[ "$hostname" == *.* ]]; then
        host=$(echo "$hostname" | cut -d '.' -f1)
        # Cut the hostname by '.' and take the section from the second field to the end
        # Ex. my-db.example.com -> example.com
        domain=$(echo "$hostname" | cut -d '.' -f2-)
    else 
        host=$hostname
    fi
    service_name="$3"
fi

# Source .bashrc only when $ORACLE_HOME is unset, which is the case under crontab
# and systemd since neither loads the oracle user's profile. A caller that has
# deliberately selected a different Oracle home (19c.env, 12c.sh) keeps its own.
if [ -z "$ORACLE_HOME" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
        if [ $? -ne 0 ]; then
            echo "An error occurred while sourcing $HOME/.bashrc. Exiting..."
            exit 1
        fi
    else
        echo "Error: $HOME/.bashrc does not exist. Exiting..."
        exit 1
    fi
fi

# Fail closed on a bad $ORACLE_HOME rather than reporting a missing tnsnames.ora
# under the misleading path "/network/admin/tnsnames.ora"
if [ ! -x "$ORACLE_HOME/bin/tnsping" ]; then
    echo "Error: \$ORACLE_HOME is not set to an Oracle home containing bin/tnsping. Exiting..."
    exit 1
fi

# Check that listener is running
listener=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
if [ $? -ne 0 ]; then 
    echo "Error occurred while running CheckIfListenerRunning.sh. Exiting..."
    exit 1
elif [ "$listener" != "Yes" ]; then
    echo "Listener is not running. Exiting..."
    exit 1
fi

# Verify that tnsnames.ora file exists
if ! [ -f "$ORACLE_HOME/network/admin/tnsnames.ora" ]; then
    echo "Error: tnsnames.ora file does not exist under the directory $ORACLE_HOME/network/admin/"
    exit 1
fi

# If "ALL" argument passed, grab list of all tns_entries in tnsnames.ora
if [ "${1^^}" == "ALL" ]; then
    # Grep for '(DESCRIPTION =' including the previous line, where the entries will be
    tns_entries=$(grep -i -B 1 '(DESCRIPTION =
    >   (' $ORACLE_HOME/network/admin/tnsnames.ora)
    # Sed used to remove the extraneous parts of the output (removes '= (DESCRIPTION = -- ' and ' = (DESCRIPTION =')
    targets=$(echo "$tns_entries" | sed 's/ = (DESCRIPTION = -- / /g' | sed 's/ = (DESCRIPTION =/ /g' )
# If single ORACLE_SID was passed, set it to the targets variable
else
    targets="$1"
fi

for target in $targets; do

    # DB checked with tnsping. If tns_check is set, the check was good.
    # If tns_error is set, there was an error with the check.
    # Timeout will trigger if tnsping waits 5 seconds
    tns_check=$(timeout 5 "$ORACLE_HOME/bin/tnsping" "$target")
    bash_error=$?
    tns_error=$(echo "$tns_check" | grep "TNS-")

    # Check if tns_error isn't empty, meaning there was an error
    if [ -n "$tns_error" ]; then
        echo "TNS- error received when running tnsping on $target: ${tns_error}"
        error=1
    # Check if tns_check didn't print 'OK'
    elif [ -z "$tns_check" ]; then
        echo "'OK' not received by tnsping on $target"
        error=1
    # If bash_error is non-zero, but no tns_error was set then a timeout occurred
    elif [ "$bash_error" -ne 0 ]; then
        echo "tnsping timed out when running on $target"
        error=1
    else
        if [ $# -eq 3 ]; then
            # Checking if hostname is on an unspecified domain
            if [ -z "$domain" ]; then
                host_found=$(echo "$tns_check" | grep "(HOST = $host)")
                if [ -z "$host_found" ]; then
                    host_found=$(echo "$tns_check" | grep -o "HOST = $host\.[^)]*")
                    domain_found=$(echo "$host_found" | cut -d '.' -f2-)
                fi
            # Checking if hostname is found without the specified domain, or on a different domain
            else
                host_found=$(echo "$tns_check" | grep "(HOST = $host.$domain)")
                if [ -z "$host_found" ]; then
                    # match everything after and including '.' but before ')'
                    # Ex. (HOST = my-db.example.com) -> .example.com
                    host_found=$(echo "$tns_check" | grep -o "HOST = $host\.[^)]*")
                    if [ $? -ne 0 ]; then
                        host_found=$(echo "$tns_check" | grep -o "(HOST = $host)")
                    else
                        domain_found=$(echo "$host_found" | cut -d '.' -f2-)
                    fi
                fi
            fi

            service_name_found=$(echo "$tns_check" | grep -i "(SERVICE_NAME = $service_name)")

            if [ -z "$host_found" ] && [ -z "$service_name_found" ]; then
                echo "No TNS entry found for $target on host $hostname with SERVICE_NAME $service_name."
                exit 1
            elif [ -z "$host_found" ]; then
                echo "No TNS entry found for $target on host $hostname."
                exit 1
            elif [ -z "$service_name_found" ]; then
                echo "No TNS entry found for $target with SERVICE_NAME $service_name."
                exit 1
            elif [ ! -z "$domain_found" ]; then
                echo "tnsping on $target was successful, service name was verified, host $host found with domain $domain_found"
                exit 0
            elif [ -z "$domain_found" ] && [ ! -z "$domain" ]; then
                echo "tnsping on $target was successful, service name was verified, host $host found without domain $domain"
                exit 0
            fi
            echo "tnsping on $target was successful, and hostname/service_name were verified in tns entry"
        else
            echo "tnsping on $target was successful"
        fi
    fi
done

# Check error status of script
if [ "$error" -ne 0 ]; then
    exit 1
else
    exit 0
fi
