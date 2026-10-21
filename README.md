# Onboarding Tracker

A Salesforce onboarding tracker for SkyPath AI's Customer Success team. When an Opportunity is won, an Onboarding is created automatically and assigned to the eligible CSM with the fewest active onboardings, within their capacity. Onboardings move through six enforced stages, and the time spent in each stage is recorded. The full design is in [docs/project-spec.md](docs/project-spec.md).

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`)
- [Node.js](https://nodejs.org/) (for the Prettier and lint pre-commit hook; run `npm install` once after cloning)

## Deploy

```bash
sf project deploy start --target-org <alias>
```

Setup, demo and test instructions will be added as the build completes.
