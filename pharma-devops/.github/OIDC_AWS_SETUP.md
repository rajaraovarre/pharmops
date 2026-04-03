# AWS OIDC Setup for GitHub Actions

GitHub Actions uses OIDC (OpenID Connect) to get short-lived AWS credentials.
No static access keys are stored anywhere. This is the most secure approach.

## How it works

```
GitHub Actions job
  → requests OIDC token from GitHub
  → exchanges token with AWS STS for temporary credentials
  → credentials expire after the job ends
```

## One-time Setup Steps

### Step 1 — Create OIDC Provider in AWS (run once per AWS account)

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### Step 2 — Create IAM Role

Replace `YOUR_GITHUB_ORG` and `YOUR_ACCOUNT_ID` with real values.

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GITHUB_ORG=YOUR_GITHUB_ORG   # e.g., my-company or personal username

cat > /tmp/github-oidc-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/pharma-devops:*"
        }
      }
    }
  ]
}
EOF

# Create the role
aws iam create-role \
  --role-name pharma-github-actions-role \
  --assume-role-policy-document file:///tmp/github-oidc-trust.json

# Attach ECR push permissions
aws iam attach-role-policy \
  --role-name pharma-github-actions-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

echo "Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/pharma-github-actions-role"
```

### Step 3 — Add GitHub Repository Secrets

Go to: **GitHub → pharma-devops repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value |
|------------|-------|
| `AWS_GITHUB_ACTIONS_ROLE_ARN` | `arn:aws:iam::YOUR_ACCOUNT_ID:role/pharma-github-actions-role` |
| `HELM_CHARTS_TOKEN` | GitHub PAT with `repo` scope on pharma-helm-charts repo |
| `HELM_CHARTS_REPO` | `https://github.com/YOUR_ORG/pharma-helm-charts.git` |

### Step 4 — Create GitHub Personal Access Token

1. GitHub → Settings (your profile) → Developer settings → Personal access tokens → Fine-grained tokens
2. Name: `helm-charts-write`
3. Repository access: Only `pharma-helm-charts`
4. Permissions: Contents → Read and Write
5. Copy token → paste as `HELM_CHARTS_TOKEN` secret

### Step 5 — Set Up GitHub Environments (for prod approval gate)

Go to: **GitHub → pharma-devops repo → Settings → Environments**

Create three environments:

**dev**
- No protection rules
- Any branch can deploy

**qa**
- No protection rules
- Any branch can deploy

**prod**
- Required reviewers: add yourself + team leads (min 1 approval)
- Deployment branches: Selected branches → `main` only
- Wait timer: optional (e.g., 5 minutes)

## Verification

After setup, push any change to a feature branch.
Go to: GitHub → Actions tab → watch the pipeline run.

The `Configure AWS credentials` step should show:
```
Assuming role arn:aws:iam::123456789012:role/pharma-github-actions-role
```
No access key/secret key appears anywhere in the logs.
