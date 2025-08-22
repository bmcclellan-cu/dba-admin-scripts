# System imports
import sys
import logging
import math
import traceback
import multiprocessing
import argparse
import csv
import os
import datetime
from functools import partial

# Third-party imports
import oracledb
import numpy as np

# Project imports
from TMAverageHelpers import OTFDException

# Global variable for the database connection (variable exists independently for each process and is persistent as long as the process exists.)
db_connection: oracledb.Connection = None

# Global variable to track if the thread is ready to function. For example, if it did not successfully initialize,
# the thread will be in a failed state, and not even attempt to do any processing. The same occurs if the script is not able to access
# the necessary tables (indicating permission or database access issues).
failed = True

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

ONTHEFLYDECOM_DBS = {
    "ixpeprod": "IXPE_MISC.ONTHEFLYDECOM",
}


def get_value_from_file(file_path):
    """
    Helper script that attempts to retrieve data from a path relative to the script directory. Intended for use to retrieve
    the username and password from the script's location.
    """
    # Get the directory where the script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # Combine the script's directory with the relative file path
    full_file_path = os.path.join(script_dir, file_path)

    try:
        # Open the file to read the password
        with open(full_file_path, "r") as file:
            password = (
                file.readline().strip()
            )  # Read the first line and strip whitespace

        if not password:
            print(
                f"Warning: The file {full_file_path} is empty or contains only whitespace."
            )
            return None

        print(f"Value successfully read from: {full_file_path}")
        return password

    except FileNotFoundError:
        print(f"Error: The file {full_file_path} was not found.")
        return None
    except PermissionError:
        print(f"Error: Permission denied when accessing the file {full_file_path}.")
        return None
    except Exception as e:
        print(f"An error occurred while reading the password: {e}")
        return None

def update_tmaverage_stats(
        cursor: oracledb.Cursor,
        database: str,
        start_time: datetime.datetime,
        time_duration: datetime.timedelta = None,
        failed: bool = None,
        cancelled: bool = None,
        ingested: int = None,
        inserted: int = None,
        unique_constraint_num: int = None,
        errors: list[str] = None,
):
    """
    Updates the TMAVERAGE_STATS table. This is ran once during script initialization, and once the script completes.
    The second time it is ran, it updates the record created during the first execution.
    """
    logger = multiprocessing.get_logger()
        
    # Convert errors list to CLOB-compatible string
    errors_clob = '\n'.join(errors) if errors else None
    
    # Convert timedelta to Oracle INTERVAL DAY TO SECOND format
    interval_value = None
    if time_duration is not None:
        total_seconds = int(time_duration.total_seconds())
        days = total_seconds // 86400
        remaining_seconds = total_seconds % 86400
        hours = remaining_seconds // 3600
        remaining_seconds %= 3600
        minutes = remaining_seconds // 60
        seconds = remaining_seconds % 60
        interval_value = f"{days} {hours:02d}:{minutes:02d}:{seconds:02d}"
    
    failed = 1 if failed else 0
    cancelled = 1 if cancelled else 0
    
    # Use MERGE statement to INSERT if not exists, UPDATE if exists
    sql = f"""MERGE INTO {DB_SCHEMAS[database]}.{TMAVERAGE_STATS_NAME} target
             USING (SELECT :1 as DATABASE_NAME, :2 as START_TIME, :3 as TIME_RAN, :4 as FAILED, :5 as CANCELLED,
                           :6 as INGESTED, :7 as INSERTED, :8 as UNIQUE_CONSTRAINT_NUM, :9 as ERRORS FROM dual) source
             ON (target.DATABASE_NAME = source.DATABASE_NAME AND target.START_TIME = source.START_TIME)
             WHEN MATCHED THEN
                 UPDATE SET 
                     TIME_RAN  = source.TIME_RAN,
                     FAILED    = source.FAILED,
                     CANCELLED = source.CANCELLED,
                     INGESTED  = source.INGESTED,
                     INSERTED  = source.INSERTED,
                     UNIQUE_CONSTRAINT_NUM = source.UNIQUE_CONSTRAINT_NUM,
                     ERRORS    = source.ERRORS
             WHEN NOT MATCHED THEN
                 INSERT (DATABASE_NAME, START_TIME, TIME_RAN, FAILED, CANCELLED, INGESTED, INSERTED, UNIQUE_CONSTRAINT_NUM, ERRORS)
                 VALUES (source.DATABASE_NAME, source.START_TIME, source.TIME_RAN, source.FAILED, source.CANCELLED,
                        source.INGESTED, source.INSERTED, source.UNIQUE_CONSTRAINT_NUM, source.ERRORS)"""
    
    try:
        cursor.execute(sql, [
            database,
            start_time,
            interval_value,
            failed,
            cancelled,
            ingested,
            inserted,
            unique_constraint_num,
            errors_clob
        ])
        cursor.connection.commit()
        logger.info(f"Successfully updated TMAVERAGE_STATS for database {database}")
    except oracledb.DatabaseError as error:
        logger.exception(f"Error updating TMAVERAGE_STATS: {error}")
        cursor.connection.rollback()
        raise error


