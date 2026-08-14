# AWS Account Cleanup

Partner-side cleanup for reclaiming customer AWS accounts (does not close the account).

Modules follow **AWS billing service names**. Cloud Shell still uses one command.

## Cloud Shell

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
```

## Module map (aligned with bill)

| Module | Bill-style scope |
| --- | --- |
| `elb` | Elastic Load Balancing (CLB/ALB/NLB) |
| `ec2` | Instances, ASG, EBS volumes, AMIs, snapshots |
| `vpc` | Elastic IP, NAT Gateway, VPC endpoints |
| `s3` | Amazon S3 |
| `cloudfront` | Amazon CloudFront |
| `kms` | KMS customer keys (schedule 7-day deletion) |
| `rds` `elasticache` `redshift` `dynamodb` `opensearch` | databases |
| `efs` `fsx` | file systems |
| `ecs` `eks` `lambda` `ecr` | containers / compute |
| `route53` | hosted zones |
| `iam` | users/roles (skip current SSO role) |

## Optional: one service

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- vpc
```
