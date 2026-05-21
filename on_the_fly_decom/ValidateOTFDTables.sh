#!/bin/bash
#
# Purpose: Validates TMDecom entries against L0_Packets for OTFD compliance.
#          Warns when startbit+length exceeds packet length and fails when
#          TMDecom length exceeds 64 bits.
#
# Author: Greyson Hall
#
# Created on: May 21, 2026
##########################################################################

usage="Usage: ./ValidateOTFDTables.sh <system_id> <ORACLE_SID>"
example="Example: ./ValidateOTFDTables.sh 19 emadev"

# Process input options
while getopts ":h" option; do
	case $option in
	h)
		echo "$usage"
		echo "$example"
		exit 0
		;;
	\?)
		echo "Error: Invalid option"
		exit 1
		;;
	esac
done

shift $((OPTIND - 1))

# Check arguments
if [ $# -lt 2 ]; then
	echo "$usage"
	echo "$example"
	exit 1
fi

system_id="$1"
export ORACLE_SID="${2,,}"

if ! [[ "$system_id" =~ ^[0-9]+$ ]]; then
	echo "Error: system_id must be a number. Exiting..."
	exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
	echo "Error occurred when checking ORACLE_SID. Exiting..."
	exit 1
elif [ -n "$sid_check" ]; then
	if [ "$sid_check" == "-1" ]; then
		echo "Error, \$ORACLE_SID not set..."
		exit 1
	fi
	echo "Error, provided ORACLE_SID is not open. Exiting..."
	exit 1
fi

# Get mission prefix and schema names
mission_prefix=$("$HOME/common/oracle/GetSchemaName.sh" -v)
if [ $? -ne 0 ] || [ -z "$mission_prefix" ]; then
	echo "$mission_prefix"
	echo "Error occurred while getting mission prefix for $ORACLE_SID. Exiting..."
	exit 1
fi

misc_schema=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ] || [ -z "$misc_schema" ]; then
	echo "$misc_schema"
	echo "Error occurred while getting MISC schema name for $ORACLE_SID. Exiting..."
	exit 1
fi

ct_schema=$("$HOME/common/oracle/GetSchemaName.sh" -c -v)
if [ $? -ne 0 ] || [ -z "$ct_schema" ]; then
	echo "$ct_schema"
	echo "Error occurred while getting CT schema name for $ORACLE_SID. Exiting..."
	exit 1
fi

if [ "$ORACLE_SID" == "ixpeprod" ]; then
    tmdecom_name="$misc_schema.TMDecom"
    l0_packets_name="IXPE_L0.L0_Packets_SID$system_id"
    decom_identifier="APID"
elif [ "$ORACLE_SID" == "emadev" ]; then
    padded_sid=$(printf %02d "$system_id")
    tmdecom_name="EMA_SCHEMA$padded_sid.TMDecom"
    l0_packets_name="EMA_SCHEMA$padded_sid.L0_Packets"
    decom_identifier="DMID"
elif [ "$ORACLE_SID" == "neosd19" ]; then
    padded_sid=$(printf %02d "$system_id")
    tmdecom_name="NEOS_SCHEMA$padded_sid.TMDecom"
    l0_packets_name="NEOS_SCHEMA$padded_sid.L0_Packets"
    decom_identifier="DMID"
else
    echo "ERROR: Database $ORACLE_SID is not supported by OnTheFlyDecom (supported: ixpeprod,emadev,neosd19). Exiting..."
    exit 1
fi

length_gt_64_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    set pagesize 0
    set linesize 200

    SELECT tlmid || '|' || $decom_identifier || '|' || length
    FROM $tmdecom_name
    WHERE length > 64
    GROUP BY tlmid, $decom_identifier, length
    ORDER BY tlmid, $decom_identifier;
EOD
)
if [ $? -ne 0 ]; then
    echo "$length_gt_64_check"
    echo "An error occurred while checking if any decom maps contained LENGTH > 64. Exiting..."
    exit 1
fi

if [ -n "$length_gt_64_check" ]; then
    echo "FAILURE:  TMDecom Length Validation Failed:"
    echo "          TMDecom length values must be <= 64 bits. See below summary of affected TLMIDs:"
				
    while IFS= read -r line; do
        IFS='|' read -r tlmid dmid length <<< "$line"
        echo "    TLMID $tlmid ($decom_identifier $dmid): Decom map length $length exceeds 64 bits."
    done <<< "$length_gt_64_check"
else
    echo "SUCCESS: No decom maps with length > 64 bits."
fi

echo "Scanning all packets for packets that are too small for OTFD decom maps. This may take some time..."

packet_length_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    set pagesize 0
    set linesize 200

    SELECT d.tlmid || '|' || d.$decom_identifier || '|' || d.startbit || '|' || d.length || '|' || min(p.length) || '|' || count(*)
    FROM $tmdecom_name d
    JOIN $l0_packets_name p
    ON p.$decom_identifier = d.$decom_identifier
    WHERE p.length < (d.startbit + d.length)
    GROUP BY d.tlmid, d.$decom_identifier, d.startbit, d.length
    ORDER BY d.tlmid, d.$decom_identifier;
EOD
)
if [ $? -ne 0 ]; then
    echo "$packet_length_check"
    echo "An error occurred while checking if any packets are too small for their respective decom maps. Exiting..."
    exit 1
fi


if [ -n "$packet_length_check" ]; then
    echo "WARNING: Packet Length Validation Failed:"
    echo "      This violation will not cause OTFD to fail outright, but OTFD will skip packets that do not comply. "
    echo "      Please validate that no invalid TMDecom entries or corrupt packets are present."


    while IFS= read -r line; do
        IFS='|' read -r tlmid dmid startbit length min_packet_length packets_affected <<< "$line"
        echo "    TLMID $tlmid ($decom_identifier $dmid): Startbit $startbit and length $length out of range of min packet length $min_packet_length. $packets_affected packets affected."
    done <<< "$packet_length_check"
else
    echo "SUCCESS: No out-of-range decom maps found."
fi

echo "Script completed!"