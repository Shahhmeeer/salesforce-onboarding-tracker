# Onboarding Tracker — Project Spec

This document is the single source of truth for the build. It explains what we are building, why, and how. It is written in plain English so anyone can read it: a developer picking up the work, a reviewer, or a business user who wants to understand how the system behaves.

If something in the code disagrees with this spec, either the code is wrong or the spec needs updating. Do not leave them out of sync.

---

## Table of contents

1. Background and the problem
2. Goals and non-goals
3. Environment and setup
4. Conventions
5. Data model
6. Automation design
7. CSM assignment (the core logic)
8. Stage tracking
9. Validation rules
10. Security and sharing
11. App and record page
12. Reports and dashboard
13. Testing plan
14. Demo data and post-deploy setup
15. Assumptions log
16. Known limitations and next steps
17. How this scales
18. Stretch goal: business days
19. Build order
20. Decisions to be ready to defend

---

## 1. Background and the problem

SkyPath AI is a B2B SaaS company. Sales closes deals (Opportunities) in Salesforce. After a deal is won, the Customer Success (CS) team runs a structured onboarding until the customer is live.

Today, onboarding is tracked in spreadsheets and Slack. The VP of Customer Success has three problems:

| Problem         | What it looks like today                                                                                               |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| No visibility   | Leadership cannot see which stage each customer is in, or where customers get stuck.                                   |
| Uneven workload | Some Customer Success Managers (CSMs) carry 12 onboardings, others carry 3. New customers go to whoever notices first. |
| Slow starts     | Some customers wait days after the deal closes before anyone picks them up.                                            |

The fix: an onboarding tracker inside Salesforce that creates onboardings automatically, assigns them fairly within each CSM's capacity, enforces the process, and records how long each stage takes.

---

## 2. Goals and non-goals

### Goals

- Every won deal gets exactly one onboarding, automatically.
- Onboardings follow the six stages in order. Required notes are captured.
- The date each stage was first reached is recorded and never changes.
- Time spent in each stage is reportable, including rework (going backwards).
- New onboardings are assigned to the eligible CSM with the fewest active onboardings, within their capacity.
- When everyone is full, onboardings go to a backlog queue and CS managers are notified.
- All of the above works when 200 deals are closed in one bulk load.
- A record page that shows a CSM what matters today.
- Everything deploys to a fresh org from Git.

### Non-goals (deliberately out of scope)

- No custom Lightning Web Components unless time is left at the end. Standard components, configured well, are enough.
- No CI pipeline in this build. It is listed as a next step.
- No automatic redistribution of the backlog when a CSM frees up. Listed as a next step.
- Business-day durations are designed (section 18) but not built.

---

## 3. Environment and setup

### 3.1 Orgs

| Org                                              | Purpose                                                                                                      |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| Developer Edition org ("Shahmeer Developer Org") | Where we build and demo. Also acts as the Dev Hub.                                                           |
| Scratch org (created from the Dev Hub)           | A fresh, empty org used to prove the repo deploys cleanly with `sf project deploy start`. Thrown away after. |

**Why a fresh org:** the build org collects manual Setup changes that never reach the repo. Deploying back into the same org always "works" because those pieces already exist. Only a fresh org shows what is missing.

### 3.2 Dev Hub and scratch orgs (how to use)

- **Dev Hub** is a feature you switch on in an org. It lets that org create scratch orgs. Enable it in Setup → Dev Hub. This is permanent, but it does nothing harmful to the org.
- **Scratch org** is a temporary, empty org built from a config file (`config/project-scratch-def.json`). It lives 1 to 30 days and then deletes itself.

Commands:

```bash
# Connect the Dev Hub (one time)
sf org login web --set-default-dev-hub --alias devhub

# Create a scratch org that lives 7 days
sf org create scratch --definition-file config/project-scratch-def.json --alias onb-fresh --duration-days 7 --set-default

# Deploy everything
sf project deploy start --target-org onb-fresh

# Run all tests
sf apex run test --target-org onb-fresh --test-level RunLocalTests --wait 10 --result-format human

# Open it
sf org open --target-org onb-fresh
```

Developer Edition Dev Hubs have small daily and active scratch-org limits. We only need one or two.

### 3.3 Licenses in the build org

| License             | Total | Used | Notes                                                                                                                                             |
| ------------------- | ----- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Salesforce          | 4     | 2    | Used by the admin user and the "OrgFarm EPIC" user. Do not modify or reuse the OrgFarm EPIC user; it is created by Salesforce's own provisioning. |
| Salesforce Platform | 6     | 0    | Used for the demo CSM users.                                                                                                                      |

**Important:** Salesforce Platform users cannot access Opportunities, Leads or Cases. They can access Accounts, Contacts, custom objects, reports and dashboards. This is why the Onboarding stores a direct Account lookup (see 5.1): a CSM on a Platform license can still see which customer it is. In a real company, CSMs would usually have full Salesforce licenses. This is noted in the assumptions log.

### 3.4 Demo users

| User                  | License             | Role in demo                                                                                      |
| --------------------- | ------------------- | ------------------------------------------------------------------------------------------------- |
| Admin (the developer) | Salesforce          | System admin and member of the `CS_Managers` group. Not a CSM.                                    |
| 4 CSM users           | Salesforce Platform | CSMs that receive assignments. Profile: Standard Platform User. Permission set: `Onboarding_CSM`. |

Demo capacities: 30, 40, 40, 60 (total 170). Bulk-closing 200 deals then shows fair distribution and 30 onboardings overflowing to the backlog.

### 3.5 Repository

- **Name:** `salesforce-onboarding-tracker`
- **Visibility:** private. The reviewer is added as a collaborator.
- **Format:** SFDX source format.

Folder layout:

```
salesforce-onboarding-tracker/
├── README.md                     Short: what it is, deploy steps, setup, run tests
├── sfdx-project.json
├── config/
│   └── project-scratch-def.json  Scratch org definition
├── docs/
│   └── project-spec.md           This file
├── data/
│   └── demo-opportunities.csv    200 opportunities for the bulk demo
├── scripts/
│   └── apex/
│       ├── seed-csm-capacity.apex
│       └── seed-demo-data.apex
└── force-app/main/default/       All metadata
```

Repo hygiene:

- `sfdx-project.json` sets `sourceApiVersion` to `67.0`.
- `.gitignore` excludes `.sf/`, `.sfdx/`, local org config, logs and editor files.
- `.forceignore` excludes anything not meant to deploy (e.g. local test data, profiles pulled by accident).
- Before submitting, run Salesforce Code Analyzer (`sf code-analyzer run`) on the Apex and fix anything serious. It is a cheap quality check reviewers notice.

### 3.6 Branches and commits

- `main` holds finished, working code only.
- One branch per feature, merged into `main` through a pull request (merge commit, not squash, so history stays readable):
  - `feature/data-model`
  - `feature/trigger-framework`
  - `feature/onboarding-creation`
  - `feature/stage-tracking`
  - `feature/csm-assignment`
  - `feature/record-page`
  - `feature/reports`
  - `feature/demo-data`
- Commit messages use a simple prefix: `feat:`, `fix:`, `test:`, `docs:`, `chore:`. Example: `feat: assign new onboardings to least-loaded CSM`.
- Branch protection on `main` is not available for private repos on the free GitHub plan. That is fine for this build.

---

## 4. Conventions

### 4.1 Naming

| Item                     | Convention                                               | Example                                                   |
| ------------------------ | -------------------------------------------------------- | --------------------------------------------------------- |
| Custom object            | Title_Case words joined by underscores                   | `Onboarding__c`, `Onboarding_Stage__c`, `CSM_Capacity__c` |
| Custom field             | Same as objects, describes the value, not the UI         | `Target_Go_Live_Date__c`                                  |
| Checkbox / boolean field | Starts with `Is_`, `Has_`, or reads as a yes/no question | `Is_Active__c`, `Counts_Toward_Capacity__c`               |
| Custom metadata type     | Same as objects, `__mdt`                                 | `Onboarding_Setting__mdt`                                 |
| Custom setting           | Same as objects                                          | `Automation_Bypass__c`                                    |
| Picklist API values      | Title_Case with underscores; labels are human text       | API `QA_Review`, label `QA / Review`                      |
| Validation rule          | Says what it stops or requires                           | `Prevent_Stage_Skipping`, `Require_Gathering_Info_Notes`  |
| Apex trigger             | `<Object>Trigger`                                        | `OpportunityTrigger`, `OnboardingTrigger`                 |
| Apex handler             | `<Object>TriggerHandler`                                 | `OnboardingTriggerHandler`                                |
| Apex service             | Noun describing the job + `Service` / descriptive noun   | `CsmAssignmentService`, `OnboardingStageTracker`          |
| Apex test                | Class name + `Test`                                      | `CsmAssignmentServiceTest`                                |
| Permission set           | `Onboarding_<Persona>`                                   | `Onboarding_CSM`, `Onboarding_Manager`                    |
| Queue / group            | Purpose in Title_Case                                    | `Onboarding_Backlog`, `CS_Managers`                       |
| Flow                     | `<Object>_<Timing>_<Purpose>`                            | `CSM_Capacity_Before_Save_Set_User_Key`                   |
| Report / dashboard       | Plain English title                                      | "Average Days per Stage"                                  |

