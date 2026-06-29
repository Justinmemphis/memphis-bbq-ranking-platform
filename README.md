# Memphis BBQ Ranking Platform

A serverless AWS restaurant ranking platform for Memphis BBQ restaurants, built with Terraform-managed infrastructure, GitHub Actions CI/CD, Cognito authentication, DynamoDB, and automated quality/security checks.

The application lets users view Memphis BBQ restaurants, see location details, and submit ratings. The technical focus is on building a practical cloud application with reproducible infrastructure, automated deployment, authentication, observability, and secure-by-default configuration.

---

## Project Overview

This project combines a simple local restaurant-ranking idea with a realistic cloud architecture.

The application includes:

* Restaurant listings for Memphis BBQ locations
* Individual restaurant detail pages
* User authentication through Amazon Cognito
* User ratings with one rating per user per restaurant
* Leaderboard-style ranking
* Google Maps and Street View integration
* Infrastructure managed through Terraform
* CI/CD through GitHub Actions
* Automated checks for code quality, dependency issues, and infrastructure misconfiguration

---

## Technical Goals

The main goals of this project are to practice and document:

* Serverless application architecture on AWS
* Infrastructure as Code with Terraform
* Multi-environment deployment patterns
* CI/CD with GitHub Actions
* OIDC-based AWS authentication without long-lived access keys
* Cognito-based user authentication
* DynamoDB data modeling
* Secure IAM design
* API Gateway and Lambda integration
* CloudWatch logging and monitoring
* Automated quality and security checks before deployment

---

## Architecture

### Core AWS Services

* **AWS Lambda** for backend API functions
* **API Gateway HTTP API** for API routing
* **DynamoDB** for restaurant, rating, and leaderboard data
* **Amazon Cognito** for authentication
* **S3** for static frontend hosting
* **CloudFront** for content delivery
* **CloudWatch** for logs, metrics, and alarms
* **IAM** for least-privilege access between components

### Infrastructure and Deployment

* **Terraform** manages AWS infrastructure
* **GitHub Actions** runs CI/CD workflows
* **OIDC federation** allows GitHub Actions to deploy without static AWS credentials
* Separate **dev** and **prod** environments are managed in Terraform
* Automated checks run before deployment

---

## Application Stack

* **Backend:** Python Lambda functions
* **Frontend:** Static HTML, CSS, and JavaScript
* **Database:** DynamoDB
* **Authentication:** Cognito User Pools
* **Infrastructure:** Terraform
* **CI/CD:** GitHub Actions
* **Security/Quality Checks:** Checkov, pip-audit, ruff, pytest
* **Monitoring:** CloudWatch

---

## Key Features

### Restaurant Data

The app stores and displays Memphis BBQ restaurant information, including basic details, contact information, and location data.

### Restaurant Detail Pages

Each restaurant can have an individual page with store details, map integration, and Street View support.

### Authenticated Ratings

Users authenticate through Cognito before submitting ratings. Cognito `sub` values are used as stable user identifiers.

### Leaderboard

Ratings are used to generate a leaderboard-style view of restaurants. The project is designed around read-optimized access patterns rather than scanning raw rating data for every leaderboard request.

### Multi-Environment Infrastructure

The project supports separate dev and prod environments through Terraform environment directories.

### Automated Deployment

GitHub Actions handles deployment steps and uses OIDC authentication to assume AWS roles without storing long-lived AWS access keys in GitHub.

---

## Security and Reliability Practices

This project includes several security-minded and operations-focused practices:

* Least-privilege IAM roles for AWS components
* No long-lived AWS credentials in GitHub Actions
* Cognito-based authentication
* Environment separation between dev and prod
* Terraform-managed infrastructure
* Automated infrastructure checks with Checkov
* Python dependency scanning with pip-audit
* Linting with ruff
* Unit tests with pytest
* CloudWatch logs and alarms
* Structured logging for easier troubleshooting
* Cost-conscious serverless architecture

---

## Data Model

### `restaurants`

Stores restaurant metadata.

* `restaurant_id`
* name
* location details
* contact information
* display metadata

### `ratings`

Stores the current rating from a user for a restaurant.

* partition key: `user_id`
* sort key: `restaurant_id`
* score
* timestamps

This structure enforces one active rating per user per restaurant.

### `rating_events`

Stores append-only rating history for auditing and future analysis.

* `restaurant_id`
* `created_at`
* user identifier
* score
* event metadata

### `leaderboard_snapshot`

Stores read-optimized ranking data.

* `scope`
* `rank`
* restaurant summary
* rating summary
* version metadata

---

## Directory Structure

```text
/app
  /lambdas
    health/
    submit_rating/
    get_leaderboard/
    get_restaurants/
    get_restaurant_detail/
  /shared
    auth.py
    models.py

/infra
  /modules
    api_http/
    cognito/
    dynamodb/
    lambda/
    static_site/
  /envs
    /dev
      main.tf
      variables.tf
      terraform.tfvars
    /prod
      main.tf
      variables.tf
      terraform.tfvars

/docs
  roadmap.md
  01-product-brief.md
  02-architecture.md
  03-threat-model.md
  04-cost-estimate.md
  /adr

/scripts
/static
```

---

## CI/CD Checks

The deployment workflow is designed to verify the application and infrastructure before deployment.

Checks include:

* Terraform validation
* Terraform planning
* Checkov scan for infrastructure misconfiguration
* Python linting with ruff
* Dependency vulnerability scan with pip-audit
* Unit tests with pytest

---

## Current Status

This project is an active hands-on cloud application build. The core serverless architecture, Terraform infrastructure, authentication flow, API endpoints, and deployment automation are in place. Ongoing work includes additional restaurant detail features, ranking improvements, monitoring refinements, and continued hardening.

---

## What This Project Demonstrates

This project demonstrates practical experience with:

* Designing a small cloud-native application
* Building AWS infrastructure with Terraform
* Structuring serverless APIs with Lambda and API Gateway
* Modeling application data in DynamoDB
* Using Cognito for authentication
* Deploying with GitHub Actions and OIDC
* Applying automated security and quality checks
* Thinking through operational concerns like logs, monitoring, cost, and reliability

---

## License

MIT
