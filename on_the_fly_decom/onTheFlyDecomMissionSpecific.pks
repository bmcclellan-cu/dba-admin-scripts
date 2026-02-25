/*************************************************************************************************
File:       onTheFlyDecomMissionSpecific.pks (package spec)

Purpose:    Spec for mission-specific code for on-the-fly decom, called exclusively by the generic
            package, and is not intended to be directly used by the end user.

Methods:
    getVersion                  - Returns the version of the mission-specific package. 
    setOption                   - Sets mission-specific options.
    clearOption                 - Clears mission-specific options.
    getOptionsHelp              - Lists available options and valid inputs.
    getTableName                - Gets mission-specific table name based on SID and type
                                  passed. 0: L0_Packets, 1: TMAnalog, 2: TMDiscrete, 
                                  3: TelemetryStorageLocation, 4: TMDecom.
    getTimeColumnsL0            - Gets the L0 time columns to query by, returns an array of
                                  3 columns (SCT, ERT, ASCT).
    getTimeColumnsL1            - Gets the L1 time columns to query by, returns an array of
                                  3 columns (SCT, ERT, ASCT).
    getDecomIdentifier          - Gets the column name to identify decom maps. EMA uses dmid, 
                                  standard is apid.
                                  Initially required to accommodate EMA.
    addToL0Query                - Append any additional query restrictions at the end of an L0 query
                                  used by IXPE to query by filename.
    addToL1Query                - Append any additional query restrictions at the end of an L1 query.
    getDefinitionStartStopTimes - Determine what column to use to query TSL and TMDecom, and return the
                                  appropriate start and stop times. This is required to allow for querying
                                  by multiple time columns at once, as well as differences in what timestamp
                                  is used by different missions. EMA primarily uses ASCT, while the standard
                                  is SCT, with a fallback of SCT. Also acts as input validation, and unsupported
                                  queries will fail here.

Usage: 
  1. In sqlplus:
     @<full_path>/onTheFlyDecomMissionSpecific.pks  -- compile the package spec

     @<full_path>/onTheFlyDecomMissionSpecificXXXX.pkb     -- compile the package body  

*************************************************************************************************/
CREATE OR REPLACE PACKAGE onTheFlyDecomMissionSpecific
AS 
    TYPE curType IS REF CURSOR; -- Weakly typed cursor

    FUNCTION getVersion RETURN VARCHAR2;
    FUNCTION setOption(optionName VARCHAR2, optionValue VARCHAR2) RETURN NUMBER;
    FUNCTION clearOption(optionName VARCHAR2) RETURN NUMBER;
    FUNCTION getOptionsHelp RETURN VARCHAR2;

    FUNCTION getTableName(type_in IN NUMBER, systemId_in IN NUMBER) RETURN VARCHAR2;
    FUNCTION getTimeColumnsL0 RETURN onTheFlyDecom.string_varray;
    FUNCTION getTimeColumnsL1 RETURN onTheFlyDecom.string_varray;
    FUNCTION getDecomIdentifier RETURN VARCHAR2;

    PROCEDURE addToL0Query(exeString IN OUT VARCHAR2, systemId_in IN NUMBER);
    PROCEDURE addToL1Query(exeString IN OUT VARCHAR2, systemId_in IN NUMBER);

    FUNCTION getDefinitionStartStopTimes(
        systemId_in IN NUMBER,
        startSCT_in IN NUMBER,
        stopSCT_in IN NUMBER,
        startERT_in IN NUMBER,
        stopERT_in IN NUMBER,
        startASCT_in IN NUMBER,
        stopASCT_in IN NUMBER,
        definitionStartTime OUT NUMBER,
        definitionStopTime OUT NUMBER,
        definitionColumn OUT NUMBER
    ) RETURN NUMBER;

END onTheFlyDecomMissionSpecific;
/
