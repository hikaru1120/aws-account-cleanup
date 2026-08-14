# AWS Account Cleanup

Partner-side cleanup modules for reclaiming customer AWS accounts (do not close the account).

## Module design

Modules follow **console / billing surface**, not raw AWS API names.

| Module | What it covers |
| --- | --- |
| `iam` | IAM users and roles |
| `ec2` | Billable items on the EC2 console: instances, ASG, ELB/ALB/NLB, EIP, EBS volumes, AMIs, snapshots, NAT gateways |
| `route53` | Hosted zones |

## Cloud Shell (fixed one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- iam
```

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- ec2
```

```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- route53
```

This clones the latest `main` into `/tmp/aws-account-cleanup` and runs the module.

## Local / cloned run

```bash
bash run.sh iam
bash run.sh ec2
bash run.sh route53
```

## Validation

New modules start as `PENDING_SECONDARY_VERIFICATION` in `verification/module_validation_registry.json`.
