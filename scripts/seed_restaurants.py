#!/usr/bin/env python3
"""
Seed script: populate bbq-dev-restaurants with Memphis BBQ test data.

Usage:
    python scripts/seed_restaurants.py [--env dev|prod]

Why a script (not Terraform locals or console):
    - Idempotent: put_item with the same PK just overwrites — safe to re-run.
    - Version-controlled: restaurant catalog lives in git, not click history.
    - No Terraform coupling: data seeding is an ops concern, not infra state.

Scope: Shelby County, TN only.

Security: runs with your local AWS credentials — same role you use for Terraform.
Never run against prod without explicit intent (--env prod requires confirmation).
"""

import argparse
import sys

import boto3
from botocore.exceptions import ClientError

# All restaurants must be within Shelby County, TN.
RESTAURANTS = [
    {
        "restaurant_id": "paynes-bar-b-que",
        "name": "Payne's Bar-B-Que",
        "location": "1762 Lamar Ave, Memphis, TN 38114",
        "neighborhood": "Midtown",
        "style": "Memphis dry rub",
        "notes": "Cash only, lunch until sold out. James Beard America's Classics 2003.",
    },
    {
        "restaurant_id": "central-bbq-downtown",
        "name": "Central BBQ (Downtown)",
        "location": "147 E Butler Ave, Memphis, TN 38103",
        "neighborhood": "Downtown",
        "style": "Memphis wet and dry",
        "notes": "Multiple locations; Downtown flagship. Known for smoked wings.",
    },
    {
        "restaurant_id": "cozy-corner",
        "name": "Cozy Corner Restaurant",
        "location": "745 N Pkwy, Memphis, TN 38105",
        "neighborhood": "North Memphis",
        "style": "Memphis wet ribs",
        "notes": "Cornish hen BBQ is the signature item. Family-run since 1977.",
    },
    {
        "restaurant_id": "bar-b-q-shop",
        "name": "The Bar-B-Q Shop",
        "location": "1782 Madison Ave, Memphis, TN 38104",
        "neighborhood": "Midtown",
        "style": "Memphis dry rub",
        "notes": "Dancing Pigs sauce. Voted best ribs in Memphis multiple times.",
    },
    {
        "restaurant_id": "germantown-commissary",
        "name": "Germantown Commissary",
        "location": "2290 S Germantown Rd, Germantown, TN 38138",
        "neighborhood": "Germantown",
        "style": "Memphis slow-smoked",
        "notes": "Shelby County institution. Housed in a 1913 country store building.",
    },
]


def seed(env: str, dry_run: bool = False) -> None:
    table_name = f"bbq-{env}-restaurants"
    print(f"Target table: {table_name}")

    if env == "prod":
        confirm = input("WARNING: seeding PROD. Type 'yes' to continue: ")
        if confirm.strip().lower() != "yes":
            print("Aborted.")
            sys.exit(0)

    dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
    table = dynamodb.Table(table_name)

    for restaurant in RESTAURANTS:
        if dry_run:
            print(f"[dry-run] Would write: {restaurant['restaurant_id']}")
            continue
        try:
            table.put_item(Item=restaurant)
            print(f"  OK  {restaurant['restaurant_id']}")
        except ClientError as e:
            print(f"  ERR {restaurant['restaurant_id']}: {e.response['Error']['Message']}")
            sys.exit(1)

    if not dry_run:
        print(f"\nSeeded {len(RESTAURANTS)} restaurants into {table_name}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed restaurant data into DynamoDB.")
    parser.add_argument("--env", choices=["dev", "prod"], default="dev")
    parser.add_argument("--dry-run", action="store_true", help="Print items without writing")
    args = parser.parse_args()
    seed(args.env, dry_run=args.dry_run)
