/**
 * Tests for OpportunityTriggerHandler: onboarding creation on win, hold on reopen, cancel on loss,
 * reactivation on re-win, bulk, the kill switch, insert error handling, and a sales user with no
 * onboarding access winning a deal.
 */
@IsTest
private class OpportunityTriggerHandlerTest {
  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    TestDataFactory.createAccounts(1);
  }

  private static Id accountId() {
    // System mode: tests read results as the admin.
    return [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id;
  }

  private static List<Onboarding__c> onboardingsFor(Id opportunityId) {
    // System mode: tests read results as the admin.
    return [
      SELECT
        Id,
        OwnerId,
        Opportunity__c,
        Opportunity_Key__c,
        Stage__c,
        Status__c,
        Status_Reason__c
      FROM Onboarding__c
      WHERE Opportunity__c = :opportunityId
      WITH SYSTEM_MODE
    ];
  }

  private static void setStage(Opportunity opp, String stageName) {
    opp.StageName = stageName;
    // System mode: acts as the admin; the sales user case is tested separately.
    update as system opp;
  }

  private static Opportunity wonDealWithOnboarding() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );
    setStage(opp, TestDataFactory.wonStage());
    return opp;
  }

  @IsTest
  static void winningDealCreatesExactlyOneLinkedOnboarding() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );
    Assert.areEqual(0, onboardingsFor(opp.Id).size(), 'Open deal has none');

    Test.startTest();
    setStage(opp, TestDataFactory.wonStage());
    Test.stopTest();

    List<Onboarding__c> onboardings = onboardingsFor(opp.Id);
    Assert.areEqual(1, onboardings.size(), 'Exactly one onboarding');
    Assert.areEqual(opp.Id, onboardings[0].Opportunity__c);
    Assert.areEqual(String.valueOf(opp.Id), onboardings[0].Opportunity_Key__c);
    Assert.areEqual('Active', onboardings[0].Status__c);
    Assert.areEqual('Kickoff_Scheduled', onboardings[0].Stage__c);
  }

  @IsTest
  static void insertingWonOpportunityCreatesOneOnboarding() {
    Test.startTest();
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    Test.stopTest();

    Assert.areEqual(1, onboardingsFor(opp.Id).size());
  }

  @IsTest
  static void editingWonDealAgainCreatesNoSecondOnboarding() {
    Opportunity opp = wonDealWithOnboarding();

    Test.startTest();
    opp.Description = 'Edited after the win';
    // System mode: acts as the admin; triggers and validation rules still run.
    update as system opp;
    Test.stopTest();

    Assert.areEqual(1, onboardingsFor(opp.Id).size());
  }

  @IsTest
  static void reopeningWonDealPutsOnboardingOnHold() {
    Opportunity opp = wonDealWithOnboarding();

    Test.startTest();
    setStage(opp, TestDataFactory.openStage());
    Test.stopTest();

    Onboarding__c onboarding = onboardingsFor(opp.Id)[0];
    Assert.areEqual('On_Hold', onboarding.Status__c);
    Assert.areEqual(
      System.Label.Onboarding_Reason_Deal_Reopened,
      onboarding.Status_Reason__c
    );
  }

  @IsTest
  static void rewinningReopenedDealReactivatesSameOnboarding() {
    Opportunity opp = wonDealWithOnboarding();
    setStage(opp, TestDataFactory.openStage());
    Onboarding__c before = onboardingsFor(opp.Id)[0];

    Test.startTest();
    setStage(opp, TestDataFactory.wonStage());
    Test.stopTest();

    List<Onboarding__c> onboardings = onboardingsFor(opp.Id);
    Assert.areEqual(1, onboardings.size(), 'No second onboarding');
    Assert.areEqual(before.Id, onboardings[0].Id);
    Assert.areEqual('Active', onboardings[0].Status__c);
    Assert.isNull(onboardings[0].Status_Reason__c, 'Reason cleared');
  }

  @IsTest
  static void losingDealCancelsOnboarding() {
    Opportunity opp = wonDealWithOnboarding();

    Test.startTest();
    setStage(opp, TestDataFactory.lostStage());
    Test.stopTest();

    Onboarding__c onboarding = onboardingsFor(opp.Id)[0];
    Assert.areEqual('Cancelled', onboarding.Status__c);
    Assert.areEqual(
      System.Label.Onboarding_Reason_Deal_Lost,
      onboarding.Status_Reason__c
    );
  }

  @IsTest
  static void losingReopenedDealCancelsOnHoldOnboarding() {
    Opportunity opp = wonDealWithOnboarding();
    setStage(opp, TestDataFactory.openStage());

    Test.startTest();
    setStage(opp, TestDataFactory.lostStage());
    Test.stopTest();

    Onboarding__c onboarding = onboardingsFor(opp.Id)[0];
    Assert.areEqual('Cancelled', onboarding.Status__c);
    Assert.areEqual(
      System.Label.Onboarding_Reason_Deal_Lost,
      onboarding.Status_Reason__c
    );
  }

  @IsTest
  static void rewinningLostDealReactivatesSameOnboarding() {
    Opportunity opp = wonDealWithOnboarding();
    setStage(opp, TestDataFactory.lostStage());
    Onboarding__c cancelled = onboardingsFor(opp.Id)[0];
    Assert.areEqual('Cancelled', cancelled.Status__c);

    Test.startTest();
    setStage(opp, TestDataFactory.wonStage());
    Test.stopTest();

    List<Onboarding__c> onboardings = onboardingsFor(opp.Id);
    Assert.areEqual(1, onboardings.size(), 'No second onboarding');
    Assert.areEqual(cancelled.Id, onboardings[0].Id, 'Same onboarding');
    Assert.areEqual('Active', onboardings[0].Status__c);
    Assert.isNull(onboardings[0].Status_Reason__c, 'Reason cleared');
    Assert.areEqual(cancelled.OwnerId, onboardings[0].OwnerId, 'Same owner');
  }

  @IsTest
  static void postLaunchReviewOnboardingUnchangedWhenDealReopened() {
    Opportunity opp = wonDealWithOnboarding();
    Id onboardingId = onboardingsFor(opp.Id)[0].Id;
    TestDataFactory.walkOnboardingTo(onboardingId, 'Post_Launch_Review');

    Test.startTest();
    setStage(opp, TestDataFactory.openStage());
    Test.stopTest();

    Onboarding__c onboarding = onboardingsFor(opp.Id)[0];
    Assert.areEqual('Post_Launch_Review', onboarding.Stage__c);
    Assert.areEqual('Active', onboarding.Status__c, 'Not put on hold');
    Assert.isNull(onboarding.Status_Reason__c);
  }

  @IsTest
  static void postLaunchReviewOnboardingUnchangedWhenDealRewon() {
    Opportunity opp = wonDealWithOnboarding();
    Id onboardingId = onboardingsFor(opp.Id)[0].Id;
    TestDataFactory.walkOnboardingTo(onboardingId, 'Post_Launch_Review');
    // A manager cancels the finished onboarding by hand.
    // System mode: acts as the admin; triggers and validation rules still run.
    update as system new Onboarding__c(
      Id = onboardingId,
      Status__c = 'Cancelled',
      Status_Reason__c = 'Customer churned'
    );
    setStage(opp, TestDataFactory.openStage());

    Test.startTest();
    setStage(opp, TestDataFactory.wonStage());
    Test.stopTest();

    List<Onboarding__c> onboardings = onboardingsFor(opp.Id);
    Assert.areEqual(1, onboardings.size(), 'No second onboarding');
    Assert.areEqual('Cancelled', onboardings[0].Status__c, 'Not reactivated');
    Assert.areEqual('Customer churned', onboardings[0].Status_Reason__c);
  }

  @IsTest
  static void salesUserWinningDealStillCreatesOnboarding() {
    User salesUser = TestDataFactory.createSalesUser();
    Opportunity opp;

    Test.startTest();
    System.runAs(salesUser) {
      Account account = new Account(Name = 'Sales Rep Customer');
      // User mode: the sales user's own save, with their own permissions.
      insert as user account;
      opp = TestDataFactory.buildOpportunity(
        account.Id,
        TestDataFactory.openStage()
      );
      insert as user opp;
      opp.StageName = TestDataFactory.wonStage();
      update as user opp;

      // The sales user really has no access to onboardings, so the automation needed system mode.
      Boolean blocked = false;
      try {
        Database.query('SELECT Id FROM Onboarding__c', AccessLevel.USER_MODE);
      } catch (QueryException e) {
        blocked = true;
      }
      Assert.isTrue(blocked, 'Sales user should have no onboarding access');
    }
    Test.stopTest();

    List<Onboarding__c> onboardings = onboardingsFor(opp.Id);
    Assert.areEqual(1, onboardings.size());
    Assert.areEqual('Active', onboardings[0].Status__c);
  }

  @IsTest
  static void bulkWinCreatesExactlyOneOnboardingPerOpportunity() {
    List<Opportunity> opportunities = TestDataFactory.createOpportunities(
      accountId(),
      200,
      TestDataFactory.openStage()
    );
    for (Opportunity opp : opportunities) {
      opp.StageName = TestDataFactory.wonStage();
    }

    Test.startTest();
    // System mode: acts as the admin, like a Data Loader job.
    update as system opportunities;
    Test.stopTest();

    Set<Id> opportunityIds = new Map<Id, Opportunity>(opportunities).keySet();
    // System mode: tests read results as the admin.
    List<Onboarding__c> onboardings = [
      SELECT Opportunity__c
      FROM Onboarding__c
      WHERE Opportunity__c IN :opportunityIds
      WITH SYSTEM_MODE
    ];
    Set<Id> linked = new Set<Id>();
    for (Onboarding__c onboarding : onboardings) {
      linked.add(onboarding.Opportunity__c);
    }
    Assert.areEqual(200, onboardings.size(), 'Exactly 200 onboardings');
    Assert.areEqual(200, linked.size(), 'No Opportunity has two');
    Assert.areEqual(opportunityIds, linked, 'Every Opportunity has one');
  }

  @IsTest
  static void killSwitchStopsOnboardingCreation() {
    Automation_Bypass__c setting = Automation_Bypass__c.getOrgDefaults();
    setting.Bypass_Triggers__c = true;
    // System mode: admin configuration, test setup.
    update as system setting;
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );

    Test.startTest();
    setStage(opp, TestDataFactory.wonStage());
    Test.stopTest();

    Assert.areEqual(0, onboardingsFor(opp.Id).size());
  }

  @IsTest
  static void nonDuplicateInsertErrorFailsOpportunitySave() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );
    OpportunityTriggerHandler.simulateInsertFailure = true;

    Test.startTest();
    opp.StageName = TestDataFactory.wonStage();
    // System mode: acts as the admin; triggers and validation rules still run.
    Database.SaveResult result = Database.update(
      opp,
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    Assert.isFalse(result.isSuccess(), 'The Opportunity save must fail');
    String message = result.getErrors()[0].getMessage();
    Assert.isTrue(
      message.startsWith(
        System.Label.Onboarding_Creation_Failed.substringBefore('{0}')
      ),
      'Uses the Onboarding_Creation_Failed label: ' + message
    );
    Assert.isTrue(
      message.contains(
        'Add a reason when an onboarding is On Hold or Cancelled.'
      ),
      'Includes the underlying error: ' + message
    );
    // System mode: tests read results as the admin.
    Assert.areEqual(
      TestDataFactory.openStage(),
      [SELECT StageName FROM Opportunity WHERE Id = :opp.Id WITH SYSTEM_MODE]
      .StageName,
      'The deal is not saved as won'
    );
    Assert.areEqual(0, onboardingsFor(opp.Id).size());
  }

  @IsTest
  static void duplicateInsertForExistingOnboardingIsIgnored() {
    Opportunity opp = wonDealWithOnboarding();

    Test.startTest();
    // Another transaction got there first: this insert hits a real DUPLICATE_VALUE on the key.
    OpportunityTriggerHandler.insertOnboardings(
      new List<Onboarding__c>{ new Onboarding__c(Opportunity__c = opp.Id) },
      new List<Opportunity>{ opp }
    );
    Test.stopTest();

    Assert.isFalse(opp.hasErrors(), 'Duplicate ignored: ' + opp.getErrors());
    Assert.areEqual(1, onboardingsFor(opp.Id).size(), 'Still one onboarding');
  }

  @IsTest
  static void nonDuplicateInsertErrorIsAddedToOpportunity() {
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );

    Test.startTest();
    // A real validation error (Start_At_Kickoff), not a duplicate.
    OpportunityTriggerHandler.insertOnboardings(
      new List<Onboarding__c>{
        new Onboarding__c(Opportunity__c = opp.Id, Stage__c = 'Gathering_Info')
      },
      new List<Opportunity>{ opp }
    );
    Test.stopTest();

    Assert.isTrue(opp.hasErrors(), 'Non-duplicate error must fail the save');
    String message = opp.getErrors()[0].getMessage();
    Assert.isTrue(
      message.startsWith(
        System.Label.Onboarding_Creation_Failed.substringBefore('{0}')
      ),
      message
    );
    Assert.isTrue(
      message.contains('New onboardings start at Kickoff Scheduled.'),
      message
    );
  }

  @IsTest
  static void editingLostDealLeavesReactivatedOnboardingUnchanged() {
    Opportunity opp = wonDealWithOnboarding();
    setStage(opp, TestDataFactory.lostStage());
    Id onboardingId = onboardingsFor(opp.Id)[0].Id;
    // A manager reactivates the onboarding by hand.
    // System mode: acts as the admin; triggers and validation rules still run.
    update as system new Onboarding__c(
      Id = onboardingId,
      Status__c = 'Active',
      Status_Reason__c = null
    );

    Test.startTest();
    opp.Description = 'Unrelated edit';
    // System mode: acts as the admin.
    update as system opp;
    Test.stopTest();

    Onboarding__c onboarding = onboardingsFor(opp.Id)[0];
    Assert.areEqual('Active', onboarding.Status__c, 'Not cancelled again');
    Assert.isNull(onboarding.Status_Reason__c);
  }

  @IsTest
  static void resavingLostDealDoesNoOnboardingWork() {
    Opportunity opp = wonDealWithOnboarding();
    setStage(opp, TestDataFactory.lostStage());

    Test.startTest();
    // System mode: acts as the admin.
    update as system opp;
    Integer dmlStatements = Limits.getDmlStatements();
    Integer queries = Limits.getQueries();
    Test.stopTest();

    Assert.areEqual(1, dmlStatements, 'Only the Opportunity update itself');
    Assert.areEqual(0, queries, 'No onboarding lookup');
  }

  @IsTest
  static void failedStatusUpdateFailsOnlyItsOwnOpportunity() {
    Opportunity good = wonDealWithOnboarding();
    Opportunity bad = wonDealWithOnboarding();
    Id goodOnboarding = onboardingsFor(good.Id)[0].Id;
    Id badOnboarding = onboardingsFor(bad.Id)[0].Id;

    Test.startTest();
    // The second change breaks a real rule (Require_Status_Reason: On Hold with no reason).
    OpportunityTriggerHandler.updateOnboardings(
      new List<Onboarding__c>{
        new Onboarding__c(
          Id = goodOnboarding,
          Status__c = 'On_Hold',
          Status_Reason__c = 'Deal reopened by Sales'
        ),
        new Onboarding__c(Id = badOnboarding, Status__c = 'On_Hold')
      },
      new List<Opportunity>{ good, bad }
    );
    Test.stopTest();

    Assert.isFalse(
      good.hasErrors(),
      'Good deal unaffected: ' + good.getErrors()
    );
    Assert.areEqual('On_Hold', onboardingsFor(good.Id)[0].Status__c);
    Assert.isTrue(bad.hasErrors(), 'The failing change fails its own deal');
    String message = bad.getErrors()[0].getMessage();
    Assert.isTrue(
      message.startsWith(
        System.Label.Onboarding_Status_Update_Failed.substringBefore('{0}')
      ),
      'Uses the Onboarding_Status_Update_Failed label: ' + message
    );
    Assert.isTrue(
      message.contains(
        'Add a reason when an onboarding is On Hold or Cancelled.'
      ),
      'Includes the underlying error: ' + message
    );
    Assert.areEqual(
      'Active',
      onboardingsFor(bad.Id)[0].Status__c,
      'Not changed'
    );
  }
}