The word "CSM" stays uppercase because it is an acronym the business uses. In Apex class names it follows Apex camel case: `CsmAssignmentService`.

### 4.2 Descriptions (required everywhere)

Every object, field, validation rule, permission set, queue, group, custom metadata type, custom setting, custom notification type, flow, report type and Apex class gets a description.

- One or two sentences.
- Say what it is for and anything non-obvious (who sets it, whether users can edit it).
- Do not restate the label.

Good: "Date and time this stage was first reached. Set once by automation and never changed, even if the onboarding moves backwards."
Bad: "First Reached field."

Fields that users see also get **help text** when the meaning is not obvious.

Every validation rule has an **error message a CSM understands**, written as what to do, not what went wrong in system terms.

### 4.3 Apex style

- Each class starts with a short header comment: what it does and why it exists.
- Each public method gets a short comment if its purpose is not obvious from the name. Comments explain _why_, not _what_.
- No hardcoded record IDs, user IDs, queue IDs, profile IDs or usernames. Look things up by DeveloperName or API name.
- Every SOQL and DML is outside loops.
- `without sharing` is used only where explained in the class header (see section 10).
- User-facing error messages thrown or added from Apex come from **Custom Labels**, not string literals, so admins can reword or translate them without a deployment.

### 4.5 API version and access mode (important)

All Apex classes, triggers and the project use **API version 67.0**, the version the project was generated with. Never go lower than 67.0. The build org itself runs a newer version, which is fine. Set `sourceApiVersion` to `67.0` in `sfdx-project.json` and `apiVersion` to `67.0` in every `-meta.xml`.

**Why this matters.** From API 67.0, Salesforce changed two defaults:

| Behaviour                     | API 66.0 and earlier                                             | API 67.0 and later                                                                               |
| ----------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| SOQL, SOSL and DML            | System mode (ignores the user's object, field and record access) | **User mode** (enforces the running user's object permissions, field-level security and sharing) |
| Class with no sharing keyword | Without sharing (in most contexts)                               | **With sharing**                                                                                 |
| `WITH SECURITY_ENFORCED`      | Supported                                                        | Not supported. Use `WITH USER_MODE`.                                                             |

If we leave the default, code that worked in testing as an admin can fail or silently return fewer records for a CSM or a sales user. So we never rely on the default.

**Rules for this project:**

1. **Every class declares its sharing keyword** (`with sharing`, `without sharing` or `inherited sharing`). No class is left blank.
2. **Every SOQL query declares its mode:** `WITH USER_MODE` or `WITH SYSTEM_MODE`.
3. **Every DML statement declares its mode:** `insert as user` / `insert as system` (same for update, upsert, delete), or `Database.insert(records, allOrNone, AccessLevel.SYSTEM_MODE)` / `AccessLevel.USER_MODE`.
4. **Every use of system mode has a one-line comment saying why.**
5. Triggers themselves always run in system context, but the classes they call follow the rules above.

**Which mode, where:**

| Operation                                                                           | Mode   | Why                                                                                                     |
| ----------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------- |
| Opportunity handler: find existing onboardings, insert new ones, update status      | System | The user closing the deal is a sales user who has no access to onboardings. Creation must still happen. |
| Onboarding handler: read related Opportunities and Accounts for defaults and naming | System | CSMs on Platform licenses cannot read Opportunities. The name must still be built.                      |
| Assignment: lock CSM Capacity rows, count onboardings, look up the backlog queue    | System | Must see every CSM and every onboarding regardless of who triggered it.                                 |
| Stage tracker: read and upsert Onboarding Stage rows                                | System | CSMs can only read stage rows. Automation writes them on their behalf.                                  |
| Backlog notification: look up the CS Managers group                                 | System | Same reason as assignment.                                                                              |
| Seed scripts                                                                        | System | Run by an admin for setup.                                                                              |

There is no user-mode database operation in the core automation, because every operation is done by the system on the user's behalf. If anyone later adds code that reads or writes data **as the user** (for example, an LWC controller), that code must use `WITH USER_MODE` / `as user`.

### 4.4 Class layering rule

We add a layer only when it earns its place.

- A class gets split into handler / service / selector only when it grows big enough that one class has several unrelated jobs.
- No selector classes or unit-of-work classes. Queries live in the class that uses them.
- We deliberately do not use a large framework (such as fflib Apex Enterprise Patterns or a third-party trigger framework). The domain is small; a framework would add more code to read than it saves. This is stated in the write-up.

---

## 5. Data model

```
Opportunity (standard)
   │  1 ──── 0..1   (required Lookup, delete restricted, unique key)
   ▼
Onboarding__c ───── Account (standard, lookup, copied from the Opportunity)
   │  owned by a CSM user or the Onboarding_Backlog queue
   │  1 ──── 0..6   (Master-Detail)
   ▼
Onboarding_Stage__c   (one row per stage reached)

CSM_Capacity__c ───── User (lookup)       who can be assigned, and how many

Onboarding_Setting__mdt                    org-wide configuration
Automation_Bypass__c (hierarchy setting)   switch automation off for data loads
Global value set: Onboarding_Stage         the six stages, shared by both picklists
```

### 5.1 Onboarding__c

Label: Onboarding. Plural: Onboardings. Name field: Text(80), set by automation.

Description: "One customer's onboarding after a deal is won. Created automatically when an Opportunity is won. Owned by the assigned CSM, or by the Onboarding Backlog queue when every CSM is full."

Sharing: Public Read Only (see section 10). Field history tracking: on.

| Field                       | Type                                                                                   | Set by                             | Description                                                                                                                                                                |
| --------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Name`                      | Text(80)                                                                               | Automation (every save)            | Customer name and target launch date, e.g. `Acme Corp - Go Live 2026-11-20`. Rebuilt on every save so it always matches the data.                                          |
| `Opportunity__c`            | Lookup(Opportunity), required, delete restricted                                       | Automation / user on manual create | The won deal this onboarding belongs to. Required, cannot be changed after creation, and the Opportunity cannot be deleted while this exists.                              |
| `Opportunity_Key__c`        | Text(18), Unique, External ID                                                          | Automation                         | Copy of the Opportunity ID. Marked unique so the database itself blocks a second onboarding for the same deal, no matter how it is created. Hidden from page layouts.      |
| `Account__c`                | Lookup(Account)                                                                        | Automation                         | The customer. Copied from the Opportunity at creation. Lets users without Opportunity access see the customer.                                                             |
| `Stage__c`                  | Picklist (global value set `Onboarding_Stage`), required, default `Kickoff_Scheduled`  | User                               | Current onboarding stage. Field history tracked.                                                                                                                           |
| `Status__c`                 | Picklist: `Active`, `On_Hold`, `Cancelled`. Default `Active`.                          | Automation, managers               | Whether the onboarding is running. On Hold when the deal is reopened by Sales; Cancelled when the deal is lost. Field history tracked.                                     |
| `Status_Reason__c`          | Text(255)                                                                              | Automation, managers               | Why the onboarding is On Hold or Cancelled. Required when Status is not Active.                                                                                            |
| `Target_Go_Live_Date__c`    | Date                                                                                   | Automation default, then the CSM   | Planned launch date. Defaults to the Opportunity close date plus the default days in Onboarding Setting. The CSM updates it after the kickoff call. Field history tracked. |
| `Gathering_Info_Notes__c`   | Long Text Area(32768)                                                                  | CSM                                | Notes captured during information gathering. Required before moving past Gathering Info.                                                                                   |
| `Implementation_Notes__c`   | Long Text Area(32768)                                                                  | CSM                                | Notes captured during implementation. Required before moving past Implementation.                                                                                          |
| `Current_Stage_Entered__c`  | Date/Time                                                                              | Automation                         | When the onboarding entered its current stage (this visit). Used for "days in current stage". Read-only.                                                                   |
| `Days_In_Current_Stage__c`  | Formula (Number, 1 dp)                                                                 | Formula                            | `NOW() - Current_Stage_Entered__c`. Days spent in the current stage on this visit.                                                                                         |
| `Days_To_Go_Live__c`        | Formula (Number, 0 dp)                                                                 | Formula                            | `Target_Go_Live_Date__c - TODAY()`. Negative means the target date has passed.                                                                                             |
| `Is_At_Risk__c`             | Formula (Checkbox)                                                                     | Formula                            | True when the target go-live date has passed and the onboarding has not reached Go Live yet, and it is Active.                                                             |
| `Counts_Toward_Capacity__c` | Formula (Checkbox)                                                                     | Formula                            | True when the onboarding uses up one of the owner's capacity slots: Status is not Cancelled and Stage is not Post-Launch Review. On Hold still counts (see assumption A9). |
| `Go_Live_Reached__c`        | Roll-up summary: MIN of `Onboarding_Stage__c.First_Reached__c` where Stage = `Go_Live` | Roll-up                            | When the onboarding first reached Go Live.                                                                                                                                 |
| `Days_To_Launch__c`         | Formula (Number, 1 dp)                                                                 | Formula                            | Days from onboarding creation to first reaching Go Live. Blank until Go Live is reached.                                                                                   |

Formula sketches:

```
Counts_Toward_Capacity__c:
  AND( NOT(ISPICKVAL(Status__c, "Cancelled")), NOT(ISPICKVAL(Stage__c, "Post_Launch_Review")) )

