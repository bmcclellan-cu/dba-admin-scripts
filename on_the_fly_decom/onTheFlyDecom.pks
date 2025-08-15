/*************************************************************************************************
File:       onTheFlyDecom.pks (package spec)

Purpose:    Defines which methods in the body are callable from the application (end-user).
            See body, onTheFlyDecom.pkb, for documentation.
*************************************************************************************************/
CREATE OR REPLACE PACKAGE EMA_MISC.onTheFlyDecom
AS 

    TYPE string_varray IS VARRAY(3) OF VARCHAR2(200);

    PROCEDURE getVersion; 

    PROCEDURE setOption( optionName IN VARCHAR2,
                        optionValue IN VARCHAR2);

    PROCEDURE clearOption( optionName IN VARCHAR2);

    PROCEDURE selectNumericTlm( systemId_in IN NUMBER,
                                tlmId_in IN NUMBER,
                                startERT_in IN NUMBER,
                                stopERT_in IN NUMBER,
                                startSCT_in IN NUMBER,
                                stopSCT_in IN NUMBER,
                                startAST_in IN NUMBER,
                                stopAST_in IN NUMBER
                                );
    PROCEDURE logError(msg VARCHAR2);

END onTheFlyDecom;
/
