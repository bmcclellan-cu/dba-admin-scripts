# Purpose: This python script stores all of the static variables for TMAverage, and
#          generates bash in order to allows the relevant bash scripts to access the
#          configuration information.
# 
# 
# Notes:   The configuration details are database-dependent, and the script needs to be
#          passed the database name in order to correctly output the appropriate bash.
# 
#          For more detailed documentation go to https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/228214621/TMAverage+-+Usage+Performance
# 
# IMPORTANT: The ConfigureTMAverageEnvironment.sh script runs checks to make sure the DDL is 
#            up-to-date by checking the most recent DDL changes, which are indicated by the 
#            tmaverage_table_check_columns and tmaverage_stats_check_columns variables. These
#            should be update any time the DDL is updated in order to keep the check up-to-date.
# 
# Usage:
#          python TMAverageHelpers.py [ <database> <system_id | list> ] OR [ version ]
# 
# Examples:
#          python TMAverageHelpers.py ixpeprod 1
#          python TMAverageHelpers.py version
#          python TMAverageHelpers.py emadev list
# 
# Author: Robert Schmidt
# Created: August 25th, 2025
# Last Modified: November 17th, 2025 - RS
##########################################################################
import sys
import os

TMAVERAGE_VERSION = "3.1"

# Dictionary of databases and SIDs that the script is designed for. Any attempt 
# to run any TMAverage scripts on SIDs or databases not listed here will fail and 
# display an appropriate error message.
SUPPORTED_DB_SIDS = {
    "goldprod": [1],
    "evep12c": [1],
    "tsisprod": [1],
    "aimprod": [1],
    "ixpeprod": [1],
    "emadev": [19, 20],
}

# The schema where data is primarily stored (typically L1A), and where TMAverage tables
# are located.
DATA_SCHEMAS = {
    "aimprod": "AIM_L1A",
    "goldprod": "GOLD_L1A",
    "evep12c": "EVE_L1A",
    "tsisprod": "TSIS_L1A",
    "ixpeprod": "IXPE_L1A",
    "emadev": "EMA_SCHEMA<SID>"  # (EMA) Data is separated by SID/Schema
}

# Primary metadata schemas.
CT_SCHEMAS = {
    "aimprod": "AIM_CT_SC",
    "goldprod": "GOLD_CT",
    "evep12c": "EVE_CT",
    "tsisprod": "TSIS_CT",
    "ixpeprod": "IXPE_CT",
    "emadev": "EMA_CT",
}

# The location and name of TMAnalog. Depends on SID.
TMANALOG_DBS = {
    "evep12c":  "<DATA_SCHEMA>.TMANALOG",
    "emadev":   "<DATA_SCHEMA>.TMANALOG",
    "aimprod":  "<DATA_SCHEMA>.TMANALOG_TABLE",
    "*":        "<DATA_SCHEMA>.TMANALOG_SID<SID>",
}

# The non-schema prefixed name of the TMAverage table. Separated out in order to derive
# the primary key name from it effectively without needing to truncate the schema name from it.
TMAVERAGE_TAB_NAME = {
    "emadev":   "TMAVERAGE",
    "*":        "TMAVERAGE_SID<SID>"
}

# Full TMAverage table name.
TMAVERAGE_TABLE_NAME = "<DATA_SCHEMA>.<TMAVERAGE_TAB_NAME>"

# Full TMAverage stats name.
TMAVERAGE_STATS_NAME = "<DATA_SCHEMA>.TMAVERAGE_STATS"

# Name of the tablespace where TMAverage and TMAverage_Stats are stored.
TABLESPACE_NAME = {
    "emadev":   "<DATA_SCHEMA>_TMAVERAGE",
    "*":        "TMAVERAGE_SID<SID>",
}

# TelemetryItemDefinition stores a list of all TMIDs, as well as their datatype.
TELEMETRYITEMDEFINITION_DBS = {
    "*":  "<CT_SCHEMA>.TELEMETRYITEMDEFINITION",
}

# Defines polynomial conversions of the raw data into EU (Engineering Units). 
TELEMETRYANALOGCONVERSIONS_DBS = {
    "emadev":   "<DATA_SCHEMA>.TMANALOGCONVERSIONS",   # (EMA) Separate analog conversions for each SID.
    "*":        "<CT_SCHEMA>.TELEMETRYANALOGCONVERSIONS",
}