def setup_logger(log_file: str):
    """
    Configures and returns a logger for use in the main thread, writing both to a file as well as standard out.
    """
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.INFO)

    # Clear existing handlers
    logger.handlers.clear()

    # File handler. File logging includes timestamps.
    file_handler = logging.FileHandler(log_file)
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    )

    # Console handler (stdout). Console logging excludes timestamps.
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(logging.Formatter(""))

    logger.addHandler(file_handler)
    logger.addHandler(console_handler)

    return logger


def init_worker(
    database: str,
    username: str,
    password: str,
    connection_string: str,
):
    """
    An initialization function that is called by each worker in the multiprocessing pool to connect to the database, as
    well as configure logging, both of which are persistent per-thread, and will be re-used by each task that the thread
    is given. If this process fails for any reason, the failed status will not be updated and the thread will remain in
    a 'failed' state, and will not accept any new work.
    """
    global db_connection
    global failed
    # The returned object is modifiable, and the modified object will be returned any time 'multiprocessing.get_logger' is called.
    logger = multiprocessing.get_logger()
    logger.setLevel(logging.INFO)

    # Create a per-process log file based on the time the process is initialized and the unique thread id.
    proc = multiprocessing.current_process()
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    log_file = f"/tmp/TMAverageLogs/{database}/TMAverage-{timestamp}-{proc.name}.log"

    # Clear and add handler
    logger.handlers.clear()
    fh = logging.FileHandler(log_file)
    formatter = logging.Formatter("%(asctime)s %(levelname)s - %(message)s")
    fh.setFormatter(formatter)
    logger.addHandler(fh)

    logger.info("Logger has been set")

    # Setup database connection for the thread.
    logger.info(
        f"Connecting to database using username: {username} and connection string {connection_string}."
    )
    db_connection = oracledb.connect(
        user=username, password=password, dsn=connection_string
    )
    failed = False  # Only set global variable if successfully initialized.=


def fail_worker():
    """
    This function sets a worker into the failed state and reports it.
    """
    global failed
    global db_connection
    logger = multiprocessing.get_logger()
    logger.critical(
        "This thread is now in a failed state. Any future tasks assigned to it "
        "will be dropped immediately."
    )
    failed = True
    db_connection.close()


def fetch_values_by_time_range(
    database: str,
    tmid,
    start_time_gps: int,
    end_time_gps: int,
):
    """
    Fetches all values for a given SCT time period from the appropriate L1A table, and returns a tuple
    containing the total number of results, the actual data of the results, as well as the corresponding
    'bucket_id's, which signify which 5-minute chunk any given value corresponds to. This 3rd value is used
    by numpy to quickly filter the data for the respective time chunk.
    """
    global db_connection
    global failed
    logger = multiprocessing.get_logger()

    # This exists because AIMPROD's primary key index has a 1st column of SID,
    # and excluding it causes the optimizer not to use the index at all.
    sid_clause = ""
    if database[:3] == "aim":
        sid_clause = " SID=1 AND "

    sql = f"""
        SELECT SCT_VTCW, VALUE FROM {TMANALOG_DBS[database]} WHERE 
        {sid_clause}
        (tmid = {tmid}) AND 
        (SCT_VTCW >= {start_time_gps} AND (SCT_VTCW < {end_time_gps}))
    """

    logger.debug(sql)

    cursor = db_connection.cursor()
    try:
        results = cursor.execute(sql).fetchall()
        cursor.close()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            # If the table is inaccessible, processing is presumed to have failed catastrophically,
            # so the thread is set to a failed state.
            logger.exception(
                "ORA-00942: table or view does not exist. \n"
                "Either the following tables do not exist or the script does not have access to them. \n"
                "Ensure that the script has the following permissions:  \n"
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), \n"
                "TelemetryAnalogConversions(SELECT), TMAverage(ALL).\n"
            )
            raise error
        else:
            logger.exception("An unknown exception occurred.")
            raise error
    except Exception as error:
        logger.exception("An unknown exception occurred.")
        raise error

    # Gets length of the python array returned by oracle to pre-allocate the numpy array
    # this is assumed to be faster because numpy fully re-allocates the array upon append,
    # but the difference is likely marginal.
    results_len = len(results)  # Pre-allocates numpy array to prevent appends.
    results_values = np.zeros((results_len), dtype=np.float128)
    results_bucket_ids = np.zeros((results_len), dtype=np.uintc)

    logger.info(f"Retrieved {results_len} records. Ingesting...")

    row_number = 0
    for row in results:
        # Calculate the bucket_id for the specific row. This is used to determine
        # which 5-minute chunk the corresponding value belongs to, and is used in a
        # numpy bit mask later on to filter efficiently.
        time = row[0]
        timeDelta = time - start_time_gps
        results_bucket_ids[row_number] = int(math.trunc(timeDelta / 300000000))

        results_values[row_number] = row[1]
        row_number += 1

    return (
        results_len,
        results_values,
        results_bucket_ids,
    )