Is_At_Risk__c:
  AND(
    ISPICKVAL(Status__c, "Active"),
    NOT(ISBLANK(Target_Go_Live_Date__c)),
    Target_Go_Live_Date__c < TODAY(),
    OR(ISPICKVAL(Stage__c, "Kickoff_Scheduled"), ISPICKVAL(Stage__c, "Gathering_Info"),
       ISPICKVAL(Stage__c, "Implementation"), ISPICKVAL(Stage__c, "QA_Review"))
  )

Days_To_Launch__c:
  IF(ISBLANK(Go_Live_Reached__c), NULL, Go_Live_Reached__c - CreatedDate)
```

### 5.2 Onboarding_Stage__c

Label: Onboarding Stage. Plural: Onboarding Stages. Name field: Text(80), set to the stage label by automation.

Description: "One row per stage an onboarding has reached. Records when the stage was first reached, how many times it was visited, and total days spent in it, including rework. Created and updated only by automation."

Relationship: Master-Detail to `Onboarding__c`. Sharing: Controlled by Parent. Users can read but not create, edit or delete.

| Field                      | Type                                           | Description                                                                                                                       |
| -------------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `Onboarding__c`            | Master-Detail(Onboarding__c)                   | The onboarding this stage belongs to.                                                                                             |
| `Stage__c`                 | Picklist (global value set `Onboarding_Stage`) | Which stage this row tracks.                                                                                                      |
| `Unique_Key__c`            | Text(100), Unique, External ID                 | `<Onboarding Id>-<Stage API value>`. Guarantees one row per stage per onboarding and lets automation upsert. Hidden from layouts. |
| `First_Reached__c`         | Date/Time                                      | When this stage was first reached. Set once and never changed, even if the onboarding goes back and forth.                        |
| `Current_Visit_Started__c` | Date/Time                                      | When the current visit to this stage started. Blank when the onboarding is not in this stage.                                     |
| `Completed_Visit_Days__c`  | Number(18, 10)                                 | Total days from earlier, finished visits to this stage. Kept unrounded; `Days_In_Stage__c` rounds it (A28).                       |
| `Days_In_Stage__c`         | Formula (Number, 2 dp)                         | Total days in this stage across all visits, including the current one if still in it.                                             |
| `Visit_Count__c`           | Number(3, 0)                                   | How many times the onboarding has entered this stage. More than 1 means rework.                                                   |
| `Is_Current_Stage__c`      | Formula (Checkbox)                             | True when the onboarding is in this stage right now.                                                                              |
| `Stage_Sequence__c`        | Formula (Number)                               | Position of the stage (1 to 6). Used to sort the related list and reports.                                                        |

```
Days_In_Stage__c:
  Completed_Visit_Days__c + IF(ISBLANK(Current_Visit_Started__c), 0, NOW() - Current_Visit_Started__c)

Is_Current_Stage__c:
  NOT(ISBLANK(Current_Visit_Started__c))
```

### 5.3 CSM_Capacity__c

Label: CSM Capacity. Plural: CSM Capacities. Name field: Auto Number `CAP-{0000}`.

Description: "Who can receive new onboardings and how many active onboardings each person can hold. Admins and CS managers add, pause or change CSMs here without a developer."

Sharing: Private. Managers and admins get access through `Onboarding_Manager`.

| Field                       | Type                                                                               | Description                                                                                                                                                                                             |
| --------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `User__c`                   | Lookup(User), optional at field level; required via validation rule `Require_User` | The CSM. Salesforce does not allow a required lookup to User (a required lookup needs a delete constraint, and User lookups cannot have one), so "required" is enforced by a validation rule (see A19). |
| `User_Key__c`               | Text(18), Unique                                                                   | Copy of the User ID, set by a before-save flow. Stops two capacity records for the same person. Hidden from layouts.                                                                                    |
| `Is_Active__c`              | Checkbox, default true                                                             | Untick to stop new assignments to this CSM (holiday, leaving the team) without losing their settings.                                                                                                   |
| `Max_Active_Onboardings__c` | Number(3, 0), required                                                             | Maximum onboardings this CSM can hold that count toward capacity. 0 means no new assignments.                                                                                                           |

**Why a custom object and not custom metadata** (for the write-up):

1. CSM membership is people data that changes often, not configuration.
2. Custom metadata cannot look up to User. Usernames differ in every org, so a deployed record would point at a user that does not exist.
3. The assignment logic must lock each CSM's row with `FOR UPDATE` to stop two parallel loads over-assigning. Custom metadata rows cannot be locked.

### 5.4 Onboarding_Setting__mdt (custom metadata type)

Description: "Org-wide settings for onboarding automation. One record named Default."

| Field                        | Type   | Default record value       | Description                                                                    |
| ---------------------------- | ------ | -------------------------- | ------------------------------------------------------------------------------ |
| `Default_Days_To_Go_Live__c` | Number | 30                         | Days added to the Opportunity close date to set the first target go-live date. |
| `Backlog_Queue_Name__c`      | Text   | `Onboarding_Backlog`       | DeveloperName of the queue that receives onboardings when every CSM is full.   |
| `Manager_Group_Name__c`      | Text   | `CS_Managers`              | DeveloperName of the public group notified about backlog onboardings.          |
| `Notification_Type_Name__c`  | Text   | `Onboarding_Backlog_Alert` | DeveloperName of the custom notification type used for backlog alerts.         |

### 5.5 Automation_Bypass__c (hierarchy custom setting) — the kill switch

Description: "Kill switch for onboarding automation. Lets an admin switch off triggers, flows and validation rules for one user, one profile or the whole org, for example during a bulk data fix or migration. No deployment needed."

**Why a custom setting and not custom metadata:** the kill switch must be on for one person (say, the user running a data load) and off for everyone else at the same moment. Hierarchy custom settings are built for exactly that: org default, then profile, then user. Custom metadata is the same for everyone.

**Rule of thumb for this project:** configuration that moves between orgs with the code goes in **custom metadata**. Switches that differ per user go in **custom settings**. People data goes in a **custom object**.

| Field                        | Type     | Description                                                                                                             |
| ---------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------- |
| `Bypass_Triggers__c`         | Checkbox | When ticked, all onboarding-related Apex trigger handlers stop at the start and do nothing for this user.               |
| `Bypass_Flows__c`            | Checkbox | When ticked, onboarding record-triggered flows do nothing for this user. Every flow checks this in its entry condition. |
| `Bypass_Validation_Rules__c` | Checkbox | When ticked, onboarding validation rules do not fire for this user. Every validation rule checks this first.            |

How each piece checks the switch:

| Automation       | Check                                                                                                      |
| ---------------- | ---------------------------------------------------------------------------------------------------------- |
| Apex handlers    | `TriggerHandler.run()` reads `Automation_Bypass__c.getInstance().Bypass_Triggers__c` before anything else. |
| Flows            | Entry condition includes `{!$Setup.Automation_Bypass__c.Bypass_Flows__c} = false`.                         |
| Validation rules | Formula starts with `NOT($Setup.Automation_Bypass__c.Bypass_Validation_Rules__c) && ...`                   |

**Warning to include in the README:** turning off triggers during a data load means those records get no onboarding, no assignment and no stage rows. That is the point of a kill switch, but whoever uses it is responsible for the data afterwards.

There is also a **code-level bypass** (`TriggerHandler.bypass('OnboardingTriggerHandler')`) for one Apex transaction, for example inside a test or a one-off script. It does not touch the custom setting.

### 5.6 Other metadata

| Item                                 | Type                                        | Description                                                                                                                                                                           |
| ------------------------------------ | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Onboarding_Stage`                   | Global value set                            | The six stages in order. Shared by `Onboarding__c.Stage__c` and `Onboarding_Stage__c.Stage__c` so they never drift apart.                                                             |
| `Onboarding_Backlog`                 | Queue (supports Onboarding__c)              | Holds onboardings when every CSM is at capacity. Members: the `CS_Managers` group.                                                                                                    |
| `CS_Managers`                        | Public group                                | CS managers who work the backlog and receive backlog alerts. Members are added manually after deploy.                                                                                 |
| `Onboarding_Backlog_Alert`           | Custom notification type (desktop + mobile) | Alerts CS managers when onboardings go to the backlog.                                                                                                                                |
| `PathAssistant` settings             | Settings                                    | Turns Path on in the org. Deployed so a fresh org works.                                                                                                                              |
| Custom Labels (prefix `Onboarding_`) | Custom labels                               | Every user-facing message raised from Apex, e.g. `Onboarding_Backlog_Queue_Missing`, `Onboarding_Backlog_Alert_Title`, `Onboarding_Backlog_Alert_Body`, `Onboarding_Creation_Failed`. |

Stage values in the global value set:

| Order | API value            | Label              |
| ----- | -------------------- | ------------------ |
| 1     | `Kickoff_Scheduled`  | Kickoff Scheduled  |
| 2     | `Gathering_Info`     | Gathering Info     |
| 3     | `Implementation`     | Implementation     |
| 4     | `QA_Review`          | QA / Review        |
| 5     | `Go_Live`            | Go Live            |
| 6     | `Post_Launch_Review` | Post-Launch Review |

---

## 6. Automation design

### 6.1 What runs where