# Contains the column to use for time-variant analog conversions. If conversions are not time-variant, 
# contain an empty string.
TIME_VARIANT_ANALOG_CONVERSION = {
    "emadev":   "true",
    "*":        ""
}

# What time column to use based on database. EMA is using ASCT (Adjusted time) rather than SCT or ERT.
# This is separated from OTFD_TIME_COLUMN because the table column name is SCT_VTCW rather than SCT.
TABLE_TIME_COLUMN = {
    "emadev": "ASCT",
    "*": "SCT_VTCW"
}

OTFD_TIME_COLUMN = {
    "emadev": "ASCT",
    "*": "SCT"
}

# The DDL to create the TMAverage table. This requires TMAVERAGE_TAB_NAME to derive
# the primary key constraint name so that duplicates indexes are not created during testing
# When this is updated, update the tmaverage_table_check_columns variable as well.
# Note: This is ONLY executed in ConfigureTMAverageEnvironment.sh, and the escape characters (\\) 
#       present to allow for the bash variable assignment to succeed without interpreting it literally.
TMAVERAGE_TABLE_DDL=f"""CREATE TABLE <TMAVERAGE_TABLE_NAME>
(
    TMID NUMBER(7,0) NOT NULL ENABLE,
    <TABLE_TIME_COLUMN> NUMBER(16,0) NOT NULL ENABLE,
    AVERAGE_VALUE FLOAT(126) NOT NULL ENABLE,
    MINIMUM_VALUE FLOAT(126) NOT NULL ENABLE,
    MAXIMUM_VALUE FLOAT(126) NOT NULL ENABLE,
    VALUE_COUNT NUMBER(7,0) NOT NULL ENABLE,
    CONSTRAINT PK_<TMAVERAGE_TAB_NAME> PRIMARY KEY (TMID, <TABLE_TIME_COLUMN>) ENABLE
)
ORGANIZATION INDEX PCTFREE 0 LOGGING
TABLESPACE \\"<TABLESPACE_NAME>\\";"""
# Should always check that the loaded DDL has the correct time column set.
TMAVERAGE_TABLE_CHECK_COLUMNS="<TABLE_TIME_COLUMN>"

# When this is updated, update the tmaverage_stats_check_columns variable as well.
TMAVERAGE_STATS_DDL=f"""CREATE TABLE <TMAVERAGE_STATS_NAME> (
    DATABASE_NAME   VARCHAR2(128),
    START_TIME      TIMESTAMP PRIMARY KEY,
    RUN_PARAMS          VARCHAR(200),
    TIME_RAN        INTERVAL DAY TO SECOND,
    FAILED          NUMBER(1),
    CANCELLED       NUMBER(1),
    ROWS_READ       NUMBER,
    ROWS_RETURNED   NUMBER,
    UNIQUE_CONSTRAINT_NUM NUMBER,
    OTFD_ERROR_NUM  NUMBER,
    ERRORS          CLOB
)
TABLESPACE \\"<TABLESPACE_NAME>\\";"""
TMAVERAGE_STATS_CHECK_COLUMNS="ROWS_READ ROWS_RETURNED RUN_PARAMS"

class OTFDException(Exception):
    """
    Custom exception class for OTFD errors. Includes an array of rows from ONTHEFLYDECOM_ERRORS.
    """