# This function assumes that the on-the-fly-decom package has been loaded on the database. This is checked by the wrapper
# script.
# Returns a tuple of (results_len, results_values, and results_bucket_ids)
def fetch_otfd_values_by_time_range(
    tmid: int,
    start_time_gps: int,
    end_time_gps: int,
):
    """
    Fetches all values for a given SCT time period using OTFD, and returns a tuple containing the total
    number of results, the actual data of the results, as well as the corresponding 'bucket_id's, which signify
    which 5-minute chunk any given value corresponds to. This 3rd value is used by numpy to quickly
    filter the data for the respective time chunk.
    """
    global db_connection
    global failed
    logger = multiprocessing.get_logger()

    cursor = db_connection.cursor()
    try:
        # Call PSQL function to retrieve data (SID (always 1), tmid, START_ERT (unused), END_ERT (unused), START_GPS, END_GPS))
        cursor.callproc(
            f"ONTHEFLYDECOM.selectNumericTlm",
            [1, tmid, -1, -1, start_time_gps, end_time_gps],
        )
        # Calling the function should lock the thread until it returns, at which point the results will be in ONTHEFLYDECOM_RESULTS
        otfd_results = cursor.execute(
            "SELECT SCT, VALUE FROM ONTHEFLYDECOM_RESULTS"
        ).fetchall()
        # Check if any errors occurred
        otfd_error = cursor.execute("SELECT * FROM ONTHEFLYDECOM_ERRORS").fetchall()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            # If the table is inaccessible, processing is presumed to have failed catastrophically,
            # so the thread is set to a failed state.
            logger.exception(
                "ORA-00942: table or view does not exist. \n"
                "Either the following tables do not exist or the script does not have access to them. \n"
                "Ensure that the script has the following permissions:  \n"
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), \n"
                "TelemetryAnalogConversions(SELECT), TMAverage(ALL).\n"
            )
            fail_worker()
            raise error
        else:
            logger.exception("An unknown exception occurred.")
            raise error
    except Exception as error:
        logger.exception("An unknown exception occurred.")
        raise error

    if len(otfd_error) != 0:
        logger.error(
            "ONTHEFYDECOM_ERRORS contains errors. See below output for more details. Skipping..."
        )
        for row in otfd_error:
            logger.error(row)

        error = OTFDException(
            f"ONTHEFYDECOM_ERRORS Contains errors. See below for more details: {otfd_error}."
        )

        error.error_rows=otfd_error

        raise error

    # Gets length of the python array returned by oracle to pre-allocate the numpy array
    # this is assumed to be faster because numpy fully re-allocates the array upon append,
    # but the difference is likely marginal.
    results_len = len(otfd_results)
    results_values = np.zeros((results_len), dtype=np.float128)
    results_bucket_ids = np.zeros((results_len), dtype=np.uintc)

    logger.info(f"Retrieved {results_len} records. Ingesting...")

    row_number = 0
    for row in otfd_results:
        # Calculate the bucket_id for the specific row. This is used to determine
        # which 5-minute chunk the corresponding value belongs to, and is used in a
        # numpy bit mask later on to filter efficiently.
        time = row[0]
        timeDelta = time - start_time_gps
        results_bucket_ids[row_number] = int(math.trunc(timeDelta / 300000000))

        results_values[row_number] = row[1]
        row_number += 1

    cursor.close()

    return (
        results_len,
        results_values,
        results_bucket_ids,
    )