| Need                                                                 | Tool                                                     | Why                                                                                                                                    |
| -------------------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Create onboarding on win; hold / cancel / reactivate on deal changes | Apex trigger on Opportunity                              | Bulk-safe, testable at 200 records, and keeps Opportunity automation in one ordered place other teams can extend.                      |
| Defaults, naming, assignment on new onboardings                      | Apex trigger on Onboarding (before insert)               | Setting OwnerId and Name in "before" costs no extra DML. Works for every way an onboarding is created, not just from an Opportunity.   |
| Stage tracking                                                       | Apex trigger on Onboarding (after insert / after update) | Needs to create and update child rows in bulk.                                                                                         |
| Stage order, required notes, locked fields                           | Validation rules                                         | Declarative, visible to admins, run on every save path including the Path component and Data Loader.                                   |
| Unique user per CSM Capacity                                         | Before-save record-triggered flow                        | One field copy. A flow is simpler to read and change than Apex for this. Its entry condition checks the `Bypass_Flows__c` kill switch. |
| Switching automation off                                             | `Automation_Bypass__c` hierarchy custom setting          | One kill switch for triggers, flows and validation rules, set per user, profile or org. See 5.5.                                       |
| Durations                                                            | Formula fields and roll-up summaries                     | No code; always current; reportable.                                                                                                   |
| Audit trail of every stage change                                    | Field history tracking                                   | Free, standard, reportable.                                                                                                            |

### 6.2 Trigger framework

A small base class we write ourselves.

```
TriggerHandler (virtual)
  - run(): checks bypass, then calls the matching method for Trigger.operationType
  - beforeInsert(), beforeUpdate(), afterInsert(), afterUpdate(), ... (empty by default)
  - static bypass(String handlerName) / clearBypass(String handlerName)  for code-level bypass
  - reads Automation_Bypass__c.getInstance().Bypass_Triggers__c for user-level bypass
```

Rules:

- One trigger per object. The trigger only calls `new <Object>TriggerHandler().run();`.
- Other teams add their logic as methods or services called from the handler, or in their own handler class called from the same trigger, so order is explicit.

### 6.3 Opportunity trigger

Events: `after insert`, `after update`.

`OpportunityTriggerHandler` sorts each Opportunity into one of these groups:

| Change             | Detected by                                                      | Action                                                                                                                                                            |
| ------------------ | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Won                | `IsWon = true` and (insert, or old `IsWon = false`)              | If no onboarding exists for it: create one. If one exists, is On Hold or Cancelled, and is not at Post-Launch Review: set it back to Active and clear the reason. |
| Reopened after win | old `IsWon = true`, new `IsClosed = false`                       | Set its onboarding to On Hold, reason "Deal reopened by Sales".                                                                                                   |
| Lost               | new `IsClosed = true`, `IsWon = false`, and it has an onboarding | Set its onboarding to Cancelled, reason "Deal closed as lost".                                                                                                    |

Rules:

- Use `IsWon` and `IsClosed`, never the text "Closed Won". Admins can rename stages or add more won stages.
- Hold (reopened) and cancel (lost) only apply to onboardings that still count toward capacity (`Counts_Toward_Capacity__c`). Reactivation (won again) applies to On Hold and Cancelled onboardings unless the stage is Post-Launch Review; it cannot use `Counts_Toward_Capacity__c`, because that is false for every Cancelled onboarding. Either way, a finished onboarding (Post-Launch Review) is left alone.
- Reactivation keeps the current owner and does not check capacity (assumption A21).
- One query for existing onboardings by `Opportunity_Key__c`. One insert. One update.
- The handler only creates bare onboardings (`Opportunity__c` set). The Onboarding trigger fills in everything else. One place owns defaults.
- Insert with `Database.insert(records, false, AccessLevel.SYSTEM_MODE)`. If a row fails with a duplicate-value error on `Opportunity_Key__c`, ignore it (another process already created it). Any other error is added to the Opportunity with `addError` so the save fails visibly. A won deal must never end up silently without an onboarding.

### 6.4 Onboarding trigger

Events: `before insert`, `before update`, `after insert`, `after update`.

**Before insert** (in this order):

1. Query the related Opportunities (Name, CloseDate, AccountId, Account.Name).
2. Set `Opportunity_Key__c` from `Opportunity__c`.
3. Set `Account__c` from the Opportunity if blank.
4. Set `Target_Go_Live_Date__c` = CloseDate + `Default_Days_To_Go_Live__c` if blank.
5. Set `Stage__c` = `Kickoff_Scheduled`, `Status__c` = `Active` if blank.
6. Set `Current_Stage_Entered__c` = now.
7. Build the Name (6.5).
8. Assign owners via `CsmAssignmentService` (section 7).

**Before update:**

1. If `Stage__c` changed: set `Current_Stage_Entered__c` = now.
2. Rebuild the Name (query Account / Opportunity names only for records that need it).

**After insert:**

1. `OnboardingStageTracker` creates the first stage row (Kickoff Scheduled).
2. If any records were assigned to the backlog queue: send one custom notification to `CS_Managers`.

**After update:**

1. `OnboardingStageTracker` processes records whose `Stage__c` changed.

Note on order of execution: Salesforce runs before triggers, then validation rules, then saves, then after triggers. So stage tracking only runs for stage changes that passed validation.

### 6.5 Naming

Format: `<Customer> - Go Live <yyyy-MM-dd>`

- Customer = Account name. If the Opportunity has no Account, use the Opportunity name.
- Date in ISO format so it sorts correctly and reads the same in any locale.
- If there is no target date: `<Customer> - Go Live TBD`.
- Plain hyphen, not an en dash, to avoid encoding issues in exports.
- The full name must fit 80 characters. The customer part is cut to fit; the date part is never cut.
- Rebuilt on every save, so it never goes stale. Manual edits to the Name are overwritten by design.

---

## 7. CSM assignment (the core logic)

Class: `CsmAssignmentService`, declared `without sharing` (explained in section 10).

### 7.1 The rule

Assign each new onboarding to the eligible CSM with the **fewest onboardings that count toward capacity**.

- **Eligible** means: `CSM_Capacity__c.Is_Active__c = true`, the linked User is active, and their current count is below `Max_Active_Onboardings__c`.
- **Tie-break** when several CSMs have the same lowest count:
  1. The one with the most remaining capacity (protects people with smaller limits).
  2. Then alphabetical by user name (makes results predictable and testable).
- If nobody is eligible: assign to the `Onboarding_Backlog` queue and notify `CS_Managers`.

### 7.2 Steps (one transaction, any number of records)

1. **Lock** the CSM rows:
   `SELECT Id, User__c, User__r.Name, Max_Active_Onboardings__c FROM CSM_Capacity__c WHERE Is_Active__c = true AND User__r.IsActive = true WITH SYSTEM_MODE FOR UPDATE`
   Any other transaction running assignment at the same moment waits here until this one finishes.
2. **Count** current load (live, never stored):
   `SELECT OwnerId, COUNT(Id) total FROM Onboarding__c WHERE Counts_Toward_Capacity__c = true AND OwnerId IN :csmUserIds WITH SYSTEM_MODE GROUP BY OwnerId`

   (Both queries run in system mode on purpose: see section 4.5.)

3. **Assign in memory.** Walk through the new onboardings in the order they arrived. For each one, pick the CSM using the rule in 7.1, set `OwnerId`, and add 1 to that CSM's count in memory before moving to the next record.
4. **Overflow.** When nobody is eligible, set `OwnerId` to the backlog queue (looked up by DeveloperName from `Onboarding_Setting__mdt`).
5. Remember which records went to the backlog so the after-insert step can send one notification.

Two queries for any batch size. No queries or DML inside the loop.

### 7.3 Worked example

Capacities: Shahmeer 5, A 4, B 4, C 10. Everyone starts at 0. 24 onboardings arrive in one batch.

| Onboarding | Loads before (S/A/B/C) | Tied at lowest      | Goes to | Why                                   |
| ---------- | ---------------------- | ------------------- | ------- | ------------------------------------- |
| 1          | 0/0/0/0                | all                 | C       | most headroom                         |
| 2          | 0/0/0/1                | S, A, B             | S       | headroom 5 beats 4                    |
| 3          | 1/0/0/1                | A, B                | A       | same headroom, alphabetical           |
| 4          | 1/1/0/1                | B                   | B       | only one at 0                         |
| 5–16       |                        |                     | rotates | everyone rises together to 4          |
| 17         | 4/4/4/4                | S, C (A and B full) | C       | headroom 6 beats 1                    |
| 18         | 4/4/4/5                | S                   | S       | S is now lowest; S reaches 5/5 (full) |
| 19–23      |                        | only C has room     | C       | C reaches 10/10                       |
| 24         | all full               | —                   | Backlog | managers notified                     |

### 7.4 Edge cases

