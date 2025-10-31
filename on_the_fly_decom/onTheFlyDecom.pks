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
    PROCEDURE logError(msg VARCHAR2);

END onTheFlyDecom;
/
