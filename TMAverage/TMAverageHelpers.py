


# Dictionary of databases this script is designed for and the appropriate table to access. If script is run on an unsupported database,
# it will fail.
TMANALOG_DBS = {
    "goldprod": "TMANALOG_SID1",
    "evep12c": "TMANALOG",
    "aimprod": "AIM_L1A.TMANALOG_TABLE",
    "tsisprod": "TMANALOG_SID1",
    "ixpeprod": "TMANALOG_SID1",
}

# The L1A schema for each supported DB. Should theoretically be derived from DB name.
DB_SCHEMAS = {
    "aimprod": "AIM_L1A",
    "goldprod": "GOLD_L1A",
    "evep12c": "EVE_L1A",
    "tsisprod": "TSIS_L1A",
    "ixpeprod": "IXPE_L1A",
}

TMAVERAGE_TABLE_NAME = "TMAVERAGE_SID1"
TMAVERAGE_STATS_NAME = "TMAVERAGE_STATS"

TELEMETRYITEMDEFINITION_DBS = {
    "aimprod": "AIM_CT_SC.TelemetryItemDefinition",
    "goldprod": "TelemetryItemDefinition",
    "evep12c": "TelemetryItemDefinition",
    "tsisprod": "TelemetryItemDefinition",
    "ixpeprod": "TelemetryItemDefinition",
}

TELEMETRYANALOGCONVERSIONS_DBS = {
    "aimprod": "AIM_CT_SC.TelemetryAnalogConversions",
    "goldprod": "TelemetryAnalogConversions",
    "evep12c": "TelemetryAnalogConversions",
    "tsisprod": "TelemetryAnalogConversions",
    "ixpeprod": "TelemetryAnalogConversions",
}

class OTFDException(Exception):
    """
    Custom exception class for OTFD errors. Includes an array of rows from ONTHEFLYDECOM_ERRORS.
    """