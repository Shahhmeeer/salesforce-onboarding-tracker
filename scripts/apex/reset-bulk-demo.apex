// Removes the bulk demo records so the 200-deal demo (spec 14.2) can be run again.
//
// Deletes Onboardings whose Opportunity is named "Demo Bulk ...", then those Opportunities. Stage
// rows go with their Onboarding (master-detail). Records are found by the demo naming pattern,
// never by Id. Users, CSM Capacity records and the seeded history ("Demo Seed - ...") are left in
// place, so a rerun gives the same result.
//
// Safe to run twice. Run as the admin:
//   sf apex run --file scripts/apex/reset-bulk-demo.apex

final String BULK_PATTERN = 'Demo Bulk %';

List<Opportunity> opportunities = [
  SELECT Id
  FROM Opportunity
  WHERE Name LIKE :BULK_PATTERN
  WITH USER_MODE
];
// Matched by their Opportunity's demo name. Run as the admin, who can see and delete every
// onboarding, including those owned by CSMs and the backlog queue.
List<Onboarding__c> onboardings = [
  SELECT Id
  FROM Onboarding__c
  WHERE Opportunity__r.Name LIKE :BULK_PATTERN
  WITH USER_MODE
];

// Onboardings first: the Opportunity lookup is delete-restricted.
delete as user onboardings;
delete as user opportunities;

System.debug(
  LoggingLevel.ERROR,
  'Reset: ' + onboardings.size() + ' onboardings and ' + opportunities.size() + ' opportunities deleted.'
);
