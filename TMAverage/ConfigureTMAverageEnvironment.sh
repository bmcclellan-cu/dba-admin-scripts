#!/bin/bash
#
# Purpose:  This script creates the TMAverage tablespace and table in the L1A schema,
#           as well as (optionally) a user with the required permissions to populate the
#           table.
# 
# Notes:    This script uses TMAverageHelpers.py to set various static parameters that vary by 
#           database. Any updates to tmaverage configurations must be done in TMAverageHelpers.py
# 
#           For more detailed documentation go to https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/228214621/TMAverage+-+Usage+Performance
# 
# IMPORTANT:    As a part of the TMAverage & TMAverage_Stats table checks, this script will validate 
#               that the MOST RECENT DDL changes have been applied to the respective table. It is 
#               assumed that all previous updates have been applied, and the the only check that is 
#               performed is for the most recent modifications. This check must be updated every time 
#               the DDL is updated, and the respective variables in TMAverageHelpers.py must be updated:
#               tmaverage_table_check_columns, tmaverage_stats_check_columns.
# 
# 
# Author: Robert Schmidt
# Created: June 6th, 2025
# Last Modified: November 17th, 2025 - RS
##########################################################################
usage="Usage: ./ConfigureTMAverageEnvironment.sh [ -t [ absolute path to datafile ] (optional, create TMAverage tablespace) ] [ -b (optional, create TMAverage tables) ] [ -v (optional, create venv in tmaverage script directory, does not require system_id ) ] [ -u (optional, create TMAverage user. Requires username & password fields) ] [ -o (optional, requires -u, grant user with access to OTFD packages) ] [ system_id ] [ username (optional) ] [ password (optional) ]"
example1="Example: ./ConfigureTMAverageEnvironment.sh -t 1 /ssd_internal/Robert/AIMPROD_TMAVERAGE/tmaverage_table.dbf"
example2="         ./ConfigureTMAverageEnvironment.sh -u -o -v 1 PROCESSTMIDTEST testPWD"

user_opt=0
otfd_opt=0
venv_opt=0
table_opt=0
datafile_path=""
while getopts ":hubovt:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    u)
        user_opt=1
        ;;
    o)
        otfd_opt=1
        ;;
    v)
        venv_opt=1
        ;;
    t)
        datafile_path="$OPTARG"
        ;;
    b)
        table_opt=1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift $(($OPTIND -1))

