/*************************************************************************************************
File:       onTheFlyDecom.pks (package spec)

Purpose:    Defines which methods in the body are callable from the application (end-user).
            See body, onTheFlyDecom.pkb, for documentation.
*************************************************************************************************/
CREATE OR REPLACE PACKAGE onTheFlyDecom
AS 
    -- Note: string_varray is used both in the mission-specific code and the generic code, so it is only defined in the package 
    -- here and referenced as ONTHEFLYDECOM.string_varray in the mission-specific code due to compilation issues.
    TYPE string_varray IS VARRAY(3) OF VARCHAR2(200);

    -- Make a type for input to prepareDebugSQL.
    TYPE name_value_t IS TABLE OF VARCHAR2(64) INDEX BY VARCHAR2(64);


    PROCEDURE getVersion; 

    PROCEDURE setOption( optionName IN VARCHAR2,
                        optionValue IN VARCHAR2);

    PROCEDURE clearOption( optionName IN VARCHAR2);

    -- While the timestamps are all optional and have defaults for the procedure call, specifying none of 
    -- them will throw a definition_error due to missing inputs and warn the user.
    PROCEDURE selectNumericTlm( systemId_in IN NUMBER,
                                tlmId_in IN NUMBER,
                                startERT_in IN NUMBER DEFAULT -1,
                                stopERT_in IN NUMBER DEFAULT -1,
                                startSCT_in IN NUMBER DEFAULT -1,
                                stopSCT_in IN NUMBER DEFAULT -1,
                                startASCT_in IN NUMBER DEFAULT -1,
                                stopASCT_in IN NUMBER DEFAULT -1
                                );
    
    FUNCTION prepareDebugSQL(query_str IN VARCHAR2, name_value IN name_value_t) RETURN VARCHAR2;
    
    PROCEDURE logOTFD(msg VARCHAR2, priority NUMBER);

END onTheFlyDecom;
/
