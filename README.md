# memphis-bbq-ranking-platform
A full-stack, secure, cloud-native restaurant ranking platform built with modern DevSecOps practices.


Architecture Decisions:
- AWS Lambda / API Gateway
- Python
- DynamoDB (two table - votes, leaderboards)
- Project Tracking - GitHub Projects
- Terraform
- Single AWS account
- dev and prod environments - infra/envs/dev and infra/envs/prod
- HTTP API
- REST-ish endpoints
- Versioning /v1/
- Authenticated on everything
- Auth provider - Cognito
- Identity - sub with email as attribute
- Later - snapshot table
- Frontend - S3 + CloudFront
- OIDC / SSM
- Naming convention ${app}-${env}-${dev}
- log retention - dev (7 days), prod (30 days)
- Cloudwatch log on lambda (default)
- Log in json
- Metric alarm on 5xx rate (API gateway)

/app
  /lambdas
    submit_vote/
    get_leaderboard/
    get_restaurants/
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
