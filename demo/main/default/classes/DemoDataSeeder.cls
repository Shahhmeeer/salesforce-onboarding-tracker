/**
 * Writes demo onboardings with backdated stage history, so the record page, reports and dashboard
 * have something to show (spec 14.1). Called by scripts/apex/seed-demo-data.apex, which holds the
 * demo data and turns the kill switch on around the call.
 *
 * Real onboardings only get stage rows through automation, which always stamps "now". History in
 * the past has to be written directly, with automation switched off (A33): a won Opportunity, the
 * Onboarding and one Onboarding Stage row per stage reached. First Reached, Visit Count and
 * Completed Visit Days are worked out from each onboarding's list of visits, the same way
 * OnboardingStageTracker would have recorded them, so Days In Stage is correct. The last visit is
 * the current stage and stays open. CreatedDate cannot be backdated, so it is the day of the run
 * (A34).
 *
 * Refuses to run unless every kill switch (triggers, flows, validation rules) is on for the running
 * user: without it, automation would create a second onboarding per deal, overwrite the owner and
 * stamp "now" on the history.
 *
 * Safe to run twice: Accounts, Opportunities ("Demo Seed - <company>") and Onboardings are only
 * created when missing.
 *
 * Lives in the demo/ package directory, not force-app, so it can be left out of a deploy.
 *
 * without sharing, system mode: anonymous Apex cannot use system mode, and the history fields are
 * read-only for every user, so this class does the writing.
 */
