"""
AvailabilityFlag: Public

S3 storage growth report, sourced from CloudWatch's daily bucket-size
metrics.

For every bucket with storage metrics, compares total size (summed across
storage classes) near the start and end of the reporting window and lists
the buckets that grew.
"""

import logging
import boto3
from datetime import timedelta
from zoneinfo import ZoneInfo
from helpers import format_period_description

logger = logging.getLogger("billing-report")
logger.setLevel(logging.INFO)

cloudwatch_client = boto3.client("cloudwatch")

# Mapping of CloudWatch StorageType dimension values to display names
STORAGE_CLASSES = {
    "StandardStorage": "Standard",
    "IntelligentTieringFAStorage": "IT - Frequent Access",
    "IntelligentTieringIAStorage": "IT - Infrequent Access",
    "IntelligentTieringAAStorage": "IT - Archive Access",
    "IntelligentTieringDAAStorage": "IT - Deep Archive Access",
    "StandardIAStorage": "Standard-IA",
    "OneZoneIAStorage": "One Zone-IA",
    "GlacierInstantRetrievalStorage": "Glacier Instant Retrieval",
    "GlacierStorage": "Glacier Flexible Retrieval",
    "DeepArchiveStorage": "Glacier Deep Archive",
}


def get_storage_report(start_time, end_time):
    """Build the formatted S3 storage-growth report table for a time window."""
    # Discover all buckets and their storage classes from CloudWatch metrics
    bucket_storage_class_map = get_all_bucket_storage_classes()

    if not bucket_storage_class_map:
        table = "No S3 buckets with storage metrics found.\n"
        return table

    # Bulk-fetch all storage metrics in minimal API calls
    recent_data, past_data = get_bulk_storage_metrics(
        bucket_storage_class_map, start_time, end_time
    )

    # Calculate growth for each bucket
    storage_growth = {}
    for bucket, storage_types in bucket_storage_class_map.items():
        storage_growth[bucket] = get_storage_growth(
            bucket,
            storage_types,
            recent_data.get(bucket, {}),
            past_data.get(bucket, {}),
        )

    # Generate table report
    table = format_growth_report_table(storage_growth, start_time, end_time)

    return table


def get_all_bucket_storage_classes():
    """
    Discover which storage classes exist for each bucket via CloudWatch list_metrics.

    Returns:
        dict: {bucket_name: [storage_type_1, storage_type_2, ...]}
    """
    paginator = cloudwatch_client.get_paginator("list_metrics")
    bucket_storage_map = {}

    for page in paginator.paginate(
        Namespace="AWS/S3",
        MetricName="BucketSizeBytes",
    ):
        for metric in page["Metrics"]:
            dims = {d["Name"]: d["Value"] for d in metric["Dimensions"]}
            bucket = dims.get("BucketName")
            storage_type = dims.get("StorageType")
            if bucket and storage_type and storage_type in STORAGE_CLASSES:
                bucket_storage_map.setdefault(bucket, []).append(storage_type)

    return bucket_storage_map


