# AWS Account Cleanup

Partner-side cleanup for reclaiming customer AWS accounts (does not close the account).

## Cloud Shell (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
```

After delete, leftover check runs (all-region describe). Result handling:

- **PASS**: if a previous report bucket exists, it is deleted (no leftover S3 charge)
- **FAIL**: report is stored at `s3://aws-cleanup-report-<account-id>/latest_report.json` (private). Open that object in the console instead of pasting Cloud Shell logs. Re-run the same one-liner after fixes; PASS will remove this bucket.

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
