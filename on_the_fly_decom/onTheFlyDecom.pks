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

    PROCEDURE selectNumericTlm( systemId_in IN NUMBER,
                                tlmId_in IN NUMBER,
                                startSCT_in IN NUMBER,
                                stopSCT_in IN NUMBER,
                                startERT_in IN NUMBER,
                                stopERT_in IN NUMBER,
                                startASCT_in IN NUMBER,
                                stopASCT_in IN NUMBER
                                );
    
    FUNCTION prepareDebugSQL(query_str IN VARCHAR2, name_value IN name_value_t) RETURN VARCHAR2;
    
    PROCEDURE logOTFD(msg VARCHAR2, priority NUMBER);

END onTheFlyDecom;
/