def get_bulk_storage_metrics(bucket_storage_map, start_time, end_time):
    """
    Fetch storage metrics for all buckets and storage classes using get_metric_data.
    Batches queries into groups of 500 (the API limit) to handle large accounts.

    Args:
        bucket_storage_map (dict): {bucket_name: [storage_type_1, ...]} from get_all_bucket_storage_classes
        start_time (datetime): Start of the reporting window
        end_time (datetime): End of the reporting window

    Returns:
        tuple: (recent_data, past_data) where each is {bucket_name: {storage_type: bytes}}
    """
    # Build all metric queries — two per (bucket, storage_class): recent + past
    all_queries = []
    query_key_map = {}  # id -> (bucket, storage_type, "recent"|"past")

    for bucket, storage_types in bucket_storage_map.items():
        for storage_type in storage_types:
            # Sanitize bucket name for use as a CloudWatch metric data query Id
            # Ids must match ^[a-z][a-zA-Z0-9_]*$
            safe_bucket = bucket.replace("-", "_").replace(".", "_")
            base_id = f"b{safe_bucket}_{storage_type}"

            recent_id = f"r_{base_id}"
            past_id = f"p_{base_id}"
            query_key_map[recent_id] = (bucket, storage_type, "recent")
            query_key_map[past_id] = (bucket, storage_type, "past")

            metric_stat = {
                "Metric": {
                    "Namespace": "AWS/S3",
                    "MetricName": "BucketSizeBytes",
                    "Dimensions": [
                        {"Name": "BucketName", "Value": bucket},
                        {"Name": "StorageType", "Value": storage_type},
                    ],
                },
                "Period": 86400,
                "Stat": "Average",
            }

            all_queries.append(
                {
                    "Id": recent_id,
                    "MetricStat": metric_stat,
                    "ReturnData": True,
                }
            )
            all_queries.append(
                {
                    "Id": past_id,
                    "MetricStat": metric_stat,
                    "ReturnData": True,
                }
            )

    # Define separate time windows for recent and past queries
    recent_start = end_time - timedelta(days=2)
    recent_end = end_time
    past_start = start_time - timedelta(days=2)
    past_end = start_time

    # Split into batches of 500 (get_metric_data limit) and fetch
    recent_data = {}  # {bucket: {storage_type: bytes}}
    past_data = {}  # {bucket: {storage_type: bytes}}

    # Separate recent and past queries since they have different time windows
    recent_queries = [q for q in all_queries if q["Id"].startswith("r_")]
    past_queries = [q for q in all_queries if q["Id"].startswith("p_")]

    try:
        recent_results = fetch_batches(recent_queries, recent_start, recent_end)
        past_results = fetch_batches(past_queries, past_start, past_end)
    except Exception as e:
        logger.error(f"Exception during bulk fetch: {type(e).__name__}: {e!s}")
        return {}, {}

    # Map results back to {bucket: {storage_type: bytes}} structure
    for query_id, value in recent_results.items():
        bucket, storage_type, _ = query_key_map[query_id]
        recent_data.setdefault(bucket, {})[storage_type] = value

    for query_id, value in past_results.items():
        bucket, storage_type, _ = query_key_map[query_id]
        past_data.setdefault(bucket, {})[storage_type] = value

    return recent_data, past_data


def fetch_batches(queries, start_time, end_time):
    """Run get_metric_data in batches of 500 queries and collect one value
    per query Id (the first datapoint, since callers request a single-day
    period)."""
    results = {}
    batch_size = 500

    for i in range(0, len(queries), batch_size):
        batch = queries[i : i + batch_size]

        paginator = cloudwatch_client.get_paginator("get_metric_data")
        for page in paginator.paginate(
            MetricDataQueries=batch,
            StartTime=start_time,
            EndTime=end_time,
        ):
            for result in page["MetricDataResults"]:
                query_id = result["Id"]

                if result["Values"]:
                    results[query_id] = int(result["Values"][0])
    return results


def get_storage_growth(bucket_name, storage_types, recent, past):
    """
    Calculate the aggregate storage growth across all storage classes for a bucket.

    Args:
        bucket_name (str): S3 bucket name
        storage_types (list): CloudWatch StorageType dimension values present in this bucket
        recent (dict): {storage_type: bytes} for the recent time window
        past (dict): {storage_type: bytes} for the past time window

    Returns:
        dict: Aggregated storage growth metrics including bytes and human-readable format
    """
    try:
        # Aggregate across all storage classes
        all_types = set(list(recent.keys()) + list(past.keys()))
        recent_size = sum(recent.get(storage_type, 0) for storage_type in all_types)
        past_size = sum(past.get(storage_type, 0) for storage_type in all_types)
        growth_bytes = recent_size - past_size
        growth_percent = (
            ((recent_size - past_size) / past_size * 100)
            if past_size > 0
            else "undefined"
        )

        if growth_bytes > 0:
            direction = " increased"
        elif growth_bytes < 0:
            direction = " decreased"
        else:
            direction = ""

        # Build list of human-readable storage class names present
        active_classes = [
            STORAGE_CLASSES.get(st, st) for st in storage_types if recent.get(st, 0) > 0
        ]

        return {
            "bucket_name": bucket_name,
            "current_storage_bytes": recent_size,
            "previous_storage_bytes": past_size,
            "growth_bytes": growth_bytes,
            "growth_percent": round(growth_percent, 2)
            if isinstance(growth_percent, (int, float))
            else growth_percent,
            "current_storage": convert_bytes(recent_size),
            "previous_storage": convert_bytes(past_size),
            "growth": convert_bytes(abs(growth_bytes)),
            "direction": direction,
            "storage_classes": active_classes,
        }

    except Exception as e:
        print(f"Error calculating storage growth for {bucket_name}: {str(e)}")
        return {"error": str(e), "bucket_name": bucket_name}


