# Onboarding Tracker

A Salesforce onboarding tracker for SkyPath AI's Customer Success team. The full design is in [docs/project-spec.md](docs/project-spec.md).

- When an Opportunity is won, an Onboarding is created automatically. Reopening the deal puts it On Hold; losing it cancels it.
- Each new onboarding goes to the eligible CSM with the fewest active onboardings, within their capacity. CS managers set capacities in **CSM Capacity** records, without a developer.
- When every CSM is full, onboardings go to the **Onboarding Backlog** queue and the `CS_Managers` group gets one alert per transaction (a 200-record batch), saying how many went there.
- Onboardings move through six stages (Kickoff Scheduled → Post-Launch Review), with skipping, required notes and Go Live locking enforced by validation rules.
- Every stage records when it was first reached, how many times it was visited and the total days spent in it, rework included. The **Onboarding Overview** dashboard reports on load, stages, rework and at-risk onboardings.

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`)
- [Node.js](https://nodejs.org/), for the bulk demo helper and the Prettier and lint pre-commit hook. Run `npm install` once after cloning.
- An org with 4 free Salesforce Platform licences for the demo CSMs, and 4 more free Salesforce or Salesforce Platform licences for the tests (see [Run tests](#run-tests)).

## Deploy

The repo has two package directories:

- `force-app/`: the tracker itself.
- `demo/`: demo-only code (`DemoDataSeeder` and its test), used by the seed script.

`sf project deploy start` with no source flag deploys **both**:

```bash
sf project deploy start --target-org <alias>
```

To leave the demo code out (for example in a reviewer's own org), deploy `force-app` only. The seed script in step 3 below then cannot run; everything else works.

```bash
sf project deploy start --source-dir force-app --target-org <alias>
```

## Post-deploy setup

Run these as the admin user, in this order. Every script is safe to run twice.

1. Create the 4 demo CSMs (Avery Brooks, Jordan Lee, Priya Shah, Sam Ortiz) and make yourself the CS manager. CSMs get the Salesforce Platform licence, the Standard Platform User profile, `Onboarding_CSM`, and your time zone, locale and email. You get `Onboarding_Manager` and join `CS_Managers`, so backlog alerts come to you.

   ```bash
   sf apex run --file scripts/apex/create-demo-users.apex
   ```

2. Give each CSM a CSM Capacity record: 5, 7, 7 and 10 in name order. This must be a separate run from step 1, because Salesforce does not allow users and other records to be saved together.

   ```bash
   sf apex run --file scripts/apex/seed-csm-capacity.apex
   ```

3. Seed 8 onboardings with realistic past history, so the record page and dashboard have something to show. 5 are finished, 3 are active (one each for Jordan, Priya and Sam, one of them at risk), and 3 include a QA → Implementation rework loop. Needs the `demo/` package.

   ```bash
   sf apex run --file scripts/apex/seed-demo-data.apex
   ```

   Seeded history is written directly with the kill switch on, which the script switches off again afterwards, even if it fails. Real onboardings only get stage history through automation. Seeded onboardings are created today, but Days To Launch counts from the backdated kickoff, so it is still right (spec A33, A34).

Open the **Revinfinity | Onboarding Tracker** app and the **Onboarding Overview** dashboard. Average Days per Stage leaves out Post-Launch Review, the last stage, whose time so far never stops growing.

## Run tests

```bash
sf apex run test --test-level RunLocalTests --wait 10 --result-format human --code-coverage
```

Some tests create up to 4 users of their own, so the org needs 4 free Salesforce or Salesforce Platform licences. In a Developer Edition org with the 4 demo CSMs, that is exactly what is left. Add any other user and those tests fail with a licence error.

## Bulk demo: 200 deals won in one load

This is the Data Loader scenario: a quarter-end load closes 200 deals in one job.

With the seed data in place, CSMs have 26 free slots, so the expected result is:

| CSM          | Capacity | Active before | Assigned |
| ------------ | -------- | ------------- | -------- |
| Avery Brooks | 5        | 0             | 5        |
| Jordan Lee   | 7        | 1             | 6        |
| Priya Shah   | 7        | 1             | 6        |
| Sam Ortiz    | 10       | 1             | 9        |
| **Backlog**  |          |               | **174**  |

The managers also get one backlog alert, "174 new onboardings went to the Onboarding Backlog queue …". Clicking it opens the **Backlog** list view, the onboardings waiting in the queue. A larger load sends one alert per 200-record batch.

1. Load 200 open opportunities (`Demo Bulk 001` to `Demo Bulk 200`):

   ```bash
   sf data import bulk --sobject Opportunity --file data/demo-opportunities.csv --line-ending LF --target-org <alias> --wait 10
   ```

2. Export their Ids:

   ```bash
   sf data export bulk --query "SELECT Id FROM Opportunity WHERE Name LIKE 'Demo Bulk %' AND IsClosed = false" --output-file data/demo-opportunities-ids.csv --result-format csv --line-ending LF --target-org <alias> --wait 10
   ```

3. Build the close file (`Id`, `StageName` = `Closed Won`):

   ```bash
   node scripts/build-close-csv.mjs
   ```

4. Close all 200 as won in one job:

   ```bash
   sf data update bulk --sobject Opportunity --file data/demo-opportunities-close.csv --line-ending LF --target-org <alias> --wait 10
   ```

Data Loader works just as well for steps 1 and 4. The two generated CSVs hold org-specific Ids and are git-ignored.

To run the demo again, remove the `Demo Bulk` onboardings and opportunities, then repeat steps 1 to 4. The reset finds them by name, never by Id, and leaves users, capacities and the seed data alone.

```bash
sf apex run --file scripts/apex/reset-bulk-demo.apex
```

### Very large loads: use serial mode

Assignment locks each CSM's capacity row while it counts, so two parallel batches can never over-assign a CSM. A very large load in parallel batches can wait on that lock long enough to fail with `UNABLE_TO_LOCK_ROW`. For quarter-end loads of thousands of deals, run Data Loader in **serial mode** (Settings → "Enable serial mode for Bulk API").

## Kill switch

**Automation Bypass** (Setup → Custom Settings → Automation Bypass → Manage) turns onboarding automation off for one user, one profile or the whole org, with no deployment. It is meant for bulk data fixes and migrations. There are three switches: triggers, flows and validation rules.

> **Warning:** while triggers are bypassed, won deals get **no onboarding, no assignment and no stage rows**. Nothing catches up afterwards. Whoever uses the switch is responsible for the data, and should turn it off as soon as the load is done.

## Design

See [docs/project-spec.md](docs/project-spec.md) for the data model, assignment rules, stage tracking, security, assumptions and known limitations.