username=""
password=""

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# The -u option requires the SID, username, and password parameters.
if [[ $user_opt -ne 0 && $# -eq 3 ]]; then
    system_id="$1"
    username="$2"
    password="$3"

    # The -o, and -b options need the SID parameter.
elif [[ $# -eq 1 ]] && { [ $otfd_opt -eq 1 ] || [ $table_opt -eq 1 ]; }; then
    system_id="$1"

    # The -v option requires no parameters.
elif [[ $# -eq 0 ]] && [ $venv_opt -eq 1 ]; then
    :
else
    echo "Invalid parameters."
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

# If system_id is set, check it.
if [ -n "$system_id" ] && ! [[ $system_id =~ ^[0-9]+$ ]]; then
    echo "ERROR: System_ID must be a valid integer. Exiting..."
    exit 1
fi

# Check that username and password are oracle standard, if they need to be provided
if [ "$user_opt" -ne 0 ] && [[ ! "$username" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]]; then
    echo "Invalid username. Username must fit the regex '^[A-Za-z][A-Za-z0-9_$#]{0,29}$' Exiting..."
    exit 1
fi
if [ "$user_opt" -ne 0 ] && [[ ! "$password" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]]; then
    echo "Invalid password. Password must fit the regex '^[A-Za-z][A-Za-z0-9_$#]{0,29}$'. Exiting..."
    exit 1
fi

if [[ "$otfd_opt" -ne 0 && "$user_opt" -eq 0 ]]; then
    echo "Invalid, the -o option requires the -u option. Exiting..."
    exit 1
fi

# If user did not specify anything for script to do, display a warning.
if [ $user_opt -eq 0 ] && [ $otfd_opt -eq 0 ] && [ $venv_opt -eq 0 ] && [ $table_opt -eq 0 ] && [ -z "$datafile_path" ]; then
    echo "Error: Must specify at least 1 action for script to take. Please enter at least 1 flag (-u, -o, -v, -t, -b). Exiting..."
    exit 1
fi

# Checking $ORACLE_SID
sid_check=$("$HOME"/common/oracle/VerifyAllParam.sh -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error: \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error: Provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Get MISC schema of database.
misc_schema=$(GetSchemaName.sh -m -v)
if [ $? -ne 0 ]; then
    echo "$misc_schema"
    echo "An error occurred while getting the MISC schema name. Exiting..."
    exit 1
fi


newest_python=$(ls /usr/bin/python3* | grep -oP 'python3\.\d+' | sort -V | tail -n 1)
if [ $? -ne 0 ] || [ -z "$newest_python" ]; then
    echo "$newest_python"
    echo "Failed to find newest version of python. TMAverage requires the use of python. Exiting..."
    exit 1
fi

# If system_id is set, then get SID-dependent helper variables.
if [ -n "$system_id" ]; then
    # Set config variables to default values:
    version="";tmaverage_table_name="";tmaverage_stats_name="";tablespace_name="";tmanalog_table_name="";
    telemetry_analog_conversions_name="";telemetry_item_definitions_name="";tmaverage_table_ddl="";tmaverage_stats_ddl=""
    tmaverage_table_check_columns="";tmaverage_stats_check_columns=""

    # Set static values from helper script. Also checks if database is supported by script.
    var_commands=$($newest_python TMAverageHelpers.py "$ORACLE_SID" "$system_id" 2>&1)
    if [ $? -ne 0 ]; then
        if [[ "$var_commands" == *"not supported by TMAverage"* ]]; then
            echo "ERROR: Database $ORACLE_SID system_id $system_id is not supported by TMAverage. Exiting..."
        else
            echo "$var_commands"
            echo "ERROR: An error occurred while parsing configs. Exiting..."
        fi
        exit 1
    fi

    eval "$var_commands"

    # Split apart table names for helper scripts
    IFS="." read -r tmaverage_schema tmaverage_tab <<< "$tmaverage_table_name"
    IFS="." read -r stats_schema stats_tab <<< "$tmaverage_stats_name"
fi

# Create tablespace if path is specified
if [ -n "$datafile_path" ]; then
    # Check that tablespace exists.
    tablespace_check=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$tablespace_name")
    if [ $? -ne 0 ]; then
        echo "$tablespace_check"
        echo "An error occurred while running CheckIfTablespaceExists.sh. Exiting..."
        exit 1
    fi
    if [ "$tablespace_check" == "No" ]; then
        echo "Creating tablespace $tablespace_name..."
        if [ -f "$datafile_path" ]; then
            echo "Error: Datafile path may not contain a pre-existing path. Exiting..."
            exit 1
        fi
        create_tablespace=$("$HOME/common/oracle/CreateNewTablespace.sh" "$tablespace_name" "$datafile_path")
        status_code=$?
        if [ $status_code -ne 0 ] && [[ "$create_tablespace" == *"already exists in the current database"* ]]; then
            echo "Tablespace $tablespace_name already exists. Continuing..."
        elif [ $status_code -ne 0 ]; then
            echo "$create_tablespace"
            echo "An error occurred while running CreateNewTablespace.sh. Exiting..."
            exit 1
        fi
    else
        echo "Tablespace $tablespace_name already exists. Continuing..."
    fi
fi

# Create the TMAverage table if desired.
if [ $table_opt -ne 0 ]; then

    # Trap that enters a "Failure" record into MIGRATION_STATUS if this step fails
    table_exit_handler() {
        echo "Table creation/validation failed. Inserting record into MIGRATION_STATUS."
        timestamp=$(date +"%Y-%m-%d %H:%M:%S")

        migration_status_insert=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            set heading off
            set feedback off
            whenever oserror exit 1
            whenever sqlerror exit 1

            INSERT INTO $misc_schema.MIGRATION_STATUS (STATUS_TIMESTAMP, SOFTWARE_NAME, SID, UPDATE_VERSION, SOFTWARE_PATH, UPDATE_SUCCESS) VALUES
            (TIMESTAMP '$timestamp', 'TMAverage (Tables)', $system_id, '$version', '$SCRIPT_DIR', 'Failure');
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$migration_status_insert"
            echo "An error occurred while inserting an update record into $misc_schema.MIGRATION_STATUS. Exiting..."
        else
            echo "Successfully inserted a record into $misc_schema.MIGRATION_STATUS."
        fi
        # Prevent the trap from being triggered twice
        trap - EXIT INT TERM
    }
    trap table_exit_handler EXIT INT TERM # On exit, call table_exit_handler.

    # Check that tablespace exists.
    tablespace_check=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$tablespace_name")
    if [ $? -ne 0 ]; then
        echo "$tablespace_check"
        echo "An error occurred while running CheckIfTablespaceExists.sh. Exiting..."
        exit 1
    fi
    if [ "$tablespace_check" != "Yes" ]; then
        echo "Tablespace $tablespace_name does not exist. Please run script with -t flag to create. Exiting..."
        exit 1
    fi

    # Check that L1A schema exists.
    tmaverage_schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" "$tmaverage_schema")
    if [ $? -ne 0 ]; then
        echo "$tmaverage_schema_check"
        echo "An error occurred while running CheckIfSchemaExists.sh. Exiting... "
        exit 1
    fi
    if [[ "$tmaverage_schema_check" != "Yes" ]]; then
        echo "Schema $tmaverage_schema does not exist. Exiting..."
        exit 1
    fi

    # Check if TMAverage table already exists
    check_table_exists=$("$HOME/common/oracle/CheckIfTableExists.sh" "$tmaverage_schema" "$tmaverage_tab")
    if [ $? -ne 0 ]; then
        echo "$check_table_exists"
        echo "An error occurred while running CheckIfTableExists.sh Exiting..."
        exit 1
    fi

    if [[ "$check_table_exists" == *"No"* ]]; then
        # Create TMAverage table
        echo "Creating table $tmaverage_table_name in tablespace $tablespace_name..."
        create_table=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
            set heading off
            set feedback off
            whenever oserror exit 1
            whenever sqlerror exit 1

            $tmaverage_table_ddl
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$create_table"
            echo "An error occurred while creating table $tmaverage_table_name. Exiting..."
            exit 1
        fi
    else
        echo "Table $tmaverage_table_name already exists, checking most-recently-updated columns..."
        # Check most recent updates to the TMAverage table. 
        for column in $tmaverage_table_check_columns; do
            echo "Checking: $column"
            column_check=$("$HOME/common/oracle/CheckIfColumnExists.sh" "$tmaverage_schema" "$tmaverage_tab" "$column")
            if [ $? -ne 0 ]; then
                echo "$column_check"
                echo "An error occurred while running CheckIfColumnExists.sh. Exiting..."
                exit 1
            fi
            if [[ $column_check != "Yes" ]]; then
                echo "ERROR: Column $column is not present in $tmaverage_table_name. Please update the table DDL to match the following: "
                echo
                echo
                echo "$tmaverage_table_ddl"
                exit 1
            fi
        done
        echo "Table exists and is up-to-date. Continuing..."
    fi

    # Check that L1A schema exists.
    stats_schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" "$stats_schema")
    if [ $? -ne 0 ]; then
        echo "$stats_schema_check"
        echo "An error occurred while running CheckIfSchemaExists.sh. Exiting... "
        exit 1
    fi
    if [[ "$stats_schema_check" != "Yes" ]]; then
        echo "Schema $stats_schema does not exist. Exiting..."
        exit 1
    fi

    # Check if TMAverage_stats table already exists
    check_table_exists=$("$HOME/common/oracle/CheckIfTableExists.sh" "$stats_schema" "$stats_tab")
    if [ $? -ne 0 ]; then
        echo "$check_table_exists"
        echo "An error occurred while running CheckIfTableExists.sh Exiting..."
        exit 1
    fi

    if [[ "$check_table_exists" == *"No"* ]]; then
        echo "Creating table $tmaverage_stats_name in tablespace $tablespace_name..."
        create_table=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1

        $tmaverage_stats_ddl
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$create_table"
            echo "An error occurred while creating table $tmaverage_stats_name. Exiting..."
            exit 1
        fi
    else
        echo "Table $tmaverage_stats_name already exists, checking most-recently-updated columns..."
       # Check most recent updates to the TMAVERAGE_STATS table. 
        for column in $tmaverage_stats_check_columns; do
            echo "Checking: $column"
            column_check=$("$HOME/common/oracle/CheckIfColumnExists.sh" "$stats_schema" "$stats_tab" "$column")
            if [ $? -ne 0 ]; then
                echo "$column_check"
                echo "An error occurred while running CheckIfColumnExists.sh. Exiting..."
                exit 1
            fi
            if [[ $column_check != "Yes" ]]; then
                echo "ERROR: Column $column is not present in $tmaverage_stats_name. Please update the table DDL to match the following: "
                echo
                echo
                echo "$tmaverage_stats_ddl"
                exit 1
            fi
        done
        echo "Table exists and is up-to-date. Continuing..."
    fi

    # Tables were updated/verified successfully, add record to MIGRATION_STATUS indicating current version

    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    migration_status_insert=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1

        INSERT INTO $misc_schema.MIGRATION_STATUS (STATUS_TIMESTAMP, SOFTWARE_NAME, SID, UPDATE_VERSION, SOFTWARE_PATH, UPDATE_SUCCESS) VALUES
        (TIMESTAMP '$timestamp', 'TMAverage (Tables)', $system_id, '$version', '$SCRIPT_DIR', 'Success');

EOD
    )
    if [ $? -ne 0 ]; then
        echo "$migration_status_insert"
        echo "An error occurred while inserting an update record into $misc_schema.MIGRATION_STATUS. Exiting..."
        exit 1
    fi

    echo "Successfully inserted a record into $misc_schema.MIGRATION_STATUS."

    # Unset trap once update/validation is complete
    trap - EXIT INT TERM
fi

# Create the requested user for TMAverage
if [ $user_opt -ne 0 ]; then
    echo "Creating user $username with password $password..."
    create_user=$("$HOME/common/oracle/CreateNewSchema.sh" "$username" "$password" "USERS")
    status_code=$?
    if [ $status_code -ne 0 ] && [[ $create_user == *"already exists"* ]]; then
        echo "User with username $username already exists on database $ORACLE_SID. Resetting password..."
        alter_user=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
            set heading off
            set feedback off
            whenever oserror exit 1
            whenever sqlerror exit 1

            ALTER USER $username IDENTIFIED BY $password;
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$alter_user"
            echo "An error occurred while resetting password for user $username. Exiting..."
            exit 1
        fi
        echo "Successfully reset password for user $username."
    elif [ $status_code -ne 0 ]; then
        echo "$create_user"
        echo "An error occurred while creating user $username with password $password. Exiting..."
        exit 1
    fi

    echo "Creating .username and .passwd files..."
    file_create_failed=0
    echo "$username" > "$SCRIPT_DIR/.username" || file_create_failed=1
    echo "$password" > "$SCRIPT_DIR/.passwd" || file_create_failed=1

    if [ $file_create_failed -ne 0 ]; then
        echo "An error occurred while creating .username and .passwd files. Exiting..."
        exit 1
    fi

    tables="$tmaverage_table_name,$tmaverage_stats_name"

    echo "Granting required permissions to user $username:"
    read_write_permissions=$("$HOME/common/oracle/GrantNewPermissions.sh" "$tables" table ALL "$username" Y)
    if [ $? -ne 0 ]; then
        echo "$read_write_permissions"
        echo "An error occurred while granting read-write permissions to tables $tables on $username. Exiting..."
        exit 1
    fi

    # TODO: Replace this with updated GrantNewPermissions.sh. TMANALOG is a view on EMA, and GrantNewPermissions.sh does not 
    #       currently support adding permissions to views. This update will be addressed in DB-3350.
    table_permission_add=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1

        GRANT SELECT ON $tmanalog_table_name TO $username;
        GRANT SELECT ON $telemetry_item_definitions_name TO $username;
        GRANT SELECT ON $telemetry_analog_conversions_name TO $username;
        exit;   
EOD
)
    if [ $? -ne 0 ]; then
        echo "$table_permission_add"
        echo "An error occurred while adding permissions for $tmanalog_table_name, $telemetry_item_definitions_name, $telemetry_analog_conversions_name. Exiting..."
        exit 1
    fi

    # read_only_permissions=$("$HOME/common/oracle/GrantNewPermissions.sh" "$table1,$table2,$table3" table SELECT "$username" Y)
    # if [ $? -ne 0 ]; then
    #     echo "$read_only_permissions"
    #     echo "An error occurred while granting read-only permission to the following tables $table1, $table2, $table3. Exiting..."
    #     exit 1
    # fi

    if [ $otfd_opt -ne 0 ]; then
        echo "Granting user access to OTFD package & tables..."

        # Check that OTFD packages & tables exist. 
        otfd_status=$("$HOME/common/oracle/GetOTFDStatus.sh" "$ORACLE_SID")
        if [ $? -ne 0 ]; then
            echo "$otfd_status"
            echo "An error occurred while checking OTFD table & package status. Exiting..."
            exit 1
        fi
        if [[ "$otfd_status" == *"Does Not Exist"* ]] || [[ "$otfd_status" == *"Not Loaded"* ]] || [[ "$otfd_status" == *"Compilation Error"* ]]; then
            echo "$otfd_status"
            echo "One or more OTFD Packages/tables do not exist/has compilation errors. See procedure status above. Exiting..."
            exit 1
        fi

        otfd_execute=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
            set heading off
            set feedback off
            whenever oserror exit 1
            whenever sqlerror exit 1

            GRANT EXECUTE ON ONTHEFLYDECOM TO $username;
            GRANT EXECUTE ON ONTHEFLYDECOMMISSIONSPECIFIC TO $username;
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$otfd_execute"
            echo "An error occurred while granting access to the OTFD package to $username. Exiting..."
            exit 1
        fi
        
        tables="$misc_schema.ONTHEFLYDECOM_RESULTS,$misc_schema.ONTHEFLYDECOM_ERRORS"

        otfd_tables=$("$HOME/common/oracle/GrantNewPermissions.sh" "$tables" table SELECT $username Y)
        if [ $? -ne 0 ]; then
            echo "$otfd_tables"
            echo "An error occurred while granting SELECT permissions to tables $tables on $username. Exiting..."
            exit 1
        fi
    fi
    echo "Successfully created user $username and granted appropriate permissions."
fi


# Create a virtual environment in the current directory and install needed dependencies.
if [ $venv_opt -ne 0 ]; then
    create_venv=$("$newest_python" -m venv "$SCRIPT_DIR/venv")
    if [ $? -ne 0 ]; then
        echo "$create_venv"
        echo "Error occurred while creating python venv in $SCRIPT_DIR/venv. Exiting..."
        exit 1
    fi
    # Activate venv
    source "$SCRIPT_DIR/venv/bin/activate"
    if [ $? -ne 0 ]; then
        echo "An error occurred while activating venv environment. Exiting..."
        exit 1
    fi

    # Install needed dependencies.
    install_requirements=$(pip install -r "$SCRIPT_DIR/requirements.txt")
    if [ $? -ne 0 ]; then
        echo "$install_requirements"
        echo "Error occurred while installing requirements at $SCRIPT_DIR/requirements.txt. Exiting..."
        exit 1
    fi

    echo "Successfully created venv at $SCRIPT_DIR/venv."
fi


echo "Script completed successfully"
exit 0