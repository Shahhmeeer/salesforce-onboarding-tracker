/**
 * Tests for the CSM_Capacity_Before_Save_Set_User_Key flow: it copies User into the unique
 * User_Key__c so a person can have only one capacity record, and the Bypass_Flows__c kill switch
 * stops it. Uses the running admin as the CSM, so no extra user licence is needed.
 */
@IsTest
private class CsmCapacityFlowTest {
  @TestSetup
  static void setup() {
    TestDataFactory.createBypassSetting();
  }

  private static CSM_Capacity__c capacityForAdmin() {
    return new CSM_Capacity__c(
      User__c = UserInfo.getUserId(),
      Max_Active_Onboardings__c = 5
    );
  }

  private static String userKey(Id capacityId) {
    // System mode: tests read results as the admin.
    return [
      SELECT User_Key__c
      FROM CSM_Capacity__c
      WHERE Id = :capacityId
      WITH SYSTEM_MODE
    ]
    .User_Key__c;
  }

  @IsTest
  static void creatingCapacitySetsUserKeyAndBlocksSecondForSameUser() {
    CSM_Capacity__c first = capacityForAdmin();

    Test.startTest();
    // System mode: acts as the admin; the flow still runs.
    insert as system first;
    // System mode: acts as the admin; the flow and unique field still apply.
    Database.SaveResult second = Database.insert(
      capacityForAdmin(),
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    Assert.areEqual(String.valueOf(UserInfo.getUserId()), userKey(first.Id));
    Assert.isFalse(second.isSuccess(), 'Second record for the same user');
    Assert.areEqual(
      StatusCode.DUPLICATE_VALUE,
      second.getErrors()[0].getStatusCode()
    );
  }

  @IsTest
  static void bypassFlowsLeavesUserKeyBlank() {
    Automation_Bypass__c setting = Automation_Bypass__c.getOrgDefaults();
    setting.Bypass_Flows__c = true;
    // System mode: admin configuration, test setup.
    update as system setting;
    CSM_Capacity__c first = capacityForAdmin();
    CSM_Capacity__c second = capacityForAdmin();

    Test.startTest();
    // System mode: acts as the admin.
    insert as system first;
    // System mode: acts as the admin.
    insert as system second;
    Test.stopTest();

    Assert.isNull(userKey(first.Id), 'Flow did not run');
    Assert.isNull(userKey(second.Id), 'So the duplicate is not caught either');
  }
}
