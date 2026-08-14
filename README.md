# AWS Account Cleanup

Partner-side cleanup for reclaiming customer AWS accounts (does not close the account).

## Cloud Shell (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
```

After delete, it runs an independent leftover check (all-region describe, like EC2 Global View) and writes `verification/latest_report.json`.

## Feedback (no log paste)

I cannot read Cloud Shell. Set one of these so the report comes back automatically:

```bash
export CLEANUP_GITHUB_TOKEN=ghp_xxx   # creates a counts-only GitHub issue
# or
export REPORT_WEBHOOK=https://example.com/hook
# or
export REPORT_S3=s3://your-bucket/cleanup-report.json
```

Then the same one-liner. Issues are counts only (no account/resource IDs).

## Modules (billing service)

| Module | Scope |
| --- | --- |
| `elb` | Load balancers |
| `ec2` | Instances, ASG, EBS, AMI, snapshots |
| `vpc` | EIP, NAT, VPC endpoints |
| `s3` `cloudfront` `kms` | storage / CDN / keys |
| `rds` and other data/compute modules | as named |
| `route53` `iam` | DNS / identity |
| `verify` | leftover check only |
