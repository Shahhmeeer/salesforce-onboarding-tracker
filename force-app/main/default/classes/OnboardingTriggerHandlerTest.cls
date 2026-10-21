/**
 * Tests for OnboardingTriggerHandler: defaults on insert, the Name format and length, the unique
 * Opportunity key and the stage-entered timestamp.
 */
@IsTest
private class OnboardingTriggerHandlerTest {
  private static final String ACCOUNT_NAME = 'Acme Corp';

  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    // System mode: test setup.
    insert as system new Account(Name = ACCOUNT_NAME);
  }

  private static Id accountId() {
    return [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id;
  }

  private static Onboarding__c onboardingFor(Id opportunityId) {
    // System mode: tests read results as the admin.
    return [
      SELECT
        Id,
        Name,
        Account__c,
        Opportunity_Key__c,
        Stage__c,
        Status__c,
        Target_Go_Live_Date__c,
        Current_Stage_Entered__c
      FROM Onboarding__c
      WHERE Opportunity__c = :opportunityId
      WITH SYSTEM_MODE
    ];
  }

  private static Onboarding__c reload(Id onboardingId) {
    // System mode: tests read results as the admin.
    return [
      SELECT Id, Name, Target_Go_Live_Date__c, Current_Stage_Entered__c
      FROM Onboarding__c
      WHERE Id = :onboardingId
      WITH SYSTEM_MODE
    ];
  }

  private static Integer defaultDays() {
    return Onboarding_Setting__mdt.getInstance('Default')
      .Default_Days_To_Go_Live__c.intValue();
  }

  @IsTest
  static void nameUsesAccountNameAndIsoDate() {
    Test.startTest();
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Test.stopTest();

    Onboarding__c onboarding = onboardingFor(opp.Id);
    Assert.areEqual(
      ACCOUNT_NAME +
        ' - Go Live ' +
        String.valueOf(onboarding.Target_Go_Live_Date__c),
      onboarding.Name
    );
    Assert.isTrue(
      Pattern.matches('.* - Go Live \\d{4}-\\d{2}-\\d{2}', onboarding.Name),
      'ISO date: ' + onboarding.Name
    );
  }

  @IsTest
  static void nameUsesOpportunityNameWithoutAccount() {
    Opportunity opp = TestDataFactory.buildOpportunity(
      null,
      TestDataFactory.wonStage()
    );
    opp.Name = 'Globex Expansion';

    Test.startTest();
    // System mode: test setup.
    insert as system opp;
    Onboarding__c onboarding = onboardingFor(opp.Id);
    String nameOnInsert = onboarding.Name;
    // The rebuild on update looks the Opportunity name up again.
    onboarding.Target_Go_Live_Date__c = Date.newInstance(2027, 2, 1);
    // System mode: acts as the admin.
    update as system onboarding;
    Test.stopTest();

    Assert.isNull(onboarding.Account__c);
    Assert.areEqual(
      'Globex Expansion - Go Live ' +
      String.valueOf(opp.CloseDate.addDays(defaultDays())),
      nameOnInsert
    );
    Assert.areEqual(
      'Globex Expansion - Go Live 2027-02-01',
      reload(onboarding.Id).Name
    );
  }

  @IsTest
  static void nameShowsTbdWithoutTargetDate() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Onboarding__c onboarding = onboardingFor(opp.Id);

    Test.startTest();
    onboarding.Target_Go_Live_Date__c = null;
    // System mode: acts as the admin.
    update as system onboarding;
    Test.stopTest();

    Assert.areEqual(
      ACCOUNT_NAME + ' - Go Live TBD',
      reload(onboarding.Id).Name
    );
  }

  @IsTest
  static void longAccountNameIsShortenedAndDateKept() {
    Account longAccount = new Account(Name = 'L'.repeat(120));
    // System mode: test setup.
    insert as system longAccount;

    Test.startTest();
    Opportunity opp = TestDataFactory.createOpportunity(
      longAccount.Id,
      TestDataFactory.wonStage()
    );
    Test.stopTest();

    Onboarding__c onboarding = onboardingFor(opp.Id);
    String suffix =
      ' - Go Live ' + String.valueOf(onboarding.Target_Go_Live_Date__c);
    Assert.areEqual(80, onboarding.Name.length(), onboarding.Name);
    Assert.isTrue(onboarding.Name.endsWith(suffix), 'Date intact');
    Assert.areEqual('L'.repeat(80 - suffix.length()) + suffix, onboarding.Name);
  }

  @IsTest
  static void buildNameKeepsTbdSuffixWhenCustomerIsLong() {
    String name = OnboardingTriggerHandler.buildName('X'.repeat(200), null);
    Assert.areEqual(80, name.length());
    Assert.isTrue(name.endsWith(' - Go Live TBD'));
  }

  @IsTest
  static void insertSetsDefaults() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );
    opp.CloseDate = Date.newInstance(2026, 3, 10);
    // System mode: test setup.
    update as system opp;

    Test.startTest();
    // A manually created onboarding (A12) gets the same defaults as an automatic one.
    insert as system new Onboarding__c(Opportunity__c = opp.Id);
    Test.stopTest();

    Onboarding__c onboarding = onboardingFor(opp.Id);
    Assert.areEqual(
      opp.CloseDate.addDays(defaultDays()),
      onboarding.Target_Go_Live_Date__c,
      'CloseDate + Default_Days_To_Go_Live__c'
    );
    Assert.areEqual(String.valueOf(opp.Id), onboarding.Opportunity_Key__c);
    Assert.areEqual(accountId(), onboarding.Account__c);
    Assert.areEqual('Kickoff_Scheduled', onboarding.Stage__c);
    Assert.areEqual('Active', onboarding.Status__c);
    Assert.isNotNull(onboarding.Current_Stage_Entered__c);
  }

  @IsTest
  static void explicitTargetDateIsKept() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );
    Date chosen = Date.newInstance(2027, 1, 15);

    Test.startTest();
    // System mode: test setup.
    insert as system new Onboarding__c(
      Opportunity__c = opp.Id,
      Target_Go_Live_Date__c = chosen
    );
    Test.stopTest();

    Assert.areEqual(chosen, onboardingFor(opp.Id).Target_Go_Live_Date__c);
  }

  @IsTest
  static void changingTargetDateUpdatesName() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Onboarding__c onboarding = onboardingFor(opp.Id);

    Test.startTest();
    onboarding.Target_Go_Live_Date__c = Date.newInstance(2027, 6, 30);
    // System mode: acts as the admin.
    update as system onboarding;
    Test.stopTest();

    Assert.areEqual(
      ACCOUNT_NAME + ' - Go Live 2027-06-30',
      reload(onboarding.Id).Name
    );
  }

  @IsTest
  static void updateWithoutNameInputChangesRunsNoNameQuery() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Onboarding__c onboarding = onboardingFor(opp.Id);
    String expected = onboarding.Name;

    Test.startTest();
    onboarding.Gathering_Info_Notes__c = 'Notes only';
    Integer before = Limits.getQueries();
    // System mode: acts as the admin.
    update as system onboarding;
    Integer forNotes = Limits.getQueries() - before;
    String nameAfterNotes = reload(onboarding.Id).Name;

    onboarding.Target_Go_Live_Date__c = Date.newInstance(2027, 3, 1);
    before = Limits.getQueries();
    // System mode: acts as the admin.
    update as system onboarding;
    Integer forDate = Limits.getQueries() - before;
    Test.stopTest();

    Assert.areEqual(0, forNotes, 'No name input changed: no Account lookup');
    Assert.areEqual(expected, nameAfterNotes, 'Name unchanged');
    Assert.areEqual(1, forDate, 'Target date changed: 1 Account lookup');
    Assert.areEqual(
      ACCOUNT_NAME + ' - Go Live 2027-03-01',
      reload(onboarding.Id).Name
    );
  }

  @IsTest
  static void manualNameEditIsOverwritten() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Onboarding__c onboarding = onboardingFor(opp.Id);
    String expected = onboarding.Name;

    Test.startTest();
    onboarding.Name = 'Typed by hand';
    // System mode: acts as the admin.
    update as system onboarding;
    Test.stopTest();

    Assert.areEqual(expected, reload(onboarding.Id).Name);
  }

  @IsTest
  static void accountIsCopiedAtCreationOnly() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Account other = new Account(Name = 'Other Customer');
    // System mode: test setup.
    insert as system other;

    Test.startTest();
    opp.AccountId = other.Id;
    update as system opp;
    Test.stopTest();

    Onboarding__c onboarding = onboardingFor(opp.Id);
    Assert.areEqual(accountId(), onboarding.Account__c, 'A14: not synced');
    Assert.isTrue(onboarding.Name.startsWith(ACCOUNT_NAME));
  }

  @IsTest
  static void secondOnboardingForSameOpportunityFails() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );

    Test.startTest();
    // System mode: acts as the admin; triggers and validation rules still run.
    Database.SaveResult result = Database.insert(
      new Onboarding__c(Opportunity__c = opp.Id),
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    Assert.isFalse(result.isSuccess());
    Assert.areEqual(
      StatusCode.DUPLICATE_VALUE,
      result.getErrors()[0].getStatusCode()
    );
    // System mode: tests read results as the admin.
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Onboarding__c
        WHERE Opportunity__c = :opp.Id
        WITH SYSTEM_MODE
      ]
    );
  }

  @IsTest
  static void changingStageUpdatesCurrentStageEntered() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Onboarding__c onboarding = onboardingFor(opp.Id);
    Datetime earlier = Datetime.newInstance(
      Date.today().addDays(-3),
      Time.newInstance(9, 0, 0, 0)
    );
    // Backdate it; an edit without a stage change must leave it alone.
    onboarding.Current_Stage_Entered__c = earlier;
    // System mode: test setup.
    update as system onboarding;
    Assert.areEqual(earlier, reload(onboarding.Id).Current_Stage_Entered__c);

    Test.startTest();
    update as system new Onboarding__c(
      Id = onboarding.Id,
      Stage__c = 'Gathering_Info'
    );
    Test.stopTest();

    Assert.isTrue(
      reload(onboarding.Id).Current_Stage_Entered__c > earlier,
      'Re-stamped on stage change'
    );
  }
}
