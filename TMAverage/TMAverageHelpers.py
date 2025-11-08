import sys


# Dictionary of databases this script is designed for and the appropriate table to access. If script is run on an unsupported database,
# it will fail.
TMANALOG_DBS = {
    "goldprod": "GOLD_L1A.TMANALOG_SID1",
    "evep12c": "EVE_L1A.TMANALOG",
    "tsisprod": "TSIS_L1A.TMANALOG_SID1",
    "aimprod": "AIM_L1A.TMANALOG_TABLE",
    "ixpeprod": "IXPE_L1A.TMANALOG_SID1",
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

# Only gets called directly by bash scripts to set the correct environment variables. 
# Print out the variable assignments, and the bash script will execute them via `exec`.
if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("ERROR: Must take database parameter.")
        exit(1)

    database = sys.argv[1]

    print(f"export tmaverage_table_name={TMAVERAGE_TABLE_NAME.upper()}")
    print(f"export tmaverage_stats_name={TMAVERAGE_STATS_NAME.upper()}")
    print(f"export tablespace_name={TABLESPACE_NAME.upper()}")

    print(f"export tmanalog_table_name={TMANALOG_DBS[database].upper()}")
    print(f"export schema_name={DB_SCHEMAS[database].upper()}")

    print(f"export telemetry_analog_conversions_name={TELEMETRYANALOGCONVERSIONS_DBS[database].upper()}")
    print(f"export telemetry_item_definitions_name={TELEMETRYITEMDEFINITION_DBS[database].upper()}")