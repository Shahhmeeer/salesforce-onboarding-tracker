/**
 * Shared test data: Accounts, Opportunities (open, won or lost), the Automation_Bypass__c org
 * default with every switch off, a sales user with no onboarding access, a CS manager user, CSM
 * users with their capacity records, and existing onboardings that make up a CSM's current load.
 *
 * Opportunity stages are looked up by IsWon / IsClosed, never by name, so tests keep working if an
 * admin renames stages. build* methods return unsaved records; create* methods insert them.
 *
 * without sharing, system mode: test setup only, run as the test's admin (spec 10.3).
 */
@IsTest
public without sharing class TestDataFactory {
  private static final String SALES_PROFILE_NAME = 'Standard User';
  private static final String PLATFORM_PROFILE_NAME = 'Standard Platform User';
  private static final String PLATFORM_LICENCE = 'Salesforce Platform';
  private static final String SALESFORCE_LICENCE = 'Salesforce';
  private static final String CSM_PERMISSION_SET = 'Onboarding_CSM';
  private static final String MANAGER_PERMISSION_SET = 'Onboarding_Manager';

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

  // A Standard User with Onboarding_Manager: a CS manager who can reassign and work the backlog.
  public static User createManagerUser() {
    // System mode: profile and permission set lookups for test setup.
    Profile profile = [
      SELECT Id
      FROM Profile
      WHERE Name = :SALES_PROFILE_NAME
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    Id managerPermissionSetId = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :MANAGER_PERMISSION_SET
      WITH SYSTEM_MODE
      LIMIT 1
    ]
    .Id;
    String unique = String.valueOf(Crypto.getRandomInteger()).remove('-');
    User user = new User(
      ProfileId = profile.Id,
      LastName = 'CS Manager',
      Alias = 'mgr' + unique.left(5),
      Email = 'cs.manager@onboarding-tracker.test',
      Username = 'cs.manager.' + unique + '@onboarding-tracker.test',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      TimeZoneSidKey = 'Europe/London'
    );
    // Users and permission set assignments are setup DML; running them as the current user keeps
    // them apart from the test's other DML (no MIXED_DML_OPERATION).
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // System mode: test setup.
      insert as system user;
      // System mode: test setup.
      insert as system new PermissionSetAssignment(
        AssigneeId = user.Id,
        PermissionSetId = managerPermissionSetId
      );
    }
    return user;
  }

  /**
   * CSM users with Onboarding_CSM, one per last name, in the order given. FirstName is left blank so
   * User.Name is the last name and the alphabetical tie-break follows the names passed in.
   *
   * Free Salesforce Platform licences are used first, then Standard User (Salesforce licence) for
   * the rest, so tests do not depend on how many licences an org has. Assignment does not depend
   * on the licence. Throws LicenceException, before inserting anything, if there are not enough.
   */
  public static List<User> createCsmUsers(
    Integer count,
    List<String> lastNames
  ) {
    if (lastNames != null && lastNames.size() != count) {
      throw new IllegalArgumentException(
        'createCsmUsers needs one last name per user: got ' +
          lastNames.size() +
          ' names for ' +
          count +
          ' users.'
      );
    }
    Map<String, Integer> free = freeLicences();
    Integer freePlatform = free.get(PLATFORM_LICENCE);
    Integer freeSalesforce = free.get(SALESFORCE_LICENCE);
    if (count > freePlatform + freeSalesforce) {
      throw new LicenceException(
        'createCsmUsers needs ' +
          count +
          ' user licences but only ' +
          freePlatform +
          ' Salesforce Platform and ' +
          freeSalesforce +
          ' Salesforce licences are free.'
      );
    }

    Map<String, Id> profileIds = new Map<String, Id>();
    // System mode: profile lookup for test setup.
    for (Profile profile : [
      SELECT Id, Name
      FROM Profile
      WHERE Name IN (:PLATFORM_PROFILE_NAME, :SALES_PROFILE_NAME)
      WITH SYSTEM_MODE
    ]) {
      profileIds.put(profile.Name, profile.Id);
    }
    // System mode: permission set lookup for test setup.
    Id csmPermissionSetId = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :CSM_PERMISSION_SET
      WITH SYSTEM_MODE
      LIMIT 1
    ]
    .Id;

    List<User> users = new List<User>();
    for (Integer i = 0; i < count; i++) {
      String unique = String.valueOf(Crypto.getRandomInteger()).remove('-');
      String profileName = i < freePlatform
        ? PLATFORM_PROFILE_NAME
        : SALES_PROFILE_NAME;
      users.add(
        new User(
          ProfileId = profileIds.get(profileName),
          LastName = lastNames == null ? 'CSM ' + i : lastNames[i],
          Alias = 'csm' + unique.left(5),
          Email = 'csm@onboarding-tracker.test',
          Username = 'csm.' + i + '.' + unique + '@onboarding-tracker.test',
          EmailEncodingKey = 'UTF-8',
          LanguageLocaleKey = 'en_US',
          LocaleSidKey = 'en_US',
          TimeZoneSidKey = 'Europe/London'
        )
      );
    }
    // Users and permission set assignments are setup DML; running them as the current user keeps
    // them apart from the test's other DML (no MIXED_DML_OPERATION).
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // System mode: test setup.
      insert as system users;
      List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
      for (User user : users) {
        assignments.add(
          new PermissionSetAssignment(
            AssigneeId = user.Id,
            PermissionSetId = csmPermissionSetId
          )
        );
      }
      // System mode: test setup.
      insert as system assignments;
    }
    return users;
  }

  // Free = total - used, for the two licences CSM users can have.
  @TestVisible
  private static Map<String, Integer> freeLicences() {
    Map<String, Integer> free = new Map<String, Integer>{
      PLATFORM_LICENCE => 0,
      SALESFORCE_LICENCE => 0
    };
    // System mode: licence counts for test setup.
    for (UserLicense licence : [
      SELECT Name, TotalLicenses, UsedLicenses
      FROM UserLicense
      WHERE Name IN (:PLATFORM_LICENCE, :SALESFORCE_LICENCE)
      WITH SYSTEM_MODE
    ]) {
      free.put(
        licence.Name,
        Math.max(0, licence.TotalLicenses - licence.UsedLicenses)
      );
    }
    return free;
  }

  public static CSM_Capacity__c createCapacity(User user, Integer max) {
    CSM_Capacity__c capacity = new CSM_Capacity__c(
      User__c = user.Id,
      Max_Active_Onboardings__c = max
    );
    // System mode: test setup.
    insert as system capacity;
    return capacity;
  }

  // Unsaved onboardings, one per new open Opportunity (each Opportunity can have only one).
  public static List<Onboarding__c> buildOnboardings(
    Id accountId,
    Integer count
  ) {
    List<Onboarding__c> onboardings = new List<Onboarding__c>();
    for (Opportunity opp : createOpportunities(accountId, count, openStage())) {
      onboardings.add(new Onboarding__c(Opportunity__c = opp.Id));
    }
    return onboardings;
  }

  /**
   * Existing load: onboardings already owned by ownerId at the given stage and status. The trigger
   * and validation rules are switched off for this insert only, so the records skip assignment
   * and can start at any stage. They share one open Opportunity, which is fine with the trigger
   * off because Opportunity_Key__c stays blank.
   */
  public static List<Onboarding__c> createExistingOnboardings(
    Id accountId,
    Id ownerId,
    Integer count,
    String stage,
    String status
  ) {
    Opportunity opp = createOpportunity(accountId, openStage());
    List<Onboarding__c> onboardings = new List<Onboarding__c>();
    for (Integer i = 0; i < count; i++) {
      onboardings.add(
        new Onboarding__c(
          Name = 'Existing ' + status + ' ' + i,
          Opportunity__c = opp.Id,
          Account__c = accountId,
          OwnerId = ownerId,
          Stage__c = stage,
          Status__c = status,
          Status_Reason__c = status == 'Active' ? null : 'Test setup'
        )
      );
    }
    Automation_Bypass__c setting = Automation_Bypass__c.getOrgDefaults();
    setting.Bypass_Validation_Rules__c = true;
    // System mode: admin configuration, test setup.
    update as system setting;
    TriggerHandler.bypass('OnboardingTriggerHandler');
    // System mode: test setup.
    insert as system onboardings;
    TriggerHandler.clearBypass('OnboardingTriggerHandler');
    setting.Bypass_Validation_Rules__c = false;
    // System mode: admin configuration, test setup.
    update as system setting;
    return onboardings;
  }

  public class LicenceException extends Exception {
  }
}
