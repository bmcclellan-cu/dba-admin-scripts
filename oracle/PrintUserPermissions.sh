#!/bin/bash
#
# AvailabilityFlag: Public
#
# Purpose: This script prints a user or role's system and object privileges as well 
#          as the roles granted to the user/role
#
# Note: Use the -d option to generate the DDL for all of the user/role's privileges
#
###################################################################################
usage="Usage: PrintUserPermissions.sh [-d (generate DDL)] [user | role] [identifier (user|role)]"
example="Example: PrintUserPermissions.sh USER_NAME user"

dopt=false

# Process input options
while getopts ":hd" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    d)
        dopt=true
        shift 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Checking the amount of arguments
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check for valid ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$ORACLE_SID")
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
       echo "Error, \$ORACLE_SID not set..."
       exit 1
    fi
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
fi

user=${1^^}
id=${2^^}

if [ "$id" == "USER" ]; then
    user_check=$("$HOME/common/oracle/CheckIfUserExists.sh" "$user")
    # Error Check
    if [ $? -ne 0 ]; then
        echo "$user_check"
        echo "Error, CheckIfUserExists.sh failed. Exiting..."
        exit 1
    elif [ "$user_check" != "Yes" ]; then
        echo "Error, user $user does not exist on $ORACLE_SID. Exiting..."
        exit 1
    fi
elif [ "$id" == "ROLE" ]; then
    role_check=$("$HOME/common/oracle/CheckIfRoleExists.sh" "$user")
    # Error Check
    if [ $? -ne 0 ]; then
        echo "$role_check"
        echo "Error, CheckIfRoleExists.sh failed. Exiting..."
        exit 1
    elif [ "$role_check" != "Yes" ]; then
        echo "Error, role $user does not exist on $ORACLE_SID. Exiting..."
        exit 1
    fi
else
    echo "Error, identifier must either be \"USER\" or \"ROLE\". Exiting..."
    exit 1
fi

# Role Grants
role_grants=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    set pagesize 0
    SELECT granted_role as role
    FROM DBA_ROLE_PRIVS
    WHERE grantee='$user'
    UNION
    SELECT "SYSDBA" as role
    from v\$pwfile_users
    where username = '$user'
    and sysdba = 'TRUE'
    ORDER BY role;
    exit;
EOD
)
# Error check
if [ $? -ne 0 ]; then
    echo "$role_grants"
    echo "Error, could not list roles granted to $user. Exiting..."
    exit 1
elif [ -z "$role_grants" ]; then
    role_grants="No roles granted to $user"
fi
echo
echo "ROLES GRANTED TO ${user}"
echo "-----------------------------------"
echo "$role_grants"
echo

# System Privileges
sys_privs=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    set pagesize 0
    SELECT privilege
    FROM DBA_SYS_PRIVS
    WHERE grantee='$user'
    ORDER BY privilege;
    exit;
EOD
)
# Error check
if [ $? -ne 0 ]; then
    echo "$sys_privs"
    echo "Error, could not list system privileges granted to $user. Exiting..."
    exit 1
elif [ -z "$sys_privs" ]; then
    sys_privs="No system privileges granted to $user"
fi
echo
echo "SYSTEM PRIVILEGES"
echo "---------------------"
echo "$sys_privs"
echo

# Object Privileges
obj_privs=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off 
    set linesize 1000
    set pagesize 1000
    column Object format a40
    column "Object Type" format a20
    column Owner format a40
    column Privilege format a120
    SELECT 
        D.table_name AS "Object", 
        A.object_type AS "Object Type",
        D.owner AS "Owner", 
        LISTAGG(DISTINCT D.privilege, ',') WITHIN GROUP (ORDER BY D.privilege) AS "Privilege"
    FROM DBA_TAB_PRIVS D
    JOIN ALL_OBJECTS A 
        ON A.object_name = D.table_name AND A.owner = D.owner
    WHERE D.grantee='$user'
    GROUP BY D.table_name, A.object_type, D.owner
    ORDER BY A.object_type, D.table_name, D.owner;
    exit;
EOD
)
# Error check
if [ $? -ne 0 ]; then
    echo "$obj_privs"
    echo "Error, could not list object privileges granted to $user. Exiting..."
    exit 1
elif [ -z "$obj_privs" ]; then
    obj_privs="No object privileges granted to $user"
fi
echo
echo "OBJECT PRIVILEGES"
echo "---------------------"
echo "$obj_privs"
echo

echo 
echo "Successfully listed all privileges for $user"

if $dopt; then
    echo "Generating DDL..."
    echo
    res=$("$HOME/common/oracle/GenerateDDL.sh" "-d" "$user")
    if [ $? -ne 0 ]; then
        echo "$res"
        echo
        echo "Error, GenerateDDL.sh failed. Exiting..."
        exit 1
    fi
    # This sed removes lines 1 - 4 and keeps everything else
    echo "$res" | sed '1,4d'
fi