#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to generate DDL for a specific user or role.
#	   SQL code copied from role_ddl.sql created by Tim Hall on 01/28/2006.
#	   Updated 1/31/2021 to output associated users when a role is given.
#
# Note: The -d flag will restrict the script to just print DDL of direct grants to the
#       user/role (not inherited permissions from other roles).
#
#       Regardless of whether the -d flag is given or not, the script will only
#       grant direct grants to a new user, (they will inherit the same role grants
#       and thus still have the same overall permissions)
#
#####################################################################################

usage="Usage: GenerateDDL.sh [[-d (see notes)] [ user | role ] [new user (optional)] ['GRANT' (optional, will execute generated ddl)]] | [list]"
example="Example: GenerateDDL.sh MYAPP_MGR_ROLE
         GenerateDDL.sh MYAPP_MGR_ROLE TEMP_ROLE GRANT
         GenerateDDL.sh list"

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

# Check arguments
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

username=${1^^}

# Ensure that $ORACLE_SID is already set and is valid before continuing
invalid_sid=$($HOME/common/oracle/VerifyAllParam.sh -I)
if [ $? -ne 0 ]; then
    echo "Error: script VerifyAllParam.sh did not execute correctly. Exiting..."
    exit 1
elif [ -n "$invalid_sid" ]; then
    if [ "$invalid_sid" == "-1" ]; then
        echo "Error: \$ORACLE_SID not set. Exiting..."
        exit 1
    fi
    echo "Error: \$ORACLE_SID $ORACLE_SID is not open. Exiting..."
    exit 1
fi

if [ $# -eq 3 ] && [ "${3^^}" != "GRANT" ]; then
    echo "Third parameter must be grant. Exiting..."
    exit 1
fi

# Generate list of: users that own tables
#                   users that do not own tables
#                   and roles found on the database
list=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set feedback off
    set heading off
    set pagesize 10000
    Select 'List of users that own tables:' from dual;
    select username from dba_users where common = 'NO'
    and username in (select distinct owner from dba_segments)
    order by username;

    Select 'List of users that do not own tables:' from dual;
    select username from dba_users where common = 'NO'
    and username not in (select distinct owner from dba_segments)
    order by username;
    
    Select 'List of roles:' from dual;
    select role from dba_roles where common = 'NO' and ORACLE_MAINTAINED = 'N'
    order by role;
EOD
)

if [ $? -ne 0 ]; then
    echo "Error occurred while getting table ownership information. Exiting..."
    echo "$list"
    exit 1
fi

# If user entered list option, print the data from above and the script is over
if [ "$1" == "list" ]; then
    echo "$list"
    echo
else
    # Determine if user argument is a role or user
    echo "Checking if $username is a role or user..."
    role_check=$($HOME/common/oracle/CheckIfRoleExists.sh "$username")
    if [ $? -ne 0 ]; then
        echo "Error occurred while determining if input $username is a role or a user. Exiting..."
        exit 1
    fi
    user_check=$($HOME/common/oracle/CheckIfUserExists.sh "$username")
    if [ $? -ne 0 ]; then
        echo "Error occurred while determining if input $username is a role or a user. Exiting..."
        exit 1
    fi
    # Report to the user what type the user input was determined to be
    if [ "$user_check" == "Yes" ]; then
        echo "Found $username to be a user. Continuing..."
        echo
        user=true
    elif [ "$role_check" == "Yes" ]; then
        echo "Found $username to be a role. Continuing..."
        echo
        user=false
    else
        echo "User/role $username does not exist. Exiting..."
        exit 1
    fi

    role=${1^^}
    if [ "${2^^}" != "GRANT" ] && [ -n "$2" ]; then
        new_user=${2^^}

        # Check that the new user exists before attempting to generate DDL
        new_user_check=$($HOME/common/oracle/CheckIfUserExists.sh "$new_user")
        if [ $? -ne 0 ]; then
            echo "An error occurred while running CheckIfUserExists.sh on user $new_user. Exiting..."
            exit 1
        elif [ "$new_user_check" != "Yes" ]; then
            echo "Error. New user $new_user does not exist, and therefore DDL cannot be generated. Exiting..."
            exit 1
        fi
    elif [ "${2^^}" == "GRANT" ] && [ -n "$2" ]; then
        echo "Error. No new user provided with GRANT clause. Exiting..."
        exit 1
    fi

    # Check if user/role exists in dba_users or dba_roles
    role_exists=$(echo "$list" | grep -o "^$role$")
    if [ -z "$role_exists" ]; then
        echo "User/role \"$role\" does not exist."
        exit 1
    fi
    echo "Permissions for ${role}:"
    echo

    # Run sqlplus using code copied from file mentioned in header
    # Ensure that output is sorted and any empty lines or whitespace at the start
    # of output lines are removed

    # Get create statment for specified roles
    role_result=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set long 500000 longchunksize 500000 pagesize 0 linesize 1000 feedback off verify off trimspool on
        column ddl format a1000
    
        begin
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'SQLTERMINATOR', true);
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'PRETTY', true);
        end;
        /
        select dbms_metadata.get_ddl('ROLE', r.role) AS ddl
        from   dba_roles r
        where  r.role = '$role'
        /
        exit;
