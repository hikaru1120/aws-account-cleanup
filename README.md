# AWS Account Cleanup

Partner-side cleanup for reclaiming customer AWS accounts (does not close the account).

## Cloud Shell

Normal run (no S3 report):

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
```

Early debugging, publish leftover report as public-read S3 object:

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- --report-s3
```

FAIL URL: `https://aws-cleanup-report-<account-id>.s3.amazonaws.com/latest_report.json`  
PASS: that report bucket is deleted so it does not keep billing.

## Modules (billing service)

| Module | Scope |
| --- | --- |
| `elb` | Load balancers |
| `ec2` | Instances, ASG, EBS, AMI, snapshots |
| `vpc` | EIP, NAT, VPC endpoints |
| `s3` `cloudfront` `kms` | storage / CDN / keys |
| `rds` and other named services | as named |
| `route53` `iam` | DNS / identity |
| `verify` | leftover check only |
