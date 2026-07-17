# ATS Resume Processing Pipeline — Deployment Guide

## What Are We Building?

When a candidate uploads their resume to the ATS platform, it needs to be:

1. **Scanned for malware** (viruses, malicious content) before the system touches it
2. **Parsed** to extract structured data (name, email, experience, skills, education) so it can be displayed and searched

This pipeline automates both steps using **AWS Lambda**, **S3**, **GuardDuty**, **EventBridge**, **SQS**, and **Bedrock**.

---

## High-Level Flow

```
Candidate uploads resume
        │
        ▼
┌─────────────────────┐
│  S3 Quarantine       │  Resume lands here first (untrusted)
│  Bucket              │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  GuardDuty           │  Scans the file for malware
│  Malware Protection  │
└────────┬────────────┘
         │  scan result (clean or infected)
         ▼
┌─────────────────────┐
│  EventBridge Rule    │  Listens for GuardDuty scan results
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Lambda 1:           │  Moves file to clean or infected bucket
│  ats-resume-scan-    │  Reports result to API
│  mover               │  If clean → sends SQS message
└────────┬────────────┘
         │  (SQS message, only if clean)
         ▼
┌─────────────────────┐
│  Lambda 2:           │  Downloads resume from clean bucket
│  ats-resume-parser-  │  Extracts text (PDF/DOCX)
│  consumer            │  Calls Bedrock to parse structured data
│                      │  Reports parsed data back to API
└─────────────────────┘
```

---

## Buckets (Already Created)

| Purpose | Bucket Name | Environment |
|---|---|---|
| Quarantine (upload destination) | `dev-ats-resumes-quarantine` | Dev |
| Clean (approved resumes) | `dev-ats-resume` | Dev |
| Infected (malicious resumes) | `dev-ats-resume-infected` | Dev |
| Quarantine | `stagging-ats-resumes-quarantine` | Staging |
| Clean | `stagging-ats-resume` | Staging |
| Infected | `stagging-ats-resume-infected` | Staging |
| Quarantine | `prod-ats-resumes-quarantine` | Prod |
| Clean | `prod-ats-resume` | Prod |
| Infected | `prod-ats-resume-infected` | Prod |

---

## Pre-requisites Before Starting

Before deploying anything, make sure you have:

1. **AWS Console access** with permissions to create Lambda, IAM, SQS, EventBridge resources
2. **Your internal API key** — a secret key your backend API uses to verify that the lambda is the one calling (not a random attacker). You'll need to set this in your backend first.
3. **Bedrock model access enabled** — go to AWS Console → Bedrock → Model access → request access to `Amazon Nova Pro`
4. **The two lambda zip files** built and ready:
   - `resume_scan_mover/dist/resume_scan_mover.zip`
   - `resume_parser_consumer/dist/resume_parser_consumer.zip`

---

## Step-by-Step Implementation

### STEP 1: Build the Lambda Deployment Zips

You need to create the `.zip` files that AWS Lambda will run.

**For ats-resume-scan-mover (no third-party dependencies):**

```bash
cd resume_scan_mover
bash build.sh
# Output: dist/resume_scan_mover.zip
```

**For ats-resume-parser-consumer (needs PyMuPDF + python-docx):**

```bash
cd resume_parser_consumer
bash build.sh
# Output: dist/resume_parser_consumer.zip
```

