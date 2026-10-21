/**
 * Tests for CsmAssignmentService and the backlog alert: least-loaded assignment, both tie-breaks,
 * the spec 7.3 worked example, capacity limits, what counts as load, the backlog, 200 records at
 * once (direct insert and through won deals), a sales user closing a deal, and query counts.
 *
 * Expected numbers are worked out by hand from spec 7, never copied from the code's output.
 * Assignment tests run as the admin. Sales-user tests create no CSM users, so no test needs more
 * than one Salesforce licence on top of the CSMs (see TestDataFactory.createCsmUsers).
 */
@IsTest
private class CsmAssignmentServiceTest {
  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    TestDataFactory.createAccounts(1);
  }

  private static Id accountId() {
    // System mode: tests read results as the admin.
    return [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id;
  }

  private static Id backlogQueueId() {
    String queueName = Onboarding_Setting__mdt.getInstance('Default')
      .Backlog_Queue_Name__c;
    // System mode: tests read configuration as the admin.
    return [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = :queueName
      WITH SYSTEM_MODE
    ]
    .Id;
  }

  private static Id managersGroupId() {
    String groupName = Onboarding_Setting__mdt.getInstance('Default')
      .Manager_Group_Name__c;
    // System mode: tests read configuration as the admin.
    return [
      SELECT Id
      FROM Group
      WHERE Type = 'Regular' AND DeveloperName = :groupName
      WITH SYSTEM_MODE
    ]
    .Id;
  }

  // Owner of each onboarding, in the order of the list passed in.
  private static List<Id> ownersInOrder(List<Onboarding__c> onboardings) {
    // System mode: tests read results as the admin.
    Map<Id, Onboarding__c> saved = new Map<Id, Onboarding__c>(
      [
        SELECT Id, OwnerId
        FROM Onboarding__c
        WHERE Id IN :onboardings
        WITH SYSTEM_MODE
      ]
    );
    List<Id> owners = new List<Id>();
    for (Onboarding__c onboarding : onboardings) {
      owners.add(saved.get(onboarding.Id).OwnerId);
    }
    return owners;
  }

  // How many of the given onboardings each owner received.
  private static Map<Id, Integer> countsByOwner(
    List<Onboarding__c> onboardings
  ) {
    Map<Id, Integer> counts = new Map<Id, Integer>();
    for (Id ownerId : ownersInOrder(onboardings)) {
      counts.put(ownerId, countFor(counts, ownerId) + 1);
    }
    return counts;
  }

  private static Integer countFor(Map<Id, Integer> counts, Id ownerId) {
    return counts.containsKey(ownerId) ? counts.get(ownerId) : 0;
  }

  // Everything the user owns that counts toward capacity, old and new.
  private static Integer countingLoad(Id userId) {
    // System mode: tests read results as the admin.
    return [
      SELECT COUNT()
      FROM Onboarding__c
      WHERE OwnerId = :userId AND Counts_Toward_Capacity__c = TRUE
      WITH SYSTEM_MODE
    ];
  }

  private static List<Onboarding__c> insertNew(Integer count) {
    List<Onboarding__c> onboardings = TestDataFactory.buildOnboardings(
      accountId(),
      count
    );
    Test.startTest();
    // System mode: acts as the admin, like a Data Loader job.
    insert as system onboardings;
    Test.stopTest();
    return onboardings;
  }

  private static void existing(
    User owner,
    Integer count,
    String stage,
    String status
  ) {
    TestDataFactory.createExistingOnboardings(
      accountId(),
      owner.Id,
      count,
      stage,
      status
    );
  }

  @IsTest
  static void assignsToCsmWithFewestCountingOnboardings() {
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'A', 'B' }
    );
    TestDataFactory.createCapacity(csms[0], 10);
    TestDataFactory.createCapacity(csms[1], 10);
    existing(csms[0], 3, 'Kickoff_Scheduled', 'Active');
    existing(csms[1], 1, 'Kickoff_Scheduled', 'Active');

    // Created by hand with an owner already set: still auto-assigned (A12).
    List<Onboarding__c> onboardings = TestDataFactory.buildOnboardings(
      accountId(),
      1
    );
    onboardings[0].OwnerId = UserInfo.getUserId();
    Test.startTest();
    // System mode: acts as the admin.
    insert as system onboardings;
    Test.stopTest();

    // A has 3, B has 1: B is lowest.
    Assert.areEqual(csms[1].Id, ownersInOrder(onboardings)[0]);
  }

  @IsTest
  static void tieGoesToMostRemainingCapacity() {
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'A', 'B' }
    );
    TestDataFactory.createCapacity(csms[0], 5);
    TestDataFactory.createCapacity(csms[1], 8);

    List<Onboarding__c> onboardings = insertNew(1);

    // Both at 0. B has 8 left, A has 5, so B wins although A is first alphabetically.
    Assert.areEqual(csms[1].Id, ownersInOrder(onboardings)[0]);
  }

  @IsTest
  static void tieWithSameRemainingCapacityGoesAlphabetically() {
    // Zed is created first, so creation order cannot be the reason Amy wins.
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'Zed', 'Amy' }
    );
    TestDataFactory.createCapacity(csms[0], 5);
    TestDataFactory.createCapacity(csms[1], 5);

    List<Onboarding__c> onboardings = insertNew(2);

    // Both at 0 with 5 left: Amy first. Then Amy 1, Zed 0: Zed is lowest.
    List<Id> owners = ownersInOrder(onboardings);
    Assert.areEqual(csms[1].Id, owners[0], 'Amy before Zed');
    Assert.areEqual(csms[0].Id, owners[1], 'Then the lowest count');
  }

  @IsTest
  static void workedExampleFromSpec() {
    // Spec 7.3: capacities Shahmeer 5, A 4, B 4, C 10. Everyone starts at 0. 24 in one batch.
    List<User> csms = TestDataFactory.createCsmUsers(
      4,
      new List<String>{ 'Shahmeer', 'A', 'B', 'C' }
    );
    User s = csms[0];
    User a = csms[1];
    User b = csms[2];
    User c = csms[3];
    TestDataFactory.createCapacity(s, 5);
    TestDataFactory.createCapacity(a, 4);
    TestDataFactory.createCapacity(b, 4);
    TestDataFactory.createCapacity(c, 10);
    Id backlog = backlogQueueId();
    Integer alertsBefore = OnboardingTriggerHandler.backlogAlertsSent;

    List<Onboarding__c> onboardings = insertNew(24);

    // Expected owners copied from the "Goes to" column of the spec 7.3 table.
    List<Id> owners = ownersInOrder(onboardings);
    Assert.areEqual(c.Id, owners[0], 'Row 1: C, most headroom');
    Assert.areEqual(s.Id, owners[1], 'Row 2: S, headroom 5 beats 4');
    Assert.areEqual(a.Id, owners[2], 'Row 3: A, same headroom, alphabetical');
    Assert.areEqual(b.Id, owners[3], 'Row 4: B, only one at 0');
    Assert.areEqual(c.Id, owners[16], 'Row 17: C, headroom 6 beats 1');
    Assert.areEqual(s.Id, owners[17], 'Row 18: S, now lowest, reaches 5/5');
    for (Integer row = 19; row <= 23; row++) {
      Assert.areEqual(
        c.Id,
        owners[row - 1],
        'Row ' + row + ': only C has room'
      );
    }
    Assert.areEqual(backlog, owners[23], 'Row 24: backlog');

    // Final counts from the spec: S 5, A 4, B 4, C 10, and exactly 1 in the backlog.
    Map<Id, Integer> counts = countsByOwner(onboardings);
    Assert.areEqual(5, countFor(counts, s.Id), 'S');
    Assert.areEqual(4, countFor(counts, a.Id), 'A');
    Assert.areEqual(4, countFor(counts, b.Id), 'B');
    Assert.areEqual(10, countFor(counts, c.Id), 'C');
    Assert.areEqual(1, countFor(counts, backlog), 'Backlog');
    Assert.areEqual(
      1,
      OnboardingTriggerHandler.backlogAlertsSent - alertsBefore,
      'One alert'
    );
  }

  @IsTest
  static void neverAssignsAboveMaximum() {
    List<User> csms = TestDataFactory.createCsmUsers(
      3,
      new List<String>{ 'Over', 'Zero', 'One' }
    );
    User over = csms[0];
    User zero = csms[1];
    User one = csms[2];
    // Over: capacity lowered to 2 while holding 3 (A18). Zero: paused with 0. One: room for one.
    TestDataFactory.createCapacity(over, 2);
    TestDataFactory.createCapacity(zero, 0);
    TestDataFactory.createCapacity(one, 1);
    existing(over, 3, 'Kickoff_Scheduled', 'Active');

    List<Onboarding__c> onboardings = insertNew(3);

    Map<Id, Integer> counts = countsByOwner(onboardings);
    Assert.areEqual(0, countFor(counts, over.Id), 'Over limit gets none');
    Assert.areEqual(0, countFor(counts, zero.Id), 'Capacity 0 gets none');
    Assert.areEqual(1, countFor(counts, one.Id), 'One fills its only slot');
    Assert.areEqual(2, countFor(counts, backlogQueueId()), 'Rest to backlog');
    Assert.areEqual(3, countingLoad(over.Id), 'Nothing reassigned away (A18)');
  }

  @IsTest
  static void inactiveCapacityAndInactiveUserAreSkipped() {
    List<User> csms = TestDataFactory.createCsmUsers(
      3,
      new List<String>{ 'Paused', 'Gone', 'Ready' }
    );
    User paused = csms[0];
    User gone = csms[1];
    User ready = csms[2];
    CSM_Capacity__c pausedCapacity = TestDataFactory.createCapacity(paused, 10);
    TestDataFactory.createCapacity(gone, 10);
    TestDataFactory.createCapacity(ready, 1);
    pausedCapacity.Is_Active__c = false;
    // System mode: test setup.
    update as system pausedCapacity;
    // Deactivating a user is setup DML, kept apart from the test's other DML.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // System mode: test setup.
      update as system new User(Id = gone.Id, IsActive = false);
    }

    List<Onboarding__c> onboardings = insertNew(2);

    // Paused and Gone have the most room but are not eligible; Ready takes 1, the other overflows.
    Map<Id, Integer> counts = countsByOwner(onboardings);
    Assert.areEqual(0, countFor(counts, paused.Id), 'Inactive capacity');
    Assert.areEqual(0, countFor(counts, gone.Id), 'Inactive user');
    Assert.areEqual(1, countFor(counts, ready.Id));
    Assert.areEqual(1, countFor(counts, backlogQueueId()));
  }

  @IsTest
  static void onHoldCountsButCancelledAndPostLaunchReviewDoNot() {
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'A', 'B' }
    );
    User a = csms[0];
    User b = csms[1];
    TestDataFactory.createCapacity(a, 2);
    TestDataFactory.createCapacity(b, 2);
    existing(a, 1, 'Implementation', 'On_Hold');
    existing(b, 2, 'Gathering_Info', 'Cancelled');
    existing(b, 1, 'Post_Launch_Review', 'Active');

    List<Onboarding__c> onboardings = insertNew(4);

    // Loads: A 1 (On Hold counts), B 0 (Cancelled and Post-Launch Review do not).
    // 1 -> B (0 < 1). 2 -> A (1 = 1, 1 left each, A first). 3 -> B. 4 -> backlog.
    // Had Cancelled/PLR counted, B would start full: A 1, B 0, backlog 3.
    // Had On Hold not counted: A 2, B 2, backlog 0.
    Map<Id, Integer> counts = countsByOwner(onboardings);
    Assert.areEqual(1, countFor(counts, a.Id), 'A');
    Assert.areEqual(2, countFor(counts, b.Id), 'B');
    Assert.areEqual(1, countFor(counts, backlogQueueId()), 'Backlog');
  }

  @IsTest
  static void noCapacityRecordsSendsEverythingToBacklogWithOneAlert() {
    Integer alertsBefore = OnboardingTriggerHandler.backlogAlertsSent;

    List<Onboarding__c> onboardings = insertNew(3);

    Assert.areEqual(3, countFor(countsByOwner(onboardings), backlogQueueId()));
    Assert.areEqual(
      1,
      OnboardingTriggerHandler.backlogAlertsSent - alertsBefore,
      'One alert for the batch, not one per record'
    );
    OnboardingTriggerHandler.BacklogAlert alert = OnboardingTriggerHandler.lastBacklogAlert;
    Assert.areEqual(3, alert.backlogCount, 'Body count');
    Assert.isTrue(
      new Map<Id, Onboarding__c>(onboardings).containsKey(alert.targetId),
      'Target is one of the backlog records'
    );
    Assert.areEqual(
      new Set<String>{ managersGroupId() },
      alert.recipientIds,
      'Sent to the CS managers group'
    );
  }

  @IsTest
  static void noBacklogMeansNoAlert() {
    List<User> csms = TestDataFactory.createCsmUsers(1, null);
    TestDataFactory.createCapacity(csms[0], 5);
    Integer alertsBefore = OnboardingTriggerHandler.backlogAlertsSent;

    insertNew(5);

    Assert.areEqual(
      0,
      OnboardingTriggerHandler.backlogAlertsSent - alertsBefore
    );
  }

  @IsTest
  static void missingBacklogQueueFailsWithClearError() {
    CsmAssignmentService.backlogQueueName = 'Missing_Queue_For_Test';
    List<Onboarding__c> onboardings = TestDataFactory.buildOnboardings(
      accountId(),
      1
    );

    Test.startTest();
    // System mode: acts as the admin.
    Database.SaveResult result = Database.insert(
      onboardings[0],
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    Assert.isFalse(result.isSuccess(), 'Nobody has room and there is no queue');
    Assert.areEqual(
      String.format(
        Label.Onboarding_Backlog_Queue_Missing,
        new List<Object>{ 'Missing_Queue_For_Test' }
      ),
      result.getErrors()[0].getMessage()
    );
  }

  @IsTest
  static void bulk200FillsEveryCsmExactlyAndOverflowsTheRest() {
    List<User> csms = TestDataFactory.createCsmUsers(
      4,
      new List<String>{ 'Alpha', 'Bravo', 'Charlie', 'Delta' }
    );
    User alpha = csms[0];
    User bravo = csms[1];
    User charlie = csms[2];
    User delta = csms[3];
    TestDataFactory.createCapacity(alpha, 30);
    TestDataFactory.createCapacity(bravo, 40);
    TestDataFactory.createCapacity(charlie, 40);
    TestDataFactory.createCapacity(delta, 60);
    // Counting load: Alpha 5, Bravo 6 + 4 On Hold = 10, Charlie 0, Delta 20.
    existing(alpha, 5, 'Implementation', 'Active');
    existing(alpha, 3, 'Kickoff_Scheduled', 'Cancelled');
    existing(bravo, 6, 'Gathering_Info', 'Active');
    existing(bravo, 4, 'QA_Review', 'On_Hold');
    existing(charlie, 2, 'Post_Launch_Review', 'Active');
    existing(delta, 20, 'Go_Live', 'Active');
    Integer alertsBefore = OnboardingTriggerHandler.backlogAlertsSent;

    List<Onboarding__c> onboardings = insertNew(200);

    // Room: Alpha 30-5 = 25, Bravo 40-10 = 30, Charlie 40-0 = 40, Delta 60-20 = 40. Total 135.
    // 200 > 135, and a record only overflows when nobody has room, so all four fill up:
    // new Alpha 25, Bravo 30, Charlie 40, Delta 40; backlog 200 - 135 = 65.
    Map<Id, Integer> counts = countsByOwner(onboardings);
    Assert.areEqual(25, countFor(counts, alpha.Id), 'Alpha');
    Assert.areEqual(30, countFor(counts, bravo.Id), 'Bravo');
    Assert.areEqual(40, countFor(counts, charlie.Id), 'Charlie');
    Assert.areEqual(40, countFor(counts, delta.Id), 'Delta');
    Assert.areEqual(65, countFor(counts, backlogQueueId()), 'Backlog');

    // Nobody above their maximum, counting old and new.
    Assert.areEqual(30, countingLoad(alpha.Id), 'Alpha at max');
    Assert.areEqual(40, countingLoad(bravo.Id), 'Bravo at max');
    Assert.areEqual(40, countingLoad(charlie.Id), 'Charlie at max');
    Assert.areEqual(60, countingLoad(delta.Id), 'Delta at max');

    Assert.areEqual(
      1,
      OnboardingTriggerHandler.backlogAlertsSent - alertsBefore,
      'One alert for 65 backlog records'
    );
    Assert.areEqual(65, OnboardingTriggerHandler.lastBacklogAlert.backlogCount);
  }

  @IsTest
  static void endToEnd200WonDealsAreDistributedWithOverflowInBacklog() {
    List<User> csms = TestDataFactory.createCsmUsers(
      4,
      new List<String>{ 'Alpha', 'Bravo', 'Charlie', 'Delta' }
    );
    TestDataFactory.createCapacity(csms[0], 30);
    TestDataFactory.createCapacity(csms[1], 40);
    TestDataFactory.createCapacity(csms[2], 40);
    TestDataFactory.createCapacity(csms[3], 60);
    List<Opportunity> opportunities = TestDataFactory.createOpportunities(
      accountId(),
      200,
      TestDataFactory.openStage()
    );
    for (Opportunity opp : opportunities) {
      opp.StageName = TestDataFactory.wonStage();
    }
    Integer alertsBefore = OnboardingTriggerHandler.backlogAlertsSent;

    Test.startTest();
    // System mode: acts as the admin, like a Data Loader job closing 200 deals.
    update as system opportunities;
    Test.stopTest();

    // System mode: tests read results as the admin.
    List<Onboarding__c> onboardings = [
      SELECT Id
      FROM Onboarding__c
      WHERE Opportunity__c IN :opportunities
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(200, onboardings.size(), 'One per won deal');
    // Nobody has load, so room is the capacity: 30 + 40 + 40 + 60 = 170. All fill; 200 - 170 = 30.
    Map<Id, Integer> counts = countsByOwner(onboardings);
    Assert.areEqual(30, countFor(counts, csms[0].Id), 'Alpha');
    Assert.areEqual(40, countFor(counts, csms[1].Id), 'Bravo');
    Assert.areEqual(40, countFor(counts, csms[2].Id), 'Charlie');
    Assert.areEqual(60, countFor(counts, csms[3].Id), 'Delta');
    Assert.areEqual(30, countFor(counts, backlogQueueId()), 'Backlog');
    Assert.areEqual(
      1,
      OnboardingTriggerHandler.backlogAlertsSent - alertsBefore
    );
    Assert.areEqual(30, OnboardingTriggerHandler.lastBacklogAlert.backlogCount);
  }

  private static Opportunity winDealAsSalesUser(User salesUser) {
    Opportunity opp;
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
    }
    return opp;
  }

  private static Id onboardingOwner(Id opportunityId) {
    // System mode: tests read results as the admin.
    return [
      SELECT OwnerId
      FROM Onboarding__c
      WHERE Opportunity__c = :opportunityId
      WITH SYSTEM_MODE
    ]
    .OwnerId;
  }

  @IsTest
  static void salesUserClosingDealWithNoCsmsSendsItToBacklog() {
    User salesUser = TestDataFactory.createSalesUser();
    Integer alertsBefore = OnboardingTriggerHandler.backlogAlertsSent;

    Test.startTest();
    Opportunity opp = winDealAsSalesUser(salesUser);
    Test.stopTest();

    Assert.areEqual(backlogQueueId(), onboardingOwner(opp.Id));
    Assert.areEqual(
      1,
      OnboardingTriggerHandler.backlogAlertsSent - alertsBefore
    );
  }

  @IsTest
  static void salesUserClosingDealStillAssignsToCsm() {
    // The admin holds the only capacity record, so this needs no CSM user and no extra licence.
    // The sales user cannot see CSM Capacity or onboardings; assignment must still find the CSM.
    User admin = new User(Id = UserInfo.getUserId());
    TestDataFactory.createCapacity(admin, 5);
    User salesUser = TestDataFactory.createSalesUser();

    Test.startTest();
    Opportunity opp = winDealAsSalesUser(salesUser);
    Test.stopTest();

    Assert.areEqual(admin.Id, onboardingOwner(opp.Id));
  }

  @IsTest
  static void insertUsesSameQueryCountForOneOrTwoHundredRecords() {
    List<User> csms = TestDataFactory.createCsmUsers(1, null);
    TestDataFactory.createCapacity(csms[0], 500);
    List<Onboarding__c> one = TestDataFactory.buildOnboardings(accountId(), 1);
    List<Onboarding__c> many = TestDataFactory.buildOnboardings(
      accountId(),
      200
    );

    Test.startTest();
    Integer before = Limits.getQueries();
    // System mode: acts as the admin.
    insert as system one;
    Integer forOne = Limits.getQueries() - before;
    before = Limits.getQueries();
    // System mode: acts as the admin.
    insert as system many;
    Integer forMany = Limits.getQueries() - before;
    Test.stopTest();

    // Per insert: 1 Opportunity lookup for defaults and names, then assignment's lock and count.
    // The Kickoff stage row changes the Kickoff Reached roll-up, which saves the onboardings again:
    // that update rebuilds the Name with 1 Account lookup.
    Assert.areEqual(4, forOne, 'Queries to insert 1');
    Assert.areEqual(4, forMany, 'Queries to insert 200');
  }

  @IsTest
  static void assignmentRunsLockAndCountQueriesOnceForAnyBatchSize() {
    List<User> csms = TestDataFactory.createCsmUsers(1, null);
    TestDataFactory.createCapacity(csms[0], 150);
    List<Onboarding__c> single = new List<Onboarding__c>{ new Onboarding__c() };
    List<Onboarding__c> batch = new List<Onboarding__c>();
    for (Integer i = 0; i < 200; i++) {
      batch.add(new Onboarding__c());
    }

    Test.startTest();
    Integer before = Limits.getQueries();
    CsmAssignmentService.assign(single);
    Integer forOne = Limits.getQueries() - before;

    before = Limits.getQueries();
    CsmAssignmentService.assign(batch);
    Integer forBatch = Limits.getQueries() - before;

    before = Limits.getQueries();
    CsmAssignmentService.assign(batch);
    Integer forSecondBatch = Limits.getQueries() - before;
    Test.stopTest();

    // Nothing was saved, so each call starts from a load of 0 with 150 slots.
    Assert.areEqual(2, forOne, '1 record, no overflow: lock + count');
    Assert.areEqual(
      3,
      forBatch,
      '200 records, 50 overflow: lock + count + queue'
    );
    Assert.areEqual(
      2,
      forSecondBatch,
      'Queue Id is cached for the transaction'
    );
    Assert.areEqual(csms[0].Id, batch[149].OwnerId, '150th fits');
    Assert.areEqual(backlogQueueId(), batch[150].OwnerId, '151st overflows');
  }
}
