/**
 * Tests for the validation rules in spec 9: stage order, required notes, the stage lock while not
 * Active, the status reason, the fixed Opportunity, first-reached protection, CSM capacity, and the
 * Bypass_Validation_Rules__c switch. Each blocked case checks the exact error message.
 */
@IsTest
private class OnboardingValidationTest {
  private static final String MSG_START = 'New onboardings start at Kickoff Scheduled.';
  private static final String MSG_SKIP = 'Move one stage at a time. Complete the current stage before moving on.';
  private static final String MSG_BACK_AFTER_GO_LIVE = 'This onboarding has gone live. It can no longer move back to an earlier stage.';
  private static final String MSG_GATHERING_NOTES = 'Add Gathering Info Notes before moving past Gathering Info.';
  private static final String MSG_IMPLEMENTATION_NOTES = 'Add Implementation Notes before moving past Implementation.';
  private static final String MSG_LOCKED = 'This onboarding is On Hold or Cancelled. Change the status back to Active before moving stages.';
  private static final String MSG_REASON = 'Add a reason when an onboarding is On Hold or Cancelled.';
  private static final String MSG_OPPORTUNITY = 'An onboarding always belongs to the deal it was created for. It cannot be moved to another deal.';
  private static final String MSG_FIRST_REACHED = 'The date a stage was first reached is a historical record and cannot be changed.';
  private static final String MSG_CAPACITY = 'Maximum active onboardings cannot be negative. Use 0 to pause new assignments.';
  private static final String MSG_USER = 'Choose the CSM this capacity record is for.';

  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    Account account = TestDataFactory.createAccounts(1)[0];
    TestDataFactory.createOpportunity(account.Id, TestDataFactory.wonStage());
  }

  private static Id onboardingId() {
    // System mode: tests read setup data as the admin.
    return [SELECT Id FROM Onboarding__c WITH SYSTEM_MODE LIMIT 1].Id;
  }

  private static Database.SaveResult save(Onboarding__c onboarding) {
    // System mode: acts as the admin; validation rules still run.
    return Database.update(onboarding, false, AccessLevel.SYSTEM_MODE);
  }

  private static Database.SaveResult moveTo(Id onboardingId, String stage) {
    return save(new Onboarding__c(Id = onboardingId, Stage__c = stage));
  }

  private static void assertAllowed(Database.SaveResult result) {
    Assert.isTrue(
      result.isSuccess(),
      'Expected success: ' + result.getErrors()
    );
  }

  private static void assertBlocked(
    Database.SaveResult result,
    String expectedMessage
  ) {
    Assert.isFalse(result.isSuccess(), 'Expected: ' + expectedMessage);
    Assert.areEqual(expectedMessage, result.getErrors()[0].getMessage());
  }

  @IsTest
  static void newOnboardingMustStartAtKickoff() {
    // System mode: tests read results as the admin.
    Opportunity opp = TestDataFactory.createOpportunity(
      [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id,
      TestDataFactory.openStage()
    );

    Test.startTest();
    // System mode: acts as the admin; triggers and validation rules still run.
    Database.SaveResult result = Database.insert(
      new Onboarding__c(Opportunity__c = opp.Id, Stage__c = 'Implementation'),
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    assertBlocked(result, MSG_START);
  }

  @IsTest
  static void skippingStageIsBlockedAndOneStepIsAllowed() {
    Id recordId = onboardingId();

    Test.startTest();
    Database.SaveResult skip = moveTo(recordId, 'Implementation');
    Database.SaveResult oneStep = moveTo(recordId, 'Gathering_Info');
    Test.stopTest();

    assertBlocked(skip, MSG_SKIP);
    assertAllowed(oneStep);
  }

  @IsTest
  static void gatheringInfoNotesRequiredToMovePast() {
    Id recordId = onboardingId();
    assertAllowed(moveTo(recordId, 'Gathering_Info'));

    Test.startTest();
    Database.SaveResult withoutNotes = moveTo(recordId, 'Implementation');
    Database.SaveResult withNotes = save(
      new Onboarding__c(
        Id = recordId,
        Stage__c = 'Implementation',
        Gathering_Info_Notes__c = 'Requirements captured.'
      )
    );
    Test.stopTest();

    assertBlocked(withoutNotes, MSG_GATHERING_NOTES);
    assertAllowed(withNotes);
  }

  @IsTest
  static void implementationNotesRequiredToMovePast() {
    Id recordId = onboardingId();
    TestDataFactory.walkOnboardingTo(recordId, 'Implementation');
    // System mode: test setup.
    update as system new Onboarding__c(
      Id = recordId,
      Implementation_Notes__c = null
    );

    Test.startTest();
    Database.SaveResult withoutNotes = moveTo(recordId, 'QA_Review');
    Database.SaveResult withNotes = save(
      new Onboarding__c(
        Id = recordId,
        Stage__c = 'QA_Review',
        Implementation_Notes__c = 'Configured.'
      )
    );
    Test.stopTest();

    assertBlocked(withoutNotes, MSG_IMPLEMENTATION_NOTES);
    assertAllowed(withNotes);
  }

  @IsTest
  static void movingBackFromQaReviewToKickoffIsAllowed() {
    Id recordId = onboardingId();
    TestDataFactory.walkOnboardingTo(recordId, 'QA_Review');

    Test.startTest();
    Database.SaveResult result = moveTo(recordId, 'Kickoff_Scheduled');
    Test.stopTest();

    assertAllowed(result);
  }

  @IsTest
  static void movingBackFromGoLiveIsBlocked() {
    Id recordId = onboardingId();
    TestDataFactory.walkOnboardingTo(recordId, 'Go_Live');

    Test.startTest();
    Database.SaveResult result = moveTo(recordId, 'QA_Review');
    Test.stopTest();

    assertBlocked(result, MSG_BACK_AFTER_GO_LIVE);
  }

  @IsTest
  static void changingStageWhileOnHoldIsBlocked() {
    Id recordId = onboardingId();
    assertAllowed(
      save(
        new Onboarding__c(
          Id = recordId,
          Status__c = 'On_Hold',
          Status_Reason__c = 'Customer paused'
        )
      )
    );

    Test.startTest();
    Database.SaveResult result = moveTo(recordId, 'Gathering_Info');
    Test.stopTest();

    assertBlocked(result, MSG_LOCKED);
  }

  @IsTest
  static void onHoldWithoutReasonIsBlocked() {
    Test.startTest();
    Database.SaveResult result = save(
      new Onboarding__c(Id = onboardingId(), Status__c = 'On_Hold')
    );
    Test.stopTest();

    assertBlocked(result, MSG_REASON);
  }

  @IsTest
  static void changingOpportunityIsBlocked() {
    // System mode: tests read results as the admin.
    Opportunity other = TestDataFactory.createOpportunity(
      [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id,
      TestDataFactory.openStage()
    );

    Test.startTest();
    Database.SaveResult result = save(
      new Onboarding__c(Id = onboardingId(), Opportunity__c = other.Id)
    );
    Test.stopTest();

    assertBlocked(result, MSG_OPPORTUNITY);
  }

  @IsTest
  static void bypassSwitchAllowsStageSkip() {
    Automation_Bypass__c setting = Automation_Bypass__c.getOrgDefaults();
    setting.Bypass_Validation_Rules__c = true;
    // System mode: admin configuration, test setup.
    update as system setting;

    Test.startTest();
    Database.SaveResult result = moveTo(onboardingId(), 'Go_Live');
    Test.stopTest();

    assertAllowed(result);
  }

  @IsTest
  static void firstReachedCannotChangeOnceSet() {
    Onboarding_Stage__c stageRow = new Onboarding_Stage__c(
      Onboarding__c = onboardingId(),
      Stage__c = 'Kickoff_Scheduled',
      First_Reached__c = Datetime.now().addDays(-1)
    );
    // System mode: test setup. Stage rows are written by automation from S5.
    insert as system stageRow;

    Test.startTest();
    stageRow.First_Reached__c = Datetime.now();
    // System mode: acts as the admin; validation rules still run.
    Database.SaveResult result = Database.update(
      stageRow,
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    assertBlocked(result, MSG_FIRST_REACHED);
  }

  @IsTest
  static void firstReachedCanBeSetWhenBlank() {
    Onboarding_Stage__c stageRow = new Onboarding_Stage__c(
      Onboarding__c = onboardingId(),
      Stage__c = 'Kickoff_Scheduled'
    );
    // System mode: test setup.
    insert as system stageRow;

    Test.startTest();
    stageRow.First_Reached__c = Datetime.now();
    // System mode: acts as the admin; validation rules still run.
    Database.SaveResult result = Database.update(
      stageRow,
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    assertAllowed(result);
  }

  @IsTest
  static void negativeCapacityIsBlockedAndZeroAllowed() {
    Test.startTest();
    // System mode: acts as the admin; validation rules still run.
    Database.SaveResult negative = Database.insert(
      new CSM_Capacity__c(
        User__c = UserInfo.getUserId(),
        Max_Active_Onboardings__c = -1
      ),
      false,
      AccessLevel.SYSTEM_MODE
    );
    // System mode: acts as the admin; triggers and validation rules still run.
    Database.SaveResult zero = Database.insert(
      new CSM_Capacity__c(
        User__c = UserInfo.getUserId(),
        Max_Active_Onboardings__c = 0
      ),
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    assertBlocked(negative, MSG_CAPACITY);
    assertAllowed(zero);
  }

  @IsTest
  static void capacityWithoutUserIsBlocked() {
    Test.startTest();
    // System mode: acts as the admin; validation rules still run.
    Database.SaveResult result = Database.insert(
      new CSM_Capacity__c(Max_Active_Onboardings__c = 5),
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    assertBlocked(result, MSG_USER);
  }
}
