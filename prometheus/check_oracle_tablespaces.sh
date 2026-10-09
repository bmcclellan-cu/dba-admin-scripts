#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script was created to check all Oracle Table Space status
# 
###########################################################################

usage="Usage: check_oracle_tablespaces.sh [ <ORACLE_SID> ] "
example="Example: check_oracle_tablespaces.sh sid1"

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

vm_user=$(whoami)
if [[ "$vm_user" != "oracle" ]]; then
    echo "Script must be run as the oracle user. Exiting..."
    exit 1  
fi

if [[ $# -ne 1 ]]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

source "$HOME/19c.env"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing $HOME/19c.env. Exiting..."
    exit 1
fi

#Set variables from input
SID="${1,,}"

tbsp_info_query="whenever oserror exit 1
whenever sqlerror exit 1
set pagesize 0
set feedback off
SELECT
distinct tablespace_name, used_percent
FROM
DBA_TABLESPACE_USAGE_METRICS;"

export ORACLE_SID="$SID"
tbsp=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba << EOF
    $tbsp_info_query
EOF
)


#Check for Oracle errors and exit if present
if [ $? -ne 0 ] || [ -n "$(echo "$tbsp" | grep ORA-)" ]; then
    echo "$tbsp" | tee -a "/tmp/check_oracle_tablespaces_${SID}_$(date +%Y_%m_%d_%H_%M_%S).err"
    exit 1
fi

IFS=$'\n'
for line in $tbsp; do
    name=$(echo "$line" | awk '{print $1}')
    used_pcnt=$(echo "$line" | awk '{print $2}')
    tbsp_name+=" $name"
    tbsp_pcnt+=$(echo -e " $used_pcnt")
done

unset IFS

array_name=($tbsp_name)
array_pcnt=($tbsp_pcnt)

for ((i=0; i<${#array_name[@]}; i++)); do
    printf "oracle_tablespace_used_pcnt{sid=\"%s\",tablespace=\"%s\"} %.4f\n" "$SID" "${array_name[i]}" "${array_pcnt[i]}"
done