def fetch_analog_conversions_by_tmid(tmid, database):
    """
    Fetches a single analog conversion from the TelemetryAnalogConversion table. This table is not expected to have multiple entries,
    and the function only fetches the first one, if more than one is found.
    """
    global db_connection
    logger = multiprocessing.get_logger()
    cursor = db_connection.cursor()

    sql = f"""select C.c0,  C.c1,  C.c2,  C.c3,  C.c4,  C.c5,  C.c6,  C.c7 
            FROM {TELEMETRYANALOGCONVERSIONS_DBS[database]} C 
            where C.tlmId = {tmid} order by C.segmentNumber"""

    logger.debug(sql)
    try:
        result = cursor.execute(sql).fetchone()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            logger.fatal(
                "ORA-00942: table or view does not exist"
                "Either the following tables do not exist or the script does not have access to them."
                "Ensure that the script has the following permissions: "
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), "
                "TelemetryAnalogConversions(SELECT), TMAverage(ALL)"
            )
            fail_worker()
            exit(1)
        else:
            logger.fatal(traceback.format_exc())
            logger.fatal(
                "An error occurred while retrieving Analog Conversion Polynomial. See above output:"
            )
            raise error

    return result


def insert_tmaverage_rows(database: str, tmaverage_values: list):
    """
    Attempts to insert the passed array into the TMAverage table. Returns the number of rows inserted if successful,
    and raises an exception if the process fails.
    """
    global db_connection
    global failed
    logger = multiprocessing.get_logger()

    # If no data is being inserted, automatically succeed.
    expected_rows_inserted = len(tmaverage_values)
    if expected_rows_inserted == 0:
        logger.info("No values to insert. Continuing...")
        return 0

    cursor = db_connection.cursor()

    sql = f"""INSERT INTO {DB_SCHEMAS[database]}.{TMAVERAGE_TABLE_NAME} 
        (tmid, SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT) 
        VALUES (:1, :2, :3, :4, :5, :6)"""

    logger.debug(sql)

    try:
        cursor.executemany(sql, tmaverage_values)
        db_connection.commit()
    except oracledb.IntegrityError as error:
        if str(error).find("ORA-00001") != -1:
            logger.exception(
                f"ORA-00001: Unique Constraint Violated during insert. Insert has been automatically rolled back."
                "This is likely due to the script parameters overlapping with pre-existing data. Please double-check"
                "the data in TMAverage. Continuing..."
            )
            raise error
        else:
            logger.exception("An unknown exception occurred.")
            raise error
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            logger.exception(
                "ORA-00942: table or view does not exist. "
                "This error is likely due to missing permissions. "
                "Ensure that the script has the following permissions: "
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), TelemetryAnalogConversions(SELECT), TMAverage(ALL) "
            )
            fail_worker()
            raise error
        elif str(error).find("ORA-01654") != -1 or str(error).find("ORA-01647"):
            logger.exception(
                "ORA-01654: unable to extend index. / ORA-01647: tablespace is read-only, cannot allocate space in it"
                "This error is likely due to the script running out of storage space or the tablespace being set as read-only. "
                "Ensure that the TMAVERAGE tablespace has enough extra storage space for the script to run and that the TMAVERAGE "
                "tablespace is READ WRITE."
            )
            fail_worker()
            raise error
        else:
            logger.exception("An unknown exception occurred.")
            raise error
    if cursor.rowcount == expected_rows_inserted:
        logger.info(f"Successfully inserted {cursor.rowcount} rows into TMAverage.")
        return cursor.rowcount
    else:
        raise Exception(
            f"Error: Mismatch between expected rows inserted and successful insertions. "
            "{cursor.rowcount}/{expected_rows_inserted} successfully inserted."
        )


