# Validation Record Workflow

This folder tracks which cleanup modules are validated in real accounts.

## Current module state
- `route53_cleanup_module`: `PENDING_SECONDARY_VERIFICATION`
- `iam_cleanup_module`: `PENDING_SECONDARY_VERIFICATION`
- `ec2_cleanup_module`: `PENDING_SECONDARY_VERIFICATION`
- `billable_cleanup_module`: `PENDING_SECONDARY_VERIFICATION`

## Run
```bash
curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
```

## Runtime records
- Run log: `verification/route53_cleanup_runs.log`
- Registry: `verification/module_validation_registry.json`

## After user verification
When you confirm a module is fully validated, update:
- `status` -> `VERIFIED`
- `verified_by_user` -> `true`
- `notes` with validation scope (account type/edge cases)

This makes future cleanup tasks reuse the same validated requirements without repeating details.
