# Purpose: This python script stores all of the static variables for TMAverage, and
#          generates bash in order to allows the relevant bash scripts to access the
#          configuration information.
# 
# Notes:   The configuration details are database-dependent, and the script needs to be
#          passed the database name in order to correctly output the appropriate bash.
# 
# IMPORTANT: The ConfigureTMAverageEnvironment.sh script runs checks to make sure the DDL is 
#            up-to-date by checking the most recent DDL changes, which are indicated by the 
#            tmaverage_table_check_columns and tmaverage_stats_check_columns variables. These
#            should be update any time the DDL is updated in order to keep the check up-to-date.
# 
# 
# Author: Robert Schmidt
# Created: August 25th, 2025
# Last Modified: November 10th, 2025 - RS
##########################################################################
import sys

# Dictionary of databases this script is designed for and the appropriate table to access. If script is run on an unsupported database,
# it will fail.
TMANALOG_DBS = {
    "goldprod": "GOLD_L1A.TMANALOG_SID<SID>",
    "evep12c": "EVE_L1A.TMANALOG",
    "tsisprod": "TSIS_L1A.TMANALOG_SID<SID>",
    "aimprod": "AIM_L1A.TMANALOG_TABLE",
    "ixpeprod": "IXPE_L1A.TMANALOG_SID<SID>",
    "emadev": "EMA_SCHEMA<SID>.TMANALOG"
}

# The L1A schema for each supported DB. Should theoretically be derived from DB name.
DB_SCHEMAS = {
    "aimprod": "AIM_L1A",
    "goldprod": "GOLD_L1A",
    "evep12c": "EVE_L1A",
    "tsisprod": "TSIS_L1A",
    "ixpeprod": "IXPE_L1A",
}

TMAVERAGE_TABLE_NAME    = "TMAVERAGE_SID1"
TMAVERAGE_STATS_NAME    = "TMAVERAGE_STATS"
TABLESPACE_NAME         = "TMAVERAGE_SID1"

TELEMETRYITEMDEFINITION_DBS = {
    "aimprod": "AIM_CT_SC.TELEMETRYITEMDEFINITION",
    "goldprod": "GOLD_CT.TELEMETRYITEMDEFINITION",
    "evep12c": "EVE_CT.TELEMETRYITEMDEFINITION",
    "tsisprod": "TSIS_CT.TELEMETRYITEMDEFINITION",
    "ixpeprod": "IXPE_CT.TELEMETRYITEMDEFINITION",
}

TELEMETRYANALOGCONVERSIONS_DBS = {
    "aimprod": "AIM_CT_SC.TELEMETRYANALOGCONVERSIONS",
    "goldprod": "GOLD_CT.TELEMETRYANALOGCONVERSIONS",
    "evep12c": "EVE_CT.TELEMETRYANALOGCONVERSIONS",
    "tsisprod": "TSIS_CT.TELEMETRYANALOGCONVERSIONS",
    "ixpeprod": "IXPE_CT.TELEMETRYANALOGCONVERSIONS",
}

class OTFDException(Exception):
    """
    Custom exception class for OTFD errors. Includes an array of rows from ONTHEFLYDECOM_ERRORS.
    """

class TMAverageConfigs():
    """
    Class that parses and allows access to TMAverage config parameters. 
    Is a single point through which database and SID-dependent alterations are made.

    Note: TODO: I have realized that the fact that this now needs to be evaluated at runtime means that it will have to be passed
                to the worker threads in some way. I can probably just pass a copy of this class and let it serialize-deserialize it into the process.
    """
    def __init__(self, database: str, sid: str):
        self.tmanalog_table_name = TMANALOG_DBS[database].replace("<SID>", sid)
        self.tmaverage_table_name = f"{DB_SCHEMAS[database]}.{TMAVERAGE_TABLE_NAME}" # TODO: Add exception for emadev
        self.tmaverage_stats_name = f"{DB_SCHEMAS[database]}.{TMAVERAGE_STATS_NAME}" # TODO: Add exception for emadev
        self.telemetry_analog_conversions_name = TELEMETRYANALOGCONVERSIONS_DBS[database]  # TODO: Add exception for emadev
        self.telemetry_item_definitions_name = TELEMETRYITEMDEFINITION_DBS[database]  # TODO: 