> If `build.sh` fails because of platform issues, you need Docker installed. The script cross-compiles Python packages for Linux (Lambda's OS) even if you're on Mac/Windows.

---

### STEP 2: Create an IAM Role for Lambda

Both lambdas need an IAM role to access S3, SQS, Bedrock, and CloudWatch Logs.

**In AWS Console:**

1. Go to **IAM** → **Roles** → **Create role**
2. Trusted entity type: **AWS service**
3. Use case: **Lambda** → **Next**
4. Search and attach these **permission policies**:

   - `AmazonS3FullAccess` (or create a custom policy with only the 3 buckets)
   - `AmazonSQSFullAccess` (or restrict to the specific queue)
   - `AmazonBedrockFullAccess` (or restrict to InvokeModel only)
   - `CloudWatchLogsFullAccess`

5. Role name: `ats-lambda-resume-role`
6. Click **Create role**

> **Note:** In production, you should create a tighter policy instead of using *FullAccess. For initial setup and testing, FullAccess is fine.

---

### STEP 3: Enable Amazon Bedrock Model Access

The parser lambda calls Bedrock to extract structured data from resume text.

1. Go to **AWS Console** → **Amazon Bedrock**
2. Left sidebar → **Model access**
3. Click **Request model access**
4. Find **Amazon Nova Pro** → click **Request access**
5. Wait for approval (usually instant for Nova models)
6. You should see status **Access granted**

> The model ID we'll use is: `amazon.nova-pro-v1:0`

---

### STEP 4: Create the SQS Queue

This queue connects the two lambdas. When the mover finds a clean resume, it puts a message here. The consumer picks it up.

1. Go to **AWS Console** → **Amazon SQS**
2. Click **Create queue**
3. Type: **Standard**
4. Name: `ats-resume-parse-queue`
5. Leave all other settings as default
6. Click **Create queue**
7. **Copy the queue URL** — you'll need it later (looks like `https://sqs.ap-south-1.amazonaws.com/123456789/ats-resume-parse-queue`)

---

### STEP 5: Deploy Lambda 1 — ats-resume-scan-mover

This lambda receives GuardDuty scan results and moves files.

**5.1 Create the function:**

1. Go to **AWS Console** → **Lambda**
2. Click **Create function**
3. Select **Author from scratch**
4. Function name: `ats-resume-scan-mover`
5. Runtime: **Python 3.12**
6. Architecture: **x86_64**
7. Execution role: **Use an existing role** → select `ats-lambda-resume-role`
8. Click **Create function**

**5.2 Upload the code:**

1. In the function page, scroll to **Code source**
2. Click **Upload from** → **.zip file**
3. Select `resume_scan_mover/dist/resume_scan_mover.zip`
4. Click **Save**

**5.3 Set environment variables:**

1. Go to **Configuration** tab → **Environment variables**
2. Click **Edit**
3. Add these variables:

| Key | Value | Notes |
|---|---|---|
| `QUARANTINE_BUCKET` | `dev-ats-resumes-quarantine` | Where uploads land |
| `CLEAN_BUCKET` | `dev-ats-resume` | Where clean files go |
| `INFECTED_BUCKET` | `dev-ats-resume-infected` | Where infected files go |
| `SQS_QUEUE_URL` | *(paste the queue URL from Step 4)* | For sending parse messages |
| `API_BASE_URL` | `https://staging-athena.fissionlabs.in` | Your backend API |
| `INTERNAL_API_KEY` | *(your secret key)* | Shared secret with API |
| `PRESIGNED_URL_EXPIRY_SECONDS` | `300` | How long presigned URLs last |

4. Click **Save**

**5.4 Set timeout:**

1. Go to **Configuration** → **General configuration**
2. Click **Edit**
3. Timeout: **5 minutes** (300 seconds)
4. Click **Save**

---

### STEP 6: Deploy Lambda 2 — ats-resume-parser-consumer

This lambda reads clean resumes from S3, extracts text, and calls Bedrock.

**6.1 Create the function:**

1. Go to **AWS Console** → **Lambda**
2. Click **Create function**
3. Select **Author from scratch**
4. Function name: `ats-resume-parser-consumer`
5. Runtime: **Python 3.12**
6. Architecture: **x86_64**
7. Execution role: **Use an existing role** → select `ats-lambda-resume-role`
8. Click **Create function**

**6.2 Upload the code:**

1. In the function page, scroll to **Code source**
2. Click **Upload from** → **.zip file**
3. Select `resume_parser_consumer/dist/resume_parser_consumer.zip`
4. Click **Save**

**6.3 Set environment variables:**

1. Go to **Configuration** tab → **Environment variables**
2. Click **Edit**
3. Add these variables:

| Key | Value | Notes |
|---|---|---|
| `API_BASE_URL` | `https://staging-athena.fissionlabs.in` | Your backend API |
| `INTERNAL_API_KEY` | *(your secret key)* | Same key as mover lambda |
| `BEDROCK_MODEL_ID` | `amazon.nova-pro-v1:0` | Amazon Nova Pro |
| `AWS_REGION` | `ap-south-1` | Mumbai region |
| `PRESIGNED_URL_EXPIRY_SECONDS` | `300` | How long presigned URLs last |

4. Click **Save**

**6.4 Set timeout:**

1. Go to **Configuration** → **General configuration**
2. Click **Edit**
3. Timeout: **5 minutes** (300 seconds)
4. Click **Save**

---

### STEP 7: Connect SQS Queue to the Consumer Lambda

This tells AWS: "When a message arrives in the queue, run the consumer lambda."

1. Go to **Lambda** → click on `ats-resume-parser-consumer`
2. Go to **Configuration** → **Triggers** → **Add trigger**
3. Select trigger type: **SQS**
4. Select queue: `ats-resume-parse-queue`
5. Batch size: **10** (process up to 10 messages per invocation)
6. Check **Report batch item failures** ✅ (so one bad message doesn't block the rest)
7. Click **Add**

---

### STEP 8: Create the EventBridge Rule

This tells AWS: "When GuardDuty finishes scanning a file, run the mover lambda."

1. Go to **AWS Console** → **Amazon EventBridge**
2. Left sidebar → **Rules** → **Create rule**
3. **Name:** `guardduty-malware-scan-to-mover`
4. **Event bus:** `default`
5. **Rule type:** Select **Rule with an event pattern** → **Next**
6. Under **Event pattern**, select:
   - **Event source:** AWS services
   - **AWS service:** GuardDuty
   - **Event type:** GuardDuty Malware Protection Object Scan Result
7. Or choose **Custom patterns (JSON editor)** and paste:

```json
{
  "source": ["aws.guardduty"],
  "detail-type": ["GuardDuty Malware Protection Object Scan Result"],
  "detail": {
    "scanStatus": ["COMPLETED"]
  }
}
```

8. Click **Next**
9. Under **Target**, select:
   - **Target 1:** Lambda function
   - **Function:** `ats-resume-scan-mover`
10. Click **Next**
11. Review → click **Create rule**

---

### STEP 9: Grant EventBridge Permission to Invoke the Mover Lambda

AWS Console usually does this automatically when you create the rule. But if it doesn't:

1. Go to **Lambda** → `ats-resume-scan-mover`
2. Go to **Configuration** → **Triggers**
3. You should see an EventBridge rule listed. If not, add it manually:

Via AWS CLI (if you have it):
```bash
aws lambda add-permission \
  --function-name ats-resume-scan-mover \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn arn:aws:events:ap-south-1:YOUR_ACCOUNT_ID:rule/guardduty-malware-scan-to-mover
```

---

### STEP 10: Verify Backend API Endpoints Exist

The lambdas call these API endpoints. Make sure your backend has them:

| Endpoint | Called by | Purpose |
|---|---|---|
| `POST /internal/documents/{id}/scan-result` | Mover | Reports clean/infected status |
| `POST /internal/documents/{id}/parse-started` | Consumer | Reports parsing started |
| `POST /internal/documents/{id}/parse-result` | Consumer | Reports parsed JSON or failure |

All requests include header: `X-Internal-Api-Key: <your-internal-api-key>`

> **Important:** These endpoints must accept the `X-Internal-Api-Key` header for authentication. If your backend doesn't have these endpoints yet, the lambdas will fail with HTTP errors.

---

## Testing the Pipeline

### Test 1: Upload a PDF to the quarantine bucket

1. Go to **S3** → `dev-ats-resumes-quarantine`
2. Click **Upload** → select a test PDF
3. Wait 1-2 minutes for GuardDuty to scan

### Test 2: Check GuardDuty

1. Go to **GuardDuty** → **Findings**
2. You should see a finding for the uploaded file
3. Status should be **COMPLETED** with **NO_THREATS_FOUND** (if file is clean)

### Test 3: Check the mover lambda

1. Go to **Lambda** → `ats-resume-scan-mover` → **Monitor** → **Log groups**
2. Open the latest log stream
3. You should see: `document_id=... clean=True moving s3://...`
4. Check S3: the file should now be in `dev-ats-resume` (clean bucket)

### Test 4: Check the consumer lambda

1. Go to **Lambda** → `ats-resume-parser-consumer` → **Monitor** → **Log groups**
2. Open the latest log stream
3. You should see: `Parsed document_id=... successfully`

### Test 5: Check SQS

1. Go to **SQS** → `ats-resume-parse-queue` → **Monitoring**
2. You should see messages were sent (from mover) and received (by consumer)

---

## Environment Variables Reference

### ats-resume-scan-mover

| Variable | Description | Dev Value |
|---|---|---|
| `QUARANTINE_BUCKET` | Bucket where uploads land | `dev-ats-resumes-quarantine` |
| `CLEAN_BUCKET` | Bucket for clean files | `dev-ats-resume` |
| `INFECTED_BUCKET` | Bucket for infected files | `dev-ats-resume-infected` |
| `SQS_QUEUE_URL` | SQS queue URL | *(from Step 4)* |
| `API_BASE_URL` | Backend API base URL | `https://staging-athena.fissionlabs.in` |
| `INTERNAL_API_KEY` | Secret key for API auth | *(your secret)* |
| `PRESIGNED_URL_EXPIRY_SECONDS` | URL expiry time | `300` |

### ats-resume-parser-consumer

| Variable | Description | Dev Value |
|---|---|---|
| `API_BASE_URL` | Backend API base URL | `https://staging-athena.fissionlabs.in` |
| `INTERNAL_API_KEY` | Secret key for API auth | *(your secret)* |
| `BEDROCK_MODEL_ID` | Bedrock model to use | `amazon.nova-pro-v1:0` |
| `AWS_REGION` | AWS region | `ap-south-1` |
| `PRESIGNED_URL_EXPIRY_SECONDS` | URL expiry time | `300` |

---

## Deployment Order Summary

```
Step 1:  Build lambda zips
Step 2:  Create IAM role
Step 3:  Enable Bedrock model access
Step 4:  Create SQS queue
Step 5:  Deploy ats-resume-scan-mover
Step 6:  Deploy ats-resume-parser-consumer
Step 7:  Connect SQS → consumer lambda (trigger)
Step 8:  Create EventBridge rule (GuardDuty → mover)
Step 9:  Verify EventBridge has invoke permission
Step 10: Verify backend API endpoints exist
```

---

## Troubleshooting

| Problem | Check |
|---|---|
| Mover lambda not triggering | EventBridge rule exists and targets the right lambda? |
| Mover fails with "Access Denied" on S3 | IAM role has S3 permissions on all 3 buckets? |
| Consumer not receiving messages | SQS trigger added to consumer? Queue URL correct? |
| Bedrock invocation fails | Model access enabled in Bedrock console? Model ID correct? |
| API returns 401 | `INTERNAL_API_KEY` matches what backend expects? |
| API returns 404 | Backend endpoints `/scan-result`, `/parse-started`, `/parse-result` exist? |
| Presigned URL expired | Increase `PRESIGNED_URL_EXPIRY_SECONDS` or check clock sync |