class TMAverageConfigs():
    """
    Class that parses and allows access to TMAverage config parameters. Each instance variable in this class
    is used to substitute out the markers demarcated by <VARIABLE_NAME>, allowing for updates to a single 
    parameter to cascade and update all dependent parts. For example, if a config contains the string 
    "TEST_SCHEMA<SID>", then if the SID variable exists when that config is parsed, then the <SID> marker
    gets replaced by the value of the variable.

    Note: This is necessary both so that there is a standard way to set the configs, but also so that
          this data can be passed to the worker threads in a convenient manner. Previously they just 
          accessed the constants in TMAverageHelpers.py, but now the configuration needs to be evaluated at 
          runtime to handle multiple possible SIDs, and this allows for a single object to be passed to 
          the worker threads.
    """
    def __init__(self, database: str, sid: str):
        # Check that database and sid are supported
        if not (database in SUPPORTED_DB_SIDS.keys() and int(sid) in SUPPORTED_DB_SIDS[database]):
            raise ValueError(f"ERROR: Database {database} SID {sid} is not supported by TMAverage.\n"
                             "Supported databases are: {str(tuple(SUPPORTED_DB_SIDS.keys()))}")
        
        self.VERSION = TMAVERAGE_VERSION

        self.SID = sid
        self.DATABASE = database

        self.DATA_SCHEMA = self.parse_config(DATA_SCHEMAS, database)
        self.CT_SCHEMA = self.parse_config(CT_SCHEMAS, database)

        self.TMAVERAGE_TAB_NAME = self.parse_config(TMAVERAGE_TAB_NAME, database)
        self.TMANALOG_TABLE_NAME = self.parse_config(TMANALOG_DBS, database)
        self.TMAVERAGE_TABLE_NAME = self.parse_config(TMAVERAGE_TABLE_NAME, database)
        self.TMAVERAGE_STATS_NAME = self.parse_config(TMAVERAGE_STATS_NAME, database)

        self.TABLESPACE_NAME = self.parse_config(TABLESPACE_NAME, database)

        self.TELEMETRY_ANALOG_CONVERSIONS_NAME = self.parse_config(TELEMETRYANALOGCONVERSIONS_DBS, database)
        self.TELEMETRY_ITEM_DEFINITIONS_NAME = self.parse_config(TELEMETRYITEMDEFINITION_DBS, database)
        self.TIME_VARIANT_ANALOG_CONVERSION = self.parse_config(TIME_VARIANT_ANALOG_CONVERSION, database)

        self.TABLE_TIME_COLUMN = self.parse_config(TABLE_TIME_COLUMN, database)
        self.OTFD_TIME_COLUMN = self.parse_config(OTFD_TIME_COLUMN, database)
        
        self.TMAVERAGE_TABLE_DDL = self.parse_config(TMAVERAGE_TABLE_DDL, None)
        self.TMAVERAGE_TABLE_CHECK_COLUMNS = self.parse_config(TMAVERAGE_TABLE_CHECK_COLUMNS, None)

        self.TMAVERAGE_STATS_DDL = self.parse_config(TMAVERAGE_STATS_DDL, None)
        self.TMAVERAGE_STATS_CHECK_COLUMNS = self.parse_config(TMAVERAGE_STATS_CHECK_COLUMNS, None)

    def parse_config(self, static_config, config_key: str):
        """
        Uses the instance variables already defined to replace placeholders in a newly added config item dynamically.
        """
        if isinstance(static_config, dict):
            try:
                config_item = static_config[config_key]
            except KeyError:
                try:
                    config_item = static_config["*"] # Try to get default value instead.
                except:
                    raise ValueError(f"ERROR: Config key {config_key} not supported. Database/SID passed is not valid.")
        elif isinstance(static_config, str):
            config_item = static_config
        else:
            raise ValueError("ERROR: Config must be of type dict or string")
        
        # Gets the configs that were populated so far.
        attributes = vars(self)

        for key in attributes.keys():
            config_item = config_item.replace(f"<{key}>", str(attributes[key]))
        
        if "<" in config_item and ">" in config_item:
            print("WARNING: Unreplaced substitution present in config: ", file=sys.stderr)
            print(config_item, file=sys.stderr)
        
        return config_item

# Gets called directly by bash scripts to set the correct environment variables. 
# Print out the variable assignments, and the bash script will execute them via `exec`.
if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "version":
        print(TMAVERAGE_VERSION)
        exit(0)
    if len(sys.argv) != 3:
        print("ERROR: Must take database and SystemID parameter.")
        exit(1)

    database = sys.argv[1]
    sid = sys.argv[2]

    if sid == "list":
        try:
            print(" ".join([str(x) for x in SUPPORTED_DB_SIDS[database]]))
            exit(0)
        except KeyError:
            print(f"Database {database} is not supported by TMAverage. Exiting...")
            exit(1)
    try:
        int(sid)
    except ValueError:
        raise ValueError("SystemID must be an integer")

    conf=TMAverageConfigs(database, sid)
    attributes = vars(conf)  # Gets dict of variables and their values

    for attribute in attributes:
        print(f"export {attribute.lower()}=\"{attributes[attribute]}\"")