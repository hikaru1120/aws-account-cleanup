# AWS Account Cleanup

Partner-side cleanup for reclaiming customer AWS accounts (does not close the account).

## Cloud Shell

Normal run (no S3 report):

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
```

Scan only (no delete):

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- --scan-only
```

Default full run **deletes immediately**. Inventory without delete: `--scan-only`. `curl | bash` cannot prompt yes/no.

Cloud Shell may recycle the environment. If the job dies, run the same `curl` again (retry-safe). Do not use tmux.

Early debugging, publish leftover report as public-read S3 object:

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- --report-s3
```

FAIL URL: `https://aws-cleanup-report-<account-id>.s3.amazonaws.com/latest_report.json`  
PASS: that report bucket is deleted so it does not keep billing.

## Delete order

1. IAM **users** — stop other keys from creating resources mid-run  
2. CloudTrail, Config, EventBridge, CloudWatch — stop writing to S3 / stop scheduled recreate  
3. ELB, EKS, ECS, Lambda, databases, file systems, ECR  
4. EC2 then VPC — instances before EIP/NAT  
5. CloudFront then S3  
6. KMS (schedule deletion after data is gone)  
7. Route53  
8. IAM **roles** last — after compute that used those roles  

## Modules (billing service)

| Module | Scope |
| --- | --- |
| `elb` | Load balancers |
| `ec2` | Instances, ASG, EBS, AMI, snapshots |
| `vpc` | EIP, NAT, VPC endpoints |
| `s3` | Empty with 1000-object batches, then delete bucket |
| `rds` and other named services | as named |
| `route53` `iam` | DNS / identity |
| `verify` | leftover check only |