def convert_bytes(bytes_size):
    """
    Convert bytes to human-readable format.

    Args:
        bytes_size (int): Size in bytes

    Returns:
        str: Human-readable size string
    """
    for unit in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if abs(bytes_size) < 1024.0:
            return f"{bytes_size:.2f} {unit}"
        bytes_size /= 1024.0
    return f"{bytes_size:.2f} PiB"


def format_growth_report_table(storage_growth, start_time, end_time):
    """
    Format storage growth data as a readable table string.

    Args:
        storage_growth (dict): Storage growth data keyed by bucket name

    Returns:
        str: Formatted table string
    """
    # Build header
    period_description = format_period_description(start_time, end_time)
    header = "S3 STORAGE GROWTH REPORT\n"
    header += "Only includes growing buckets. Totals are aggregated across all storage classes.\n"
    header += f"Comparing storage near {start_time.astimezone(ZoneInfo('America/Denver')).strftime('%Y-%m-%d %H:%M')} MTN to storage near {end_time.astimezone(ZoneInfo('America/Denver')).strftime('%Y-%m-%d %H:%M')} MTN.\n"
    header += "=" * 85 + "\n\n"

    # Column headers with formatting
    col_width = [35, 20, 20, 20, 15, 12]
    columns = [
        "Bucket Name",
        f"Start ({period_description})",
        "End",
        "Growth",
        "Growth %",
        "Direction",
    ]

    header_line = ""
    for i, col in enumerate(columns):
        header_line += col.ljust(col_width[i])
    header += header_line + "\n"
    header += "-" * 140 + "\n"

    # Build rows
    rows = ""
    total_growth = 0
    total_current = 0
    total_prev = 0

    for bucket_name, data in sorted(storage_growth.items()):
        if "error" in data:
            row = f"{bucket_name:<{col_width[0]}}{'ERROR':<{col_width[1]}}\n"
            rows += row
            continue

        prev_storage = data.get("previous_storage", "N/A")
        current_storage = data.get("current_storage", "N/A")
        growth_bytes = data.get("growth_bytes", 0)
        growth_percent = data.get("growth_percent", 0)
        direction = data.get("direction", "")
        total_growth += growth_bytes
        total_current += data.get("current_storage_bytes", 0)
        total_prev += data.get("previous_storage_bytes", 0)

        # Only display growing buckets
        if growth_bytes <= 0:
            continue

        growth_readable = convert_bytes(growth_bytes)
        classes_str = ", ".join(data.get("storage_classes", []))

        row = ""
        row += bucket_name[:30].ljust(col_width[0])
        row += prev_storage[:20].ljust(col_width[1])
        row += current_storage[:20].ljust(col_width[2])
        row += f"{growth_readable:<{col_width[3]}}"
        if growth_percent != "undefined":
            row += f"{growth_percent:.2f}%"
        else:
            row += growth_percent
        row += f"{direction:<{col_width[5]}}"
        rows += row + "\n"
        rows += f"{'':>{col_width[0]}}Classes: {classes_str}\n"

    # Build footer with totals
    footer = "-" * 140 + "\n"
    total_readable = convert_bytes(total_current)
    total_growth_readable = convert_bytes(total_growth)
    total_prev_readable = convert_bytes(total_prev)
    total_growth_percent = (
        (total_growth / total_current * 100) if total_current > 0 else "undefined"
    )
    if total_growth > 0:
        direction = " increased"
    elif total_growth < 0:
        direction = " decreased"
    else:
        direction = ""

    footer_row = ""
    footer_row += "TOTAL".ljust(col_width[0])
    footer_row += "".ljust(col_width[1])
    footer_row += f"{total_prev_readable:<{col_width[2]}}"
    footer_row += total_readable[:20].ljust(col_width[3])
    footer_row += f"{total_growth_readable:<{col_width[4]}}"
    if total_growth_percent != "undefined":
        footer_row += f"{total_growth_percent:<.2f}%"
    else:
        footer_row += total_growth_percent
    footer_row += f"{direction:<{col_width[5]}}"
    footer += footer_row + "\n"
    footer += "=" * 85 + "\n"

    return header + rows + footer