| Case                                                   | Behaviour                                                                                                                                                                                                                                                                            |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| No CSM Capacity records at all                         | Everything goes to the backlog.                                                                                                                                                                                                                                                      |
| Backlog queue missing (bad setup)                      | Records that overflow fail with the `Onboarding_Backlog_Queue_Missing` label: "Every CSM is at capacity and the backlog queue {0} could not be found. Ask your Salesforce admin to create the queue or fix the Onboarding Setting." ({0} is the queue name from Onboarding Setting.) |
| Admin lowers a CSM's capacity below their current load | Nobody is reassigned. That CSM just gets no new onboardings until they drop below the new limit.                                                                                                                                                                                     |
| CSM deactivated in Salesforce                          | Excluded from assignment. Their existing onboardings stay with them until a manager reassigns.                                                                                                                                                                                       |
| Manager reassigns an onboarding by hand                | Counts update automatically on the next assignment, because counts are live.                                                                                                                                                                                                         |
| Onboarding created manually by a user                  | Still auto-assigned. Managers can reassign after.                                                                                                                                                                                                                                    |
| Deal reopened and re-won                               | The existing onboarding is reactivated. No new assignment, it stays with its owner.                                                                                                                                                                                                  |

### 7.5 Bulk and concurrency

- A Data Loader job closing 200 Opportunities produces one insert of up to 200 onboardings. All 200 are assigned in one pass with two queries. The 200-record test proves exact counts per CSM.
- If Data Loader runs batches in parallel, two transactions could try to assign at the same time. The `FOR UPDATE` lock makes the second one wait until the first commits, so it sees the first one's assignments in its count. Assignment never puts a CSM over capacity. (Reactivating a Cancelled onboarding can, because it keeps its owner without a capacity check; see A21.)
- Salesforce waits about 10 seconds for a lock before failing with `UNABLE_TO_LOCK_ROW`. Our locked section is two queries and an in-memory loop, so the lock is held very briefly. Still, the README recommends **serial mode** for very large quarter-end loads. This is listed as a known limitation.
- The lock cannot be fully proven in a unit test (tests run in one transaction). It is explained in the write-up.
- Assignment and the backlog alert run once per **trigger run**, and Salesforce runs a trigger on at most 200 records at a time. A Data Loader or API batch of up to 200 is one transaction, so it gets one lock, one count and at most one alert. An Apex insert of more than 200 records in one transaction runs the trigger once per 200-record chunk, so it locks and counts once per chunk and sends one alert per chunk that had backlog records. Counts are not cached between chunks, so each chunk sees the earlier chunks' assignments.

---

## 8. Stage tracking

Class: `OnboardingStageTracker`, declared `without sharing`.

### 8.1 Behaviour

When an onboarding is created:

- Create a stage row for the onboarding's `Stage__c` (normally Kickoff Scheduled, which the defaults and `Start_At_Kickoff` enforce): `First_Reached__c` = now, `Current_Visit_Started__c` = now, `Visit_Count__c` = 1, `Completed_Visit_Days__c` = 0. Using the record's own stage keeps the history right if an onboarding is inserted at a later stage with validation rules bypassed.

When an onboarding's stage changes from X to Y:

0. **Skip if already recorded:** if Y's row already has an open visit (`Current_Visit_Started__c` set), this change was already processed in this transaction (for example when a roll-up recalculation re-saves the onboarding), so nothing is written. The guard reads the rows rather than a static flag because a static flag would block legitimate repeats in one transaction (Implementation to QA twice) and is not reset when a partly successful bulk save is rolled back and retried.
1. **Close X:** add `(now - Current_Visit_Started__c)` in days to `Completed_Visit_Days__c`. Clear `Current_Visit_Started__c`. If X has no row or no open visit (for example an onboarding loaded with the kill switch on), there is nothing to close and only Y is opened.
2. **Open Y:**
   - If Y has no row yet: create it with `First_Reached__c` = now, `Visit_Count__c` = 1, `Current_Visit_Started__c` = now.
   - If Y already has a row (the onboarding was here before): add 1 to `Visit_Count__c`, set `Current_Visit_Started__c` = now. **Never touch `First_Reached__c`.**

All rows are written with one `upsert as system` on `Unique_Key__c`, after one query for existing rows (`WITH SYSTEM_MODE`). System mode is needed because CSMs only have read access to stage rows.

### 8.2 Example

Kickoff May 1 → Gathering Info May 3 → Implementation May 5 → QA May 10 → back to Implementation May 12 → QA May 20 → Go Live May 22.

| Stage             | First Reached | Days In Stage | Visits |
| ----------------- | ------------- | ------------- | ------ |
| Kickoff Scheduled | May 1         | 2             | 1      |
| Gathering Info    | May 3         | 2             | 1      |
| Implementation    | May 5         | 13 (5 + 8)    | 2      |
| QA / Review       | May 10        | 4 (2 + 2)     | 2      |
| Go Live           | May 22        | still running | 1      |

### 8.3 Why this design (for the write-up)

- **Fields on Onboarding** (six dates plus durations) would record first-reached dates, but the "Implementation to QA = 5 days" duration would hide the 8 days of rework. Leadership asked where customers get stuck; that answer would be wrong.
- **One row per transition** would make "first reached" a calculation across many rows, and durations between non-adjacent stages would need cross-row math that standard reports cannot do.
- **One row per stage** stores first-reached as a fact, totals time correctly with rework, reports with a simple group-by-stage, and works for any number of stages without schema changes.
- The full move-by-move history comes free from field history tracking on `Stage__c`.

### 8.4 Testability

Time in tests is controlled with a test-visible clock:

```apex
@TestVisible private static Datetime nowOverride;
private static Datetime now() { return nowOverride != null ? nowOverride : Datetime.now(); }
```

Tests set `nowOverride` to move time forward without waiting.

### 8.5 Protection of first-reached dates

- Field-level security: `First_Reached__c` read-only for every permission set.
- Validation rule `Prevent_First_Reached_Change` on `Onboarding_Stage__c` (section 9).
- No user can create, edit or delete stage rows.

---

## 9. Validation rules

All onboarding validation rules start with a bypass check:

```
NOT($Setup.Automation_Bypass__c.Bypass_Validation_Rules__c) && ...
```

Stage order is calculated in each rule with:

```
CASE(TEXT(Stage__c), "Kickoff_Scheduled",1, "Gathering_Info",2, "Implementation",3,
     "QA_Review",4, "Go_Live",5, "Post_Launch_Review",6, 0)
```

and the same with `TEXT(PRIORVALUE(Stage__c))` for the old stage.

### On Onboarding__c

| Rule                                | Fires when                                                                      | Error message                                                                                      |
| ----------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `Start_At_Kickoff`                  | New record and Stage is not Kickoff Scheduled                                   | "New onboardings start at Kickoff Scheduled."                                                      |
| `Prevent_Stage_Skipping`            | Stage changed and new order > old order + 1                                     | "Move one stage at a time. Complete the current stage before moving on."                           |
| `Prevent_Moving_Back_After_Go_Live` | Stage changed, old order ≥ 5, new order < old order                             | "This onboarding has gone live. It can no longer move back to an earlier stage."                   |
| `Require_Gathering_Info_Notes`      | Stage changed, new order > 2, Gathering Info Notes blank                        | "Add Gathering Info Notes before moving past Gathering Info."                                      |
| `Require_Implementation_Notes`      | Stage changed, new order > 3, Implementation Notes blank                        | "Add Implementation Notes before moving past Implementation."                                      |
| `Lock_Stage_When_Not_Active`        | Stage changed and Status is not Active                                          | "This onboarding is On Hold or Cancelled. Change the status back to Active before moving stages."  |
| `Require_Status_Reason`             | Status is not Active and Status Reason blank                                    | "Add a reason when an onboarding is On Hold or Cancelled."                                         |
| `Prevent_Opportunity_Change`        | Not new and Opportunity changed                                                 | "An onboarding always belongs to the deal it was created for. It cannot be moved to another deal." |
| `Prevent_Owner_Change`              | Not new, Owner changed, and the user lacks the `Onboarding_Reassign` permission | "Only CS managers can reassign onboardings."                                                       |

Going backwards: allowed from any stage before Go Live to **any** earlier stage (not only QA → Implementation). After going back, the onboarding moves forward one stage at a time again. Notes already captured still count.

Note: the Path component lets users click any stage and "Mark as Current Stage". It does not enforce order by itself. These rules do.

### On Onboarding_Stage__c

| Rule                           | Fires when                                            | Error message                                                                      |
| ------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Prevent_First_Reached_Change` | First Reached changed and the old value was not blank | "The date a stage was first reached is a historical record and cannot be changed." |

### On CSM_Capacity__c

| Rule                            | Fires when                 | Error message                                                                    |
| ------------------------------- | -------------------------- | -------------------------------------------------------------------------------- |
| `Require_Non_Negative_Capacity` | Max Active Onboardings < 0 | "Maximum active onboardings cannot be negative. Use 0 to pause new assignments." |
| `Require_User`                  | User is blank              | "Choose the CSM this capacity record is for."                                    |

`Require_User` formula: `NOT($Setup.Automation_Bypass__c.Bypass_Validation_Rules__c) && ISBLANK(User__c)`

---

## 10. Security and sharing

### 10.1 Sharing model

| Object                | Org-wide default     | Why                                                                                                                                   |
| --------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `Onboarding__c`       | Public Read Only     | The CS team can see each other's onboardings (covering for a colleague, leadership visibility). Only the owner and managers can edit. |
| `Onboarding_Stage__c` | Controlled by Parent | Follows the onboarding.                                                                                                               |
| `CSM_Capacity__c`     | Private              | Only managers and admins need it.                                                                                                     |

### 10.2 Permission sets

Two permission sets, one per persona. All access (objects, fields, app, tabs, Apex classes where needed) is granted only through these. No profile changes, so everything deploys cleanly.

| Permission set       | Label              | For                                                                               | Grants                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------- | ------------------ | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Onboarding_CSM`     | Onboarding CSM     | CSMs doing the day-to-day work                                                    | App visibility and tabs (Onboardings, Accounts). Onboarding: read, create, edit (no delete). Onboarding Stage: read only. Account: read. System-set fields (`Opportunity_Key__c`, `Current_Stage_Entered__c`, `First_Reached__c`, etc.) read only. Can edit Stage, notes and Target Go-Live Date on records they own.                                                                                            |
| `Onboarding_Manager` | Onboarding Manager | CS managers, leadership and admins of the tracker. The all-access permission set. | Everything in `Onboarding_CSM`, plus: Onboarding View All and Modify All (reassign, work the backlog, change Status), the `Onboarding_Reassign` custom permission (required by `Prevent_Owner_Change` to change the owner of an existing onboarding), Onboarding Stage read, CSM Capacity full access (add, pause, change capacity), CSM Capacities tab, Opportunities tab, reports and dashboard folder access. |

