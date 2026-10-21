/**
 * Tests for the Onboarding_CSM permission set and the sharing model (spec 10.1, 10.2), run as a
 * CSM: no delete, Status is manager-only, colleagues' onboardings are read only, and CSM Capacity
 * is out of reach. Moving stages and stage-row protection are covered in OnboardingStageTrackerTest.
 */
@IsTest
private class OnboardingAccessTest {
  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    TestDataFactory.createAccounts(1);
  }

  // Two CSMs with room for one each, then one won deal: assignment gives it to Avery (alphabetical).
  private static Onboarding__c createOnboardingFor(List<User> csms) {
    for (User csm : csms) {
      TestDataFactory.createCapacity(csm, 5);
    }
    // System mode: tests read setup data as the admin.
    Id accountId = [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id;
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId,
      TestDataFactory.wonStage()
    );
    // System mode: tests read results as the admin.
    return [
      SELECT Id, OwnerId, Status__c
      FROM Onboarding__c
      WHERE Opportunity__c = :opp.Id
      WITH SYSTEM_MODE
    ];
  }

  private static Integer onboardingCount(Id onboardingId) {
    // System mode: tests read results as the admin.
    return [
      SELECT COUNT()
      FROM Onboarding__c
      WHERE Id = :onboardingId
      WITH SYSTEM_MODE
    ];
  }

  @IsTest
  static void csmCannotDeleteTheirOnboarding() {
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    Onboarding__c onboarding = createOnboardingFor(new List<User>{ csm });
    Assert.areEqual(csm.Id, onboarding.OwnerId, 'Assigned to the CSM');

    Test.startTest();
    Exception error;
    System.runAs(csm) {
      try {
        delete as user new Onboarding__c(Id = onboarding.Id);
      } catch (Exception e) {
        error = e;
      }
    }
    Test.stopTest();

    Assert.isNotNull(error, 'A CSM deleting an onboarding must fail');
    Assert.areEqual(1, onboardingCount(onboarding.Id), 'Still there');
  }

  @IsTest
  static void csmCannotChangeStatus() {
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    Onboarding__c onboarding = createOnboardingFor(new List<User>{ csm });

    Test.startTest();
    Exception error;
    System.runAs(csm) {
      try {
        update as user new Onboarding__c(
          Id = onboarding.Id,
          Status__c = 'On_Hold',
          Status_Reason__c = 'Customer asked to pause'
        );
      } catch (Exception e) {
        error = e;
      }
    }
    Test.stopTest();

    Assert.isNotNull(error, 'Status is for managers only');
    // System mode: tests read results as the admin.
    Assert.areEqual(
      'Active',
      [
        SELECT Status__c
        FROM Onboarding__c
        WHERE Id = :onboarding.Id
        WITH SYSTEM_MODE
      ]
      .Status__c
    );
  }

  @IsTest
  static void csmCanEditNotesAndGoLiveDateOnTheirOnboarding() {
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    Onboarding__c onboarding = createOnboardingFor(new List<User>{ csm });
    Date newGoLive = Date.today().addDays(60);

    Test.startTest();
    System.runAs(csm) {
      update as user new Onboarding__c(
        Id = onboarding.Id,
        Gathering_Info_Notes__c = 'Two integrations, SSO required.',
        Target_Go_Live_Date__c = newGoLive
      );
    }
    Test.stopTest();

    // System mode: tests read results as the admin.
    Onboarding__c saved = [
      SELECT Gathering_Info_Notes__c, Target_Go_Live_Date__c
      FROM Onboarding__c
      WHERE Id = :onboarding.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(
      'Two integrations, SSO required.',
      saved.Gathering_Info_Notes__c
    );
    Assert.areEqual(newGoLive, saved.Target_Go_Live_Date__c);
  }

  @IsTest
  static void csmCanReadButNotEditAColleaguesOnboarding() {
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'Avery', 'Blake' }
    );
    Onboarding__c onboarding = createOnboardingFor(csms);
    Assert.areEqual(csms[0].Id, onboarding.OwnerId, 'Assigned to Avery');

    Test.startTest();
    Integer visible;
    Exception error;
    System.runAs(csms[1]) {
      visible = [
        SELECT COUNT()
        FROM Onboarding__c
        WHERE Id = :onboarding.Id
        WITH USER_MODE
      ];
      try {
        update as user new Onboarding__c(
          Id = onboarding.Id,
          Target_Go_Live_Date__c = Date.today().addDays(90)
        );
      } catch (Exception e) {
        error = e;
      }
    }
    Test.stopTest();

    Assert.areEqual(1, visible, 'Public Read Only: colleagues can see it');
    Assert.isNotNull(error, 'Only the owner and managers can edit');
  }

  @IsTest
  static void csmCannotSeeCsmCapacity() {
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    TestDataFactory.createCapacity(csm, 5);

    Test.startTest();
    Exception error;
    System.runAs(csm) {
      try {
        Integer seen = [SELECT COUNT() FROM CSM_Capacity__c WITH USER_MODE];
      } catch (Exception e) {
        error = e;
      }
    }
    Test.stopTest();

    Assert.isNotNull(error, 'CSM Capacity is for managers only');
  }
}
