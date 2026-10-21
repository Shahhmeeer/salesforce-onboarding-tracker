/**
 * Tests for TriggerHandler: dispatch to the right context method, the code-level bypass and the
 * Automation_Bypass__c kill switch. Uses a small handler that records which methods ran, so no
 * object trigger is needed.
 */
@IsTest
private class TriggerHandlerTest {
  private class RecordingHandler extends TriggerHandler {
    public List<String> calls = new List<String>();

    protected override void beforeInsert() {
      calls.add('beforeInsert');
    }
    protected override void beforeUpdate() {
      calls.add('beforeUpdate');
    }
    protected override void beforeDelete() {
      calls.add('beforeDelete');
    }
    protected override void afterInsert() {
      calls.add('afterInsert');
    }
    protected override void afterUpdate() {
      calls.add('afterUpdate');
    }
    protected override void afterDelete() {
      calls.add('afterDelete');
    }
    protected override void afterUndelete() {
      calls.add('afterUndelete');
    }
  }

  private static final String HANDLER_NAME = 'RecordingHandler';

  private static List<String> runAs(System.TriggerOperation operation) {
    RecordingHandler handler = new RecordingHandler();
    handler.operationType = operation;
    handler.run();
    return handler.calls;
  }

  private static void setKillSwitch(Boolean bypassTriggers) {
    // Test setup: the custom setting is admin configuration, not user data.
    insert as system new Automation_Bypass__c(
      SetupOwnerId = UserInfo.getUserId(),
      Bypass_Triggers__c = bypassTriggers
    );
  }

  @IsTest
  static void eachOperationCallsOnlyItsMethod() {
    Map<System.TriggerOperation, String> expected = new Map<System.TriggerOperation, String>{
      System.TriggerOperation.BEFORE_INSERT => 'beforeInsert',
      System.TriggerOperation.BEFORE_UPDATE => 'beforeUpdate',
      System.TriggerOperation.BEFORE_DELETE => 'beforeDelete',
      System.TriggerOperation.AFTER_INSERT => 'afterInsert',
      System.TriggerOperation.AFTER_UPDATE => 'afterUpdate',
      System.TriggerOperation.AFTER_DELETE => 'afterDelete',
      System.TriggerOperation.AFTER_UNDELETE => 'afterUndelete'
    };

    Test.startTest();
    for (System.TriggerOperation operation : System.TriggerOperation.values()) {
      Assert.areEqual(
        new List<String>{ expected.get(operation) },
        runAs(operation),
        operation +
          ' should call ' +
          expected.get(operation) +
          ' and nothing else'
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void bypassStopsHandlerAndClearBypassRestoresIt() {
    Test.startTest();
    TriggerHandler.bypass(HANDLER_NAME);
    Assert.isTrue(
      TriggerHandler.isBypassed(HANDLER_NAME),
      'Handler should report as bypassed'
    );
    Assert.isTrue(
      runAs(System.TriggerOperation.AFTER_INSERT).isEmpty(),
      'Bypassed handler should not run'
    );

    TriggerHandler.clearBypass(HANDLER_NAME);
    Assert.isFalse(
      TriggerHandler.isBypassed(HANDLER_NAME),
      'Handler should no longer report as bypassed'
    );
    Assert.areEqual(
      new List<String>{ 'afterInsert' },
      runAs(System.TriggerOperation.AFTER_INSERT),
      'Handler should run again once the bypass is cleared'
    );
    Test.stopTest();
  }

  @IsTest
  static void bypassOfOtherHandlerDoesNotStopThisOne() {
    Test.startTest();
    TriggerHandler.bypass('SomeOtherHandler');
    Assert.areEqual(
      new List<String>{ 'afterInsert' },
      runAs(System.TriggerOperation.AFTER_INSERT),
      'Bypassing a different handler should not affect this one'
    );
    Test.stopTest();
  }

  @IsTest
  static void clearAllBypassesClearsEveryBypass() {
    Test.startTest();
    TriggerHandler.bypass(HANDLER_NAME);
    TriggerHandler.bypass('SomeOtherHandler');

    TriggerHandler.clearAllBypasses();

    Assert.isFalse(
      TriggerHandler.isBypassed(HANDLER_NAME),
      'RecordingHandler bypass should be cleared'
    );
    Assert.isFalse(
      TriggerHandler.isBypassed('SomeOtherHandler'),
      'SomeOtherHandler bypass should be cleared'
    );
    Assert.areEqual(
      new List<String>{ 'afterInsert' },
      runAs(System.TriggerOperation.AFTER_INSERT),
      'Handler should run after all bypasses are cleared'
    );
    Test.stopTest();
  }

  @IsTest
  static void killSwitchOnStopsHandler() {
    setKillSwitch(true);

    Test.startTest();
    for (System.TriggerOperation operation : System.TriggerOperation.values()) {
      Assert.isTrue(
        runAs(operation).isEmpty(),
        'Kill switch should stop ' + operation
      );
    }
    Test.stopTest();
  }

  @IsTest
  static void killSwitchOffLetsHandlerRun() {
    setKillSwitch(false);

    Test.startTest();
    Assert.areEqual(
      new List<String>{ 'afterUpdate' },
      runAs(System.TriggerOperation.AFTER_UPDATE),
      'Handler should run when the kill switch is off'
    );
    Test.stopTest();
  }
}
