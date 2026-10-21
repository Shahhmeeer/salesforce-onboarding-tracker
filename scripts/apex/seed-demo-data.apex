// Seeds 8 onboardings with backdated stage history, so the record page, reports and dashboard have
// something to show (spec 14.1). Needs the demo/ package (DemoDataSeeder) and the CSM Capacity
// records from seed-csm-capacity.apex.
//
// Seeded history is written directly with the kill switch on (A33); real onboardings only get
// stage rows through automation. This script turns the kill switch on for the running user, calls
// DemoDataSeeder and turns it back off, also when the seed fails (a failure rolls the whole run
// back, including the switch).
//
// - 5 finished (Post-Launch Review), so they use no capacity. 3 active: one each for the 2nd, 3rd
//   and 4th CSM in name order (Jordan, Priya, Sam in the demo), none for the first (Avery).
// - 3 include a QA / Review -> Implementation rework loop.
// - Each visit is a stage and how many days ago it started; the last visit is the current stage.
//
// Safe to run twice. Run as the admin:
//   sf apex run --file scripts/apex/seed-demo-data.apex

List<DemoDataSeeder.SeedOnboarding> seeds = new List<DemoDataSeeder.SeedOnboarding>{
  new DemoDataSeeder.SeedOnboarding('Brightwave Analytics', 0, 48000)
    .visit('Kickoff_Scheduled', 95).visit('Gathering_Info', 92).visit('Implementation', 87)
    .visit('QA_Review', 75).visit('Go_Live', 71).visit('Post_Launch_Review', 64),
  new DemoDataSeeder.SeedOnboarding('Halcyon Foods', 1, 36500)
    .visit('Kickoff_Scheduled', 88).visit('Gathering_Info', 85.5).visit('Implementation', 80)
    .visit('QA_Review', 70).visit('Implementation', 67).visit('QA_Review', 60)
    .visit('Go_Live', 57).visit('Post_Launch_Review', 50),
  new DemoDataSeeder.SeedOnboarding('Ironleaf Manufacturing', 2, 72000)
    .visit('Kickoff_Scheduled', 80).visit('Gathering_Info', 76).visit('Implementation', 70)
    .visit('QA_Review', 58).visit('Go_Live', 55).visit('Post_Launch_Review', 47),
  new DemoDataSeeder.SeedOnboarding('Juniper Health', 3, 91000)
    .visit('Kickoff_Scheduled', 70).visit('Gathering_Info', 66).visit('Implementation', 61)
    .visit('QA_Review', 52).visit('Implementation', 49).visit('QA_Review', 44)
    .visit('Go_Live', 41).visit('Post_Launch_Review', 34),
  new DemoDataSeeder.SeedOnboarding('Kestrel Freight', 0, 27500)
    .visit('Kickoff_Scheduled', 55).visit('Gathering_Info', 52).visit('Implementation', 46)
    .visit('QA_Review', 37).visit('Go_Live', 33).visit('Post_Launch_Review', 26),
  // Active, past its target go-live date: shows on the At Risk report.
  new DemoDataSeeder.SeedOnboarding('Lumen Retail', 1, 54000)
    .visit('Kickoff_Scheduled', 40).visit('Gathering_Info', 37).visit('Implementation', 31)
    .visit('QA_Review', 22).visit('Implementation', 19).visit('QA_Review', 12),
  new DemoDataSeeder.SeedOnboarding('Northstar Learning', 2, 33000)
    .visit('Kickoff_Scheduled', 20).visit('Gathering_Info', 16).visit('Implementation', 9),
  new DemoDataSeeder.SeedOnboarding('Orchid Hotels', 3, 61500)
    .visit('Kickoff_Scheduled', 8).visit('Gathering_Info', 5)
};

// Kill switch on for this user only, remembering any values they already had.
Automation_Bypass__c previous = Automation_Bypass__c.getInstance(UserInfo.getUserId());
Boolean hadUserSetting = previous?.Id != null && previous.SetupOwnerId == UserInfo.getUserId();
Automation_Bypass__c bypass = hadUserSetting
  ? previous.clone(true, true)
  : new Automation_Bypass__c(SetupOwnerId = UserInfo.getUserId());
bypass.Bypass_Triggers__c = true;
bypass.Bypass_Flows__c = true;
bypass.Bypass_Validation_Rules__c = true;
upsert as user bypass;

Integer created;
try {
  created = DemoDataSeeder.seed(seeds);
} finally {
  // Kill switch off again, whatever happened above.
  if (hadUserSetting) {
    update as user previous;
  } else {
    delete as user bypass;
  }
}

System.debug(
  LoggingLevel.ERROR,
  'Seed: ' + created + ' onboardings created, ' + (seeds.size() - created) + ' already existed.'
);