Notes:

- Editing the kill switch (custom setting values) needs the "Customize Application" permission, which only system admins have. That is deliberate: switching automation off is an admin action, not a CS action.
- If more personas appear later (e.g. read-only leadership), add a new `Onboarding_<Persona>` permission set rather than editing these two.
- Both permission sets are created in build step 1 with object and field access only (see A20). App and tab access is added in step 6, and report and dashboard folder access in step 7, when those components exist.
- Required fields (`Opportunity__c`, `Stage__c`, `Max_Active_Onboardings__c`, the master-detail `Onboarding__c`) have no field permissions. Salesforce always grants them to anyone with object access.

### 10.3 Sharing keywords and access mode per class

The person who closes a deal is a sales user. They cannot see CSM Capacity records or other people's onboardings. Assignment must still see every CSM and count every onboarding correctly, whoever triggered it. On API 67.0, a class with no sharing keyword runs **with sharing** and its queries run in **user mode**, so we declare both explicitly (section 4.5).

| Class                       | Sharing keyword              | Database mode      | Why                                                                |
| --------------------------- | ---------------------------- | ------------------ | ------------------------------------------------------------------ |
| `TriggerHandler`            | `inherited sharing`          | No database access | Base class only.                                                   |
| `OpportunityTriggerHandler` | `without sharing`            | System             | Creates onboardings for users who cannot see them.                 |
| `OnboardingTriggerHandler`  | `without sharing`            | System             | Reads Opportunities and Accounts that CSMs may not be able to see. |
| `CsmAssignmentService`      | `without sharing`            | System             | Must see every CSM and every onboarding.                           |
| `OnboardingStageTracker`    | `without sharing`            | System             | Writes stage rows CSMs can only read.                              |
| `TestDataFactory`           | `@IsTest`, `without sharing` | System             | Test setup only.                                                   |

Each class header states its keyword and why. Tests also run key scenarios **as a CSM user and as a sales user** (`System.runAs`) to prove the automation works for people with limited access, not only for an admin.

---

## 11. App and record page

### 11.1 Lightning app

- Label: **Revinfinity | Onboarding Tracker**
- Brand colors, matched to the brief visually: primary violet `#6D28D9` (app nav bar and record page header) and hot pink accent `#EC4899` (thin underline under "Onboarding" in the page header).
- No logo image. App logos are stored as Documents, which do not deploy cleanly in source format. Noted in assumptions.
- Navigation: Home, Onboardings, Accounts, Opportunities, CSM Capacities, Reports, Dashboards.
- Visibility granted through both permission sets.

### 11.2 Record page: "Revinfinity | Onboarding Tracker"

Layout (top to bottom):

1. **Rich Text header:** "Revinfinity | Onboarding Tracker", in brand style. Branding on the page itself, not just the nav bar.
2. **Highlights panel** (compact layout): Account, Stage, Status, Target Go-Live Date, Days In Current Stage, Owner.
3. **Path** on `Stage__c` with Guidance for Success:

   | Stage              | Key fields           | Guidance                                                                        |
   | ------------------ | -------------------- | ------------------------------------------------------------------------------- |
   | Kickoff Scheduled  | Target Go-Live Date  | Book the kickoff call. Confirm the go-live date with the customer.              |
   | Gathering Info     | Gathering Info Notes | Capture requirements, contacts and integrations. Notes are required to move on. |
   | Implementation     | Implementation Notes | Record what was configured and any open issues. Notes are required to move on.  |
   | QA / Review        | Implementation Notes | Test with the customer. If QA fails, move back to Implementation and note why.  |
   | Go Live            | Target Go-Live Date  | Confirm launch with the customer.                                               |
   | Post-Launch Review | —                    | Review the launch with the customer and close out.                              |

4. **Tabs:**
   - **Today** (default): Dynamic Forms sections.
     - "Current work": the notes field for the current stage only (visibility rules: Gathering Info Notes shown when Stage = Gathering Info; Implementation Notes shown when Stage = Implementation or QA / Review).
     - "Key dates": Target Go-Live Date, Days To Go Live, Is At Risk.
     - "Status": Status, Status Reason (Status Reason only shown when Status is not Active).
   - **Stage History:** Onboarding Stages related list (Stage, First Reached, Days In Stage, Visits), sorted by Stage Sequence. Plus the Onboarding History related list.
   - **Details:** all fields, including both notes fields and system fields.
   - **Related:** Opportunity, Account, files.
5. **Right column:** Activity timeline.

Search layout and default list view columns: Name, Account, Stage, Status, Target Go-Live Date, Owner.

List views: My Onboardings, All Active, At Risk, Backlog (owner is the queue).

---

## 12. Reports and dashboard

### 12.1 Report types

| Report type               | Objects                                | Description                                                              |
| ------------------------- | -------------------------------------- | ------------------------------------------------------------------------ |
| `Onboardings_with_Stages` | Onboarding__c with Onboarding_Stage__c | Onboardings and their per-stage timing. Used for stage duration reports. |

Onboarding on its own is reportable through the standard report type created with the object.

### 12.2 Reports (folder: "Onboarding Reports")

| Report                      | Shows                                                                     |
| --------------------------- | ------------------------------------------------------------------------- |
| Active Onboardings by Stage | Count of onboardings counting toward capacity, grouped by Stage.          |
| Average Days per Stage      | Average Days In Stage, grouped by Stage. Shows where customers get stuck. |
| Rework by Stage             | Stages with Visit Count > 1. Shows how often QA sends work back.          |
| Active Onboardings by CSM   | Count grouped by Owner. Shows workload balance.                           |
| At Risk Onboardings         | Onboardings where Is At Risk is true.                                     |

### 12.3 Dashboard: "Onboarding Overview"

One component per report above.

**Important:** dashboards normally run as a named user, which would put a username in the metadata and break deployment to another org. This dashboard is set to **run as the logged-in user** (dynamic dashboard), so no username is stored.

---

## 13. Testing plan

### 13.1 Test data

`TestDataFactory` (shared by all tests, so it earns its own class):

- Creates CSM users with the `Onboarding_CSM` permission set (assigned in the same `System.runAs` block as the user insert, so there is no mixed-DML error), with profiles looked up by name. It uses free Salesforce Platform licences first (Standard Platform User), then Standard User (Salesforce licence) for the rest, so tests do not depend on an org's licence counts. If there are not enough licences of either kind, it fails before inserting anything, with an error naming how many are needed and how many are free. FirstName is left blank, so the user's Name is the last name the test passes in.
- No test creates both four CSMs and the sales user. Sales-user tests create no CSM users; assignment tests run as the admin.
- Creates one sales user with the Standard User profile and no onboarding permission set, to prove automation works for someone with no onboarding access.
- Creates CSM Capacity records, Accounts and Opportunities.
- Inserts the `Automation_Bypass__c` org default with everything off, so tests never depend on org data.

**Checked in S4:** creating users in a test does use licences. The dev org has 6 Platform licences, but a Developer edition scratch org has only 3, so tests that need four CSMs would fail there with Platform users only. That is why the factory falls back to Standard User (see A27).

### 13.2 Test classes and cases

Each test asserts behaviour, not just coverage.

**`OpportunityTriggerHandlerTest`**

- Winning a deal creates exactly one onboarding linked to it.
- Inserting an Opportunity already Closed Won creates an onboarding.
- Reopening a won deal sets the onboarding to On Hold with a reason.
- Re-winning the deal sets it back to Active and creates no second onboarding.
- Losing a deal that had an onboarding sets it to Cancelled.
- An onboarding in Post-Launch Review is not changed when its deal is reopened.
- Opportunity without an Account: onboarding name uses the Opportunity name.
- **Bulk:** 200 Opportunities closed in one update create exactly 200 onboardings.

**`CsmAssignmentServiceTest`**

- Assigns to the CSM with the fewest active onboardings.
- Tie-break: most remaining capacity, then alphabetical.
- Never assigns above a CSM's maximum.
- Overflow goes to the backlog queue.
- Inactive CSM Capacity records and inactive users are skipped.
- On Hold onboardings count toward capacity; Cancelled and Post-Launch Review do not.
- No CSMs configured: everything goes to the backlog.
- **Bulk:** 200 onboardings with set capacities and existing loads produce the exact expected count per CSM and the exact backlog count. No CSM exceeds capacity.

