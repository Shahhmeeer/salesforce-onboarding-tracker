/**
 * Tests for the permission sets and the sharing model (spec 10.1, 10.2). As a CSM: no delete,
 * Status is manager-only, colleagues' onboardings are read only, CSM Capacity is out of reach, and
 * the owner cannot be changed (Prevent_Owner_Change). As a manager: reassigning from the backlog
 * works. Moving stages and stage-row protection are covered in OnboardingStageTrackerTest.
 */
@IsTest
private class OnboardingAccessTest {
  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
    TestDataFactory.createAccounts(1);
  }

  private static Id accountId() {
    // System mode: tests read setup data as the admin.
    return [SELECT Id FROM Account WITH SYSTEM_MODE LIMIT 1].Id;
  }

  private static Id ownerOf(Id onboardingId) {
    // System mode: tests read results as the admin.
    return [
      SELECT OwnerId
      FROM Onboarding__c
      WHERE Id = :onboardingId
      WITH SYSTEM_MODE
    ]
    .OwnerId;
  }

  // Each CSM gets room for five, then one won deal: assignment gives it to the first by name.
  private static Onboarding__c createOnboardingFor(List<User> csms) {
    for (User csm : csms) {
      TestDataFactory.createCapacity(csm, 5);
    }
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
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

    // Status is read only for CSMs (field-level security), so the user-mode save is refused.
    Assert.isInstanceOfType(
      error,
      DmlException.class,
      'Status is for managers only: ' + error
    );
    DmlException dmlError = (DmlException) error;
    Assert.isTrue(
      dmlError.getMessage().contains('fields being inaccessible'),
      'Refused for field access: ' + dmlError.getMessage()
    );
    Assert.areEqual(
      new List<String>{ 'Status__c', 'Status_Reason__c' },
      dmlError.getDmlFieldNames(0),
      'Both manager-only fields are refused'
    );
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
  static void csmCannotCreateAnOnboarding() {
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.openStage()
    );

    Test.startTest();
    Exception error;
    System.runAs(csm) {
      try {
        insert as user new Onboarding__c(Opportunity__c = opp.Id);
      } catch (Exception e) {
        error = e;
      }
    }
    Test.stopTest();

    // Managers create onboardings by hand; CSMs have no Create on Onboarding (A12).
    Assert.isInstanceOfType(
      error,
      TypeException.class,
      'CSMs cannot create onboardings: ' + error
    );
    Assert.areEqual(
      'DML operation INSERT not allowed on Onboarding__c',
      error.getMessage()
    );
    // System mode: tests read results as the admin.
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Onboarding__c
        WHERE Opportunity__c = :opp.Id
        WITH SYSTEM_MODE
      ]
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
        Database.countQuery(
          'SELECT COUNT() FROM CSM_Capacity__c',
          AccessLevel.USER_MODE
        );
      } catch (Exception e) {
        error = e;
      }
    }
    Test.stopTest();

    Assert.isNotNull(error, 'CSM Capacity is for managers only');
  }

  @IsTest
  static void csmCannotChangeTheOwner() {
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'Avery', 'Blake' }
    );
    Onboarding__c onboarding = createOnboardingFor(csms);
    Assert.areEqual(csms[0].Id, onboarding.OwnerId, 'Assigned to Avery');

    Test.startTest();
    Exception error;
    System.runAs(csms[0]) {
      try {
        update as user new Onboarding__c(
          Id = onboarding.Id,
          OwnerId = csms[1].Id
        );
      } catch (DmlException e) {
        error = e;
      }
    }
    Test.stopTest();

    Assert.isNotNull(error, 'A CSM handing off their onboarding must fail');
    Assert.isTrue(
      error.getMessage().contains('Only CS managers can reassign onboardings.'),
      error.getMessage()
    );
    Assert.areEqual(csms[0].Id, ownerOf(onboarding.Id), 'Still Avery');
  }

  @IsTest
  static void managerCanReassignFromTheBacklog() {
    User manager = TestDataFactory.createManagerUser();
    User csm = TestDataFactory.createCsmUsers(
      1,
      new List<String>{ 'Avery' }
    )[0];
    // No CSM has capacity yet, so the won deal goes to the backlog queue.
    Opportunity opp = TestDataFactory.createOpportunity(
      accountId(),
      TestDataFactory.wonStage()
    );
    // System mode: tests read results as the admin.
    Onboarding__c onboarding = [
      SELECT Id, OwnerId
      FROM Onboarding__c
      WHERE Opportunity__c = :opp.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(
      CsmAssignmentService.backlogQueueId(),
      onboarding.OwnerId,
      'In the backlog'
    );

    Test.startTest();
    System.runAs(manager) {
      update as user new Onboarding__c(Id = onboarding.Id, OwnerId = csm.Id);
    }
    Test.stopTest();

    Assert.areEqual(csm.Id, ownerOf(onboarding.Id), 'Reassigned to Avery');
  }

  @IsTest
  static void bulkCloseBySalesUserStillAssignsNormally() {
    List<User> csms = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'Avery', 'Blake' }
    );
    for (User csm : csms) {
      TestDataFactory.createCapacity(csm, 100);
    }
    User salesUser = TestDataFactory.createSalesUser();
    String won = TestDataFactory.wonStage();

    Test.startTest();
    System.runAs(salesUser) {
      // Accounts are private, so the sales user closes deals on an account they own.
      Account customer = new Account(Name = 'Sales Rep Customer');
      insert as user customer;
      List<Opportunity> deals = new List<Opportunity>();
      for (Integer i = 0; i < 200; i++) {
        deals.add(TestDataFactory.buildOpportunity(customer.Id, won));
      }
      // The sales user has no Onboarding_Reassign; assignment on insert must still set owners.
      insert as user deals;
    }
    Test.stopTest();

    Map<Id, Integer> countByOwner = new Map<Id, Integer>();
    // System mode: tests read results as the admin.
    for (AggregateResult row : [
      SELECT OwnerId, COUNT(Id) total
      FROM Onboarding__c
      WITH SYSTEM_MODE
      GROUP BY OwnerId
    ]) {
      countByOwner.put((Id) row.get('OwnerId'), (Integer) row.get('total'));
    }
    Assert.areEqual(100, countByOwner.get(csms[0].Id), 'Avery filled');
    Assert.areEqual(100, countByOwner.get(csms[1].Id), 'Blake filled');
    Assert.isFalse(
      countByOwner.containsKey(CsmAssignmentService.backlogQueueId()),
      'Nothing in the backlog'
    );
  }
}
