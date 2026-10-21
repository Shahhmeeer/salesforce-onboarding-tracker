/**
 * Shared test data: Accounts, Opportunities (open, won or lost), the Automation_Bypass__c org
 * default with every switch off, and a sales user with no onboarding access.
 *
 * Opportunity stages are looked up by IsWon / IsClosed, never by name, so tests keep working if an
 * admin renames stages. build* methods return unsaved records; create* methods insert them.
 *
 * without sharing, system mode: test setup only, run as the test's admin (spec 10.3).
 */
@IsTest
public without sharing class TestDataFactory {
  private static final String SALES_PROFILE_NAME = 'Standard User';

  private static Map<String, String> stageNames;

  public static String wonStage() {
    return stageName('won');
  }

  public static String openStage() {
    return stageName('open');
  }

  public static String lostStage() {
    return stageName('lost');
  }

  // Lowest sort order in each group, so the choice is stable.
  private static String stageName(String kind) {
    if (stageNames == null) {
      stageNames = new Map<String, String>();
      // System mode: stage configuration, read for test setup only.
      for (OpportunityStage stage : [
        SELECT ApiName, IsWon, IsClosed
        FROM OpportunityStage
        WHERE IsActive = TRUE
        WITH SYSTEM_MODE
        ORDER BY SortOrder
      ]) {
        String stageKind = stage.IsWon
          ? 'won'
          : (stage.IsClosed ? 'lost' : 'open');
        if (!stageNames.containsKey(stageKind)) {
          stageNames.put(stageKind, stage.ApiName);
        }
      }
    }
    return stageNames.get(kind);
  }

  public static List<Account> createAccounts(Integer count) {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < count; i++) {
      accounts.add(new Account(Name = 'Test Customer ' + i));
    }
    // System mode: test setup.
    insert as system accounts;
    return accounts;
  }

  public static Opportunity buildOpportunity(Id accountId, String stageName) {
    return new Opportunity(
      Name = 'Test Deal',
      AccountId = accountId,
      StageName = stageName,
      CloseDate = Date.today()
    );
  }

  public static List<Opportunity> createOpportunities(
    Id accountId,
    Integer count,
    String stageName
  ) {
    List<Opportunity> opportunities = new List<Opportunity>();
    for (Integer i = 0; i < count; i++) {
      Opportunity opp = buildOpportunity(accountId, stageName);
      opp.Name = 'Test Deal ' + i;
      opportunities.add(opp);
    }
    // System mode: test setup.
    insert as system opportunities;
    return opportunities;
  }

  public static Opportunity createOpportunity(Id accountId, String stageName) {
    return createOpportunities(accountId, 1, stageName)[0];
  }

  public static final List<String> STAGE_ORDER = new List<String>{
    'Kickoff_Scheduled',
    'Gathering_Info',
    'Implementation',
    'QA_Review',
    'Go_Live',
    'Post_Launch_Review'
  };

  // Moves an onboarding forward one stage per save, with the required notes, until it reaches
  // targetStage. Validation rules stay on, so this is the path a CSM would take.
  public static void walkOnboardingTo(Id onboardingId, String targetStage) {
    // System mode: test setup.
    update as system new Onboarding__c(
      Id = onboardingId,
      Gathering_Info_Notes__c = 'Requirements captured.',
      Implementation_Notes__c = 'Configured and handed over.'
    );
    for (Integer i = 1; i <= STAGE_ORDER.indexOf(targetStage); i++) {
      // System mode: test setup.
      update as system new Onboarding__c(
        Id = onboardingId,
        Stage__c = STAGE_ORDER[i]
      );
    }
  }

  // Org default with every switch off, so automation runs as in production.
  public static Automation_Bypass__c createBypassSetting() {
    Automation_Bypass__c setting = new Automation_Bypass__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Bypass_Triggers__c = false,
      Bypass_Flows__c = false,
      Bypass_Validation_Rules__c = false
    );
    // System mode: admin configuration, test setup.
    insert as system setting;
    return setting;
  }

  // A Standard User with no onboarding permission set: can sell, cannot see onboardings.
  public static User createSalesUser() {
    // System mode: profile lookup for test setup.
    Profile profile = [
      SELECT Id
      FROM Profile
      WHERE Name = :SALES_PROFILE_NAME
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    String unique = String.valueOf(Crypto.getRandomInteger()).remove('-');
    User user = new User(
      ProfileId = profile.Id,
      LastName = 'Sales Rep',
      Alias = 'srep' + unique.left(4),
      Email = 'sales.rep@onboarding-tracker.test',
      Username = 'sales.rep.' + unique + '@onboarding-tracker.test',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      TimeZoneSidKey = 'Europe/London'
    );
    // Inserting a User is setup DML; running it as the current user keeps it apart from the test's
    // other DML (no MIXED_DML_OPERATION).
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // System mode: test setup.
      insert as system user;
    }
    return user;
  }
}