**`OnboardingStageTrackerTest`**

- New onboarding gets a Kickoff Scheduled row with first-reached set.
- Moving forward creates the next row and closes the previous visit.
- Moving back then forward again: first-reached unchanged, visit count 2, days add up across both visits (using `nowOverride`).
- **Bulk:** 200 onboardings moving stage in one update.

**`OnboardingTriggerHandlerTest`**

- Name format, ISO date, "TBD" when no date, truncation at 80 characters.
- Target date defaults from close date plus setting.
- Name updates when the target date changes.
- Duplicate onboarding for the same Opportunity is rejected.

**`OnboardingValidationTest`**

- Skipping a stage is blocked.
- Moving past Gathering Info / Implementation without notes is blocked.
- Moving back from Go Live is blocked.
- Changing the Opportunity is blocked.
- Changing First Reached on a stage row is blocked.
- Bypass setting lets a data load through.

**`TriggerHandlerTest`**

- Code-level bypass and custom-setting bypass both stop the handler.

**Access-mode tests (spread across the classes above)**

- Running as the sales user, closing a deal still creates and assigns an onboarding (proves system mode is used where it must be).
- Running as a CSM user, moving an onboarding to the next stage still creates and updates stage rows the CSM cannot write directly.
- Running as a CSM user, trying to edit a stage row directly fails (proves the read-only design holds).

**Kill switch tests**

- With `Bypass_Triggers__c` on for the running user, winning a deal creates no onboarding.
- With `Bypass_Validation_Rules__c` on, a stage skip is allowed.
- With `Bypass_Flows__c` on, the CSM Capacity flow does not set the user key.

---

## 14. Demo data and post-deploy setup

### 14.1 Post-deploy manual steps (in README)

1. Assign `Onboarding_Manager` to yourself.
2. Add yourself to the `CS_Managers` public group. (Group membership of users cannot be deployed as metadata.)
3. Create 4 CSM users: license Salesforce Platform, profile Standard Platform User. Assign `Onboarding_CSM` to each.
4. Run `scripts/apex/seed-csm-capacity.apex`. It finds every user with `Onboarding_CSM` and creates a CSM Capacity record for each, with demo limits. No usernames are hardcoded.
5. Optional: run `scripts/apex/seed-demo-data.apex` to create a few onboardings at different stages for the record page demo.

### 14.2 Bulk demo

- `data/demo-opportunities.csv`: 200 Opportunities.
- Load them with `sf data import bulk --sobject Opportunity --file data/demo-opportunities.csv --target-org <alias> --wait 10`.
- Export their Ids, then update all 200 to Closed Won in one job with `sf data update bulk --sobject Opportunity --file data/demo-opportunities-close.csv --target-org <alias> --wait 10`. The first column of that CSV must be `Id`, the second `StageName` with the value `Closed Won`. Data Loader works just as well and is more familiar on video.
- Before relying on any command, run it with `--help` once to confirm the flags on the installed CLI version.
- Show: 170 assigned across 4 CSMs in proportion to their free capacity, 30 in the backlog, and the managers' notification.

---

## 15. Assumptions log

| #   | Ambiguity                                                                | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | Where does the target launch date come from?                             | Defaults to Opportunity close date + 30 days (configurable in Onboarding Setting). The CSM updates it after kickoff.                                                                                                                                                                                                                                                                                                                                  |
| A2  | What is in the onboarding name?                                          | `<Account name> - Go Live <yyyy-MM-dd>`. Uses the Opportunity name if there is no Account. Rebuilt on every save.                                                                                                                                                                                                                                                                                                                                     |
| A3  | How far back can an onboarding go?                                       | Any earlier stage, as long as it has not reached Go Live. After Go Live it is locked forward.                                                                                                                                                                                                                                                                                                                                                         |
| A4  | When are notes "required"?                                               | Before moving forward past Gathering Info and past Implementation respectively.                                                                                                                                                                                                                                                                                                                                                                       |
| A5  | What does "active" mean for capacity?                                    | Any onboarding not in Post-Launch Review and not Cancelled.                                                                                                                                                                                                                                                                                                                                                                                           |
| A6  | Who counts as a CSM?                                                     | Anyone with an active CSM Capacity record and an active user.                                                                                                                                                                                                                                                                                                                                                                                         |
| A7  | Who are the CS managers?                                                 | Members of the `CS_Managers` public group. In the dev org, the developer.                                                                                                                                                                                                                                                                                                                                                                             |
| A8  | Tie-break when CSMs have the same load?                                  | Most remaining capacity, then alphabetical by name.                                                                                                                                                                                                                                                                                                                                                                                                   |
| A9  | What happens when a won deal is reopened?                                | Onboarding goes On Hold and still counts toward capacity, so it can resume without overloading its CSM.                                                                                                                                                                                                                                                                                                                                               |
| A10 | What happens when a reopened deal is lost?                               | Onboarding is Cancelled and frees the slot.                                                                                                                                                                                                                                                                                                                                                                                                           |
| A11 | Re-won after reopen or loss?                                             | The same onboarding is reactivated (On Hold or Cancelled back to Active, reason cleared), unless it is at Post-Launch Review. No new onboarding, no reassignment.                                                                                                                                                                                                                                                                                     |
| A12 | Manually created onboardings?                                            | Allowed (Opportunity required). Auto-assigned like any other.                                                                                                                                                                                                                                                                                                                                                                                         |
| A13 | What does "branded" mean?                                                | App label, record page name, a header on the page, and the brand colors. No logo image. Colors matched to the brief visually: violet #6D28D9 (app and page header), hot pink #EC4899 (thin accent on the page header).                                                                                                                                                                                                                                |
| A14 | Does a CSM's Account or Opportunity change flow to the onboarding later? | No. Account is copied at creation only.                                                                                                                                                                                                                                                                                                                                                                                                               |
| A15 | Balance by count or by percentage of capacity?                           | By count, as the brief says "fewest active onboardings". Percentage balancing is noted as an alternative.                                                                                                                                                                                                                                                                                                                                             |
| A16 | Licenses for CSMs                                                        | Demo CSMs use Salesforce Platform licenses, which cannot open Opportunities. In production, CSMs would likely have full Salesforce licenses.                                                                                                                                                                                                                                                                                                          |
| A17 | Do onboardings on the backlog get picked up automatically later?         | No. Managers assign them by hand. Automation is a next step.                                                                                                                                                                                                                                                                                                                                                                                          |
| A18 | What if capacity is lowered below a CSM's current load?                  | Nothing is reassigned. They just receive no new onboardings until they are under the limit.                                                                                                                                                                                                                                                                                                                                                           |
| A19 | How is `CSM_Capacity__c.User__c` made required?                          | Optional lookup at field level, required through the `Require_User` validation rule. Salesforce rejects a required lookup to User.                                                                                                                                                                                                                                                                                                                    |
| A20 | Why are permission sets built in step 1 rather than step 6?              | Without field-level security, no user, admins included, can read or write the new fields. That blocked the step 1 smoke test of formulas and the roll-up (anonymous Apex enforces FLS and rejects system mode). So `Onboarding_CSM` and `Onboarding_Manager` are created in step 1 with object and field access. App, tab and report access is added later. `Onboarding_Manager` is assigned to the admin, who is the CS manager in the dev org (A7). |
| A21 | Does reactivating a Cancelled onboarding respect capacity?               | No. It keeps its owner and is not checked against capacity, so it can put that CSM over their limit. It stays with the owner even if they have been deactivated. Managers rebalance by hand (section 16).                                                                                                                                                                                                                                             |
| A22 | What if one user has two active CSM Capacity records?                    | Only possible if the flow was bypassed, because `User_Key__c` is unique. Assignment counts the user once and uses the smaller maximum, so they are never over-assigned.                                                                                                                                                                                                                                                                               |
| A23 | What if the CS Managers group or the notification type is missing?       | The backlog alert is skipped and the save is not blocked. The onboardings are already safe in the backlog queue.                                                                                                                                                                                                                                                                                                                                      |
| A24 | What if an onboarding is inserted with an owner already set?             | The owner is overwritten on insert. Every new onboarding goes through assignment (A12); managers can reassign after.                                                                                                                                                                                                                                                                                                                                  |
| A25 | How exactly does the alphabetical tie-break compare names?               | Ignoring case. If two CSMs have the same name, the lower user Id wins, so the result never depends on query order.                                                                                                                                                                                                                                                                                                                                    |
| A26 | Deviation from the S4 issue: permission set on CSM test users            | The S4 issue said not to assign permission sets to CSM test users because they would be created in S6. They have existed since step 1 (A20), so `TestDataFactory.createCsmUsers` assigns `Onboarding_CSM`.                                                                                                                                                                                                                                            |
| A27 | Deviation from the S4 issue: licence of CSM test users                   | The S4 issue said CSM test users use the Standard Platform User profile. They may use either licence: free Platform licences first, then Standard User (13.1), so tests pass in any org, including a scratch org with only 3 Platform licences. Assignment does not depend on the licence, and A16 already says production CSMs would likely have full licences.                                                                                      |
| A28 | How precise are stage durations?                                         | Visit days run from the visit's start (Date/Time fields keep whole seconds) to now and are added, unrounded, to the running total in `Completed_Visit_Days__c` (10 decimal places, finer than a millisecond). Rounding to 2 decimals happens once, in `Days_In_Stage__c`, so a stage visited many times shows the rounded sum of its raw visit durations and never drifts.                                                                            |
| A29 | What is a stage row's Name?                                              | The stage's picklist label (e.g. "QA / Review"), not the API value, in the language of the user whose save created the row. Falls back to the API value if the label cannot be found.                                                                                                                                                                                                                                                                 |
| A30 | Can a CSM change Status or put an onboarding On Hold?                    | No. Status is set by automation and managers only (5.1, 10.2); a CSM asks a manager to pause or cancel. Self-service pause for CSMs is a possible next step.                                                                                                                                                                                                                                                                                          |
| A31 | What email address do demo users get?                                    | The developer's own email address, so any Salesforce notification for a demo CSM reaches a real inbox the developer controls.                                                                                                                                                                                                                                                                                                                         |
| A32 | Does a manager reassigning an onboarding by hand respect capacity?       | No. Manual reassignment (including from the backlog) is not checked against the new owner's capacity, so a manager can put a CSM over their limit. Only automatic assignment on creation checks capacity.                                                                                                                                                                                                                                             |