# Only gets called directly by bash scripts to set the correct environment variables. 
# Print out the variable assignments, and the bash script will execute them via `exec`.
if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("ERROR: Must take database parameter.")
        exit(1)

    database = sys.argv[1]
    sid = sys.argv[2]

    tmaverage_table_name=TMAVERAGE_TABLE_NAME.upper()
    tmaverage_stats_name=TMAVERAGE_STATS_NAME.upper()
    tablespace_name=TABLESPACE_NAME.upper()

    tmanalog_table_name=TMANALOG_DBS[database].upper()
    schema_name=DB_SCHEMAS[database].upper()

    telemetry_analog_conversions_name=TELEMETRYANALOGCONVERSIONS_DBS[database].upper()
    telemetry_item_definitions_name=TELEMETRYITEMDEFINITION_DBS[database].upper()

    # When this is updated, update the tmaverage_table_check_columns variable as well.
    tmaverage_table_ddl=f"""CREATE TABLE {schema_name}.{tmaverage_table_name}
(
    TMID NUMBER(7,0) NOT NULL ENABLE,
    SCT_VTCW NUMBER(16,0) NOT NULL ENABLE,
    AVERAGE_VALUE FLOAT(126) NOT NULL ENABLE,
    MINIMUM_VALUE FLOAT(126) NOT NULL ENABLE,
    MAXIMUM_VALUE FLOAT(126) NOT NULL ENABLE,
    VALUE_COUNT NUMBER(7,0) NOT NULL ENABLE,
    CONSTRAINT PK_{tmaverage_table_name} PRIMARY KEY (TMID, SCT_VTCW) ENABLE
)
ORGANIZATION INDEX PCTFREE 0 LOGGING
TABLESPACE \\"{tablespace_name}\\";"""
    
    tmaverage_table_check_columns=""

    # When this is updated, update the tmaverage_stats_check_columns variable as well.
    tmaverage_stats_ddl=f"""CREATE TABLE {schema_name}.{tmaverage_stats_name} (
    DATABASE_NAME   VARCHAR2(128),
    START_TIME      TIMESTAMP PRIMARY KEY,
    TIME_RAN        INTERVAL DAY TO SECOND,
    FAILED          NUMBER(1),
    CANCELLED       NUMBER(1),
    ROWS_READ       NUMBER,
    ROWS_RETURNED   NUMBER,
    UNIQUE_CONSTRAINT_NUM NUMBER,
    OTFD_ERROR_NUM  NUMBER,
    ERRORS          CLOB
)
TABLESPACE \\"{tablespace_name}\\";"""
    
    tmaverage_stats_check_columns="ROWS_READ ROWS_RETURNED"

    print(f"export tmaverage_table_name={tmaverage_table_name}")
    print(f"export tmaverage_stats_name={tmaverage_stats_name}")
    print(f"export tablespace_name={tablespace_name}")

    print(f"export tmanalog_table_name={tmanalog_table_name}")
    print(f"export schema_name={schema_name}")

    print(f"export telemetry_analog_conversions_name={telemetry_analog_conversions_name}")
    print(f"export telemetry_item_definitions_name={telemetry_item_definitions_name}")

    print(f"export tmaverage_table_ddl=\"{tmaverage_table_ddl}\"")
    print(f"export tmaverage_stats_ddl=\"{tmaverage_stats_ddl}\"")
    print(f"export tmaverage_table_check_columns=\"{tmaverage_table_check_columns}\"")
    print(f"export tmaverage_stats_check_columns=\"{tmaverage_stats_check_columns}\"")

