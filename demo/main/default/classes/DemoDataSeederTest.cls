/**
 * Tests for DemoDataSeeder: refuses to run without the kill switch, writes stage history that adds
 * up (the spec 8.2 rework example), gives each onboarding to the CSM at the requested position in
 * name order, and creates nothing twice.
 */
@IsTest
private class DemoDataSeederTest {
  // Spec 8.2: Kickoff May 1, Gathering Info May 3, Implementation May 5, QA May 10, back to
  // Implementation May 12, QA May 20, Go Live May 22. "Now" is May 25.
  private static final Datetime NOW = Datetime.newInstanceGmt(
    2026,
    5,
    25,
    9,
    0,
    0
  );

  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'Alpha', 'Bravo' }
    );
    TestDataFactory.createCapacity(csms[0], 5);
    TestDataFactory.createCapacity(csms[1], 7);
  }

  private static void bypassOn() {
    // System mode: admin configuration, test setup.
    insert as system new Automation_Bypass__c(
      SetupOwnerId = UserInfo.getUserId(),
      Bypass_Triggers__c = true,
      Bypass_Flows__c = true,
      Bypass_Validation_Rules__c = true
    );
  }

  private static List<DemoDataSeeder.SeedOnboarding> seeds() {
    return new List<DemoDataSeeder.SeedOnboarding>{
      new DemoDataSeeder.SeedOnboarding('Rework Co', 1, 50000)
        .visit('Kickoff_Scheduled', 24)
        .visit('Gathering_Info', 22)
        .visit('Implementation', 20)
        .visit('QA_Review', 15)
        .visit('Implementation', 13)
        .visit('QA_Review', 5)
        .visit('Go_Live', 3),
      new DemoDataSeeder.SeedOnboarding('Early Co', 0, 20000)
        .visit('Kickoff_Scheduled', 4)
        .visit('Gathering_Info', 1.5)
    };
  }

  private static Onboarding__c onboardingFor(String company) {
    // System mode: test assertions read automation-only fields.
    return [
      SELECT
        Id,
        Name,
        OwnerId,
        Owner.Name,
        Stage__c,
        Status__c,
        Account__r.Name,
        Opportunity__r.IsWon,
        Opportunity__r.CloseDate,
        Opportunity_Key__c,
        Opportunity__c,
        Target_Go_Live_Date__c,
        Current_Stage_Entered__c,
        Gathering_Info_Notes__c,
        Implementation_Notes__c,
        Go_Live_Reached__c
      FROM Onboarding__c
      WHERE Account__r.Name = :company
      WITH SYSTEM_MODE
    ];
  }

  private static Map<String, Onboarding_Stage__c> rowsByStage(Id onboardingId) {
    Map<String, Onboarding_Stage__c> rows = new Map<String, Onboarding_Stage__c>();
    // System mode: test assertions read automation-only fields.
    for (Onboarding_Stage__c row : [
      SELECT
        Name,
        Stage__c,
        Unique_Key__c,
        First_Reached__c,
        Visit_Count__c,
        Completed_Visit_Days__c,
        Current_Visit_Started__c
      FROM Onboarding_Stage__c
      WHERE Onboarding__c = :onboardingId
      WITH SYSTEM_MODE
    ]) {
      rows.put(row.Stage__c, row);
    }
    return rows;
  }

  private static void assertRow(
    Onboarding_Stage__c row,
    Datetime firstReached,
    Integer visits,
    Decimal completedDays,
    Datetime openSince
  ) {
    Assert.areEqual(
      firstReached,
      row.First_Reached__c,
      row.Stage__c + ' first reached'
    );
    Assert.areEqual(visits, row.Visit_Count__c, row.Stage__c + ' visits');
    Assert.areEqual(
      completedDays,
      row.Completed_Visit_Days__c.setScale(2),
      row.Stage__c + ' completed days'
    );
    Assert.areEqual(
      openSince,
      row.Current_Visit_Started__c,
      row.Stage__c + ' open visit'
    );
  }

  @IsTest
  static void refusesToRunWithoutKillSwitch() {
    String message;
    Test.startTest();
    try {
      DemoDataSeeder.seed(seeds());
    } catch (DemoDataSeeder.BypassOffException e) {
      message = e.getMessage();
    }
    Test.stopTest();

    Assert.areEqual(Label.Onboarding_Demo_Seed_Bypass_Off, message);
    // System mode: test assertion.
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Opportunity WITH SYSTEM_MODE],
      'Nothing written'
    );
  }

  @IsTest
  static void refusesToRunWithOnlySomeSwitchesOn() {
    // System mode: admin configuration, test setup.
    insert as system new Automation_Bypass__c(
      SetupOwnerId = UserInfo.getUserId(),
      Bypass_Triggers__c = true,
      Bypass_Flows__c = true,
      Bypass_Validation_Rules__c = false
    );
    Boolean thrown = false;
    try {
      DemoDataSeeder.seed(seeds());
    } catch (DemoDataSeeder.BypassOffException e) {
      thrown = true;
    }
    Assert.isTrue(thrown, 'Every switch must be on, not just some');
  }

  @IsTest
  static void refusesToRunWithoutCsms() {
    // System mode: test setup.
    delete as system [SELECT Id FROM CSM_Capacity__c WITH SYSTEM_MODE];
    bypassOn();
    String message;
    try {
      DemoDataSeeder.seed(seeds());
    } catch (IllegalArgumentException e) {
      message = e.getMessage();
    }
    Assert.areEqual(Label.Onboarding_Demo_Seed_No_CSMs, message);
  }

  @IsTest
  static void reworkHistoryMatchesSpecExample() {
    bypassOn();
    DemoDataSeeder.nowOverride = NOW;

    Test.startTest();
    Integer created = DemoDataSeeder.seed(seeds());
    Test.stopTest();

    Assert.areEqual(2, created);
    Onboarding__c ob = onboardingFor('Rework Co');
    Datetime may1 = NOW.addHours(-24 * 24);
    Datetime may3 = NOW.addHours(-24 * 22);
    Datetime may5 = NOW.addHours(-24 * 20);
    Datetime may10 = NOW.addHours(-24 * 15);
    Datetime may22 = NOW.addHours(-24 * 3);

    Map<String, Onboarding_Stage__c> rows = rowsByStage(ob.Id);
    Assert.areEqual(5, rows.size(), 'One row per stage reached');
    assertRow(rows.get('Kickoff_Scheduled'), may1, 1, 2.00, null);
    assertRow(rows.get('Gathering_Info'), may3, 1, 2.00, null);
    assertRow(rows.get('Implementation'), may5, 2, 13.00, null);
    assertRow(rows.get('QA_Review'), may10, 2, 4.00, null);
    assertRow(rows.get('Go_Live'), may22, 1, 0.00, may22);
    Assert.areEqual(
      'QA / Review',
      rows.get('QA_Review').Name,
      'Row name is the stage label'
    );
    Assert.areEqual(ob.Id + '-Go_Live', rows.get('Go_Live').Unique_Key__c);
    Assert.areEqual(
      may22,
      ob.Go_Live_Reached__c,
      'Roll-up sees the backdated Go Live'
    );
  }

  @IsTest
  static void onboardingLooksLikeOneAutomationWouldHaveMade() {
    bypassOn();
    DemoDataSeeder.nowOverride = NOW;

    DemoDataSeeder.seed(seeds());

    Onboarding__c rework = onboardingFor('Rework Co');
    Date closeDate = NOW.addHours(-24 * 24).date();
    Assert.isTrue(rework.Opportunity__r.IsWon, 'Deal is won');
    Assert.areEqual(
      closeDate,
      rework.Opportunity__r.CloseDate,
      'Won on kickoff day'
    );
    Assert.areEqual(
      String.valueOf(rework.Opportunity__c),
      rework.Opportunity_Key__c
    );
    Assert.areEqual('Bravo', rework.Owner.Name, 'Position 1 in name order');
    Assert.areEqual('Go_Live', rework.Stage__c);
    Assert.areEqual('Active', rework.Status__c);
    Assert.areEqual(NOW.addHours(-24 * 3), rework.Current_Stage_Entered__c);
    Date target = closeDate.addDays(
      Onboarding_Setting__mdt.getInstance('Default')
        .Default_Days_To_Go_Live__c.intValue()
    );
    Assert.areEqual(target, rework.Target_Go_Live_Date__c);
    Assert.areEqual(
      'Rework Co - Go Live ' + String.valueOf(target),
      rework.Name
    );
    Assert.isNotNull(rework.Gathering_Info_Notes__c);
    Assert.isNotNull(rework.Implementation_Notes__c);

    Onboarding__c early = onboardingFor('Early Co');
    Assert.areEqual('Alpha', early.Owner.Name, 'Position 0 in name order');
    Assert.isNull(
      early.Gathering_Info_Notes__c,
      'No notes for stages not yet passed'
    );
    Map<String, Onboarding_Stage__c> rows = rowsByStage(early.Id);
    assertRow(
      rows.get('Kickoff_Scheduled'),
      NOW.addHours(-24 * 4),
      1,
      2.50,
      null
    );
    assertRow(
      rows.get('Gathering_Info'),
      NOW.addHours(-36),
      1,
      0.00,
      NOW.addHours(-36)
    );
    // System mode: test assertion.
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Onboarding__c WITH SYSTEM_MODE],
      'Automation made no second onboarding for the won deals'
    );
  }

  @IsTest
  static void runningTwiceCreatesNothingTwice() {
    bypassOn();
    DemoDataSeeder.seed(seeds());

    Integer secondRun = DemoDataSeeder.seed(seeds());

    Assert.areEqual(0, secondRun);
    // System mode: test assertions.
    Assert.areEqual(2, [SELECT COUNT() FROM Account WITH SYSTEM_MODE]);
    Assert.areEqual(2, [SELECT COUNT() FROM Opportunity WITH SYSTEM_MODE]);
    Assert.areEqual(2, [SELECT COUNT() FROM Onboarding__c WITH SYSTEM_MODE]);
    Assert.areEqual(
      7,
      [SELECT COUNT() FROM Onboarding_Stage__c WITH SYSTEM_MODE]
    );
  }
}
