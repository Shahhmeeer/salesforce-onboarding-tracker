// Creates the 4 demo CSM users (spec 3.4) if they are missing, and makes the running admin the CS
// manager.
//
// - CSMs: Salesforce Platform licence, Standard Platform User profile, Onboarding_CSM.
// - Every CSM gets the running admin's time zone, locale, language and email (A31).
// - Usernames are <first>.<last>.<org id>@onboarding-tracker.demo, so they are unique per org and
//   nothing is hardcoded. The org Id is read at run time.
// - The running admin gets Onboarding_Manager and joins CS_Managers, so backlog alerts reach them.
//
// Safe to run twice: users, permission set assignments and group membership are only created when
// missing. Existing CSMs only have their time zone, locale and language corrected.
//
// Run as the admin: sf apex run --file scripts/apex/create-demo-users.apex
// Then run seed-csm-capacity.apex in a separate run (users and CSM Capacity records cannot be
// saved in the same transaction: Salesforce's mixed DML rule).

final String USERNAME_DOMAIN = '@onboarding-tracker.demo';
final String CSM_PROFILE = 'Standard Platform User';
final String CSM_PERMISSION_SET = 'Onboarding_CSM';
final String MANAGER_PERMISSION_SET = 'Onboarding_Manager';
final String MANAGER_GROUP = 'CS_Managers';

// First name, last name, alias. Listed in name order: seed-csm-capacity.apex gives limits
// 5, 7, 7, 10 in that order.
List<List<String>> csms = new List<List<String>>{
  new List<String>{ 'Avery', 'Brooks', 'abrooks' },
  new List<String>{ 'Jordan', 'Lee', 'jlee' },
  new List<String>{ 'Priya', 'Shah', 'pshah' },
  new List<String>{ 'Sam', 'Ortiz', 'sortiz' }
};

Id adminId = UserInfo.getUserId();
String orgKey = String.valueOf(UserInfo.getOrganizationId()).toLowerCase();
User admin = [
  SELECT TimeZoneSidKey, LocaleSidKey, LanguageLocaleKey, EmailEncodingKey, Email
  FROM User
  WHERE Id = :adminId
  WITH USER_MODE
];
Id csmProfileId = [SELECT Id FROM Profile WHERE Name = :CSM_PROFILE WITH USER_MODE LIMIT 1].Id;

Map<String, List<String>> specByUsername = new Map<String, List<String>>();
for (List<String> spec : csms) {
  specByUsername.put((spec[0] + '.' + spec[1] + '.' + orgKey + USERNAME_DOMAIN).toLowerCase(), spec);
}

Map<String, User> existingByUsername = new Map<String, User>();
for (User u : [
  SELECT Id, Username, TimeZoneSidKey, LocaleSidKey, LanguageLocaleKey
  FROM User
  WHERE Username IN :specByUsername.keySet()
  WITH USER_MODE
]) {
  existingByUsername.put(u.Username.toLowerCase(), u);
}

List<User> toInsert = new List<User>();
List<User> toUpdate = new List<User>();
for (String username : specByUsername.keySet()) {
  List<String> spec = specByUsername.get(username);
  User existing = existingByUsername.get(username);
  if (existing == null) {
    toInsert.add(
      new User(
        FirstName = spec[0],
        LastName = spec[1],
        Alias = spec[2],
        Username = username,
        Email = admin.Email,
        ProfileId = csmProfileId,
        TimeZoneSidKey = admin.TimeZoneSidKey,
        LocaleSidKey = admin.LocaleSidKey,
        LanguageLocaleKey = admin.LanguageLocaleKey,
        EmailEncodingKey = admin.EmailEncodingKey,
        // CRM Content feature licences are limited (Developer Edition has 2) and CSMs do not need one.
        UserPermissionsSFContentUser = false
      )
    );
  } else if (
    existing.TimeZoneSidKey != admin.TimeZoneSidKey ||
    existing.LocaleSidKey != admin.LocaleSidKey ||
    existing.LanguageLocaleKey != admin.LanguageLocaleKey
  ) {
    existing.TimeZoneSidKey = admin.TimeZoneSidKey;
    existing.LocaleSidKey = admin.LocaleSidKey;
    existing.LanguageLocaleKey = admin.LanguageLocaleKey;
    toUpdate.add(existing);
  }
}
insert as user toInsert;
update as user toUpdate;

// Who needs which permission set: every CSM gets Onboarding_CSM, the admin Onboarding_Manager.
Map<Id, String> permissionSetByUser = new Map<Id, String>{ adminId => MANAGER_PERMISSION_SET };
for (User u : existingByUsername.values()) {
  permissionSetByUser.put(u.Id, CSM_PERMISSION_SET);
}
for (User u : toInsert) {
  permissionSetByUser.put(u.Id, CSM_PERMISSION_SET);
}

Map<String, Id> permissionSetIds = new Map<String, Id>();
for (PermissionSet ps : [
  SELECT Id, Name
  FROM PermissionSet
  WHERE Name IN (:CSM_PERMISSION_SET, :MANAGER_PERMISSION_SET)
  WITH USER_MODE
]) {
  permissionSetIds.put(ps.Name, ps.Id);
}

Set<String> existingAssignments = new Set<String>();
for (PermissionSetAssignment psa : [
  SELECT AssigneeId, PermissionSetId
  FROM PermissionSetAssignment
  WHERE AssigneeId IN :permissionSetByUser.keySet() AND PermissionSetId IN :permissionSetIds.values()
  WITH USER_MODE
]) {
  existingAssignments.add(psa.AssigneeId + ':' + psa.PermissionSetId);
}
List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
for (Id userId : permissionSetByUser.keySet()) {
  Id permissionSetId = permissionSetIds.get(permissionSetByUser.get(userId));
  if (!existingAssignments.contains(userId + ':' + permissionSetId)) {
    assignments.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSetId));
  }
}
insert as user assignments;

// The admin joins CS_Managers, the group backlog alerts are sent to.
Group managers = [
  SELECT Id
  FROM Group
  WHERE Type = 'Regular' AND DeveloperName = :MANAGER_GROUP
  WITH USER_MODE
  LIMIT 1
];
List<GroupMember> members = new List<GroupMember>();
if ([SELECT COUNT() FROM GroupMember WHERE GroupId = :managers.Id AND UserOrGroupId = :adminId WITH USER_MODE] == 0) {
  members.add(new GroupMember(GroupId = managers.Id, UserOrGroupId = adminId));
}
insert as user members;

System.debug(
  LoggingLevel.ERROR,
  'Demo users: ' + toInsert.size() + ' CSMs created, ' + toUpdate.size() + ' updated, ' +
  assignments.size() + ' permission sets assigned, admin ' +
  (members.isEmpty() ? 'already in ' : 'added to ') + MANAGER_GROUP + '.'
);