EOD
    )
    # Error check
    if [ $? -ne 0 ]; then
        echo "Error occurred getting role DDL. Exiting..."
        exit 1
    fi 

    # Get all grant statements for roles
    role_grants_result=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set long 500000 longchunksize 500000 pagesize 0 linesize 1000 feedback off verify off trimspool on
        column ddl format a1000
    
        begin
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'SQLTERMINATOR', true);
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'PRETTY', true);
        end;
        /
        select dbms_metadata.get_granted_ddl('ROLE_GRANT', rp.grantee) AS ddl
        from   dba_role_privs rp
        where  rp.grantee = '$role'
        and    rownum = 1
        /
        exit;
EOD
    )
    # Error check
    if [ $? -ne 0 ]; then
        echo "Error occurred getting role grants DDL. Exiting..."
        exit 1
    fi 

    # Get all grant statements for system
    sys_grants_result=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set long 500000 longchunksize 500000 pagesize 0 linesize 1000 feedback off verify off trimspool on
        column ddl format a1000
    
        begin
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'SQLTERMINATOR', true);
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'PRETTY', true);
        end;
        /
        select dbms_metadata.get_granted_ddl('SYSTEM_GRANT', sp.grantee) AS ddl
        from   dba_sys_privs sp
        where  sp.grantee = '$role'
        and    rownum = 1
        /
        exit;
EOD
    )
    # Error check
    if [ $? -ne 0 ]; then
        echo "Error occurred getting system grants DDL. Exiting..."
        exit 1
    fi 

    # Get all grant statements for objects
    object_grants_result=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set long 500000 longchunksize 500000 pagesize 0 linesize 1000 feedback off verify off trimspool on
        column ddl format a1000
    
        begin
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'SQLTERMINATOR', true);
            dbms_metadata.set_transform_param (dbms_metadata.session_transform, 'PRETTY', true);
        end;
        /
        select dbms_metadata.get_granted_ddl('OBJECT_GRANT', tp.grantee) AS ddl
        from   dba_tab_privs tp
        where  tp.grantee = '$role'
        and    rownum = 1
        /
        exit;
