/*************************************************************************************************
File:       onTheFlyDecomMissionSpecific.pks (package spec)

Purpose:    Spec for mission-specific code for on-the-fly decom, called by the core package.
  
Usage: 
  1. In sqlplus:
     @<full_path>/onTheFlyDecomMissionSpecific.pks  -- compile the package spec

     @<full_path>/onTheFlyDecomEMM.pkb              -- compile the package body
     or:
     @<full_path>/onTheFlyDecomIXPE.pkb             -- compile the package body
                 
*************************************************************************************************/
CREATE OR REPLACE PACKAGE onTheFlyDecomMissionSpecific
AS 


FUNCTION  getVersion RETURN VARCHAR2;
FUNCTION  setOption( optionName VARCHAR2, optionValue VARCHAR2) RETURN NUMBER;
FUNCTION  clearOption( optionName VARCHAR2) RETURN NUMBER;
FUNCTION  getOptionsHelp RETURN VARCHAR2;
FUNCTION  getTableName( type_in     IN NUMBER,
                        systemId_in IN NUMBER)
                        RETURN VARCHAR2;
FUNCTION  getL0PacketsSCTColName RETURN VARCHAR2;
PROCEDURE addToL0Query( exeString IN OUT VARCHAR2, systemId_in IN NUMBER);
PROCEDURE addToL1Query( exeString IN OUT VARCHAR2, systemId_in IN NUMBER);
FUNCTION  getDefinitionStartStopTimes( systemId_in IN NUMBER,
                                       startERT_in IN NUMBER,
                                       stopERT_in  IN NUMBER,
				       startSCT_in IN NUMBER,
				       stopSCT_in  IN NUMBER,
	                               definitionStartTime OUT NUMBER,
				       definitionStopTime OUT NUMBER) RETURN NUMBER;

END onTheFlyDecomMissionSpecific;
/