def convert_dt2gps(DTValue, isAim):
    """
    Calls the DT2GPS stored procedure with the given datetime value. The stored procedure will strictly only accept a datetime
    in the format DD-MMM-YY XX.XX.XX.XXXXXXXXX.
    """
    logger = multiprocessing.get_logger()
    cursor = db_connection.cursor()

    if isAim:
        # If this is not set, the aim query will fail due to an incorrect DT format.
        cursor.execute(
            "ALTER SESSION SET NLS_TIMESTAMP_FORMAT='DD-MON-RR HH.MI.SSXFF AM'"
        )

    sql = f"""SELECT DT2GPS('{DTValue}') FROM dual"""

    logger.debug(sql)

    try:
        result = cursor.execute(sql).fetchone()[0]
    except oracledb.DatabaseError as error:
        if "ORA-00904" in str(error):
            logger.exception(
                "ORA-00904: invalid identifier. \n"
                "The DT2GPS procedure is not currently loaded. Please run LoadGPSFunctions.sh to load them into the database."
            )
            fail_worker()
            raise error
    except Exception as error:
        logger.exception(
            "An unknown exception occurred while calling DT2GPS. See above output for more details."
        )
        raise error
    return result


def calculate_day_start_end_gps(
    date: datetime.datetime,
    database: str,
):
    """
    Gets the start and end times, in GPS for any given day.
    """
    global db_connection

    cursor = db_connection.cursor()
    # The 18_000_000 offset (18 seconds) exists to recreate how the IDL script for aimprod functioned
    # this is not strictly necessary, but is being recreated nonetheless.
    start_time_gps = (
        convert_dt2gps(
            f"{date.strftime('%d-%b-%y')} 12.00.00.000000000 AM",
            database == "aimprod",
        )
        - 18_000_000
    )

    end_time_gps = (
        convert_dt2gps(
            f"{date.strftime('%d-%b-%y')} 11.59.59.999999999 PM",
            database == "aimprod",
        )
        - 18_000_000
    )

    return (start_time_gps, end_time_gps)


def calibrate(value, c):
    """
    Helper function that is passed to numpy to calibrate the data. Is iterated over the numpy array.
    """
    newValue = (
        c[0]
        + c[1] * value
        + c[2] * value**2
        + c[3] * value**3
        + c[4] * value**4
        + c[5] * value**5
        + c[6] * value**6
        + c[7] * value**7
    )
    return newValue


def process_values_by_tmid(
    tmid: int,
    database: str,
    start_date: datetime.datetime,
    is_otfd: bool,
):
    """
    This function fetches, calibrates, and finds the minimum, maximum, and average values for each 5 minute period
    for a single specified start_date. It returns a tuple of the number of rows ingested and inserted, which are tallied
    up in the main thread. If the thread is not initialized, it will return (-1, -1), and the main thread will interpret
    that result as a complete failure. This function is run on each child process for each specified TMID.
    """
    global db_connection
    global failed
    logger = multiprocessing.get_logger()

    if failed:
        logger.critical(
            "Error: Process failed. This could either be because the process failed to initialize, or this thread is unable to access "
            "a required table. Please look through the logs for the root cause."
        )
        return (-1, -1)

    logger.info(f"Calculating start and end for date {start_date}.")

    start_time_gps, end_time_gps = calculate_day_start_end_gps(start_date, database)

    # Fetch all data for the given date range.
    logger.info(
        f"Pulling data for time range {start_time_gps} - {end_time_gps} for tmid {tmid}"
    )

    if is_otfd:
        data = fetch_otfd_values_by_time_range(
            tmid=tmid,
            start_time_gps=start_time_gps,
            end_time_gps=end_time_gps,
        )
    else:
        data = fetch_values_by_time_range(
            database=database,
            tmid=tmid,
            start_time_gps=start_time_gps,
            end_time_gps=end_time_gps,
        )

    results_len = data[0]
    results_values = data[1]
    results_bucket_ids = data[2]

    # If there is no data for the time range and tmid, then exit.
    if results_len == 0:
        logger.info(
            f"No data found for the time range {start_time_gps} - {end_time_gps} and TMID {tmid}"
        )
        return (0, 0)

    # The list of buckets that the data will be split into. If there are no values, it defaults to inserting 0s.
    unique_bucket_ids = range(int(((end_time_gps - start_time_gps) / 300000000)))

    # Fetch calibration data, then apply to all values for the specific TMID.
    calibration_data = fetch_analog_conversions_by_tmid(tmid, database)

    logger.info("Calibrating data...")
    # Apply the polynomial calibration every time, as long as it exists.
    if calibration_data != None:
        # Splices out the the polynomial coefficients, removes unnecessary data
        results_values = np.apply_along_axis(
            calibrate, -1, results_values, (calibration_data)
        )

    logger.info("Averaging data...")
    insertion_data = []
    for bucket_id in unique_bucket_ids:
        bucket_mask = np.where(results_bucket_ids == bucket_id, True, False)
        bucket_values = results_values[bucket_mask]
        sct_vtcw = int(
            bucket_id * 300_000_000 + start_time_gps + 150_000_000 + 18_000_000
        )  # Adds back 18 seconds to ensure that the SCT values are on 5-minute increments, emulating the behavior on AIM

        current_bucket_count = int(np.size(bucket_values))

        if current_bucket_count == 0:
            insertion_data.append((int(tmid), sct_vtcw, 0, 0, 0, 0))
            continue

        # WARNING: The current version of the script uses a float 128 for the numpy array.
        # As it stands, the script is capable of computing a value too large to be stored
        # as an oracle NUMBER datatype, in which case the insert will fail. This is unlikely
        # to occur in practice, unless the calibration data is incorrect.
        current_bucket_average = float(np.average(bucket_values))
        current_bucket_min = float(np.min(bucket_values))
        current_bucket_max = float(np.max(bucket_values))
        insertion_data.append(
            (
                int(tmid),
                sct_vtcw,
                current_bucket_average,
                current_bucket_min,
                current_bucket_max,
                current_bucket_count,
            )
        )
    return (results_len, insert_tmaverage_rows(database, insertion_data))


