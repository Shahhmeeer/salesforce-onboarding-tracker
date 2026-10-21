/**
 * Tests for TestDataFactory.createCsmUsers: it prefers free Salesforce Platform licences, falls back
 * to Standard User, assigns Onboarding_CSM, and fails clearly before inserting anything when the org
 * has too few licences. Written to pass in any org, whatever its licence counts.
 */
@IsTest
private class TestDataFactoryTest {
  @IsTest
  static void csmUsersUsePlatformLicencesFirstAndGetCsmPermissionSet() {
    Map<String, Integer> free = TestDataFactory.freeLicences();
    Integer freePlatform = free.get('Salesforce Platform');

    List<User> users = TestDataFactory.createCsmUsers(
      2,
      new List<String>{ 'Beta', 'Alpha' }
    );

    // System mode: tests read results as the admin.
    Map<Id, User> saved = new Map<Id, User>(
      [
        SELECT Id, Name, FirstName, Profile.Name
        FROM User
        WHERE Id IN :users
        WITH SYSTEM_MODE
      ]
    );
    for (Integer i = 0; i < users.size(); i++) {
      String expectedProfile = i < freePlatform
        ? 'Standard Platform User'
        : 'Standard User';
      Assert.areEqual(expectedProfile, saved.get(users[i].Id).Profile.Name);
    }
    Assert.isNull(saved.get(users[0].Id).FirstName, 'No first name');
    Assert.areEqual(
      'Beta',
      saved.get(users[0].Id).Name,
      'Name is the last name'
    );
    Assert.areEqual(
      2,
      [
        SELECT COUNT()
        FROM PermissionSetAssignment
        WHERE AssigneeId IN :users AND PermissionSet.Name = 'Onboarding_CSM'
        WITH SYSTEM_MODE
      ],
      'Both have Onboarding_CSM'
    );
  }

  @IsTest
  static void csmUsersFailClearlyWhenLicencesRunOut() {
    Map<String, Integer> free = TestDataFactory.freeLicences();
    Integer freePlatform = free.get('Salesforce Platform');
    Integer freeSalesforce = free.get('Salesforce');
    Integer needed = freePlatform + freeSalesforce + 1;

    String message;
    try {
      TestDataFactory.createCsmUsers(needed, null);
    } catch (TestDataFactory.LicenceException e) {
      message = e.getMessage();
    }

    Assert.areEqual(
      'createCsmUsers needs ' +
        needed +
        ' user licences but only ' +
        freePlatform +
        ' Salesforce Platform and ' +
        freeSalesforce +
        ' Salesforce licences are free.',
      message
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM User
        WHERE Email = 'csm@onboarding-tracker.test'
        WITH SYSTEM_MODE
      ],
      'Nothing inserted'
    );
  }
}