public without sharing class DemoDataSeeder {
  @TestVisible
  private static final String OPPORTUNITY_PREFIX = 'Demo Seed - ';
  private static final String SETTING_NAME = 'Default';
  private static final String STATUS_ACTIVE = 'Active';
  private static final String GATHERING_INFO = 'Gathering_Info';
  private static final String IMPLEMENTATION = 'Implementation';
  private static final String QA_REVIEW = 'QA_Review';
  private static final Decimal MILLISECONDS_PER_DAY = 86400000;

  // Lets tests fix "now" so every date is exact.
  @TestVisible
  private static Datetime nowOverride;

  public class BypassOffException extends Exception {
  }

  /**
   * One demo onboarding: the customer, which CSM gets it (position in name order, 0 = first) and
   * its visits in order, each a stage and how many days ago that visit started.
   */
  public class SeedOnboarding {
    public final String company;
    public final Integer csmPosition;
    public final Decimal amount;
    public final List<String> stages = new List<String>();
    public final List<Decimal> daysAgo = new List<Decimal>();

    public SeedOnboarding(String company, Integer csmPosition, Decimal amount) {
      this.company = company;
      this.csmPosition = csmPosition;
      this.amount = amount;
    }

    public SeedOnboarding visit(String stage, Decimal startedDaysAgo) {
      stages.add(stage);
      daysAgo.add(startedDaysAgo);
      return this;
    }
  }

  /**
   * Creates whatever is missing and returns how many onboardings were created.
   * Throws BypassOffException if the kill switch is not fully on for the running user, and
   * IllegalArgumentException if there are no active CSMs to own the onboardings.
   */
  public static Integer seed(List<SeedOnboarding> seeds) {
    Automation_Bypass__c bypass = Automation_Bypass__c.getInstance();
    if (
      bypass?.Bypass_Triggers__c != true ||
      bypass?.Bypass_Flows__c != true ||
      bypass?.Bypass_Validation_Rules__c != true
    ) {
      throw new BypassOffException(Label.Onboarding_Demo_Seed_Bypass_Off);
    }
    List<Id> csmIds = csmsInNameOrder();
    if (csmIds.isEmpty()) {
      throw new IllegalArgumentException(Label.Onboarding_Demo_Seed_No_CSMs);
    }

    Map<String, Account> accounts = upsertAccounts(seeds);
    Map<String, Opportunity> opportunities = upsertOpportunities(
      seeds,
      accounts
    );
    Set<String> seeded = existingOnboardingKeys(opportunities.values());

    Integer defaultDays = Onboarding_Setting__mdt.getInstance(SETTING_NAME)
      ?.Default_Days_To_Go_Live__c
      ?.intValue();
    List<Onboarding__c> onboardings = new List<Onboarding__c>();
    List<SeedOnboarding> created = new List<SeedOnboarding>();
    for (SeedOnboarding seed : seeds) {
      Opportunity opp = opportunities.get(OPPORTUNITY_PREFIX + seed.company);
      if (seeded.contains(opp.Id)) {
        continue;
      }
      onboardings.add(
        buildOnboarding(
          seed,
          opp,
          accounts.get(seed.company).Id,
          csmIds[Math.mod(seed.csmPosition, csmIds.size())],
          defaultDays
        )
      );
      created.add(seed);
    }
    // System mode: owner, key and stage-entered are automation-only fields (A33).
    insert as system onboardings;

    List<Onboarding_Stage__c> rows = new List<Onboarding_Stage__c>();
    Map<String, String> labels = stageLabels();
    for (Integer i = 0; i < onboardings.size(); i++) {
      rows.addAll(buildStageRows(onboardings[i].Id, created[i], labels));
    }
    // System mode: stage rows are written only by automation; nobody has create access (spec 8.5).
    insert as system rows;
    return onboardings.size();
  }

  private static Datetime now() {
    return nowOverride != null ? nowOverride : Datetime.now();
  }

  private static Datetime daysBeforeNow(Decimal days) {
    return Datetime.newInstance(
      now().getTime() - (days * MILLISECONDS_PER_DAY).longValue()
    );
  }

  private static List<Id> csmsInNameOrder() {
    List<Id> csmIds = new List<Id>();
    // System mode: the same CSM list assignment uses (spec 7.2), whoever runs the seed.
    for (CSM_Capacity__c capacity : [
      SELECT User__c
      FROM CSM_Capacity__c
      WHERE Is_Active__c = TRUE AND User__r.IsActive = TRUE
      WITH SYSTEM_MODE
      ORDER BY User__r.Name, User__c
    ]) {
      csmIds.add(capacity.User__c);
    }
    return csmIds;
  }

  private static Map<String, Account> upsertAccounts(
    List<SeedOnboarding> seeds
  ) {
    Set<String> companies = new Set<String>();
    for (SeedOnboarding seed : seeds) {
      companies.add(seed.company);
    }
    Map<String, Account> accounts = new Map<String, Account>();
    // System mode: demo setup run by the admin; finds Accounts from an earlier run.
    for (Account account : [
      SELECT Id, Name
      FROM Account
      WHERE Name IN :companies
      WITH SYSTEM_MODE
    ]) {
      accounts.put(account.Name, account);
    }
    List<Account> missing = new List<Account>();
    for (String company : companies) {
      if (!accounts.containsKey(company)) {
        Account account = new Account(Name = company);
        missing.add(account);
        accounts.put(company, account);
      }
    }
    // System mode: demo setup run by the admin.
    insert as system missing;
    return accounts;
  }

  private static Map<String, Opportunity> upsertOpportunities(
    List<SeedOnboarding> seeds,
    Map<String, Account> accounts
  ) {
    Set<String> names = new Set<String>();
    for (SeedOnboarding seed : seeds) {
      names.add(OPPORTUNITY_PREFIX + seed.company);
    }
    Map<String, Opportunity> opportunities = new Map<String, Opportunity>();
    // System mode: demo setup run by the admin; finds deals from an earlier run.
    for (Opportunity opp : [
      SELECT Id, Name, CloseDate
      FROM Opportunity
      WHERE Name IN :names
      WITH SYSTEM_MODE
    ]) {
      opportunities.put(opp.Name, opp);
    }
    String wonStage = wonStage();
    List<Opportunity> missing = new List<Opportunity>();
    for (SeedOnboarding seed : seeds) {
      String name = OPPORTUNITY_PREFIX + seed.company;
      if (opportunities.containsKey(name)) {
        continue;
      }
      // Won on the day of kickoff, the first visit.
      Opportunity opp = new Opportunity(
        Name = name,
        AccountId = accounts.get(seed.company).Id,
        StageName = wonStage,
        CloseDate = daysBeforeNow(seed.daysAgo[0]).date(),
        Amount = seed.amount,
        Description = 'Demo seed data, created by scripts/apex/seed-demo-data.apex.'
      );
      missing.add(opp);
      opportunities.put(name, opp);
    }
    // System mode: demo setup run by the admin. The kill switch is on, so no onboarding is made.
    insert as system missing;
    return opportunities;
  }

  // Looked up by IsWon, never by name, like the Opportunity trigger.
  private static String wonStage() {
    // System mode: stage configuration.
    return [
      SELECT ApiName
      FROM OpportunityStage
      WHERE IsActive = TRUE AND IsWon = TRUE
      WITH SYSTEM_MODE
      ORDER BY SortOrder
      LIMIT 1
    ]
    .ApiName;
  }

  private static Set<String> existingOnboardingKeys(
    List<Opportunity> opportunities
  ) {
    Set<String> keys = new Set<String>();
    for (Opportunity opp : opportunities) {
      keys.add(opp.Id);
    }
    Set<String> existing = new Set<String>();
    // System mode: Opportunity_Key__c is hidden from every permission set.
    for (Onboarding__c onboarding : [
      SELECT Opportunity_Key__c
      FROM Onboarding__c
      WHERE Opportunity_Key__c IN :keys
      WITH SYSTEM_MODE
    ]) {
      existing.add(onboarding.Opportunity_Key__c);
    }
    return existing;
  }

  // Fields the trigger would set, filled in by hand because automation is off. Notes are added for
  // every stage passed that requires them, so the record looks like a real one.
  private static Onboarding__c buildOnboarding(
    SeedOnboarding seed,
    Opportunity opp,
    Id accountId,
    Id ownerId,
    Integer defaultDays
  ) {
    Integer last = seed.stages.size() - 1;
    Set<String> reached = new Set<String>(seed.stages);
    Date target = defaultDays == null
      ? null
      : opp.CloseDate.addDays(defaultDays);
    return new Onboarding__c(
      Name = seed.company +
        ' - Go Live ' +
        (target == null ? 'TBD' : String.valueOf(target)),
      Opportunity__c = opp.Id,
      Opportunity_Key__c = opp.Id,
      Account__c = accountId,
      OwnerId = ownerId,
      Stage__c = seed.stages[last],
      Status__c = STATUS_ACTIVE,
      Target_Go_Live_Date__c = target,
      Current_Stage_Entered__c = daysBeforeNow(seed.daysAgo[last]),
      Gathering_Info_Notes__c = reached.contains(IMPLEMENTATION)
        ? 'Kickoff done. Systems, data sources and success criteria agreed with ' +
          seed.company +
          '.'
        : null,
      Implementation_Notes__c = reached.contains(QA_REVIEW)
        ? 'Configuration built, data migrated and integrations tested in a sandbox.'
        : null
    );
  }

  // One row per stage reached. A visit ends when the next one starts; the last visit stays open.
  @TestVisible
  private static List<Onboarding_Stage__c> buildStageRows(
    Id onboardingId,
    SeedOnboarding seed,
    Map<String, String> labels
  ) {
    Map<String, Onboarding_Stage__c> byStage = new Map<String, Onboarding_Stage__c>();
    Integer last = seed.stages.size() - 1;
    for (Integer i = 0; i <= last; i++) {
      String stage = seed.stages[i];
      Datetime started = daysBeforeNow(seed.daysAgo[i]);
      Onboarding_Stage__c row = byStage.get(stage);
      if (row == null) {
        row = new Onboarding_Stage__c(
          Onboarding__c = onboardingId,
          Name = labels.containsKey(stage) ? labels.get(stage) : stage,
          Stage__c = stage,
          Unique_Key__c = onboardingId + '-' + stage,
          First_Reached__c = started,
          Visit_Count__c = 0,
          Completed_Visit_Days__c = 0
        );
        byStage.put(stage, row);
      }
      row.Visit_Count__c += 1;
      if (i == last) {
        row.Current_Visit_Started__c = started;
      } else {
        Datetime ended = daysBeforeNow(seed.daysAgo[i + 1]);
        row.Completed_Visit_Days__c += (Decimal.valueOf(
            ended.getTime() - started.getTime()
          ) / MILLISECONDS_PER_DAY)
          .setScale(10);
      }
    }
    return byStage.values();
  }

  private static Map<String, String> stageLabels() {
    Map<String, String> labels = new Map<String, String>();
    for (
      Schema.PicklistEntry entry : Onboarding_Stage__c.Stage__c.getDescribe()
        .getPicklistValues()
    ) {
      labels.put(entry.getValue(), entry.getLabel());
    }
    return labels;
  }
}
