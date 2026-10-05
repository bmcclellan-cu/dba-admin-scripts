"""
AvailabilityFlag: Public

Lambda entry point for the BillingReport application.

Triggered on a daily or weekly schedule by EventBridge (see template.yaml).
Gathers three sub-reports - overall spend by service (spending_report.py),
EC2 instance uptime/cost (ec2_report.py), and S3 storage growth
(s3_report.py) - combines them into a single plain-text message, and
publishes that message to the SNS topic for the period so it reaches every
subscribed email address and the Slack channel (via Amazon Q Chatbot).
"""

import logging
import datetime
from zoneinfo import ZoneInfo
import os
import boto3
import json
from s3_report import get_storage_report
from ec2_report import get_ec2_report
from spending_report import get_spending_report

sns = boto3.client("sns")

logger = logging.getLogger("billing-report")
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Build the spend/EC2/S3 report for a period and publish it via SNS.

    Configuration (TIME_RANGE, SNS_TOPIC_ARN, SERVICE_SPEND_THRESHOLD,
    ACCOUNT_NAME) is read from `event` first, falling back to the Lambda's
    environment variables. See template.yaml for how EventBridge populates
    `event` for the daily and weekly schedules.

    Args:
        event (dict): Optional overrides for TIME_RANGE ("DAILY"/"WEEKLY"),
            SNS_TOPIC_ARN, SERVICE_SPEND_THRESHOLD, and ACCOUNT_NAME.
        context: Lambda context object (unused).

    Returns:
        float: Total spend for the period, in USD.

    Raises:
        Exception: TIME_RANGE is not "DAILY"/"WEEKLY", or the Cost Explorer
            or SNS calls fail.
        KeyError: a required setting is missing from both the event and environment
    """
    time_range = event.get("TIME_RANGE")
    if not time_range:
        time_range = os.environ["TIME_RANGE"]
    time_range = time_range.upper()
    if time_range != "DAILY" and time_range != "WEEKLY":
        logger.error(f"Invalid time_range {time_range}. Expected DAILY or WEEKLY")
        raise Exception("Invalid time_range")

    SNS_TOPIC_ARN = event.get("SNS_TOPIC_ARN")
    if not SNS_TOPIC_ARN:
        SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

    SERVICE_SPEND_THRESHOLD = 0.0
    try:
        if event.get("SERVICE_SPEND_THRESHOLD"):
            SERVICE_SPEND_THRESHOLD = float(event.get("SERVICE_SPEND_THRESHOLD"))
        else:
            SERVICE_SPEND_THRESHOLD = float(os.environ["SERVICE_SPEND_THRESHOLD"])
    except Exception as e:
        logger.error(f"Error occurred while setting SERVICE_SPEND_THRESHOLD: {e}")
        raise e
    logger.info(f"SERVICE_SPEND_THRESHOLD: {SERVICE_SPEND_THRESHOLD}")

    # The account name is purely for logging purposes and not used for API calls
    if event.get("ACCOUNT_NAME"):
        ACCOUNT_NAME = event.get("ACCOUNT_NAME")
    elif os.environ.get("ACCOUNT_NAME"):
        ACCOUNT_NAME = os.environ.get("ACCOUNT_NAME")
    else:
        raise KeyError("ACCOUNT_NAME not provided in event or environment variables")
    logger.info(f"ACCOUNT_NAME: {ACCOUNT_NAME}")

    end_time = datetime.datetime.now(datetime.timezone.utc)
    if time_range == "DAILY":
        start_time = end_time - datetime.timedelta(days=1)
    elif time_range == "WEEKLY":
        start_time = end_time - datetime.timedelta(days=7)

    # Get the various parts of the report
    total_spend, high_spend_percentage, high_spend_table = get_spending_report(
        start_time, end_time, SERVICE_SPEND_THRESHOLD
    )
    ec2_table = get_ec2_report(start_time, end_time)
    s3_table = get_storage_report(start_time, end_time)

    start_time_for_subject = start_time.astimezone(ZoneInfo("America/Denver")).strftime(
        "%Y-%m-%d %H:%M"
    )
    end_time_for_subject = end_time.astimezone(ZoneInfo("America/Denver")).strftime(
        "%Y-%m-%d %H:%M"
    )

    # Send the SNS message
    subject = f"{ACCOUNT_NAME} {time_range} Spend Report ({start_time_for_subject} to {end_time_for_subject})"
    full_message = f"OVERALL {time_range} SPENDING REPORT\nTotal Cost: ${total_spend:.2f}\nServices over ${SERVICE_SPEND_THRESHOLD:.2f}:\n{high_spend_table}\nSpending over threshold is {high_spend_percentage:.1f}% of total spend.\n\n{ec2_table}\n\n{s3_table}"
    json_encoded_message = {
        "default": full_message,
        # This is the format for Amazon Q Chatbot (Slack)
        "https": json.dumps(
            {
                "version": "1.0",
                "source": "custom",
                "content": {
                    "textType": "client-markdown",
                    "title": subject,
                    "description": full_message,
                },
                "metadata": {"enableCustomActions": False},
            }
        ),
    }
    try:
        logger.info(f"Attempting to send SNS message: {subject}")
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=json.dumps(json_encoded_message),
            MessageStructure="json",
        )
        logger.info("SNS message sent")
    except Exception as e:
        logger.error(f"Error occurred while sending SNS message: {e}")
        raise

    return total_spend
