# AWS Account Cleanup

Partner-side cleanup for reclaiming customer AWS accounts (does not close the account).

## Cloud Shell: one command

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
```

This clones the latest code and deletes common billable resources, then IAM.

## What it covers

| Module | Billable / reclaim scope |
| --- | --- |
| `ec2` | instances, ASG, ELB/ALB/NLB, EIP, EBS, AMI, snapshots, NAT |
| `billable` | RDS, ElastiCache, Redshift, DynamoDB, OpenSearch, S3, EFS, FSx, ECS, EKS, Lambda, ECR, VPC endpoints, CloudFront |
| `route53` | hosted zones |
| `iam` | users and roles (keeps current SSO role) |

Not every AWS service in existence. High-cost leftovers first; more services can be added later.

## Optional: run one module

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- iam
```