def main():
    """
    This script fetches the values for each TMID in the provided database for the day provided from
    all TMAnalog_SIDX tables, and computes the min, max, average, and count of measurements
    over 5 minute increments, then inserts them into the TMAverage table.
    """
    # Usage and example
    parser = argparse.ArgumentParser(
        prog="ProcessTMAverageData.py",
        description="This script will iterate through all TMIDs and insert averaged values for that telemetry point into TMAverage\n"
        "Example: ./ProcessTMAverageData.py goldprod ALL 12-JAN-25 13-FEB-25",
    )

    parser.add_argument(
        "-o",
        dest="otfd",
        action="store_true",
        help="Use OnTheFlyDecom",
    )
    parser.add_argument(
        "-e",
        dest="exclude_filename",
        type=str,
        help="filename for newline-separated TMIDs to exclude",
    )
    parser.add_argument("database", type=str)
    parser.add_argument(
        "tmid",
        type=str,
        help="TMID to process, can be 'ALL' or newline-separated filename of TMIDs.",
    )
    parser.add_argument(
        "start_date", type=str, help="(Inclusive), beginning of range to process."
    )
    parser.add_argument(
        "end_date", type=str, help="(Exclusive), end of range to process."
    )
    parser.add_argument(
        "parallel_degree",
        type=int,
        nargs="?",
        default=1,
        help="(optional, defaults to 1)",
    )

    arguments = parser.parse_args()

    database = arguments.database.lower()
    tmid_input = arguments.tmid
    is_otfd = arguments.otfd
    parallel_degree = arguments.parallel_degree

    # Configure the logger for the main thread
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    os.makedirs(f"/tmp/TMAverageLogs/{database}", exist_ok=True)
    logger = setup_logger(
        f"/tmp/TMAverageLogs/{database}/TMAverage-{timestamp}-Main.log"
    )

    # Validate TMID input if not all. If all, will query for data once db connection is
    # made
    tmids = []
    if tmid_input.upper() != "ALL":
        try:
            tmids = [int(tmid_input)]
        except ValueError:
            try:
                # If TMID is not ALL or a number, check if it is a file.
                with open(tmid_input, mode="r", newline="\n") as file:
                    csv_reader = csv.reader(file)
                    for row in csv_reader:
                        tmids.append(int(row[0]))
            except:
                logger.critical(
                    "TMID must be a number, 'ALL', or a valid filename containing newline-separated TMIDs. Exiting..."
                )
                sys.exit(1)
    else:
        tmids = "ALL"  # This tells later code to query for TMIDs.

    # Validate exclude file input if it exists. This flag is only valid for TMIDs 'ALL'
    excluded_tmids = []
    if arguments.exclude_filename:
        if tmids != "ALL":
            logger.critical(
                "The exclude flag may only be used for TMIDs 'ALL'. Exiting..."
            )
            sys.exit(1)
        try:
            with open(arguments.exclude_filename, mode="r", newline="\n") as file:
                csv_reader = csv.reader(file)
                for row in csv_reader:
                    excluded_tmids.append(int(row[0]))
        except:
            logger.critical(
                "exclude_filename must be a valid filename containing newline-separated TMIDs to exclude. Exiting..."
            )
            sys.exit(1)

    start_date = None
    end_date = None

    # Validate date input
    try:
        start_date = datetime.datetime.strptime(arguments.start_date, "%d-%b-%y").date()
    except ValueError:
        logger.critical(
            f"Inputted date {arguments.start_date} does not match format DD-MMM-YY. Exiting..."
        )
        exit(1)

    try:
        end_date = datetime.datetime.strptime(arguments.end_date, "%d-%b-%y").date()
    except ValueError:
        logger.critical(
            f"Inputted date {arguments.end_date} does not match format DD-MMM-YY. Exiting..."
        )
        exit(1)

    # Validate that date range is correct
    num_of_days = (end_date - start_date).days + 1
    if num_of_days < 1:
        logger.critical("Error, end date is earlier than start date. Exiting...")
        exit(1)

    username = get_value_from_file(".username")
    password = get_value_from_file(".passwd")

    if password is None or username is None:
        # Error message is already printed by get_password_from_file
        exit(1)

    # Validate database input, ensure that script has an entry in DB_SCHEMAS
    if database not in DB_SCHEMAS.keys():
        logger.critical(
            f"Selected database is not supported by script. Supported databases "
            f"are: {str(tuple(DB_SCHEMAS.keys()))}"
        )
        exit(1)

    # Connect to the database as a test to ensure credentials are valid.
    # Each worker process will connect to the DB individually.
    try:
        connection_string = f"localhost/{database}"
        connection = oracledb.connect(
            user=username, password=password, dsn=connection_string
        )
        logger.info(f"Successfully connected to database {database}.")
    except:
        logger.critical(
            f"Error connecting to database {database}. Check if database exists and "
            "the script has connect privileges."
        )
        exit(1)

    start_time = datetime.datetime.now()

    logger.info(f"Script has started at {start_time}")
    cursor = connection.cursor()

    # Initialize the tmaverage_stats entry.
    update_tmaverage_stats(
        cursor,
        database=database,
        start_time=start_time
    )


    try:
        # If all tmids is specified, then query for them.
        if tmids == "ALL":
            # Check if database has any TMIDs that are excluded. If so, generate SQL to filter them out.
            exclusion_clause = ""
            if len(excluded_tmids) > 0:
                exclusion_list = "', '".join(
                    [str(id) for id in excluded_tmids]
                )  # Generates a string list of the form "item1, item2"
                exclusion_clause = f" AND TLMID NOT IN ('{exclusion_list}')"

            tmids = cursor.execute(
                f"SELECT UNIQUE TLMID from {TELEMETRYITEMDEFINITION_DBS[database]} WHERE dataType='U' OR dataType='I' OR dataType='F'{exclusion_clause}"
            ).fetchall()
            tmids = [tmid[0] for tmid in tmids]
            tmids.sort()
            logger.info(f"There are {len(tmids)} unique tmids.")
    except:
        logger.exception(
            f"An error occurred while fetching TMIDs from {TELEMETRYITEMDEFINITION_DBS[database]}. Exiting..."
        )
        cursor.close()
        connection.close()
        exit(1)

    cursor.close()
    
    # Allocate worker pool of specified parallel degree and setup the logger to log to the correct file.
    worker_pool = multiprocessing.Pool(
        parallel_degree,
        initializer=init_worker,  # The function that is passed is called for each worker separately to configure the logger and DB connection.
        initargs=(database, username, password, connection_string),
    )

    error_status = False
    total_ingested_rows = 0
    total_inserted_rows = 0

    critical_failure = False
    cancelled = False

    # Array of all errors that were encountered
    all_errors = []

    # Break the task up by day (if multiple days are specified, process each day separately):
    for single_date in (start_date + datetime.timedelta(n) for n in range(num_of_days)):

        # Setup the process_values_by_tmid partial with the appropriate static arguments
        process_partial = partial(
            process_values_by_tmid,
            database=database,
            start_date=single_date,
            is_otfd=is_otfd,
        )

        logger.info(f"Processing data for TMID(s) {tmid_input} for date {single_date}")

        day_ingested_rows = 0
        day_inserted_rows = 0

        day_error_status = False
        critical_failure = False

        unique_constraint_num = 0
        otfd_error_num = 0

        cancelled = False

        num_results = len(tmids)

        # Can set chunksize if performance needs to be tuned. The default is # of workers * 4. (PD 8 -> chunksize 32)
        results = worker_pool.imap_unordered(process_partial, tmids)

        # This iterates through ALL of the results, catching any errors that occur and logging them.
        for i in range(num_results):
            try:
                result = next(results)
                if result == (-1, -1):
                    critical_failure = True
                else:
                    day_ingested_rows += result[0]
                    day_inserted_rows += result[1]

            except KeyboardInterrupt:
                logger.critical(
                    "Script has been cancelled. Terminating multiprocessing pool..."
                )

                logger.info(f"Rows ingested before cancel: {total_ingested_rows}")
                logger.info(f"Rows ingested before cancel: {total_inserted_rows}")

                worker_pool.terminate()
                cancelled = True
                all_errors.append("Cancelled. Exiting...")
                break
            except oracledb.IntegrityError as error:
                if str(error).find("ORA-00001") != -1:
                    # This is not a critical failure, and script will continue processing. Log error to user and continue
                    unique_constraint_num += 1
                else:
                    error_status = True
                    logger.exception(
                        f"An exception occurred while processing data for TMID {tmid_input} for date {single_date}. Please see below output.",
                        stack_info=True,
                    )
                    all_errors.append(traceback.format_exc())
            except OTFDException as error:
                all_errors.append(f"An OTFD error occurred. ONTHEFLYDECOM_ERRORS Rows: {error.error_rows}")
                otfd_error_num += len(error.error_rows)
            except:
                error_status = True
                logger.exception(
                    f"An exception occurred while processing data for TMID {tmid_input} for date {single_date}. Please see below output.",
                    stack_info=True,
                )
                all_errors.append(traceback.format_exc())

        if cancelled:
            break

        if day_error_status:
            error_status = True
            logger.error(
                f"One or more error(s) occurred during processing TMID {tmid_input} for date {single_date}. "
                "Please check worker log files at /tmp/TMAverageLogs/ for more details. Continuing..."
            )
        if unique_constraint_num > 0:
            logger.error(
                f"One or more unique constraint errors (ORA-00001) occurred while processing TMID {tmid_input} for date {single_date}. "
                "Please check worker log files at /tmp/TMAverageLogs/ for more details. Continuing..."
            )
        
        if otfd_error_num > 0:
            logger.error(
                f"One or more OnTheFlyDecom errors occurred during processing TMID {tmid_input} for date {single_date}. Please check logs or "
                "the TMAVERAGE_STATS for more details. Continuing..."
                )

        if critical_failure:
            logger.critical(
                f"A critical error has occurred while processing data for {single_date}. Cancelling all processing..."
            )
            all_errors.append("ERROR: Critical error detected. Check error logs for more details.")
            break
                    
        logger.info(f"Processing for date {single_date} complete.")
        logger.info(f"Ingested {day_ingested_rows} rows.")
        logger.info(f"Inserted {day_inserted_rows} rows.")

        total_inserted_rows += day_inserted_rows
        total_ingested_rows += day_ingested_rows

    worker_pool.close()
    worker_pool.join()

    end_time = datetime.datetime.now()

    update_tmaverage_stats(
        cursor=connection.cursor(),
        database=database,
        start_time=start_time,
        time_duration=end_time - start_time,
        failed=critical_failure,
        cencelled=cancelled,
        ingested=total_ingested_rows,
        inserted=total_inserted_rows,
        unique_constraint_num=unique_constraint_num,
        errors=all_errors,
    )

    logger.info(
        f"Script completed at time {end_time}. Duration: {end_time - start_time}"
    )

    if critical_failure:
        logger.critical(
            "One or more of the worker threads failed for an unknown reason. Please check worker logs to determine the cause of failure. \n"
        )
        logger.info(f"Rows ingested before failure: {total_ingested_rows}")
        logger.info(f"Rows ingested before failure: {total_inserted_rows}")
        exit(1)

    if error_status:
        logger.error(
            "One or more errors occurred during execution. "
            " Please check the above output and the log files for more details."
        )
        logger.info(f"Rows ingested: {total_ingested_rows}")
        logger.info(f"Rows inserted: {total_inserted_rows}")
        exit(1)

    else:
        logger.info("Script has successfully completed!")
        logger.info(f"Rows ingested: {total_ingested_rows}")
        logger.info(f"Rows inserted: {total_inserted_rows}")
        exit(0)


if __name__ == "__main__":
    main()