EOD
    )
    # Error check
    if [ $? -ne 0 ]; then
        echo "Error occurred getting object grants DDL. Exiting..."
        exit 1
    fi 

    # Print the results

    if $user; then
        echo -e "ROLE GRANTS \n--------------------"
        if [ -z "$role_grants_result" ]; then
            echo "  N/A"
        else
            echo -e "$role_grants_result" | sed '1{/^$/d}' | sort
        fi
    else
        echo -e "ROLE \n--------------------"
        if [ -z "$role_result" ]; then
            echo "  N/A"
        else
            echo -e "$role_result" | sed '1{/^$/d}' | sort
        fi
    fi

    echo
    echo -e "SYSTEM GRANTS \n--------------------"
    if [ -z "$sys_grants_result" ]; then
        echo "  N/A"
    else
        echo -e "$sys_grants_result" | sed '1{/^$/d}' | sort
    fi

    echo
    echo -e "OBJECT GRANTS \n--------------------"
    if [ -z "$object_grants_result" ]; then
        echo "  N/A"
    else
        echo -e "$object_grants_result" | sed '1{/^$/d}' | sort
    fi
    echo

    # If role entered, print all users with this role
    if ! $user; then
        echo "Users granted this role ($role):"
        role_users=$(
            "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            set heading off
            set feedback off
            set pagesize 10000
            select grantee from dba_role_privs
            where granted_role = '$role'
            and grantee in
            (select username from dba_users)
            and grantee != 'SYS'
            order by grantee;
            exit;
EOD
        )

        if [ -z "$role_users" ]; then
            echo "No users assigned"
        else
            echo "$role_users"
        fi
        echo ""

        echo "Other roles granted with role ($role):"
        other_roles=$(
            "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            set heading off
            set feedback off
            set pagesize 10000
            select grantee from dba_role_privs
            where granted_role = '$role'
            and grantee not in
            (select username from dba_users)
            and grantee != 'SYS'
            order by grantee;
            exit;
EOD
        )

        if [ -z "$other_roles" ]; then
            echo "No roles assigned"
            echo ""
        else
            echo "$other_roles"
        fi
    fi

    # If any roles are granted to the user, keep track of them in $roles
    roles=$(echo "${role_grants_result}" | grep -o 'GRANT \"\w\+\"')
    if ! $dopt; then
        # Loop through $roles and print permissions for each role
        for loop_role in $roles; do
            # Filter out "GRANT" roles
            if [ "$loop_role" != "GRANT" ]; then
                # Filter out double quotes from role name
                loop_role=${loop_role:1:-1}
                # Check if role is valid by attempting to find it in user/role list
                valid_role=$(echo "$list" | grep -o "$loop_role")
                if [ -n "$valid_role" ]; then
                    echo "Role $valid_role has been granted to $role. Printing permission for role $valid_role:"
                    echo

                    # Run this script with the valid role as input
                    "$HOME/common/oracle/GenerateDDL.sh" "$loop_role"
                fi
            fi
        done
    fi

    echo "Printing tablespaces user $username has access to..."
    user_tablespaces=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1
        select tablespace_name from dba_ts_quotas where username = '${username}';
        exit;
EOD
    )

    # Check for SQL errors
    if [ $? -ne 0 ]; then
        echo "An error occurred while gathering the tablespaces user $username has access to. Exiting..."
        exit 1
    elif [ -z "$user_tablespaces" ]; then
        echo "User $username does not have access to any tablespaces"
    fi

    echo "$user_tablespaces"
fi

# If user gave additional user input, output the DDL for the first user replaced with the second user
if [ -n "$2" ]; then

    echo
    echo "---------------------------------------------------------------------------------------------------------------"
    echo "Generated DDL for new user $new_user from $role permissions:"
    echo

    # We also need to exclude the information "GRANTS" lines
    new_user_result=$(echo "${role_grants_result//"\"$role\""/$new_user}" | sed 's/"//g' | grep -v 'GRANTS')
    new_user_result+=$(echo "${sys_grants_result//"\"$role\""/$new_user}" | sed 's/"//g' | grep -v 'GRANTS')
    new_user_result+=$(echo "${object_grants_result//"\"$role\""/$new_user}" | sed 's/"//g' | grep -v 'GRANTS')
    echo -e "$new_user_result"
    if [ $# -eq 3 ]; then
        echo "---------------------------------------------------------------------------------------------------------------"
        echo
        echo "Executing above DDL..."
        res=$(
            "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            whenever oserror exit 1
            whenever sqlerror exit 1
            $new_user_result
EOD
        )
        if [ $? -ne 0 ] || [[ "$res" =~ "ORA-" ]]; then
            echo "$res" | grep 'ORA'
            echo "Error occurred while executing commands. Exiting..."
            exit 1
        fi
        echo "Grants succeeded."
        exit 0
    fi
    echo "---------------------------------------------------------------------------------------------------------------"
    echo
    echo "NOTE:"
    echo "DDL generated has NOT been run. The end user must run these commands to grant the permissions to the new user $new_user."
else
    echo
fi

exit 0
