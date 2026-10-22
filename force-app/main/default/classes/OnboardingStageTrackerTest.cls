/**
 * Tests for OnboardingStageTracker: the first row on insert, closing and opening rows on a stage
 * change, rework totals from the spec 8.2 example, protection of First_Reached__c, the Go Live
 * roll-up, bulk saves, onboardings with no rows, and running as a CSM.
 */
@IsTest
private class OnboardingStageTrackerTest {
  // Spec 8.2 dates, at a fixed time of day so whole-day differences are exact.
  private static final Datetime MAY_1 = Datetime.newInstanceGmt(
    2026,
    5,
    1,
    9,
    0,
    0
  );
  private static final Datetime MAY_3 = Datetime.newInstanceGmt(
    2026,
    5,
    3,
    9,
    0,
    0
  );
  private static final Datetime MAY_5 = Datetime.newInstanceGmt(
    2026,
    5,
    5,
    9,
    0,
    0
  );
  private static final Datetime MAY_10 = Datetime.newInstanceGmt(
    2026,
    5,
    10,
    9,
    0,
    0
  );
  private static final Datetime MAY_12 = Datetime.newInstanceGmt(
    2026,
    5,
    12,
    9,
    0,
    0
  );
  private static final Datetime MAY_20 = Datetime.newInstanceGmt(
    2026,
    5,
    20,
    9,
    0,
    0
  );
  private static final Datetime MAY_22 = Datetime.newInstanceGmt(
    2026,
    5,
    22,
    9,
    0,
    0
  );

  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    TestDataFactory.createAccounts(1);
  }

  private static Id accountId() {
    // System mode: tests read setup data as the admin.
    return [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id;
  }

  // An onboarding through the real trigger, with the notes later stages need.
  private static Onboarding__c createOnboarding() {
    Onboarding__c onboarding = TestDataFactory.buildOnboardings(
      accountId(),
      1
    )[0];
    onboarding.Gathering_Info_Notes__c = 'Requirements captured.';
    onboarding.Implementation_Notes__c = 'Configured and handed over.';
    // System mode: test setup.
    insert as system onboarding;
    return onboarding;
  }

  private static void moveTo(Id onboardingId, String stage, Datetime at) {
    OnboardingStageTracker.nowOverride = at;
    // System mode: test setup, saved as the admin.
    update as system new Onboarding__c(Id = onboardingId, Stage__c = stage);
  }

  private static Map<String, Onboarding_Stage__c> rowsByStage(Id onboardingId) {
    Map<String, Onboarding_Stage__c> rows = new Map<String, Onboarding_Stage__c>();
    // System mode: tests read results as the admin.
    for (Onboarding_Stage__c row : [
      SELECT
        Id,
        Name,
        Stage__c,
        Unique_Key__c,
        First_Reached__c,
        Current_Visit_Started__c,
        Completed_Visit_Days__c,
        Days_In_Stage__c,
        Visit_Count__c,
        Is_Current_Stage__c
      FROM Onboarding_Stage__c
      WHERE Onboarding__c = :onboardingId
      WITH SYSTEM_MODE
    ]) {
      rows.put(row.Stage__c, row);
    }
    return rows;
  }

  @IsTest
  static void newOnboardingHasOneKickoffRow() {
    OnboardingStageTracker.nowOverride = MAY_1;

    Test.startTest();
    Onboarding__c onboarding = createOnboarding();
    Test.stopTest();

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    Assert.areEqual(1, rows.size(), 'Exactly one stage row: ' + rows.keySet());
    Onboarding_Stage__c kickoff = rows.get('Kickoff_Scheduled');
    Assert.isNotNull(kickoff, 'The row is for Kickoff Scheduled');
    Assert.areEqual(MAY_1, kickoff.First_Reached__c);
    Assert.areEqual(MAY_1, kickoff.Current_Visit_Started__c);
    Assert.areEqual(1, kickoff.Visit_Count__c);
    Assert.areEqual(0, kickoff.Completed_Visit_Days__c);
    Assert.isTrue(kickoff.Is_Current_Stage__c);
  }

  @IsTest
  static void rowNameIsLabelAndKeyUsesEighteenCharacterId() {
    Onboarding__c onboarding = createOnboarding();
    moveTo(onboarding.Id, 'Gathering_Info', MAY_3);
    moveTo(onboarding.Id, 'Implementation', MAY_5);
    moveTo(onboarding.Id, 'QA_Review', MAY_10);

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    String id18 = String.valueOf(onboarding.Id);
    Assert.areEqual(18, id18.length());
    Assert.areEqual(
      id18 + '-Kickoff_Scheduled',
      rows.get('Kickoff_Scheduled').Unique_Key__c
    );
    Assert.areEqual(id18 + '-QA_Review', rows.get('QA_Review').Unique_Key__c);
    Assert.areEqual('Kickoff Scheduled', rows.get('Kickoff_Scheduled').Name);
    Assert.areEqual('Gathering Info', rows.get('Gathering_Info').Name);
    Assert.areEqual('QA / Review', rows.get('QA_Review').Name);
  }

  @IsTest
  static void movingToGatheringInfoClosesKickoffAndOpensGathering() {
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();

    Test.startTest();
    moveTo(onboarding.Id, 'Gathering_Info', MAY_3);
    Test.stopTest();

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    Assert.areEqual(2, rows.size());
    Onboarding_Stage__c kickoff = rows.get('Kickoff_Scheduled');
    Assert.areEqual(2, kickoff.Completed_Visit_Days__c, 'May 1 to May 3');
    Assert.isNull(kickoff.Current_Visit_Started__c);
    Assert.isFalse(kickoff.Is_Current_Stage__c);
    Assert.areEqual(MAY_1, kickoff.First_Reached__c);

    Onboarding_Stage__c gathering = rows.get('Gathering_Info');
    Assert.areEqual(MAY_3, gathering.First_Reached__c);
    Assert.areEqual(MAY_3, gathering.Current_Visit_Started__c);
    Assert.areEqual(1, gathering.Visit_Count__c);
    Assert.areEqual(0, gathering.Completed_Visit_Days__c);
    Assert.isTrue(gathering.Is_Current_Stage__c);
  }

  // Spec 8.2: Kickoff May 1 -> Gathering Info May 3 -> Implementation May 5 -> QA May 10 -> back to
  // Implementation May 12 -> QA May 20 -> Go Live May 22. Expected values are the spec table.
  @IsTest
  static void reworkMatchesSpecExample() {
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();

    Test.startTest();
    moveTo(onboarding.Id, 'Gathering_Info', MAY_3);
    moveTo(onboarding.Id, 'Implementation', MAY_5);
    moveTo(onboarding.Id, 'QA_Review', MAY_10);
    Map<String, Onboarding_Stage__c> beforeRework = rowsByStage(onboarding.Id);
    moveTo(onboarding.Id, 'Implementation', MAY_12);
    moveTo(onboarding.Id, 'QA_Review', MAY_20);
    moveTo(onboarding.Id, 'Go_Live', MAY_22);
    Test.stopTest();

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    Assert.areEqual(
      5,
      rows.size(),
      'One row per stage reached: ' + rows.keySet()
    );

    // Stage, First Reached, Days In Stage, Visits (spec 8.2 table).
    assertRow(rows.get('Kickoff_Scheduled'), MAY_1, 2, 1);
    assertRow(rows.get('Gathering_Info'), MAY_3, 2, 1);
    assertRow(rows.get('Implementation'), MAY_5, 13, 2);
    assertRow(rows.get('QA_Review'), MAY_10, 4, 2);

    Onboarding_Stage__c goLive = rows.get('Go_Live');
    Assert.areEqual(MAY_22, goLive.First_Reached__c);
    Assert.areEqual(1, goLive.Visit_Count__c);
    Assert.areEqual(
      0,
      goLive.Completed_Visit_Days__c,
      'Go Live is still running'
    );
    Assert.areEqual(MAY_22, goLive.Current_Visit_Started__c);
    Assert.isTrue(goLive.Is_Current_Stage__c, 'Go Live is the current stage');
    for (Onboarding_Stage__c row : rows.values()) {
      if (row.Stage__c != 'Go_Live') {
        Assert.isFalse(
          row.Is_Current_Stage__c,
          row.Stage__c + ' is not current'
        );
      }
    }

    // Going back did not move the first-reached dates.
    Assert.areEqual(
      beforeRework.get('Implementation').First_Reached__c,
      rows.get('Implementation').First_Reached__c
    );
    Assert.areEqual(
      beforeRework.get('QA_Review').First_Reached__c,
      rows.get('QA_Review').First_Reached__c
    );
  }

  // Spec A28: three fractional visits must total the rounded sum of the raw durations. Rounding the
  // running total on every visit would give 1.00 + 2.00 + 3.00 = 6.00 instead of 6.01.
  // Durations are whole seconds because Date/Time fields store whole seconds.
  @IsTest
  static void repeatVisitsDoNotDriftFromRounding() {
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();
    // About 1.004, 2.004 and 3.004 days; each rounds down on its own.
    List<Integer> visitSeconds = new List<Integer>{ 86745, 173145, 259545 };

    Test.startTest();
    moveTo(onboarding.Id, 'Gathering_Info', MAY_3);
    Datetime at = MAY_5;
    Integer totalSeconds = 0;
    for (Integer seconds : visitSeconds) {
      moveTo(onboarding.Id, 'Implementation', at);
      at = at.addSeconds(seconds);
      moveTo(onboarding.Id, 'QA_Review', at);
      at = at.addDays(1);
      totalSeconds += seconds;
    }
    Test.stopTest();

    Decimal rawTotal = Decimal.valueOf(totalSeconds) / 86400;
    Onboarding_Stage__c implementation = rowsByStage(onboarding.Id)
      .get('Implementation');
    Assert.areEqual(3, implementation.Visit_Count__c);
    Assert.isTrue(
      Math.abs(implementation.Completed_Visit_Days__c - rawTotal) < 0.000001,
      'Stored total is the unrounded sum of the visits: ' +
      implementation.Completed_Visit_Days__c
    );
    Assert.areEqual(
      rawTotal.setScale(2),
      implementation.Days_In_Stage__c,
      'Displayed total is the raw sum rounded once'
    );
    Assert.areEqual(6.01, implementation.Days_In_Stage__c);
  }

  private static void assertRow(
    Onboarding_Stage__c row,
    Datetime firstReached,
    Decimal daysInStage,
    Integer visits
  ) {
    Assert.areEqual(
      firstReached,
      row.First_Reached__c,
      row.Stage__c + ' first reached'
    );
    Assert.areEqual(
      daysInStage,
      row.Days_In_Stage__c,
      row.Stage__c + ' days in stage'
    );
    Assert.areEqual(
      daysInStage,
      row.Completed_Visit_Days__c,
      row.Stage__c + ' completed days'
    );
    Assert.areEqual(visits, row.Visit_Count__c, row.Stage__c + ' visits');
    Assert.isNull(row.Current_Visit_Started__c, row.Stage__c + ' is closed');
  }

  @IsTest
  static void firstReachedNeverChangesAcrossBackAndForth() {
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();
    moveTo(onboarding.Id, 'Gathering_Info', MAY_3);
    moveTo(onboarding.Id, 'Implementation', MAY_5);

    Test.startTest();
    Datetime later = MAY_5;
    for (Integer i = 0; i < 3; i++) {
      later = later.addDays(1);
      moveTo(onboarding.Id, 'Gathering_Info', later);
      later = later.addDays(1);
      moveTo(onboarding.Id, 'Implementation', later);
    }
    Test.stopTest();

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    Assert.areEqual(MAY_1, rows.get('Kickoff_Scheduled').First_Reached__c);
    Assert.areEqual(MAY_3, rows.get('Gathering_Info').First_Reached__c);
    Assert.areEqual(MAY_5, rows.get('Implementation').First_Reached__c);
    Assert.areEqual(4, rows.get('Gathering_Info').Visit_Count__c);
    Assert.areEqual(4, rows.get('Implementation').Visit_Count__c);
  }

  @IsTest
  static void reachingGoLiveFillsRollUpAndDaysToLaunch() {
    Onboarding__c onboarding = createOnboarding();

    Test.startTest();
    TestDataFactory.walkOnboardingTo(onboarding.Id, 'Go_Live');
    Test.stopTest();

    // System mode: tests read results as the admin.
    Onboarding__c saved = [
      SELECT Go_Live_Reached__c, Days_To_Launch__c
      FROM Onboarding__c
      WHERE Id = :onboarding.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(
      rowsByStage(onboarding.Id).get('Go_Live').First_Reached__c,
      saved.Go_Live_Reached__c
    );
    Assert.isNotNull(saved.Days_To_Launch__c);
    Assert.isTrue(
      saved.Days_To_Launch__c >= 0,
      'Days to launch: ' + saved.Days_To_Launch__c
    );
  }

  @IsTest
  static void bulkStageChangeWritesEveryRow() {
    OnboardingStageTracker.nowOverride = MAY_1;
    List<Onboarding__c> onboardings = TestDataFactory.buildOnboardings(
      accountId(),
      200
    );
    // System mode: test setup.
    insert as system onboardings;
    for (Onboarding__c onboarding : onboardings) {
      onboarding.Stage__c = 'Gathering_Info';
    }

    Test.startTest();
    OnboardingStageTracker.nowOverride = MAY_3;
    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    // System mode: test setup.
    update as system onboardings;
    Integer queries = Limits.getQueries() - queriesBefore;
    Integer dml = Limits.getDmlStatements() - dmlBefore;
    Test.stopTest();

    // Queries: only the tracker's one query for rows. No name input changed, so the handler does
    // not look up the Account.
    Assert.areEqual(1, queries, 'Queries for the whole update');
    // DML: the update itself, and the tracker's one upsert.
    Assert.areEqual(2, dml, 'DML statements for the whole update');

    Set<Id> ids = new Map<Id, Onboarding__c>(onboardings).keySet();
    // System mode: tests read results as the admin.
    List<Onboarding_Stage__c> rows = [
      SELECT
        Onboarding__c,
        Stage__c,
        Unique_Key__c,
        First_Reached__c,
        Current_Visit_Started__c,
        Completed_Visit_Days__c,
        Visit_Count__c
      FROM Onboarding_Stage__c
      WHERE Onboarding__c IN :ids
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(
      400,
      rows.size(),
      'Kickoff and Gathering Info for each onboarding'
    );
    Map<Id, Set<String>> stagesByOnboarding = new Map<Id, Set<String>>();
    for (Onboarding_Stage__c row : rows) {
      if (!stagesByOnboarding.containsKey(row.Onboarding__c)) {
        stagesByOnboarding.put(row.Onboarding__c, new Set<String>());
      }
      stagesByOnboarding.get(row.Onboarding__c).add(row.Stage__c);
      Assert.areEqual(
        row.Onboarding__c + '-' + row.Stage__c,
        row.Unique_Key__c
      );
      Assert.areEqual(1, row.Visit_Count__c);
      if (row.Stage__c == 'Kickoff_Scheduled') {
        Assert.areEqual(MAY_1, row.First_Reached__c);
        Assert.areEqual(2, row.Completed_Visit_Days__c);
        Assert.isNull(row.Current_Visit_Started__c);
      } else {
        Assert.areEqual('Gathering_Info', row.Stage__c);
        Assert.areEqual(MAY_3, row.First_Reached__c);
        Assert.areEqual(MAY_3, row.Current_Visit_Started__c);
        Assert.areEqual(0, row.Completed_Visit_Days__c);
      }
    }
    Assert.areEqual(200, stagesByOnboarding.size());
    for (Set<String> stages : stagesByOnboarding.values()) {
      Assert.areEqual(
        new Set<String>{ 'Kickoff_Scheduled', 'Gathering_Info' },
        stages
      );
    }
  }

  // The tracker's own cost for a 200-record stage change, measured apart from the rest of the save.
  @IsTest
  static void bulkStageChangeUsesOneQueryAndOneUpsert() {
    OnboardingStageTracker.nowOverride = MAY_1;
    List<Onboarding__c> onboardings = TestDataFactory.buildOnboardings(
      accountId(),
      200
    );
    // System mode: test setup.
    insert as system onboardings;
    Map<Id, Onboarding__c> oldMap = new Map<Id, Onboarding__c>();
    List<Onboarding__c> moved = new List<Onboarding__c>();
    for (Onboarding__c onboarding : onboardings) {
      oldMap.put(
        onboarding.Id,
        new Onboarding__c(Id = onboarding.Id, Stage__c = 'Kickoff_Scheduled')
      );
      moved.add(
        new Onboarding__c(Id = onboarding.Id, Stage__c = 'Gathering_Info')
      );
    }

    Test.startTest();
    OnboardingStageTracker.nowOverride = MAY_3;
    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    OnboardingStageTracker.trackStageChanges(moved, oldMap);
    Integer queries = Limits.getQueries() - queriesBefore;
    Integer dml = Limits.getDmlStatements() - dmlBefore;
    Test.stopTest();

    Assert.areEqual(1, queries, 'One query for existing rows');
    Assert.areEqual(1, dml, 'One upsert');
    // System mode: tests read results as the admin.
    Assert.areEqual(
      400,
      [
        SELECT COUNT()
        FROM Onboarding_Stage__c
        WHERE Onboarding__c IN :oldMap.keySet()
        WITH SYSTEM_MODE
      ]
    );
  }

  @IsTest
  static void sameChangeTwiceInOneTransactionIsRecordedOnce() {
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();
    moveTo(onboarding.Id, 'Gathering_Info', MAY_3);

    Test.startTest();
    // A re-save presents the same Kickoff -> Gathering Info change again, later in the transaction.
    OnboardingStageTracker.nowOverride = MAY_5;
    OnboardingStageTracker.trackStageChanges(
      new List<Onboarding__c>{
        new Onboarding__c(Id = onboarding.Id, Stage__c = 'Gathering_Info')
      },
      new Map<Id, Onboarding__c>{
        onboarding.Id => new Onboarding__c(
          Id = onboarding.Id,
          Stage__c = 'Kickoff_Scheduled'
        )
      }
    );
    Test.stopTest();

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    Assert.areEqual(
      2,
      rows.get('Kickoff_Scheduled').Completed_Visit_Days__c,
      'Not counted twice'
    );
    Assert.areEqual(
      1,
      rows.get('Gathering_Info').Visit_Count__c,
      'Not entered twice'
    );
    Assert.areEqual(MAY_3, rows.get('Gathering_Info').Current_Visit_Started__c);
  }

  // An onboarding saved with automation off has no stage rows. Moving it on must not fail: there is
  // nothing to close, and the new stage gets its first row.
  @IsTest
  static void onboardingWithNoRowsCanChangeStage() {
    Onboarding__c onboarding = TestDataFactory.createExistingOnboardings(
      accountId(),
      UserInfo.getUserId(),
      1,
      'Implementation',
      'Active'
    )[0];
    Assert.areEqual(
      0,
      rowsByStage(onboarding.Id).size(),
      'Created with no stage rows'
    );
    // System mode: test setup.
    update as system new Onboarding__c(
      Id = onboarding.Id,
      Gathering_Info_Notes__c = 'Requirements captured.',
      Implementation_Notes__c = 'Configured and handed over.'
    );

    Test.startTest();
    try {
      moveTo(onboarding.Id, 'QA_Review', MAY_10);
    } catch (Exception e) {
      Assert.fail(
        'Stage change on an onboarding with no rows threw: ' + e.getMessage()
      );
    }
    Test.stopTest();

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    Assert.areEqual(
      new Set<String>{ 'QA_Review' },
      rows.keySet(),
      'No row invented for Implementation'
    );
    Assert.areEqual(MAY_10, rows.get('QA_Review').First_Reached__c);
    Assert.areEqual(1, rows.get('QA_Review').Visit_Count__c);
    Assert.isTrue(rows.get('QA_Review').Is_Current_Stage__c);
  }

  @IsTest
  static void editingFirstReachedFails() {
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();
    Onboarding_Stage__c kickoff = rowsByStage(onboarding.Id)
      .get('Kickoff_Scheduled');

    Test.startTest();
    DmlException error;
    try {
      // System mode: an admin with full access is still blocked by the validation rule.
      update as system new Onboarding_Stage__c(
        Id = kickoff.Id,
        First_Reached__c = MAY_3
      );
    } catch (DmlException e) {
      error = e;
    }
    Test.stopTest();

    Assert.isNotNull(error, 'Changing First Reached must fail');
    Assert.areEqual(
      StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION,
      error.getDmlType(0)
    );
    Assert.areEqual(
      MAY_1,
      rowsByStage(onboarding.Id).get('Kickoff_Scheduled').First_Reached__c
    );
  }

  @IsTest
  static void csmMovingTheirOnboardingWritesStageRows() {
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    TestDataFactory.createCapacity(csm, 5);
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();
    // System mode: tests read results as the admin.
    Assert.areEqual(
      csm.Id,
      [
        SELECT OwnerId
        FROM Onboarding__c
        WHERE Id = :onboarding.Id
        WITH SYSTEM_MODE
      ]
      .OwnerId,
      'Assigned to the CSM'
    );

    Test.startTest();
    System.runAs(csm) {
      OnboardingStageTracker.nowOverride = MAY_3;
      update as user new Onboarding__c(
        Id = onboarding.Id,
        Stage__c = 'Gathering_Info'
      );
      OnboardingStageTracker.nowOverride = MAY_5;
      update as user new Onboarding__c(
        Id = onboarding.Id,
        Stage__c = 'Implementation'
      );
    }
    Test.stopTest();

    Map<String, Onboarding_Stage__c> rows = rowsByStage(onboarding.Id);
    Assert.areEqual(3, rows.size());
    Assert.areEqual(2, rows.get('Kickoff_Scheduled').Completed_Visit_Days__c);
    Assert.areEqual(
      2,
      rows.get('Gathering_Info').Completed_Visit_Days__c,
      'Updated: closed'
    );
    Assert.isNull(rows.get('Gathering_Info').Current_Visit_Started__c);
    Assert.areEqual(
      MAY_5,
      rows.get('Implementation').First_Reached__c,
      'Created'
    );
    Assert.isTrue(rows.get('Implementation').Is_Current_Stage__c);
  }

  @IsTest
  static void csmCannotEditStageRowDirectly() {
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    TestDataFactory.createCapacity(csm, 5);
    OnboardingStageTracker.nowOverride = MAY_1;
    Onboarding__c onboarding = createOnboarding();
    Onboarding_Stage__c kickoff = rowsByStage(onboarding.Id)
      .get('Kickoff_Scheduled');

    Test.startTest();
    Exception error;
    System.runAs(csm) {
      // The CSM can see their row...
      Assert.areEqual(
        1,
        [
          SELECT COUNT()
          FROM Onboarding_Stage__c
          WHERE Id = :kickoff.Id
          WITH USER_MODE
        ]
      );
      // ...but cannot change it.
      try {
        update as user new Onboarding_Stage__c(
          Id = kickoff.Id,
          Visit_Count__c = 7
        );
      } catch (Exception e) {
        error = e;
      }
    }
    Test.stopTest();

    // CSMs have read-only object access to stage rows, so the user-mode save is refused.
    Assert.isInstanceOfType(
      error,
      TypeException.class,
      'A CSM editing a stage row must fail: ' + error
    );
    Assert.areEqual(
      'DML operation UPDATE not allowed on Onboarding_Stage__c',
      error.getMessage()
    );
    Assert.areEqual(
      1,
      rowsByStage(onboarding.Id).get('Kickoff_Scheduled').Visit_Count__c
    );
  }

  @IsTest
  static void unknownStageLabelFallsBackToValue() {
    Assert.areEqual(
      'QA / Review',
      OnboardingStageTracker.stageLabel('QA_Review')
    );
    Assert.areEqual(
      'Not_A_Stage',
      OnboardingStageTracker.stageLabel('Not_A_Stage')
    );
  }
}