---

## 16. Known limitations and next steps

### Limitations

- The row lock prevents over-assignment between parallel loads, but very large parallel loads can hit lock timeouts. Serial mode is recommended.
- An Apex insert of more than 200 onboardings in one transaction sends one backlog alert per 200-record chunk, not one in total (section 7.5).
- Backlog onboardings are not automatically assigned when capacity frees up.
- When a lost deal is won again, its Cancelled onboarding is reactivated with the same owner and no capacity check. That can put the CSM over their limit, and the onboarding stays with them even if they have been deactivated. Managers rebalance by hand (A21).
- "Days" are calendar days, not business days.
- An onboarding loaded with the kill switch on gets no stage rows, so it has no history for the stages it passed through before automation was on. Tracking starts with its first stage change after that (section 8.1).
- The CSM load report shows counts but does not show them next to each CSM's capacity in one view.
- The stage order lives in validation rules. That is right for one process, but would need to change for several (section 17).

### With another week

1. A scheduled job that pulls from the backlog when a CSM has free capacity, oldest first.
2. Business-day durations (section 18).
3. CI: a GitHub Action that runs a validate-only deploy and all tests on every pull request.
4. A small LWC on the record page showing days in stage against a target per stage, with a warning colour.
5. A capacity vs load report, via a stored count refreshed on assignment or a scheduled snapshot.
6. Skill-based assignment (e.g. by product or region).

---

## 17. How this scales: a second product with a different process

What stays the same:

- `Onboarding_Stage__c` already supports any number of stages. No schema change.
- Assignment, naming and the Opportunity trigger do not care about stage names.

What changes:

1. Add `Product_Line__c` (or a record type) on Onboarding.
2. Add the new stages to the global value set. Use record types to show each product only its own stages, and a separate Path per record type.
3. Move stage order and required-notes rules out of validation rules into custom metadata, e.g. `Onboarding_Stage_Definition__mdt` (Process, Stage, Order, Required Field). Enforce order in Apex using that metadata. Validation rules are simpler for one process; metadata-driven rules are better for many.
4. Optionally add a product skill to `CSM_Capacity__c` so each product is assigned only to CSMs trained on it.

---

## 18. Stretch goal: business days (designed, not built)

1. Create a Business Hours record "SkyPath Business Hours" (Mon to Fri, working hours) and add SkyPath's company holidays as Holiday records linked to it.
2. Store the Business Hours name in `Onboarding_Setting__mdt` (no hardcoded ID).
3. When a stage visit closes, calculate the business time with `BusinessHours.diff(businessHoursId, start, end)`, which already skips weekends and holidays. Convert milliseconds to business days by dividing by the length of one working day.
4. Store it in a new field `Completed_Visit_Business_Days__c` on `Onboarding_Stage__c`.
5. For a stage still in progress, a nightly scheduled job refreshes a `Current_Visit_Business_Days__c` field, because formulas cannot call Business Hours.

---

## 19. Build order

Each step ends with a commit and a pull request into `main`.

| #   | Branch                        | Work                                                                                                                                                                                                                                                                                           | Done when                                                       |
| --- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| 0   | —                             | Enable Dev Hub. Create the GitHub repo. Scaffold the SFDX project. Add this spec.                                                                                                                                                                                                              | `sf project deploy start` works on an empty project.            |
| 1   | `feature/data-model`          | Global value set, objects, fields, formulas, roll-up, custom metadata type + Default record, kill-switch custom setting, custom labels, queue, group, notification type, Path settings. Permission sets with object and field access (see A20). API version 67.0 everywhere. All descriptions. | Deploys to the build org.                                       |
| 1a  | —                             | **Check:** can a test create 4 Platform users?                                                                                                                                                                                                                                                 | Answer known before step 4.                                     |
| 2   | `feature/trigger-framework`   | `TriggerHandler` + test.                                                                                                                                                                                                                                                                       | Tests pass.                                                     |
| 3   | `feature/onboarding-creation` | Opportunity trigger + handler, Onboarding trigger + handler (defaults, naming), validation rules, tests.                                                                                                                                                                                       | Win / reopen / lose / re-win tests pass, including 200 records. |
| 4   | `feature/csm-assignment`      | `CsmAssignmentService`, backlog notification, CSM Capacity flow, tests.                                                                                                                                                                                                                        | 200-record distribution test passes with exact counts.          |
| 5   | `feature/stage-tracking`      | `OnboardingStageTracker`, tests.                                                                                                                                                                                                                                                               | Rework test passes with correct days and visits.                |
| 6   | `feature/record-page`         | Permission sets: add app and tab access. App, compact layout, Path with guidance, Lightning record page, list views, search layout.                                                                                                                                                            | A CSM user sees the right page.                                 |
| 7   | `feature/reports`             | Report type, reports, dynamic dashboard.                                                                                                                                                                                                                                                       | Dashboard shows demo data.                                      |
| 8   | `feature/demo-data`           | Seed scripts, demo CSV, README.                                                                                                                                                                                                                                                                | Fresh setup works by following the README only.                 |
| 9   | —                             | Create a scratch org. Deploy. Run all tests. Fix anything missing.                                                                                                                                                                                                                             | Clean deploy and green tests in a fresh org.                    |
| 10  | —                             | Design write-up (2 to 3 pages, from this spec). Loom recording.                                                                                                                                                                                                                                | Ready to submit.                                                |

---

## 20. Decisions to be ready to defend

| Question they may ask                                                       | Short answer                                                                                                                                                                                                              |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Why not Master-Detail from Opportunity?                                     | The child would have no owner. CSMs could not own onboardings, there could be no backlog queue, and CSMs would need Opportunity access to see their work. A required lookup with delete restricted also prevents orphans. |
| Why not a CSM user lookup field instead of OwnerId?                         | A user field cannot hold a queue, so no backlog. Owner also drives "My Onboardings", sharing and reports for free.                                                                                                        |
| Why a custom object for CSM capacity, not custom metadata?                  | People data, not config. No lookup to User in metadata, usernames differ by org, and metadata rows cannot be locked.                                                                                                      |
| Why Apex and not Flow for assignment?                                       | Row locking, exact control over ordering and tie-breaks, and precise 200-record tests.                                                                                                                                    |
| Why a flow for the CSM Capacity user key?                                   | It is one field copy. Apex would be more code for no benefit.                                                                                                                                                             |
| Why IsWon and not "Closed Won"?                                             | Stage names can be renamed or added. IsWon is set by Salesforce from stage configuration.                                                                                                                                 |
| How are duplicates prevented?                                               | A query check on the normal path, and a unique field the database enforces on every path.                                                                                                                                 |
| Why one stage row per stage, not per transition?                            | First-reached is stored, rework is totalled correctly, and reports group by stage simply.                                                                                                                                 |
| Why `without sharing`?                                                      | Assignment must see all CSMs and all onboardings even when a sales user closes the deal.                                                                                                                                  |
| Why your own trigger framework?                                             | Small, readable, gives one trigger per object and bypass. A big framework would be more to read than the logic itself.                                                                                                    |
| What happens with 200 records at once?                                      | Two queries, in-memory assignment, one DML. Proven by a 200-record test with exact expected counts.                                                                                                                       |
| What if two loads run at the same time?                                     | `FOR UPDATE` serialises them, so capacity holds.                                                                                                                                                                          |
| Why is the dashboard dynamic?                                               | A fixed running user would put a username in the metadata and break deployment to another org.                                                                                                                            |
| Why is every query and DML marked with an access mode?                      | From API 67.0, the default flipped to user mode and classes default to with sharing. Being explicit means the code behaves the same for every user and a reviewer can see each system-mode decision.                      |
| Why a custom setting for the kill switch, but custom metadata for settings? | The kill switch must differ per user at the same moment. Settings must travel with the code between orgs.                                                                                                                 |
| How do you turn everything off for a data fix?                              | Tick the kill-switch fields on `Automation_Bypass__c` for that one user. Triggers, flows and validation rules all check it. No deployment, no deactivating anything.                                                      |
